import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:patchbay/patchbay.dart';

const String patchbayPermissionDriverEnvironment = 'PATCHBAY_PERMISSION_DRIVER';
const String patchbayPermissionDriverExecutable = 'patchbay-permission-driver';

typedef PatchbayPermissionProcessStarter =
    Future<Process> Function(String executable, List<String> arguments);

final class PatchbayPermissionDriverException implements Exception {
  const PatchbayPermissionDriverException(
    this.code, {
    this.details = const <String, Object?>{},
    this.diagnostic,
  });

  final String code;
  final Map<String, Object?> details;

  /// Human-only driver stderr, never interpreted as protocol or copied to the
  /// machine response.
  final String? diagnostic;

  @override
  String toString() => 'PatchbayPermissionDriverException($code)';
}

final class PatchbayPermissionDriverDiscovery {
  const PatchbayPermissionDriverDiscovery({
    this.environment,
    this.platformEnvironment,
  });

  final Map<String, String>? environment;
  final Map<String, String>? platformEnvironment;

  String resolve({String? configuredPath}) {
    final Map<String, String> variables =
        environment ?? platformEnvironment ?? Platform.environment;
    final String? selected =
        _nonEmpty(configuredPath) ??
        _nonEmpty(variables[patchbayPermissionDriverEnvironment]);
    if (selected != null) {
      final String? resolved = _resolveCandidate(selected);
      if (resolved != null) return resolved;
      throw const PatchbayPermissionDriverException(
        'platformDriverUnavailable',
      );
    }
    final String? path = variables['PATH'];
    if (path != null) {
      for (final String directory in path.split(
        Platform.isWindows ? ';' : ':',
      )) {
        if (directory.isEmpty) continue;
        final String candidate =
            '$directory${Platform.pathSeparator}'
            '$patchbayPermissionDriverExecutable';
        final String? resolved = _resolveCandidate(candidate);
        if (resolved != null) return resolved;
      }
    }
    throw const PatchbayPermissionDriverException('platformDriverUnavailable');
  }

  static String? _nonEmpty(String? value) {
    final String? trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  static String? _resolveCandidate(String candidate) {
    final File file = File(candidate).absolute;
    if (!file.existsSync()) return null;
    if (!Platform.isWindows) {
      final int mode = file.statSync().mode;
      if (mode & 0x49 == 0) return null;
    }
    return file.resolveSymbolicLinksSync();
  }
}

final class PatchbayPermissionBudget {
  const PatchbayPermissionBudget._(this.defaultDuration, this.maximumDuration);

  static const PatchbayPermissionBudget read = PatchbayPermissionBudget._(
    Duration(seconds: 10),
    Duration(seconds: 30),
  );
  static const PatchbayPermissionBudget write = PatchbayPermissionBudget._(
    Duration(seconds: 30),
    Duration(seconds: 120),
  );
  static const PatchbayPermissionBudget exercise = PatchbayPermissionBudget._(
    Duration(seconds: 120),
    Duration(seconds: 180),
  );

  final Duration defaultDuration;
  final Duration maximumDuration;

  Duration validate(Duration? requested) {
    final Duration value = requested ?? defaultDuration;
    if (value <= Duration.zero || value > maximumDuration) {
      throw PatchbayPermissionDriverException(
        'permissionTimeoutInvalid',
        details: <String, Object?>{'maximumMs': maximumDuration.inMilliseconds},
      );
    }
    return value;
  }

  static PatchbayPermissionBudget forOperation(
    PatchbayPermissionOperation operation,
  ) => switch (operation) {
    PatchbayPermissionOperation.capabilities ||
    PatchbayPermissionOperation.status ||
    PatchbayPermissionOperation.fail => read,
    PatchbayPermissionOperation.normalize ||
    PatchbayPermissionOperation.reset => write,
    PatchbayPermissionOperation.exercise => exercise,
  };
}

/// One-request JSON Lines client for an explicitly installed external driver.
///
/// stdout must contain exactly one machine frame. stderr is collected only for
/// human diagnostics and is never parsed into a decision.
final class PatchbayPermissionDriverClient {
  PatchbayPermissionDriverClient({
    required this.executable,
    PatchbayPermissionProcessStarter? startProcess,
    this.maxOutputBytes = 1024 * 1024,
  }) : _startProcess = startProcess ?? _start;

