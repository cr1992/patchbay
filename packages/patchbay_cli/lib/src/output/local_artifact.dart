/// PB-050-20: tree-shaped commands spill their one unbounded member to a
/// local artifact once the stdout document that would carry it inline grows
/// past a threshold, and the response gets the same verified-receipt shape
/// the existing blob-download path already produces.
///
/// This file is deliberately not re-exported from `patchbay_cli.dart`: it is
/// an internal implementation detail of the CLI's own output shaping, not a
/// public SDK surface (see `docs/proposals/0.5.0/tree-artifact-output.md`).
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../artifact_download.dart';
import '../registry/command_spec.dart';
import '../result.dart';
import '../session/session_models.dart' show createRestrictedFileSync;
import '../trace/trace_context.dart';

/// Default inline-size ceiling, in UTF-8 bytes of the stdout document that
/// would otherwise carry the unbounded member. `--max-inline-bytes`
/// overrides it; `0` disables spilling entirely.
const int patchbayDefaultMaxInlineBytes = 65536;

/// Retention window for the automatic output directory: files older than
/// this are opportunistic-eviction candidates.
const Duration patchbayOutputRetentionAge = Duration(days: 7);

/// Retention cap for the automatic output directory's total size.
const int patchbayOutputRetentionMaxBytes = 128 * 1024 * 1024;

/// Hard ceiling on one rendered member, matching
/// `PatchbayArtifactDownloader.maxArtifactBytes`'s default and
/// `patchbayTraceMaxArtifactBytes`.
const int patchbayMaxLocalArtifactBytes = 64 * 1024 * 1024;

/// Resolves the automatic output directory: `PATCHBAY_OUTPUT_DIR` when set,
/// otherwise `$HOME/.patchbay/outputs/v1`. Throws `localArtifactWriteFailed`
/// when neither is available rather than guessing a path.
String defaultPatchbayOutputDirectory({Map<String, String>? environment}) {
  final Map<String, String> variables = environment ?? Platform.environment;
  final String? override = variables['PATCHBAY_OUTPUT_DIR']?.trim();
  if (override != null && override.isNotEmpty) return override;
  final String? home = variables['HOME'];
  if (home == null || home.isEmpty) {
    throw const PatchbayArtifactDownloadException('localArtifactWriteFailed');
  }
  return '$home/.patchbay/outputs/v1';
}

/// Writes one CLI-rendered member to disk, verified the same way
/// `PatchbayArtifactDownloader` verifies a downloaded blob: a restricted
/// temp file, a reread digest check, then an atomic rename.
///
/// One instance is meant to live for the whole process — a one-shot
/// invocation or a whole `repl` session — so the "never delete a file this
/// run already wrote" retention rule in
/// `docs/proposals/0.5.0/tree-artifact-output.md` has something to consult
/// across the many auto-path writes one repl session can produce.
final class PatchbayLocalArtifactWriter {
  final Set<String> _writtenThisRun = <String>{};

