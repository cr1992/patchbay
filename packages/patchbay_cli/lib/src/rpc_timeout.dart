import 'dart:async';

import 'package:patchbay/patchbay.dart';

import 'client.dart';

/// Budget for one RPC round trip against a running App, when the caller names
/// none.
///
/// Every command the CLI runs ends in a request the App has to answer, and
/// until this existed the VM Service path had no budget at all: a peer that
/// stopped answering — an Android process frozen by the vendor after the screen
/// went off is the observed case — left the CLI waiting for the socket to die
/// on its own, minutes later and with a bare `HttpException` to show for it.
/// A bounded wait with a name is the difference between "this is stuck" and
/// "the App is not answering, wake the device".
///
/// Thirty seconds is deliberately longer than any immediate command and shorter
/// than an operator's patience. A command that legitimately takes longer either
/// declares its own wait budget — see [patchbayRpcBudget] — or is a `job`, which
/// answers immediately with an id.
const Duration patchbayDefaultRpcTimeout = Duration(seconds: 30);

/// Stable code for "the App did not answer inside the RPC budget".
///
/// One code for both transports: the direct client's own socket timeout is
/// translated into it as well, so a script classifies an unresponsive peer the
/// same way regardless of how the CLI reached it.
const String patchbayAppUnresponsiveCode = 'appUnresponsive';

/// The sentence that turns [patchbayAppUnresponsiveCode] into an action.
///
/// It names the observed cause first because that is the one an operator can
/// fix from where they are sitting; raising the budget is second because a
/// merely slow App is the rarer half.
const String patchbayAppUnresponsiveHint =
    'The App did not answer in time: it may be frozen by the system, '
    'screen-off, or suspended. Wake and unlock the device, or check that the '
    'process is still running. Raise --transport-timeout-ms if the App is only '
    'slow.';

/// Socket budget for one RPC round trip.
///
/// [deadline] is a wait the *App* was asked to perform — `ui wait`, `logs tail`
/// and `patchbay.job.wait` all declare one in `timeoutMs`. The answer cannot
/// arrive before that wait elapses, so the budget has to cover the declared
/// wait *plus* an ordinary round trip. Without this arithmetic the flat default
/// would abandon requests the App is still legitimately serving, which is the
/// opposite of the failure this timeout exists to catch: a deliberate wait is
/// not an unresponsive peer.
///
/// This is the same shape `PatchbayDirectClient` already applies to its own
/// socket, so both transports agree on what "too long" means.
Duration patchbayRpcBudget(Duration rpcTimeout, Duration? deadline) =>
    deadline == null || deadline <= rpcTimeout
    ? rpcTimeout
    : deadline + rpcTimeout;

/// Awaits one RPC, failing with a diagnosable code instead of hanging.
Future<T> awaitPatchbayRpc<T>(
  Future<T> rpc, {
  required Duration rpcTimeout,
  Duration? deadline,
}) async {
  try {
    return await rpc.timeout(patchbayRpcBudget(rpcTimeout, deadline));
  } on TimeoutException {
    throw const PatchbayTransportException(patchbayAppUnresponsiveCode);
  }
}

/// Opens a connection under the RPC budget, leaving nothing behind if the
/// budget runs out first.
///
/// A dial the CLI stopped waiting for may still succeed a moment later. Nobody
/// will ever read from it, so it is closed rather than left open against an App
/// nobody is talking to. This is the half that can be cleaned up; the half that
/// cannot — a WebSocket handshake still stuck inside the transport — is why
/// `bin/patchbay.dart` ends the process on the command's result instead of
/// waiting for the event loop to drain.
Future<PatchbayClient> dialPatchbayUnderBudget(
  Future<PatchbayClient> Function() connect, {
  required Duration rpcTimeout,
}) async {
  final Future<PatchbayClient> dialing = connect();
  try {
    return await awaitPatchbayRpc(dialing, rpcTimeout: rpcTimeout);
  } on PatchbayTransportException {
    unawaited(
      dialing
          .then((PatchbayClient abandoned) => abandoned.close())
          // A dial that fails after being abandoned has no one left to tell.
          .catchError((Object _) {}),
    );
    rethrow;
  }
}

