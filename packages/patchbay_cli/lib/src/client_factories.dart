import 'client.dart';
import 'direct_connection.dart';

/// Connects to a running App over its VM Service URI.
///
/// The whole opt-in client library (PB-050-13) is these two factories plus the
/// types they hand back: the connection classes themselves, the profiling and
/// cancellation surfaces, the timeout wrapper and the request-id generator stay
/// inside `src/`, so a later transport change is not a source-breaking one.
///
/// [expectedIdentity], when given, is compared field by field against the
/// handshake the host answers with; a mismatch throws
/// `PatchbayProtocolException('identityValidationFailed')` instead of returning
/// a connection to a different App than the caller meant.
Future<PatchbayClient> connectPatchbayVmService(
  Uri serviceUri, {
  PatchbayRuntimeIdentity? expectedIdentity,
}) =>
    PatchbayConnection.connect(serviceUri, expectedIdentity: expectedIdentity);

/// Connects to a running App over the explicitly enabled direct HTTP transport.
///
/// Synchronous by construction: the direct transport has no handshake to await
/// before the first request, and the identity the caller declares here is
/// checked by the host on every call rather than once at dial time. Flutter SDK
/// diagnostic passthroughs (`widgetTree` / `renderTree` / `focusTree`) remain
/// VM-Service-only and refuse with `flutterDiagnosticUnavailable` here.
PatchbayClient connectPatchbayDirect({
  required Uri endpoint,
  required String bearerToken,
  required int schemaVersion,
  required String applicationId,
  required String appInstanceId,
  Duration timeout = const Duration(seconds: 60),
}) => PatchbayDirectConnection(
  endpoint: endpoint,
  bearerToken: bearerToken,
  schemaVersion: schemaVersion,
  applicationId: applicationId,
  appInstanceId: appInstanceId,
  timeout: timeout,
);
