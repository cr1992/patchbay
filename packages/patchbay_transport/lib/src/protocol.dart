import 'dart:io';

/// Identity that binds a direct-transport session to one application runtime.
final class PatchbayDirectIdentity {
  const PatchbayDirectIdentity({
    required this.schemaVersion,
    required this.applicationId,
    required this.appInstanceId,
  });

  final int schemaVersion;
  final String applicationId;
  final String appInstanceId;

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'applicationId': applicationId,
    'appInstanceId': appInstanceId,
  };

  bool hasSameRuntimeAs(PatchbayDirectIdentity other) =>
      schemaVersion == other.schemaVersion &&
      applicationId == other.applicationId &&
      appInstanceId == other.appInstanceId;
}

typedef PatchbayDirectIdentitySource =
    Future<PatchbayDirectIdentity> Function();
typedef PatchbayDirectCatalogSource = Future<Map<String, Object?>> Function();
typedef PatchbayDirectSnapshotSource = Future<Map<String, Object?>> Function();
typedef PatchbayDirectInvocationSource =
    Future<Map<String, Object?>> Function(
      String command,
      Map<String, Object?> arguments,
      String requestId,
    );
typedef PatchbayDirectClock = DateTime Function();
typedef PatchbayDirectExpiryCancellation = void Function();
typedef PatchbayDirectExpiryScheduler =
    PatchbayDirectExpiryCancellation Function(
      Duration duration,
      void Function() callback,
    );

/// The only application callbacks reachable through the transport.
///
/// There is deliberately no arbitrary method name or reflection callback.
final class PatchbayDirectHandlers {
  const PatchbayDirectHandlers({
    required this.identity,
    required this.catalog,
    required this.snapshot,
    required this.invoke,
  });

  final PatchbayDirectIdentitySource identity;
  final PatchbayDirectCatalogSource catalog;
  final PatchbayDirectSnapshotSource snapshot;
  final PatchbayDirectInvocationSource invoke;
}

/// LAN is cleartext and provides authentication but not confidentiality.
enum PatchbayLanExposure { disabled, experimentalSameTrustedNetworkOnly }

final class PatchbayDirectHostConfig {
  PatchbayDirectHostConfig({
    InternetAddress? bindAddress,
    this.port = 0,
    this.lanExposure = PatchbayLanExposure.disabled,
    this.tokenTtl = const Duration(minutes: 10),
    this.requestTimeout = const Duration(seconds: 10),
    this.maxRequestTimeout = const Duration(seconds: 150),
    this.maxRequestBodyBytes = 64 * 1024,
    this.maxResponseBodyBytes = 1024 * 1024,
    this.maxConcurrentRequests = 1,
  }) : bindAddress = bindAddress ?? InternetAddress.loopbackIPv4 {
    if (!this.bindAddress.isLoopback &&
        lanExposure != PatchbayLanExposure.experimentalSameTrustedNetworkOnly) {
      throw const PatchbayDirectConfigurationException(
        PatchbayDirectConfigurationError.lanOptInRequired,
      );
    }
    if (port < 0 || port > 65535) {
      throw const PatchbayDirectConfigurationException(
        PatchbayDirectConfigurationError.invalidPort,
      );
    }
    if (tokenTtl <= Duration.zero || tokenTtl > const Duration(hours: 1)) {
      throw const PatchbayDirectConfigurationException(
        PatchbayDirectConfigurationError.invalidTokenTtl,
      );
    }
    if (requestTimeout <= Duration.zero ||
        requestTimeout > const Duration(minutes: 1)) {
      throw const PatchbayDirectConfigurationException(
        PatchbayDirectConfigurationError.invalidRequestTimeout,
      );
    }
    if (maxRequestTimeout < requestTimeout ||
        maxRequestTimeout > const Duration(minutes: 5)) {
      throw const PatchbayDirectConfigurationException(
        PatchbayDirectConfigurationError.invalidRequestTimeout,
      );
    }
    if (maxRequestBodyBytes < 1 || maxRequestBodyBytes > 1024 * 1024) {
      throw const PatchbayDirectConfigurationException(
        PatchbayDirectConfigurationError.invalidRequestLimit,
      );
    }
    if (maxResponseBodyBytes < 1 || maxResponseBodyBytes > 4 * 1024 * 1024) {
      throw const PatchbayDirectConfigurationException(
        PatchbayDirectConfigurationError.invalidResponseLimit,
      );
    }
    if (maxConcurrentRequests < 1 || maxConcurrentRequests > 8) {
      throw const PatchbayDirectConfigurationException(
        PatchbayDirectConfigurationError.invalidConcurrencyLimit,
      );
    }
  }

