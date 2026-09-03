import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:patchbay/patchbay_protocol.dart';

final class PatchbayPlatformCommandResult {
  const PatchbayPlatformCommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

typedef PatchbayPlatformCommandRunner =
    Future<PatchbayPlatformCommandResult> Function(
      String executable,
      List<String> arguments,
      Duration timeout,
    );

abstract interface class PatchbayPermissionPlatformAdapter {
  Future<PatchbayPermissionDriverResponse> handle(
    PatchbayPermissionDriverRequest request,
  );
}

/// One-frame JSON Lines host for source-distributed platform adapters.
Future<int> runPatchbayPermissionPlatformAdapter(
  PatchbayPermissionPlatformAdapter adapter, {
  Stream<List<int>>? input,
  StringSink? output,
  StringSink? errorOutput,
}) async {
  final StringSink out = output ?? stdout;
  final StringSink err = errorOutput ?? stderr;
  try {
    final List<String> lines = await (input ?? stdin)
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .where((String line) => line.trim().isNotEmpty)
        .take(2)
        .toList();
    if (lines.length != 1 || utf8.encode(lines.single).length > 1024 * 1024) {
      throw const PatchbayPermissionWireException(
        'permissionDriverRequestInvalid',
      );
    }
    final Object? decoded = jsonDecode(lines.single);
    if (decoded is! Map<String, dynamic>) {
      throw const PatchbayPermissionWireException(
        'permissionDriverRequestInvalid',
      );
    }
    final PatchbayPermissionDriverRequest request =
        PatchbayPermissionDriverRequest.fromJson(
          Map<String, Object?>.from(decoded),
        );
    if (patchbayPermissionProtocolMajorOf(request.protocolVersion) !=
        patchbayPermissionProtocolMajor) {
      out.writeln(
        jsonEncode(
          rejectedPermissionDriverResponse(
            request,
            'platformDriverVersionMismatch',
          ).toJson(),
        ),
      );
      return 0;
    }
    out.writeln(jsonEncode((await adapter.handle(request)).toJson()));
    return 0;
  } on PatchbayPermissionWireException catch (failure) {
    err.writeln(failure.code);
    return 64;
  } on FormatException {
    err.writeln('permissionDriverRequestInvalid');
    return 64;
  } on Object catch (failure) {
    err.writeln(failure.runtimeType);
    return 70;
  }
}

PatchbayPermissionDriverResponse acceptedPermissionDriverResponse(
  PatchbayPermissionDriverRequest request, {
  PatchbayPermissionCapabilities? capabilities,
  PatchbayPermissionStatus? before,
  PatchbayPermissionStatus? after,
  List<PatchbayPermissionEvidence> evidence =
      const <PatchbayPermissionEvidence>[],
  PatchbayPermissionInterruption? interruption,
  String? notice,
}) => PatchbayPermissionDriverResponse(
  protocolVersion: patchbayPermissionProtocolVersion,
  requestId: request.requestId,
  admission: 'accepted',
  capabilities: capabilities,
  before: before,
  after: after,
  evidence: evidence,
  interruption: interruption,
  notice: notice,
);

PatchbayPermissionDriverResponse rejectedPermissionDriverResponse(
  PatchbayPermissionDriverRequest request,
  String code, {
  Map<String, Object?> details = const <String, Object?>{},
  List<PatchbayPermissionEvidence> evidence =
      const <PatchbayPermissionEvidence>[],
  String? notice,
}) => PatchbayPermissionDriverResponse(
  protocolVersion: patchbayPermissionProtocolVersion,
  requestId: request.requestId,
  admission: 'rejected',
  code: code,
  details: details,
  evidence: evidence,
  notice: notice,
);

Future<PatchbayPlatformCommandResult> runPatchbayPlatformCommand(
  String executable,
  List<String> arguments,
  Duration timeout,
) async {
  final Process process;
  try {
    process = await Process.start(executable, arguments).timeout(timeout);
  } on Object {
    return const PatchbayPlatformCommandResult(
      exitCode: 127,
      stdout: '',
      stderr: 'unavailable',
    );
  }
  try {
    final List<Object> result = await Future.wait<Object>(<Future<Object>>[
      process.exitCode,
      process.stdout.transform(utf8.decoder).join(),
      process.stderr.transform(utf8.decoder).join(),
    ]).timeout(timeout);
    return PatchbayPlatformCommandResult(
      exitCode: result[0] as int,
      stdout: result[1] as String,
      stderr: result[2] as String,
    );
  } on TimeoutException {
    process.kill();
    return const PatchbayPlatformCommandResult(
      exitCode: 124,
      stdout: '',
      stderr: 'timeout',
    );
  }
}

Duration permissionAdapterTimeout(PatchbayPermissionDriverRequest request) =>
    Duration(milliseconds: request.timeoutMs);