  Future<PatchbayDownloadedArtifact> write({
    required List<int> bytes,
    required String contentType,
    required String extension,
    required String commandSlug,
    String? outputPath,
    bool force = false,
    Map<String, String>? environment,
  }) async {
    if (bytes.length > patchbayMaxLocalArtifactBytes) {
      throw const PatchbayArtifactDownloadException('localArtifactTooLarge');
    }
    final String digest = sha256.convert(bytes).toString();
    final bool explicit = outputPath != null && outputPath.isNotEmpty;
    final File output;
    if (explicit) {
      output = File(outputPath).absolute;
      final Directory parent = output.parent;
      if (!parent.existsSync()) {
        throw const FormatException('--output parent directory does not exist');
      }
      if (!force && output.existsSync()) {
        throw const FormatException('--output already exists; use --force');
      }
    } else {
      final String directoryPath = defaultPatchbayOutputDirectory(
        environment: environment,
      );
      final Directory directory = Directory(directoryPath);
      try {
        if (!directory.existsSync()) directory.createSync(recursive: true);
      } on Object {
        throw const PatchbayArtifactDownloadException(
          'localArtifactWriteFailed',
        );
      }
      _pruneAutoDirectory(directory);
      final String fileName =
          '${_timestampSlug(DateTime.now().toUtc())}-$pid-'
          '$commandSlug-${digest.substring(0, 16)}.$extension';
      output = File('$directoryPath${Platform.pathSeparator}$fileName');
    }

    final File temporary = File(
      '${output.path}.patchbay-part-$pid-'
      '${DateTime.now().microsecondsSinceEpoch}',
    );
    var completed = false;
    try {
      final File created;
      try {
        created = createRestrictedFileSync(temporary.path);
        created.writeAsBytesSync(bytes, flush: true);
      } on Object {
        throw const PatchbayArtifactDownloadException(
          'localArtifactWriteFailed',
        );
      }
      final String rereadDigest;
      try {
        rereadDigest = sha256.convert(created.readAsBytesSync()).toString();
      } on Object {
        throw const PatchbayArtifactDownloadException(
          'localArtifactWriteFailed',
        );
      }
      if (rereadDigest != digest) {
        throw const PatchbayArtifactDownloadException(
          'localArtifactVerifyFailed',
        );
      }
      try {
        await temporary.rename(output.path);
      } on Object {
        throw const PatchbayArtifactDownloadException(
          'localArtifactWriteFailed',
        );
      }
      completed = true;
    } finally {
      if (!completed && temporary.existsSync()) {
        try {
          temporary.deleteSync();
        } on Object {
          // Best-effort cleanup; the exception already in flight wins.
        }
      }
    }
    _writtenThisRun.add(output.path);
    return PatchbayDownloadedArtifact(
      path: output.path,
      blobId: null,
      length: bytes.length,
      sha256: digest,
      contentType: contentType,
      origin: 'cliRendered',
    );
  }

  /// Opportunistic eviction of the automatic output directory, run just
  /// before a new auto-path write: age out anything past the retention
  /// window, then trim oldest-first until the directory is back under the
  /// byte cap. Never touches a path this run already wrote, and never
  /// touches an explicit `--output` path (the caller owns that one).
  ///
  /// Eviction failures are swallowed: retention is housekeeping, not a
  /// precondition for the write it runs ahead of.
  void _pruneAutoDirectory(Directory directory) {
    try {
      final DateTime now = DateTime.now();
      final List<File> candidates = directory
          .listSync()
          .whereType<File>()
          .where((File file) => !_writtenThisRun.contains(file.path))
          .toList();
      for (final File file in candidates) {
        if (now.difference(file.statSync().modified) >
            patchbayOutputRetentionAge) {
          _tryDelete(file);
        }
      }
      final List<File> remaining =
          directory
              .listSync()
              .whereType<File>()
              .where((File file) => !_writtenThisRun.contains(file.path))
              .toList()
            ..sort(
              (File a, File b) =>
                  a.statSync().modified.compareTo(b.statSync().modified),
            );
      int total = 0;
      final List<int> sizes = <int>[
        for (final File file in remaining) file.lengthSync(),
      ];
      for (final int size in sizes) {
        total += size;
      }
      for (var index = 0; index < remaining.length; index += 1) {
        if (total <= patchbayOutputRetentionMaxBytes) break;
        if (_tryDelete(remaining[index])) total -= sizes[index];
      }
    } on Object {
      // Listing the directory itself failed; nothing to evict.
    }
  }

  bool _tryDelete(File file) {
    try {
      file.deleteSync();
      return true;
    } on Object {
      return false;
    }
  }

  static String _timestampSlug(DateTime utc) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${utc.year.toString().padLeft(4, '0')}${two(utc.month)}'
        '${two(utc.day)}T${two(utc.hour)}${two(utc.minute)}'
        '${two(utc.second)}Z';
  }
}