  final String executable;
  final PatchbayPermissionProcessStarter _startProcess;
  final int maxOutputBytes;

  Future<PatchbayPermissionDriverResponse> call(
    PatchbayPermissionDriverRequest request, {
    required Duration timeout,
  }) async {
    if (timeout <= Duration.zero) {
      throw const PatchbayPermissionDriverException('budgetExceeded');
    }
    final Stopwatch elapsed = Stopwatch()..start();
    final Process process;
    try {
      process = await _startProcess(
        executable,
        const <String>[],
      ).timeout(timeout);
    } on TimeoutException {
      throw const PatchbayPermissionDriverException('budgetExceeded');
    } on Object {
      throw const PatchbayPermissionDriverException(
        'platformDriverUnavailable',
      );
    }

    try {
      process.stdin.writeln(jsonEncode(request.toJson()));
      await process.stdin.close().timeout(_remaining(timeout, elapsed));
    } on TimeoutException {
      process.kill();
      throw const PatchbayPermissionDriverException('budgetExceeded');
    } on PatchbayPermissionDriverException {
      process.kill();
      rethrow;
    } on Object {
      process.kill();
      throw const PatchbayPermissionDriverException(
        'platformDriverProtocolError',
      );
    }
    final Future<List<int>> stdoutBytes = _readBounded(process.stdout);
    final Future<List<int>> stderrBytes = _readBounded(process.stderr);
    late final List<Object> completed;
    try {
      completed = await Future.wait<Object>(<Future<Object>>[
        process.exitCode,
        stdoutBytes,
        stderrBytes,
      ]).timeout(_remaining(timeout, elapsed));
    } on TimeoutException {
      process.kill();
      throw const PatchbayPermissionDriverException('budgetExceeded');
    } on PatchbayPermissionDriverException {
      process.kill();
      rethrow;
    } on Object {
      process.kill();
      throw const PatchbayPermissionDriverException(
        'platformDriverProtocolError',
      );
    }

    final int exitCode = completed[0] as int;
    final String stdoutText = utf8.decode(completed[1] as List<int>);
    final String stderrText = utf8
        .decode(completed[2] as List<int>, allowMalformed: true)
        .trim();
    final List<String> frames = const LineSplitter()
        .convert(stdoutText)
        .where((String line) => line.trim().isNotEmpty)
        .toList(growable: false);
    if (frames.length != 1) {
      throw PatchbayPermissionDriverException(
        'platformDriverProtocolError',
        diagnostic: stderrText.isEmpty ? null : stderrText,
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(frames.single);
    } on FormatException {
      throw PatchbayPermissionDriverException(
        'platformDriverProtocolError',
        diagnostic: stderrText.isEmpty ? null : stderrText,
      );
    }
    if (decoded is! Map<String, dynamic>) {
      throw PatchbayPermissionDriverException(
        'platformDriverProtocolError',
        diagnostic: stderrText.isEmpty ? null : stderrText,
      );
    }
    final PatchbayPermissionDriverResponse response;
    try {
      response = PatchbayPermissionDriverResponse.fromJson(
        Map<String, Object?>.from(decoded),
      );
    } on PatchbayPermissionWireException catch (failure) {
      throw PatchbayPermissionDriverException(
        failure.code,
        diagnostic: stderrText.isEmpty ? null : stderrText,
      );
    }
    final int responseMajor;
    try {
      responseMajor = patchbayPermissionProtocolMajorOf(
        response.protocolVersion,
      );
    } on PatchbayPermissionWireException {
      throw PatchbayPermissionDriverException(
        'platformDriverVersionMismatch',
        details: <String, Object?>{
          'expectedMajor': patchbayPermissionProtocolMajor,
          'actualVersion': response.protocolVersion,
        },
        diagnostic: stderrText.isEmpty ? null : stderrText,
      );
    }
    if (responseMajor != patchbayPermissionProtocolMajor) {
      throw PatchbayPermissionDriverException(
        'platformDriverVersionMismatch',
        details: <String, Object?>{
          'expectedMajor': patchbayPermissionProtocolMajor,
          'actualVersion': response.protocolVersion,
        },
        diagnostic: stderrText.isEmpty ? null : stderrText,
      );
    }
    if (response.requestId != request.requestId) {
      throw PatchbayPermissionDriverException(
        'platformDriverRequestMismatch',
        diagnostic: stderrText.isEmpty ? null : stderrText,
      );
    }
    if (exitCode != 0) {
      throw PatchbayPermissionDriverException(
        'platformDriverFailed',
        details: <String, Object?>{'exitCode': exitCode},
        diagnostic: stderrText.isEmpty ? null : stderrText,
      );
    }
    if (response.accepted &&
        request.operation == PatchbayPermissionOperation.capabilities &&
        response.capabilities == null) {
      throw PatchbayPermissionDriverException(
        'permissionCapabilityInvalid',
        diagnostic: stderrText.isEmpty ? null : stderrText,
      );
    }
    if (response.accepted &&
        request.operation == PatchbayPermissionOperation.status &&
        response.before == null &&
        response.after == null) {
      throw PatchbayPermissionDriverException(
        'permissionStatusInvalid',
        diagnostic: stderrText.isEmpty ? null : stderrText,
      );
    }
    return response;
  }

  Future<List<int>> _readBounded(Stream<List<int>> stream) async {
    final List<int> bytes = <int>[];
    await for (final List<int> chunk in stream) {
      if (bytes.length + chunk.length > maxOutputBytes) {
        throw const PatchbayPermissionDriverException(
          'platformDriverResponseTooLarge',
        );
      }
      bytes.addAll(chunk);
    }
    return bytes;
  }

  static Future<Process> _start(String executable, List<String> arguments) =>
      Process.start(executable, arguments);

  static Duration _remaining(Duration budget, Stopwatch elapsed) {
    final Duration remaining = budget - elapsed.elapsed;
    if (remaining <= Duration.zero) {
      throw const PatchbayPermissionDriverException('budgetExceeded');
    }
    return remaining;
  }
}

/// Performs capability preflight and the requested operation under one budget.
final class PatchbayPermissionDriverRunner {
  PatchbayPermissionDriverRunner(this.client);

