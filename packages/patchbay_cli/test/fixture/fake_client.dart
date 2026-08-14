import 'package:patchbay_cli/patchbay_cli.dart';

/// One recorded call against the fake connection.
typedef FakeInvocation = ({String command, Map<String, Object?> arguments});

/// A `PatchbayClient` whose catalog and answers are supplied by the test.
///
/// One-shot CLI behaviour that depends on what the App *declares* — a sensitive
/// parameter, a chunk limit, a revision — can only be tested against a catalog
/// the test controls, and the `connect` seam of `runPatchbayCli` is the only
/// honest way in: it exercises the real dispatcher rather than a re-creation of
/// it. Every invoke is recorded so a test can assert what actually went out.
final class FakePatchbayClient implements PatchbayClient {
  FakePatchbayClient({
    required this.commands,
    required this.handle,
    this.uiTargets = const <Object?>[],
    this.snapshotData = const <String, Object?>{'source': 'appRecorded'},
  });

  /// Catalog rows exactly as an App would publish them.
  final List<Map<String, Object?>> commands;
  final List<Object?> uiTargets;

  /// What the snapshot RPC answers.
  ///
  /// The snapshot is the one place a consumer's own domain state reaches the
  /// CLI, so any CLI behaviour derived from it can only be exercised against a
  /// snapshot the test controls.
  final Map<String, Object?> snapshotData;
  final Future<Map<String, Object?>> Function(
    String command,
    Map<String, Object?> arguments,
  )
  handle;

  final List<FakeInvocation> calls = <FakeInvocation>[];
  int catalogReads = 0;
  bool closed = false;

  @override
  Future<Map<String, Object?>> identity() async => <String, Object?>{
    'schemaVersion': 1,
    'applicationId': 'dev.patchbay.fake',
    'appInstanceId': 'fake-instance',
    'isolateId': 'isolates/1',
  };

  @override
  Future<Map<String, Object?>> catalog() async {
    catalogReads += 1;
    return <String, Object?>{'commands': commands, 'uiTargets': uiTargets};
  }

  @override
  Future<Map<String, Object?>> snapshot() async => snapshotData;

  @override
  Future<Map<String, Object?>> invoke({
    required String command,
    required Map<String, Object?> arguments,
    String? requestId,
    Duration? deadline,
  }) async {
    calls.add((command: command, arguments: arguments));
    final Map<String, Object?> response = await handle(command, arguments);
    return <String, Object?>{
      'schemaVersion': 1,
      'requestId': requestId ?? 'fake-request',
      ...response,
    };
  }

  @override
  Future<Map<String, Object?>> widgetTree() =>
      throw const PatchbayProtocolException('flutterDiagnosticUnavailable');

  @override
  Future<Map<String, Object?>> renderTree() =>
      throw const PatchbayProtocolException('flutterDiagnosticUnavailable');

  @override
  Future<Map<String, Object?>> focusTree() =>
      throw const PatchbayProtocolException('flutterDiagnosticUnavailable');

  @override
  Future<void> close() async => closed = true;
}

/// A `commandNotRegistered` rejection, the shape a host returns for an unknown
/// name. Fakes use it so an unexpected call fails the same way a real App does.
Map<String, Object?> fakeCommandNotRegistered() => <String, Object?>{
  'admission': 'rejected',
  'rejection': const <String, Object?>{'code': 'commandNotRegistered'},
};

/// An accepted response carrying [payload].
Map<String, Object?> fakeAccepted(Map<String, Object?> payload) =>
    <String, Object?>{'admission': 'accepted', 'payload': payload};
