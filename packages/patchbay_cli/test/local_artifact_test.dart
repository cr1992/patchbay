import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:patchbay/patchbay.dart';
import 'package:patchbay/patchbay_protocol.dart';
import 'package:patchbay_cli/src/artifact_download.dart';
import 'package:patchbay_cli/src/output/local_artifact.dart';
import 'package:patchbay_cli/src/result.dart';
import 'package:test/test.dart';

/// The declarations these tests spill under, written directly rather than
/// resolved through the registry — these tests are about the spill mechanics
/// themselves, not about resolution (covered in
/// `output_projection_resolution_test.dart`) or path matching (covered end to
/// end in `tree_artifact_output_test.dart`).
const PatchbayOutputProjection _nodesProjection = PatchbayOutputProjection(
  artifact: PatchbayOutputArtifactProjection.renderedMember(
    member: r'$.payload.nodes',
    encoding: PatchbayOutputArtifactEncoding.json,
  ),
);

/// The three Flutter diagnostic passthroughs' declaration: one member whose
/// media type follows the runtime shape, as 0.5.0 froze it.
const PatchbayOutputProjection _dataProjection = PatchbayOutputProjection(
  artifact: PatchbayOutputArtifactProjection.renderedMember(
    member: r'$.data',
    encoding: PatchbayOutputArtifactEncoding.jsonOrDecodedText,
  ),
);

const String _slug = 'fake-tree';