  final PatchbayPermissionDriverClient client;

  Future<PatchbayPermissionDriverResponse> run(
    PatchbayPermissionDriverRequest request, {
    Duration? timeout,
  }) async {
    _validateRequestShape(request);
    final Duration budget = PatchbayPermissionBudget.forOperation(
      request.operation,
    ).validate(timeout);
    final Stopwatch elapsed = Stopwatch()..start();
    if (request.operation == PatchbayPermissionOperation.capabilities) {
      final PatchbayPermissionDriverResponse response = await client.call(
        _withTimeout(request, budget.inMilliseconds),
        timeout: budget,
      );
      _requireCapabilities(response);
      return response;
    }

    final PatchbayPermissionDriverResponse preflight = await client.call(
      PatchbayPermissionDriverRequest(
        requestId: '${request.requestId}.capabilities',
        operation: PatchbayPermissionOperation.capabilities,
        deviceId: request.deviceId,
        applicationId: request.applicationId,
        sessionRef: request.sessionRef,
        timeoutMs: budget.inMilliseconds,
      ),
      timeout: budget,
    );
    if (!preflight.accepted) return preflight;
    final PatchbayPermissionCapabilities? capabilities = preflight.capabilities;
    if (capabilities == null) {
      throw const PatchbayPermissionDriverException(
        'permissionCapabilityInvalid',
      );
    }
    final String? permission = request.permission;
    final PatchbayPermissionCapability? capability = permission == null
        ? null
        : capabilities.permissions[permission];
    if (permission == null || capability == null) {
      throw const PatchbayPermissionDriverException('permissionUnsupported');
    }
    final PatchbayPermissionAction required = _requiredAction(request);
    if (!capability.actions.contains(required)) {
      throw const PatchbayPermissionDriverException('permissionUnsupported');
    }
    if (request.operation == PatchbayPermissionOperation.normalize &&
        !capability.actions.contains(PatchbayPermissionAction.status)) {
      throw const PatchbayPermissionDriverException('permissionUnsupported');
    }
    if (request.decision case final PatchbayPermissionDecision decision
        when !capability.decisions.contains(decision)) {
      throw const PatchbayPermissionDriverException(
        'permissionDecisionUnsupported',
      );
    }
    final Duration remaining = budget - elapsed.elapsed;
    if (remaining <= Duration.zero) {
      throw const PatchbayPermissionDriverException('budgetExceeded');
    }
    final PatchbayPermissionDriverRequest driverRequest =
        request.operation == PatchbayPermissionOperation.fail
        ? PatchbayPermissionDriverRequest(
            protocolVersion: request.protocolVersion,
            requestId: request.requestId,
            operation: PatchbayPermissionOperation.status,
            deviceId: request.deviceId,
            applicationId: request.applicationId,
            sessionRef: request.sessionRef,
            permission: request.permission,
            policy: PatchbayPermissionOperation.fail.name,
            timeoutMs: max(1, remaining.inMilliseconds),
          )
        : _withTimeout(request, remaining.inMilliseconds);
    final PatchbayPermissionDriverResponse operation = await client.call(
      driverRequest,
      timeout: remaining,
    );
    if (!operation.accepted) {
      return operation;
    }
    if (request.operation == PatchbayPermissionOperation.status ||
        request.operation == PatchbayPermissionOperation.fail) {
      final PatchbayPermissionStatus observed = _requireStatus(operation);
      if (request.operation == PatchbayPermissionOperation.fail &&
          observed.state != request.state) {
        return PatchbayPermissionDriverResponse(
          protocolVersion: operation.protocolVersion,
          requestId: request.requestId,
          admission: 'rejected',
          code: 'permissionStateMismatch',
          details: <String, Object?>{
            'expected': request.state!.name,
            'actual': observed.state.name,
          },
          before: operation.before,
          after: operation.after,
          evidence: operation.evidence,
          notice: operation.notice,
        );
      }
      return operation;
    }

    // simctl privacy exposes an authoritative reset operation but no public
    // status query. A reset-only driver may therefore return the reset fact
    // itself; it must be device-reported and exactly notDetermined. Drivers
    // that do declare status still take the independent verification path.
    if (request.operation == PatchbayPermissionOperation.reset &&
        !capability.actions.contains(PatchbayPermissionAction.status)) {
      final PatchbayPermissionStatus reset = _requireStatus(operation);
      if (reset.state != PatchbayPermissionState.notDetermined ||
          reset.factSource != PatchbayPermissionFactSource.deviceReported) {
        throw const PatchbayPermissionDriverException(
          'permissionStatusInvalid',
        );
      }
      return operation;
    }
    if (request.operation == PatchbayPermissionOperation.exercise &&
        !capability.actions.contains(PatchbayPermissionAction.status)) {
      final PatchbayPermissionStatus exercised = _requireStatus(operation);
      final PatchbayPermissionInterruption? interruption =
          operation.interruption;
      if (exercised.state == PatchbayPermissionState.unknown ||
          interruption == null ||
          !interruption.expected ||
          !interruption.handled ||
          interruption.permission != request.permission ||
          interruption.decision != request.decision) {
        throw const PatchbayPermissionDriverException('systemUiUnexpected');
      }
      return operation;
    }

    // A successful mutation exit code is not a permission fact. Read the state
    // again under the same total budget and make that observation authoritative.
    final Duration verificationRemaining = budget - elapsed.elapsed;
    if (verificationRemaining <= Duration.zero) {
      throw const PatchbayPermissionDriverException('budgetExceeded');
    }
    final PatchbayPermissionDriverResponse verification = await client.call(
      PatchbayPermissionDriverRequest(
        requestId: '${request.requestId}.verify',
        operation: PatchbayPermissionOperation.status,
        deviceId: request.deviceId,
        applicationId: request.applicationId,
        sessionRef: request.sessionRef,
        permission: request.permission,
        policy: request.policy,
        timeoutMs: verificationRemaining.inMilliseconds,
      ),
      timeout: verificationRemaining,
    );
    if (!verification.accepted) return verification;
    final PatchbayPermissionStatus verified = _requireStatus(verification);
    final PatchbayPermissionState? expectedState = switch (request.operation) {
      PatchbayPermissionOperation.normalize => request.state,
      PatchbayPermissionOperation.reset =>
        PatchbayPermissionState.notDetermined,
      _ => null,
    };
    if (expectedState != null && verified.state != expectedState) {
      return PatchbayPermissionDriverResponse(
        protocolVersion: verification.protocolVersion,
        requestId: request.requestId,
        admission: 'rejected',
        code: 'permissionStateMismatch',
        details: <String, Object?>{
          'expected': expectedState.name,
          'actual': verified.state.name,
        },
        before: operation.before,
        after: verified,
        evidence: <PatchbayPermissionEvidence>[
          ...operation.evidence,
          ...verification.evidence,
        ],
        interruption: operation.interruption,
      );
    }
    return PatchbayPermissionDriverResponse(
      protocolVersion: verification.protocolVersion,
      requestId: request.requestId,
      admission: 'accepted',
      before: operation.before,
      after: verified,
      evidence: <PatchbayPermissionEvidence>[
        ...operation.evidence,
        ...verification.evidence,
      ],
      interruption: operation.interruption,
      notice: operation.notice ?? verification.notice,
    );
  }