/// Sentinel distinguishing "the dot path does not resolve" from "it resolves
/// to a JSON `null`" — the two are indistinguishable to a caller reading the
/// document, but only the former means the command declared a member it does
/// not actually publish.
const Object _missingDotPathMember = Object();

/// Whether the declared member carries nothing worth moving to a file.
///
/// Mirrors `brief_view.dart`'s rule of the same name deliberately: the two
/// layers must agree on what "there was nothing there" looks like, or a
/// response could be spilled by one and reported as present by the other.
bool _isEmptyMember(Object? value) =>
    value == null ||
    (value is String && value.isEmpty) ||
    (value is Iterable && value.isEmpty) ||
    (value is Map && value.isEmpty);

Object? _getAtDotPath(Map<String, Object?> root, List<String> segments) {
  Object? current = root;
  for (final String segment in segments) {
    if (current is Map && current.containsKey(segment)) {
      current = current[segment];
    } else {
      return _missingDotPathMember;
    }
  }
  return current;
}

/// Rebuilds [root] with the value at [segments] replaced by [replacement],
/// cloning only the ancestor maps on the path. Returns `null` — leaving
/// [root] untouched by the caller — when the path does not resolve to an
/// existing member, so a missing member renders inline rather than
/// fabricating structure.
Map<String, Object?>? _replaceAtDotPath(
  Map<String, Object?> root,
  List<String> segments,
  Object? replacement,
) {
  if (segments.isEmpty) return null;
  final String key = segments.first;
  if (!root.containsKey(key)) return null;
  if (segments.length == 1) {
    return <String, Object?>{...root, key: replacement};
  }
  final Object? child = root[key];
  if (child is! Map<String, Object?>) return null;
  final Map<String, Object?>? updatedChild = _replaceAtDotPath(
    child,
    segments.sublist(1),
    replacement,
  );
  if (updatedChild == null) return null;
  return <String, Object?>{...root, key: updatedChild};
}

/// Outcome of [maybeSpillRenderedMember]: the response to actually render,
/// and — only when a file was actually written this call — the artifact
/// that landed on disk.
final class PatchbayRenderedMemberSpillResult {
  const PatchbayRenderedMemberSpillResult({
    required this.response,
    this.artifact,
  });

  final Map<String, Object?> response;
  final PatchbayDownloadedArtifact? artifact;
}