  final InternetAddress bindAddress;
  final int port;
  final PatchbayLanExposure lanExposure;
  final Duration tokenTtl;

  /// Budget for a request that declares no deadline of its own.
  final Duration requestTimeout;

  /// Ceiling for a client-declared deadline.
  ///
  /// Long-poll operations (job wait, UI wait, log tail) are legitimately slower
  /// than [requestTimeout]. Without a separate ceiling the only safe default
  /// would be a flat timeout long enough for the slowest operation, which would
  /// also let an ordinary wedged request hold the single request slot for that
  /// same duration.
  final Duration maxRequestTimeout;
  final int maxRequestBodyBytes;
  final int maxResponseBodyBytes;

  /// A hard upper bound, not an adaptive pool. The default is one client
  /// request at a time and each response closes its HTTP connection.
  final int maxConcurrentRequests;
}

enum PatchbayDirectConfigurationError {
  lanOptInRequired,
  invalidPort,
  invalidTokenTtl,
  invalidRequestTimeout,
  invalidRequestLimit,
  invalidResponseLimit,
  invalidConcurrencyLimit,
}

final class PatchbayDirectConfigurationException implements Exception {
  const PatchbayDirectConfigurationException(this.code);

  final PatchbayDirectConfigurationError code;

  @override
  String toString() => 'PatchbayDirectConfigurationException(${code.name})';
}

enum PatchbayDirectErrorCode {
  protocolError,
  unauthorized,
  expired,
  busy,
  bodyTooLarge,
  responseTooLarge,
  originDenied,
  identityMismatch,
  identityDrift,
  timeout,
  internalError,
}

/// Why the host stopped listening.
///
/// A single request exceeding its deadline is deliberately absent: that fails
/// the one request and leaves the host serving. A handler that never settles
/// keeps holding its request slot, so the host degrades to `busy` and is then
/// bounded by [PatchbayDirectHostConfig.tokenTtl] rather than by tearing the
/// listener down under a client that is merely waiting.
enum PatchbayDirectStopReason {
  requested,
  tokenExpired,
  backgrounded,
  identityChanged,
  identityDrift,
}

/// Secret-bearing startup result. Its [toString] is intentionally redacted.
final class PatchbayDirectSession {
  const PatchbayDirectSession._({
    required this.endpoint,
    required this.bearerToken,
    required this.expiresAt,
    required this.identity,
    required this.lanExposure,
  });

  factory PatchbayDirectSession.create({
    required Uri endpoint,
    required String bearerToken,
    required DateTime expiresAt,
    required PatchbayDirectIdentity identity,
    required PatchbayLanExposure lanExposure,
  }) => PatchbayDirectSession._(
    endpoint: endpoint,
    bearerToken: bearerToken,
    expiresAt: expiresAt,
    identity: identity,
    lanExposure: lanExposure,
  );

  /// Never contains credentials or a query string.
  final Uri endpoint;

  /// Transfer only over an out-of-band channel appropriate to the consumer.
  final String bearerToken;
  final DateTime expiresAt;
  final PatchbayDirectIdentity identity;
  final PatchbayLanExposure lanExposure;

  @override
  String toString() =>
      'PatchbayDirectSession(endpoint: $endpoint, bearerToken: <redacted>, '
      'expiresAt: $expiresAt, identity: ${identity.applicationId})';
}