  static void _validateRequestShape(PatchbayPermissionDriverRequest request) {
    if ((request.operation == PatchbayPermissionOperation.normalize ||
            request.operation == PatchbayPermissionOperation.fail) &&
        request.state == null) {
      throw const PatchbayPermissionDriverException('permissionStateRequired');
    }
    if (request.operation == PatchbayPermissionOperation.exercise &&
        request.decision == null) {
      throw const PatchbayPermissionDriverException(
        'permissionDecisionRequired',
      );
    }
  }

  static void _requireCapabilities(PatchbayPermissionDriverResponse response) {
    if (response.accepted && response.capabilities == null) {
      throw const PatchbayPermissionDriverException(
        'permissionCapabilityInvalid',
      );
    }
  }

  static PatchbayPermissionStatus _requireStatus(
    PatchbayPermissionDriverResponse response,
  ) {
    final PatchbayPermissionStatus? status = response.after ?? response.before;
    if (response.accepted && status == null) {
      throw const PatchbayPermissionDriverException('permissionStatusInvalid');
    }
    return status!;
  }

  static PatchbayPermissionAction _requiredAction(
    PatchbayPermissionDriverRequest request,
  ) => switch (request.operation) {
    PatchbayPermissionOperation.status ||
    PatchbayPermissionOperation.fail => PatchbayPermissionAction.status,
    PatchbayPermissionOperation.exercise => PatchbayPermissionAction.exercise,
    PatchbayPermissionOperation.reset => PatchbayPermissionAction.reset,
    PatchbayPermissionOperation.normalize => switch (request.state) {
      PatchbayPermissionState.granted => PatchbayPermissionAction.grant,
      PatchbayPermissionState.notDetermined => PatchbayPermissionAction.reset,
      PatchbayPermissionState.denied ||
      PatchbayPermissionState.permanentlyDenied =>
        PatchbayPermissionAction.revoke,
      _ => throw const PatchbayPermissionDriverException(
        'permissionStateUnsupported',
      ),
    },
    PatchbayPermissionOperation.capabilities =>
      throw const PatchbayPermissionDriverException(
        'permissionOperationInvalid',
      ),
  };

  static PatchbayPermissionDriverRequest _withTimeout(
    PatchbayPermissionDriverRequest request,
    int timeoutMs,
  ) => PatchbayPermissionDriverRequest(
    protocolVersion: request.protocolVersion,
    requestId: request.requestId,
    operation: request.operation,
    deviceId: request.deviceId,
    applicationId: request.applicationId,
    sessionRef: request.sessionRef,
    permission: request.permission,
    policy: request.policy,
    state: request.state,
    decision: request.decision,
    timeoutMs: max(1, timeoutMs),
  );
}