/// Releases a connection without letting teardown become the thing that hangs.
///
/// The command has already produced its result. A peer that stopped answering
/// must not get a second chance to hold the CLI open while the transport says
/// goodbye, and a failed goodbye cannot be allowed to replace an outcome that
/// was already decided and written.
Future<void> closePatchbayQuietly(PatchbayClient? connection) async {
  if (connection == null) return;
  try {
    await connection.close().timeout(const Duration(seconds: 2));
  } on Object {
    // Nothing about this changes what the command answered.
  }
}

/// A [PatchbayClient] that refuses to wait forever for its App.
///
/// The budget is applied here rather than inside each transport for two
/// reasons: every transport gets it without reimplementing it, and it covers
/// the one call a transport cannot bound for itself — the VM Service extension
/// invocation, which has no per-request teardown of its own.
///
/// It is a decorator, not a policy: it never retries, never reconnects and
/// never reinterprets an answer that did arrive. The only thing it adds is an
/// end to the waiting.
final class PatchbayTimeoutClient
    implements PatchbayClient, PatchbaySnapshotDiffClient {
  const PatchbayTimeoutClient(this._inner, {required this.rpcTimeout});

  final PatchbayClient _inner;
  final Duration rpcTimeout;

  @override
  Future<Map<String, Object?>> identity() =>
      awaitPatchbayRpc(_inner.identity(), rpcTimeout: rpcTimeout);

  @override
  Future<Map<String, Object?>> catalog() =>
      awaitPatchbayRpc(_inner.catalog(), rpcTimeout: rpcTimeout);

  /// A snapshot request that declares a wait extends this budget the same way
  /// an `invoke` deadline does: the answer cannot arrive before the App has
  /// finished waiting, so the flat default would abandon a request the App is
  /// still legitimately serving.
  @override
  Future<Map<String, Object?>> snapshot({PatchbaySnapshotRequest? request}) =>
      awaitPatchbayRpc(
        _inner.snapshot(request: request),
        rpcTimeout: rpcTimeout,
        deadline: request?.timeout,
      );

  @override
  Future<Map<String, Object?>> snapshotDiff({required int fromRevision}) {
    final PatchbayClient inner = _inner;
    if (inner is! PatchbaySnapshotDiffClient) {
      throw const PatchbayProtocolException('snapshotDiffClientUnavailable');
    }
    final PatchbaySnapshotDiffClient diffClient =
        inner as PatchbaySnapshotDiffClient;
    return awaitPatchbayRpc(
      diffClient.snapshotDiff(fromRevision: fromRevision),
      rpcTimeout: rpcTimeout,
    );
  }

  @override
  Future<Map<String, Object?>> invoke({
    required String command,
    required Map<String, Object?> arguments,
    String? requestId,
    Duration? deadline,
  }) => awaitPatchbayRpc(
    _inner.invoke(
      command: command,
      arguments: arguments,
      requestId: requestId,
      deadline: deadline,
    ),
    rpcTimeout: rpcTimeout,
    deadline: deadline,
  );

  @override
  Future<Map<String, Object?>> widgetTree() =>
      awaitPatchbayRpc(_inner.widgetTree(), rpcTimeout: rpcTimeout);

  @override
  Future<Map<String, Object?>> renderTree() =>
      awaitPatchbayRpc(_inner.renderTree(), rpcTimeout: rpcTimeout);

  @override
  Future<Map<String, Object?>> focusTree() =>
      awaitPatchbayRpc(_inner.focusTree(), rpcTimeout: rpcTimeout);

  /// Closing is local teardown, not a request the App has to answer.
  @override
  Future<void> close() => _inner.close();
}