void main() {
  group('PatchbayLocalArtifactWriter', () {
    late Directory directory;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('patchbay-outputs-test-');
    });
    tearDown(() => directory.deleteSync(recursive: true));

    test(
      'explicit --output writes, verifies and reports cliRendered',
      () async {
        final File output = File('${directory.path}/tree.json');
        final List<int> bytes = utf8.encode('{"a":1}');
        final PatchbayDownloadedArtifact result =
            await PatchbayLocalArtifactWriter().write(
              bytes: bytes,
              contentType: 'application/json',
              extension: 'json',
              commandSlug: 'ui-semantics-tree',
              outputPath: output.path,
            );

        expect(output.readAsBytesSync(), bytes);
        expect(result.origin, 'cliRendered');
        expect(result.blobId, isNull);
        expect(result.length, bytes.length);
        expect(result.sha256, sha256.convert(bytes).toString());
        expect(result.toJson().containsKey('blobId'), isFalse);
        expect(
          directory.listSync().where(
            (FileSystemEntity e) => e.path.contains('.patchbay-part-'),
          ),
          isEmpty,
        );
      },
    );

    test(
      'explicit --output without --force refuses an existing file',
      () async {
        final File output = File('${directory.path}/tree.json')
          ..writeAsStringSync('keep');
        await expectLater(
          PatchbayLocalArtifactWriter().write(
            bytes: utf8.encode('new'),
            contentType: 'text/plain; charset=utf-8',
            extension: 'txt',
            commandSlug: 'ui-widget-tree',
            outputPath: output.path,
          ),
          throwsA(isA<FormatException>()),
        );
        expect(output.readAsStringSync(), 'keep');
      },
    );

    test('explicit --output --force replaces after verification', () async {
      final File output = File('${directory.path}/tree.json')
        ..writeAsStringSync('old');
      await PatchbayLocalArtifactWriter().write(
        bytes: utf8.encode('new'),
        contentType: 'text/plain; charset=utf-8',
        extension: 'txt',
        commandSlug: 'ui-widget-tree',
        outputPath: output.path,
        force: true,
      );
      expect(output.readAsStringSync(), 'new');
    });

    test(
      'explicit --output with a missing parent directory fails closed',
      () async {
        await expectLater(
          PatchbayLocalArtifactWriter().write(
            bytes: utf8.encode('x'),
            contentType: 'text/plain; charset=utf-8',
            extension: 'txt',
            commandSlug: 'ui-widget-tree',
            outputPath: '${directory.path}/does-not-exist/tree.txt',
          ),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test('auto path: PATCHBAY_OUTPUT_DIR is honoured and the filename shape is '
        'time-pid-slug-digest', () async {
      final List<int> bytes = utf8.encode('["node"]');
      final PatchbayDownloadedArtifact result =
          await PatchbayLocalArtifactWriter().write(
            bytes: bytes,
            contentType: 'application/json',
            extension: 'json',
            commandSlug: 'ui-semantics-tree',
            environment: <String, String>{
              'PATCHBAY_OUTPUT_DIR': directory.path,
            },
          );

      expect(result.path, startsWith(directory.path));
      final String fileName = result.path.split(Platform.pathSeparator).last;
      expect(
        fileName,
        matches(
          RegExp(r'^\d{8}T\d{6}Z-\d+-ui-semantics-tree-[0-9a-f]{16}\.json$'),
        ),
      );
      expect(File(result.path).readAsBytesSync(), bytes);
    });

    test('auto path with neither PATCHBAY_OUTPUT_DIR nor HOME set fails closed '
        'as localArtifactWriteFailed', () async {
      await expectLater(
        PatchbayLocalArtifactWriter().write(
          bytes: utf8.encode('x'),
          contentType: 'application/json',
          extension: 'json',
          commandSlug: 'ui-semantics-tree',
          environment: const <String, String>{},
        ),
        throwsA(
          isA<PatchbayArtifactDownloadException>().having(
            (PatchbayArtifactDownloadException e) => e.code,
            'code',
            'localArtifactWriteFailed',
          ),
        ),
      );
    });

    test('a member over the hard cap fails closed as localArtifactTooLarge '
        'without writing anything', () async {
      await expectLater(
        PatchbayLocalArtifactWriter().write(
          // `Uint8List`, not `List<int>.filled`: the latter boxes every
          // element in a regular growable-array slot, so a 64MB+1 buffer
          // costs far more than 64MB to allocate — measured 30-40x slower
          // than the typed-data equivalent, and under CI CPU contention that
          // gap has been observed to blow past `dart test`'s 30s default
          // timeout for a sibling test using the same pattern (see the
          // eviction test below). The content bytes are never inspected —
          // `write` rejects on `bytes.length` alone — so a zero-filled
          // buffer is equivalent to the original all-65s one for this test.
          bytes: Uint8List(patchbayMaxLocalArtifactBytes + 1),
          contentType: 'application/json',
          extension: 'json',
          commandSlug: 'ui-semantics-tree',
          environment: <String, String>{'PATCHBAY_OUTPUT_DIR': directory.path},
        ),
        throwsA(
          isA<PatchbayArtifactDownloadException>().having(
            (PatchbayArtifactDownloadException e) => e.code,
            'code',
            'localArtifactTooLarge',
          ),
        ),
      );
      expect(directory.listSync(), isEmpty);
    });

    test('opportunistic eviction ages out old files but keeps this run\'s '
        'writes', () async {
      final File stale = File('${directory.path}/stale.json')
        ..writeAsStringSync('old');
      final DateTime longAgo = DateTime.now().subtract(
        patchbayOutputRetentionAge + const Duration(days: 1),
      );
      stale.setLastModifiedSync(longAgo);

      final PatchbayLocalArtifactWriter writer = PatchbayLocalArtifactWriter();
      final PatchbayDownloadedArtifact first = await writer.write(
        bytes: utf8.encode('first'),
        contentType: 'text/plain; charset=utf-8',
        extension: 'txt',
        commandSlug: 'ui-widget-tree',
        environment: <String, String>{'PATCHBAY_OUTPUT_DIR': directory.path},
      );
      // A second write in the same run must not evict the first one, even
      // though nothing else protects it once it is no longer "new".
      await writer.write(
        bytes: utf8.encode('second'),
        contentType: 'text/plain; charset=utf-8',
        extension: 'txt',
        commandSlug: 'ui-render-tree',
        environment: <String, String>{'PATCHBAY_OUTPUT_DIR': directory.path},
      );

      expect(stale.existsSync(), isFalse);
      expect(File(first.path).existsSync(), isTrue);
    });

    test('opportunistic eviction trims oldest-first once the directory exceeds '
        'the byte cap, but never a path this run wrote', () async {
      final Map<String, String> environment = <String, String>{
        'PATCHBAY_OUTPUT_DIR': directory.path,
      };
      // Two old, unprotected files that together exceed the cap once a new
      // write needs room.
      //
      // This file's size is what matters to `_pruneAutoDirectory`'s byte-cap
      // check, never its content — `oldest.existsSync()` below is the only
      // assertion touching it. It used to be filled via
      // `List<int>.filled(patchbayOutputRetentionMaxBytes, 1)`: a plain
      // `List<int>` boxes every element instead of packing raw bytes, which
      // made both the fill and `writeAsBytesSync`'s internal byte conversion
      // far more expensive than the 128MB the buffer conceptually represents.
      // That overhead was invisible locally (sub-second, even saturating all
      // cores) but reproduced under a CPU-throttled container matching CI's
      // shared-runner shape: instrumented with a Stopwatch, the fill alone
      // took ~13.7s and the write ~10.3s — ~24s combined, against `dart
      // test`'s 30s default timeout, while every other step in this same
      // test (eviction scan, verify, rename) stayed under half a second even
      // under that same contention. That matches two real CI failures
      // (`TimeoutException after 0:00:30`) on branches that never touched
      // this file. `Uint8List` avoids the boxing entirely — same measured
      // scenario dropped to well under a second.
      final File oldest = File('${directory.path}/oldest.json')
        ..writeAsBytesSync(Uint8List(patchbayOutputRetentionMaxBytes));
      oldest.setLastModifiedSync(
        DateTime.now().subtract(const Duration(hours: 2)),
      );
      final File newerStale = File('${directory.path}/newer.json')
        ..writeAsBytesSync(utf8.encode('small'));
      newerStale.setLastModifiedSync(
        DateTime.now().subtract(const Duration(hours: 1)),
      );

      await PatchbayLocalArtifactWriter().write(
        bytes: utf8.encode('fresh'),
        contentType: 'application/json',
        extension: 'json',
        commandSlug: 'ui-semantics-tree',
        environment: environment,
      );

      // The oldest, largest file is the one eviction should reach for
      // first to get back under the cap.
      expect(oldest.existsSync(), isFalse);
    });
  });

  group('maybeSpillRenderedMember', () {
    late Directory directory;
    late PatchbayLocalArtifactWriter writer;
    late Map<String, String> environment;

    setUp(() {
      directory = Directory.systemTemp.createTempSync('patchbay-spill-test-');
      writer = PatchbayLocalArtifactWriter();
      environment = <String, String>{'PATCHBAY_OUTPUT_DIR': directory.path};
    });
    tearDown(() => directory.deleteSync(recursive: true));

    Map<String, Object?> _responseWithNodeCount(int nodeCount) =>
        <String, Object?>{
          'admission': 'accepted',
          'payload': <String, Object?>{
            'outcome': 'observed',
            'treeRevision': 1,
            'nodeCount': nodeCount,
            'nodes': <Object?>[
              for (var i = 0; i < nodeCount; i += 1)
                <String, Object?>{'nodeId': i, 'identifier': 'node-$i-padding'},
            ],
          },
        };

    String _prettyJson(Map<String, Object?> response) =>
        const JsonEncoder.withIndent('  ').convert(response);

    test('a declaration without an artifact is always identity', () async {
      final Map<String, Object?> response = _responseWithNodeCount(1);
      final PatchbayRenderedMemberSpillResult result =
          await maybeSpillRenderedMember(
            writer: writer,
            projection: null,
            commandSlug: _slug,
            response: response,
            exitCode: PatchbayExitCode.accepted,
            explicitOutputPath: null,
            force: false,
            maxInlineBytes: 1,
            renderDocument: _prettyJson,
            environment: environment,
          );
      expect(identical(result.response, response), isTrue);
      expect(result.artifact, isNull);
    });

    test(
      'a declared member that is absent renders inline without error',
      () async {
        final Map<String, Object?> response = <String, Object?>{
          'admission': 'accepted',
          'payload': <String, Object?>{'outcome': 'observed'},
        };
        final PatchbayRenderedMemberSpillResult result =
            await maybeSpillRenderedMember(
              writer: writer,
              projection: _nodesProjection,
              commandSlug: _slug,
              response: response,
              exitCode: PatchbayExitCode.accepted,
              explicitOutputPath: null,
              force: false,
              maxInlineBytes: 1,
              renderDocument: _prettyJson,
              environment: environment,
            );
        expect(result.response, response);
        expect(result.artifact, isNull);
      },
    );

    test(
      'a non-accepted exit code never spills, however large the document',
      () async {
        final Map<String, Object?> response = _responseWithNodeCount(5000);
        final PatchbayRenderedMemberSpillResult result =
            await maybeSpillRenderedMember(
              writer: writer,
              projection: _nodesProjection,
              commandSlug: _slug,
              response: response,
              exitCode: PatchbayExitCode.typedFailure,
              explicitOutputPath: null,
              force: false,
              maxInlineBytes: 1,
              renderDocument: _prettyJson,
              environment: environment,
            );
        expect(identical(result.response, response), isTrue);
      },
    );

    test('--max-inline-bytes 0 disables spilling entirely', () async {
      final Map<String, Object?> response = _responseWithNodeCount(5000);
      final PatchbayRenderedMemberSpillResult result =
          await maybeSpillRenderedMember(
            writer: writer,
            projection: _nodesProjection,
            commandSlug: _slug,
            response: response,
            exitCode: PatchbayExitCode.accepted,
            explicitOutputPath: null,
            force: false,
            maxInlineBytes: 0,
            renderDocument: _prettyJson,
            environment: environment,
          );
      expect(identical(result.response, response), isTrue);
    });

    test('threshold boundary: exactly at the ceiling stays inline, one byte '
        'over spills', () async {
      // The ceiling is derived from the document's own measured length,
      // so this pins the exact `<=` boundary byte-for-byte rather than
      // hoping a coarse-grained node count happens to land on it.
      final Map<String, Object?> response = _responseWithNodeCount(37);
      final int exactSize = utf8.encode(_prettyJson(response)).length;

      final PatchbayRenderedMemberSpillResult atCeiling =
          await maybeSpillRenderedMember(
            writer: writer,
            projection: _nodesProjection,
            commandSlug: _slug,
            response: response,
            exitCode: PatchbayExitCode.accepted,
            explicitOutputPath: null,
            force: false,
            maxInlineBytes: exactSize,
            renderDocument: _prettyJson,
            environment: environment,
          );
      expect(
        atCeiling.artifact,
        isNull,
        reason: 'documentBytes == ceiling must stay inline',
      );
      expect(
        (atCeiling.response['payload']! as Map<String, Object?>)['nodes'],
        isA<List<Object?>>(),
      );

      final PatchbayRenderedMemberSpillResult overCeiling =
          await maybeSpillRenderedMember(
            writer: writer,
            projection: _nodesProjection,
            commandSlug: _slug,
            response: response,
            exitCode: PatchbayExitCode.accepted,
            explicitOutputPath: null,
            force: false,
            maxInlineBytes: exactSize - 1,
            renderDocument: _prettyJson,
            environment: environment,
          );
      expect(
        overCeiling.artifact,
        isNotNull,
        reason: 'documentBytes == ceiling + 1 must spill',
      );
      final Object? nodesAfterSpill =
          (overCeiling.response['payload']! as Map<String, Object?>)['nodes'];
      expect(nodesAfterSpill, isA<Map<String, Object?>>());
      // Bounded facts a caller needs to decide the next step stay inline.
      expect(
        (overCeiling.response['payload']!
            as Map<String, Object?>)['treeRevision'],
        1,
      );
    });

    test('a spilled JSON member is byte-identical to its would-be inline '
        'rendering, and the receipt sha256 matches the file on disk', () async {
      final Map<String, Object?> response = _responseWithNodeCount(5000);
      final List<Object?> nodes =
          (response['payload']! as Map<String, Object?>)['nodes']!
              as List<Object?>;
      final PatchbayRenderedMemberSpillResult result =
          await maybeSpillRenderedMember(
            writer: writer,
            projection: _nodesProjection,
            commandSlug: _slug,
            response: response,
            exitCode: PatchbayExitCode.accepted,
            explicitOutputPath: null,
            force: false,
            maxInlineBytes: 1,
            renderDocument: _prettyJson,
            environment: environment,
          );
      final PatchbayDownloadedArtifact artifact = result.artifact!;
      final List<int> onDisk = File(artifact.path).readAsBytesSync();
      expect(
        utf8.decode(onDisk),
        const JsonEncoder.withIndent('  ').convert(nodes),
      );
      expect(sha256.convert(onDisk).toString(), artifact.sha256);
      expect(artifact.contentType, 'application/json');
    });

    test(
      'a spilled text member is written as decoded text, not a JSON string',
      () async {
        const String dump = 'FocusManager\n  focus: rootScope\n    child: x\n';
        final Map<String, Object?> response = <String, Object?>{
          'source': 'uiObserved',
          'plane': 'flutterDiagnostic',
          'data': dump * 5000,
        };
        final PatchbayRenderedMemberSpillResult result =
            await maybeSpillRenderedMember(
              writer: writer,
              projection: _dataProjection,
              commandSlug: _slug,
              response: response,
              exitCode: PatchbayExitCode.accepted,
              explicitOutputPath: null,
              force: false,
              maxInlineBytes: 1,
              renderDocument: (Map<String, Object?> r) =>
                  const JsonEncoder.withIndent('  ').convert(r),
              environment: environment,
            );
        final PatchbayDownloadedArtifact artifact = result.artifact!;
        expect(artifact.contentType, 'text/plain; charset=utf-8');
        expect(File(artifact.path).readAsStringSync(), dump * 5000);
        // Never JSON-quoted: no leading/trailing `"` and no `\n` escapes.
        final String onDisk = File(artifact.path).readAsStringSync();
        expect(onDisk.startsWith('"'), isFalse);
        expect(onDisk, contains('\n'));
      },
    );

    test('the top-level localArtifact and the in-place receipt are the same '
        'object', () async {
      final Map<String, Object?> response = _responseWithNodeCount(5000);
      final PatchbayRenderedMemberSpillResult result =
          await maybeSpillRenderedMember(
            writer: writer,
            projection: _nodesProjection,
            commandSlug: _slug,
            response: response,
            exitCode: PatchbayExitCode.accepted,
            explicitOutputPath: null,
            force: false,
            maxInlineBytes: 1,
            renderDocument: _prettyJson,
            environment: environment,
          );
      final Object? inPlace =
          (result.response['payload']! as Map<String, Object?>)['nodes'];
      expect(identical(result.response['localArtifact'], inPlace), isTrue);
    });

    group('an empty member is never spilled on the automatic path', () {
      // Outside a debug build the three Flutter diagnostic trees answer exit
      // 0 with an empty `data` rather than a refusal
      // (`tree-artifact-output.md`'s profile note). Spilling that would put a
      // "verified artifact" receipt in front of a file holding `null`, and
      // would hide the one fact the caller needed: there was nothing there.
      for (final MapEntry<String, Object?> shape in <String, Object?>{
        'a null member': null,
        'an empty list': const <Object?>[],
        'an empty map': const <String, Object?>{},
        'an empty string': '',
      }.entries) {
        test('${shape.key} renders inline and writes no file', () async {
          final Map<String, Object?> response = <String, Object?>{
            'source': 'uiObserved',
            'plane': 'flutterDiagnostic',
            'data': shape.value,
          };
          final PatchbayRenderedMemberSpillResult result =
              await maybeSpillRenderedMember(
                writer: writer,
                projection: _dataProjection,
                commandSlug: _slug,
                response: response,
                exitCode: PatchbayExitCode.accepted,
                explicitOutputPath: null,
                force: false,
                // A ceiling of 1 byte would spill anything spillable, so
                // nothing but the emptiness of the member can be keeping
                // this inline.
                maxInlineBytes: 1,
                renderDocument: _prettyJson,
                environment: environment,
              );
          expect(identical(result.response, response), isTrue);
          expect(result.artifact, isNull);
          expect(result.response.containsKey('data'), isTrue);
          expect(result.response.containsKey('localArtifact'), isFalse);
          expect(directory.listSync(), isEmpty);
        });
      }

      test('an explicit --output still writes an empty member: the operator '
          'named a file and the proposal freezes that path as '
          'unconditional', () async {
        final File output = File('${directory.path}/empty.json');
        final PatchbayRenderedMemberSpillResult result =
            await maybeSpillRenderedMember(
              writer: writer,
              projection: _dataProjection,
              commandSlug: _slug,
              response: <String, Object?>{'data': const <Object?>[]},
              exitCode: PatchbayExitCode.accepted,
              explicitOutputPath: output.path,
              force: false,
              maxInlineBytes: patchbayDefaultMaxInlineBytes,
              renderDocument: _prettyJson,
              environment: environment,
            );
        expect(result.artifact!.path, output.path);
        expect(output.readAsStringSync(), '[]');
      });
    });

    test(
      'an explicit --output always spills, even under the inline ceiling',
      () async {
        final File output = File('${directory.path}/explicit.json');
        final Map<String, Object?> response = _responseWithNodeCount(1);
        final PatchbayRenderedMemberSpillResult result =
            await maybeSpillRenderedMember(
              writer: writer,
              projection: _nodesProjection,
              commandSlug: _slug,
              response: response,
              exitCode: PatchbayExitCode.accepted,
              explicitOutputPath: output.path,
              force: false,
              maxInlineBytes: patchbayDefaultMaxInlineBytes,
              renderDocument: _prettyJson,
              environment: environment,
            );
        expect(result.artifact!.path, output.path);
        expect(output.existsSync(), isTrue);
      },
    );
  });
}