/// Spills [spec]'s declared `spilledMember` out of [response] into a local
/// artifact when it must, and returns the response to actually render.
///
/// Order matters and is fixed by the proposal: [exitCode] must already be
/// the response's final classification (computed against the unspilled
/// response, before this call), and [renderDocument] must render the exact
/// document this call's rendering mode would print — one-shot `--json`
/// pretty, one-shot human summary, repl compact line, or repl human line —
/// so the threshold measures what the operator would actually have seen.
///
/// A non-`renderedMember` command, a command with no `spilledMember`, a
/// non-accepted [exitCode], or a `spilledMember` path that does not resolve
/// in [response] all return [response] unchanged: spilling never invents
/// structure and never hides a response that was not accepted.
Future<PatchbayRenderedMemberSpillResult> maybeSpillRenderedMember({
  required PatchbayLocalArtifactWriter writer,
  required PatchbayFriendlyCommandSpec? spec,
  required Map<String, Object?> response,
  required int exitCode,
  required String? explicitOutputPath,
  required bool force,
  required int maxInlineBytes,
  required String Function(Map<String, Object?> response) renderDocument,
  Map<String, String>? environment,
}) async {
  if (spec == null ||
      spec.artifact != PatchbayArtifactDisposition.renderedMember) {
    return PatchbayRenderedMemberSpillResult(response: response);
  }
  final String? dotPath = spec.spilledMember;
  if (dotPath == null) {
    return PatchbayRenderedMemberSpillResult(response: response);
  }
  if (exitCode != PatchbayExitCode.accepted) {
    return PatchbayRenderedMemberSpillResult(response: response);
  }
  final List<String> segments = dotPath.split('.');
  final Object? member = _getAtDotPath(response, segments);
  if (identical(member, _missingDotPathMember)) {
    return PatchbayRenderedMemberSpillResult(response: response);
  }

  final bool explicitOutput =
      explicitOutputPath != null && explicitOutputPath.isNotEmpty;
  if (!explicitOutput) {
    if (maxInlineBytes <= 0) {
      return PatchbayRenderedMemberSpillResult(response: response);
    }
    // An empty member is never spilled on the automatic path. Outside a debug
    // build the three Flutter diagnostic trees answer with exit 0 and an
    // empty `data` rather than a refusal (`tree-artifact-output.md`'s
    // profile note), and a receipt pointing at a file containing `null` would
    // claim a verified artifact of a tree that was never observed — while
    // also hiding the one fact the caller needed, that there was nothing
    // there. It also keeps `brief_view.dart`'s section-5.4 distinction
    // intact: an empty member stays visible in the document either way.
    //
    // An explicit `--output` is deliberately still unconditional: the
    // proposal freezes that path as "write the member to that path, whatever
    // its size", and the operator naming a file has asked for one.
    if (_isEmptyMember(member)) {
      return PatchbayRenderedMemberSpillResult(response: response);
    }
    final int documentBytes = utf8.encode(renderDocument(response)).length;
    if (documentBytes <= maxInlineBytes) {
      return PatchbayRenderedMemberSpillResult(response: response);
    }
  }

  final List<int> bytes;
  final String contentType;
  final String extension;
  if (member is String) {
    bytes = utf8.encode(member);
    contentType = 'text/plain; charset=utf-8';
    extension = 'txt';
  } else {
    bytes = utf8.encode(const JsonEncoder.withIndent('  ').convert(member));
    contentType = 'application/json';
    extension = 'json';
  }

  final PatchbayDownloadedArtifact artifact = await writer.write(
    bytes: bytes,
    contentType: contentType,
    extension: extension,
    commandSlug: spec.path.join('-'),
    outputPath: explicitOutput ? explicitOutputPath : null,
    force: force,
    environment: environment,
  );
  final Map<String, Object?> receipt = artifact.toJson();
  final Map<String, Object?>? replaced = _replaceAtDotPath(
    response,
    segments,
    receipt,
  );
  final Map<String, Object?> spilledResponse = <String, Object?>{
    ...(replaced ?? response),
    'localArtifact': receipt,
  };
  return PatchbayRenderedMemberSpillResult(
    response: spilledResponse,
    artifact: artifact,
  );
}

/// Records a spilled artifact against the active trace, exactly the way the
/// host-blob download path in `cli.dart` already records one.
///
/// `tree-artifact-output.md`'s reuse table lists `attachArtifact` — whose
/// `blobId` is already optional — as the trace seam for this condition, so a
/// `cliRendered` file is content-addressed into the trace directory and shows
/// up in `trace show` / `trace export` beside every `hostBlob` one. Without
/// this a trace taken over a spilling session would silently lose the only
/// copy of what the command actually observed, and `--include-artifacts`
/// would export a trace that points at a path outside it.
///
/// A no-op when nothing spilled or no trace is active. The call must happen
/// before the run's `command.finished` event, so the attachment lands inside
/// the run that produced it rather than at the head of the next one.
void attachSpilledArtifactToTrace(PatchbayDownloadedArtifact? artifact) {
  if (artifact == null) return;
  PatchbayTraceContext.currentRecorder?.attachArtifact(
    localPath: artifact.path,
    blobId: artifact.blobId,
    sha256Value: artifact.sha256,
    length: artifact.length,
    contentType: artifact.contentType,
  );
}
