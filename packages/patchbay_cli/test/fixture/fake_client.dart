import 'package:patchbay/patchbay.dart';
import 'package:patchbay_cli/src/client.dart';
import 'package:patchbay_cli/src/performance_profile.dart';

/// One recorded call against the fake connection.
typedef FakeInvocation = ({
  String command,
  Map<String, Object?> arguments,
  String? requestId,
});

/// A `PatchbayClient` whose catalog and answers are supplied by the test.
///
/// One-shot CLI behaviour that depends on what the App *declares* — a sensitive
/// parameter, a chunk limit, a revision — can only be tested against a catalog
/// the test controls, and the `connect` seam of `runPatchbayCli` is the only
/// honest way in: it exercises the real dispatcher rather than a re-creation of
/// it. Every invoke is recorded so a test can assert what actually went out.
final class FakePatchbayClient
    implements
        PatchbayClient,
        PatchbayProfilingClient,
        PatchbaySnapshotDiffClient {
  FakePatchbayClient({
    required this.commands,
    required this.handle,
    this.uiTargets = const <Object?>[],
    this.snapshotData = const <String, Object?>{'source': 'appRecorded'},
    this.identityData = legacyFakeIdentity,
    this.catalogExtras = const <String, Object?>{},
    this.profilePerformance,
    this.profileNetwork,
    this.widgetTreeHandler,
    this.renderTreeHandler,
    this.focusTreeHandler,
  });

  /// What the identity handshake answers.
  ///
  /// The default is deliberately a *pre-capability* host: it reports no
  /// `serverVersion` and declares no features, which is what the App an
  /// operator is most likely to be holding actually looks like. Every test
  /// that does not care therefore keeps exercising the degradation path rather
  /// than the happy one.
  final Map<String, Object?> identityData;

  /// Extra top-level catalog keys — `catalogDigest`, for instance.
  ///
  /// Kept separate from [commands] because they are protocol-owned: a real
  /// host attaches them itself, and a test that wants to model one host
  /// version or another sets them here rather than by rewriting the command
  /// list.
  final Map<String, Object?> catalogExtras;

  final Future<Map<String, Object?>> Function(
    PatchbayPerformanceProfileRequest request,
  )?
  profilePerformance;
  final Future<Map<String, Object?>> Function()? profileNetwork;

  /// Overrides for the Flutter diagnostic passthroughs. `null` keeps the
  /// default `flutterDiagnosticUnavailable` most tests expect; PB-050-20
  /// tests supply one to exercise the local-artifact spill path.
  final Future<Map<String, Object?>> Function()? widgetTreeHandler;
  final Future<Map<String, Object?>> Function()? renderTreeHandler;
  final Future<Map<String, Object?>> Function()? focusTreeHandler;

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

  /// Every snapshot request that reached the wire; null for a whole-snapshot
  /// read. A `--path` / `snapshot wait` test asserts on these, because the
  /// CLI's job ends at the wire and only what went out proves the option
  /// arrived in the declared shape.
  final List<PatchbaySnapshotRequest?> snapshotRequests =
      <PatchbaySnapshotRequest?>[];
  final List<int> snapshotDiffRequests = <int>[];
  int catalogReads = 0;
  bool closed = false;

  @override
  Future<Map<String, Object?>> identity() async => identityData;

  @override
  Future<Map<String, Object?>> catalog() async {
    catalogReads += 1;
    return <String, Object?>{
      'commands': commands,
      'uiTargets': uiTargets,
      ...catalogExtras,
    };
  }

  @override
  Future<Map<String, Object?>> snapshot({
    PatchbaySnapshotRequest? request,
  }) async {
    snapshotRequests.add(request);
    if (request == null) return snapshotData;
    // The real selection resolver, not a re-implementation: a CLI test asserts
    // how the answer is rendered and classified, and it can only do that
    // against the shape the host actually serves.
    return <String, Object?>{
      'schemaVersion': 1,
      'selection': PatchbaySnapshotSelection.resolve(
        snapshotData,
        request.path,
      ).toJson(),
    };
  }

  @override
  Future<Map<String, Object?>> snapshotDiff({required int fromRevision}) async {
    snapshotDiffRequests.add(fromRevision);
    return <String, Object?>{
      'schemaVersion': 1,
      'fromRevision': fromRevision,
      'snapshotRevision': fromRevision + 1,
      'revisionSource': 'hostObserved',
      'added': const <Object?>[],
      'changed': const <Object?>[],
      'removed': const <Object?>[],
    };
  }

  @override
  Future<Map<String, Object?>> invoke({
    required String command,
    required Map<String, Object?> arguments,
    String? requestId,
    Duration? deadline,
  }) async {
    calls.add((command: command, arguments: arguments, requestId: requestId));
    final Map<String, Object?> response = await handle(command, arguments);
    return <String, Object?>{
      'schemaVersion': 1,
      'requestId': requestId ?? 'fake-request',
      ...response,
    };
  }

  @override
  Future<Map<String, Object?>> widgetTree() =>
      widgetTreeHandler?.call() ??
      (throw const PatchbayProtocolException('flutterDiagnosticUnavailable'));

  @override
  Future<Map<String, Object?>> renderTree() =>
      renderTreeHandler?.call() ??
      (throw const PatchbayProtocolException('flutterDiagnosticUnavailable'));

  @override
  Future<Map<String, Object?>> focusTree() =>
      focusTreeHandler?.call() ??
      (throw const PatchbayProtocolException('flutterDiagnosticUnavailable'));

  @override
  Future<Map<String, Object?>> performanceProfile(
    PatchbayPerformanceProfileRequest request,
  ) async {
    final handler = profilePerformance;
    if (handler == null) {
      throw const PatchbayProtocolException('profilingVmServiceRequired');
    }
    return handler(request);
  }

  @override
  Future<Map<String, Object?>> networkProfile() async {
    final handler = profileNetwork;
    if (handler == null) {
      throw const PatchbayProtocolException('networkProfilingUnavailable');
    }
    return handler();
  }

  @override
  Future<void> close() async => closed = true;
}

/// The identity a host that predates the capability handshake answers with.
const Map<String, Object?> legacyFakeIdentity = <String, Object?>{
  'schemaVersion': 1,
  'applicationId': 'dev.patchbay.fake',
  'appInstanceId': 'fake-instance',
  'isolateId': 'isolates/1',
};

/// A `commandNotRegistered` rejection, the shape a host returns for an unknown
/// name. Fakes use it so an unexpected call fails the same way a real App does.
Map<String, Object?> fakeCommandNotRegistered() => <String, Object?>{
  'admission': 'rejected',
  'rejection': const <String, Object?>{'code': 'commandNotRegistered'},
};

/// An accepted response carrying [payload].
Map<String, Object?> fakeAccepted(Map<String, Object?> payload) =>
    <String, Object?>{'admission': 'accepted', 'payload': payload};
