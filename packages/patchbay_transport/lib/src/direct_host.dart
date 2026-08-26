import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'protocol.dart';

/// Small HTTP/JSON host for direct debug access without a VM Service URI.
///
/// Construction is inert. The socket is bound only by an explicit [start].
/// The host intentionally performs no logging and no discovery.
final class PatchbayDirectHost {
  PatchbayDirectHost({
    required PatchbayDirectHandlers handlers,
    PatchbayDirectHostConfig? config,
    PatchbayDirectClock? clock,
    PatchbayDirectExpiryScheduler? expiryScheduler,
  }) : _handlers = handlers,
       config = config ?? PatchbayDirectHostConfig(),
       _clock = clock ?? _systemClock,
       _expiryScheduler = expiryScheduler ?? _systemExpiryScheduler {
    if ((handlers.invoke == null) == (handlers.invokeWithContext == null)) {
      throw ArgumentError('provide exactly one of invoke or invokeWithContext');
    }
    if (handlers.invokeWithContext != null &&
        handlers.cancelInvocation == null) {
      throw ArgumentError('context-aware invoke requires cancelInvocation');
    }
  }

  static const String protocolPathPrefix = '/patchbay/direct/v1';
  static const int tokenBytes = 32;

  /// Per-request deadline in milliseconds, clamped to
  /// [PatchbayDirectHostConfig.maxRequestTimeout].
  ///
  /// A long-poll client declares how long it is prepared to wait so the host
  /// does not have to infer intent from command names.
  static const String deadlineHeader = 'x-patchbay-deadline-ms';

  final PatchbayDirectHandlers _handlers;
  final PatchbayDirectHostConfig config;
  final PatchbayDirectClock _clock;
  final PatchbayDirectExpiryScheduler _expiryScheduler;

  HttpServer? _server;
  PatchbayDirectExpiryCancellation? _cancelExpiry;
  PatchbayDirectIdentity? _pinnedIdentity;
  String? _bearerToken;
  DateTime? _expiresAt;
  Future<void>? _closing;
  bool _starting = false;
  bool _expired = false;
  int _activeRequests = 0;
  int _activeCancellationRequests = 0;

  bool get isRunning => _server != null && _closing == null;
  PatchbayDirectStopReason? stopReason;

  Future<PatchbayDirectSession> start() async {
    if (_starting || _server != null || _closing != null) {
      throw StateError('PatchbayDirectHost has already been started');
    }
    _starting = true;
    HttpServer? boundServer;
    try {
      final PatchbayDirectIdentity identity = await _handlers
          .identity()
          .timeout(config.requestTimeout);
      _validateIdentity(identity);
      final HttpServer server = await HttpServer.bind(
        config.bindAddress,
        config.port,
        shared: false,
      );
      boundServer = server;
      final String token = _newBearerToken();
      final DateTime expiresAt = _clock().toUtc().add(config.tokenTtl);
      _server = server;
      _pinnedIdentity = identity;
      _bearerToken = token;
      _expiresAt = expiresAt;
      server.listen(
        _handleRequest,
        onError: _ignoreServerError,
        cancelOnError: false,
      );
      _cancelExpiry = _expiryScheduler(config.tokenTtl, () {
        _expired = true;
        unawaited(_stop(PatchbayDirectStopReason.tokenExpired, force: true));
      });
      return PatchbayDirectSession.create(
        endpoint: Uri(
          scheme: 'http',
          host: server.address.address,
          port: server.port,
          path: protocolPathPrefix,
        ),
        bearerToken: token,
        expiresAt: expiresAt,
        identity: identity,
        lanExposure: config.lanExposure,
      );
    } on Object {
      _cancelExpiry?.call();
      _cancelExpiry = null;
      _server = null;
      _bearerToken = null;
      _expiresAt = null;
      await boundServer?.close(force: true);
      rethrow;
    } finally {
      _starting = false;
    }
  }

  Future<void> stop() => _stop(PatchbayDirectStopReason.requested, force: true);

  /// Product lifecycle adapters must call this before suspension.
  Future<void> notifyBackgrounded() =>
      _stop(PatchbayDirectStopReason.backgrounded, force: true);

  /// Product identity owners call this as soon as an identity rotation occurs.
  Future<void> notifyIdentityChanged() =>
      _stop(PatchbayDirectStopReason.identityChanged, force: true);

  Future<void> _stop(PatchbayDirectStopReason reason, {required bool force}) {
    final Future<void>? existing = _closing;
    if (existing != null) return existing;
    stopReason = reason;
    _cancelExpiry?.call();
    _cancelExpiry = null;
    final HttpServer? server = _server;
    _server = null;
    _bearerToken = null;
    _expiresAt = null;
    if (server == null) return Future<void>.value();
    final Future<void> closing = server.close(force: force);
    _closing = closing;
    return closing;
  }

  void _beginGracefulStop(PatchbayDirectStopReason reason) {
    unawaited(_stop(reason, force: false));
  }

  Future<void> _handleRequest(HttpRequest request) async {
    request.response.persistentConnection = false;
    if (_hasBrowserOrigin(request)) {
      await _sendError(
        request.response,
        HttpStatus.forbidden,
        PatchbayDirectErrorCode.originDenied,
      );
      return;
    }
    final bool expiredNow =
        _expired ||
        (_expiresAt != null && !_clock().toUtc().isBefore(_expiresAt!));
    if (expiredNow) {
      _expired = true;
      _beginGracefulStop(PatchbayDirectStopReason.tokenExpired);
      await _sendError(
        request.response,
        HttpStatus.unauthorized,
        PatchbayDirectErrorCode.expired,
      );
      return;
    }
    if (!_isAuthorized(request)) {
      await _sendError(
        request.response,
        HttpStatus.unauthorized,
        PatchbayDirectErrorCode.unauthorized,
      );
      return;
    }
    final bool cancellationRequest =
        request.uri.path == '$protocolPathPrefix/cancel-invocation';
    final bool busy = cancellationRequest
        ? _activeCancellationRequests >=
              config.maxConcurrentCancellationRequests
        : _activeRequests >= config.maxConcurrentRequests;
    if (busy) {
      await _sendError(
        request.response,
        HttpStatus.tooManyRequests,
        PatchbayDirectErrorCode.busy,
      );
      return;
    }
    if (cancellationRequest) {
      _activeCancellationRequests += 1;
    } else {
      _activeRequests += 1;
    }
    final Future<void> processing = _processAuthorized(request);
    // The slot is released when the handler actually settles, not when this
    // request gives up waiting for it. A wedged handler therefore keeps
    // occupying capacity instead of letting later requests pile up behind it.
    unawaited(
      processing
          .then<void>((_) {}, onError: (Object _, StackTrace _) {})
          .whenComplete(() {
            if (cancellationRequest) {
              _activeCancellationRequests -= 1;
            } else {
              _activeRequests -= 1;
            }
          }),
    );
    try {
      if (_hasHostOwnedInvocationDeadline(request)) {
        await processing;
      } else {
        await processing.timeout(_deadlineFor(request));
      }
    } on TimeoutException {
      await _sendErrorIfOpen(
        request.response,
        HttpStatus.gatewayTimeout,
        PatchbayDirectErrorCode.timeout,
      );
    } on Object {
      await _sendErrorIfOpen(
        request.response,
        HttpStatus.internalServerError,
        PatchbayDirectErrorCode.internalError,
      );
    }
  }

  /// Resolves the budget for one request, clamped to the configured ceiling.
  Duration _deadlineFor(HttpRequest request) {
    final String? raw = request.headers.value(deadlineHeader);
    if (raw == null) return config.requestTimeout;
    final int? milliseconds = int.tryParse(raw);
    if (milliseconds == null || milliseconds <= 0) return config.requestTimeout;
    final Duration requested = Duration(milliseconds: milliseconds);
    return requested > config.maxRequestTimeout
        ? config.maxRequestTimeout
        : requested;
  }

  Duration? _declaredDeadlineFor(HttpRequest request) {
    final String? raw = request.headers.value(deadlineHeader);
    final int? milliseconds = raw == null ? null : int.tryParse(raw);
    if (milliseconds == null || milliseconds < 1 || milliseconds > 300000) {
      return null;
    }
    final Duration requested = Duration(milliseconds: milliseconds);
    return requested > config.maxRequestTimeout
        ? config.maxRequestTimeout
        : requested;
  }

  bool _hasHostOwnedInvocationDeadline(HttpRequest request) =>
      _handlers.invokeWithContext != null &&
      request.uri.path == '$protocolPathPrefix/invoke' &&
      _declaredDeadlineFor(request) != null;

  Future<void> _processAuthorized(HttpRequest request) async {
    if (request.method != 'POST' ||
        request.uri.hasQuery ||
        request.headers.contentType?.mimeType != ContentType.json.mimeType) {
      await _sendError(
        request.response,
        HttpStatus.badRequest,
        PatchbayDirectErrorCode.protocolError,
      );
      return;
    }
    final Uint8List? body = await _readBoundedBody(request);
    if (body == null) {
      await _sendError(
        request.response,
        HttpStatus.requestEntityTooLarge,
        PatchbayDirectErrorCode.bodyTooLarge,
      );
      return;
    }
    final Map<String, Object?>? message = _decodeMessage(body);
    if (message == null) {
      await _sendError(
        request.response,
        HttpStatus.badRequest,
        PatchbayDirectErrorCode.protocolError,
      );
      return;
    }

    final PatchbayDirectIdentity current = await _handlers.identity();
    _validateIdentity(current);
    final PatchbayDirectIdentity pinned = _pinnedIdentity!;
    if (!current.hasSameRuntimeAs(pinned)) {
      _beginGracefulStop(PatchbayDirectStopReason.identityDrift);
      await _sendError(
        request.response,
        HttpStatus.conflict,
        PatchbayDirectErrorCode.identityDrift,
      );
      return;
    }
    if (!_messageMatchesIdentity(message, current)) {
      await _sendError(
        request.response,
        HttpStatus.conflict,
        PatchbayDirectErrorCode.identityMismatch,
      );
      return;
    }

    final String path = request.uri.path;
    final Set<String> commonFields = <String>{
      'schemaVersion',
      'applicationId',
      'appInstanceId',
    };
    late final Map<String, Object?> result;
    if (path == '$protocolPathPrefix/identity' &&
        _hasOnlyFields(message, commonFields)) {
      result = current.toIdentityResultJson();
    } else if (path == '$protocolPathPrefix/catalog' &&
        _hasOnlyFields(message, commonFields)) {
      result = await _handlers.catalog();
    } else if (path == '$protocolPathPrefix/snapshot' &&
        _hasFields(message, commonFields, optional: _snapshotFields)) {
      // `request` is optional and forwarded verbatim; only its JSON type is
      // checked here, because what a selector may contain is the protocol
      // package's rule and this host must not grow a second opinion about it.
      final Object? selector = message['request'];
      if (selector != null && selector is! Map<String, Object?>) {
        await _sendError(
          request.response,
          HttpStatus.badRequest,
          PatchbayDirectErrorCode.protocolError,
        );
        return;
      }
      result = await _handlers.snapshot(selector as Map<String, Object?>?);
    } else if (path == '$protocolPathPrefix/invoke' &&
        (_handlers.invokeWithContext == null
            ? _hasOnlyFields(message, <String>{
                ...commonFields,
                'command',
                'arguments',
                'requestId',
              })
            : _hasFields(
                message,
                <String>{...commonFields, 'command', 'arguments', 'requestId'},
                optional: const <String>{'ownerToken'},
              ))) {
      final Object? command = message['command'];
      final Object? arguments = message['arguments'];
      final Object? requestId = message['requestId'];
      final Object? ownerToken = message['ownerToken'];
      if (command is! String ||
          command.isEmpty ||
          arguments is! Map<String, Object?> ||
          requestId is! String ||
          requestId.isEmpty ||
          (ownerToken != null &&
              (ownerToken is! String || !_ownerToken.hasMatch(ownerToken)))) {
        await _sendError(
          request.response,
          HttpStatus.badRequest,
          PatchbayDirectErrorCode.protocolError,
        );
        return;
      }
      final PatchbayDirectContextInvocationSource? contextSource =
          _handlers.invokeWithContext;
      final PatchbayDirectInvocationHandle handle;
      if (contextSource == null) {
        handle = PatchbayDirectInvocationHandle.legacy(
          _handlers.invoke!(command, arguments, requestId),
        );
      } else {
        handle = contextSource(
          command,
          arguments,
          requestId,
          ownerToken: ownerToken as String?,
          deadline: _declaredDeadlineFor(request),
        );
        if (ownerToken case final String token) {
          unawaited(
            request.response.done.then<void>(
              (_) {},
              onError: (Object _, StackTrace _) {
                unawaited(
                  _handlers
                      .cancelInvocation!(
                        command,
                        requestId,
                        token,
                        reason: 'callerDisconnected',
                      )
                      .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
                );
              },
            ),
          );
        }
      }
      try {
        result = await handle.response;
        await _sendSuccess(request.response, current, result);
      } finally {
        await handle.lifecycle;
      }
      return;
    } else if (path == '$protocolPathPrefix/cancel-invocation' &&
        _handlers.cancelInvocation != null &&
        _hasOnlyFields(message, <String>{
          ...commonFields,
          'command',
          'requestId',
          'ownerToken',
        })) {
      final Object? command = message['command'];
      final Object? requestId = message['requestId'];
      final Object? ownerToken = message['ownerToken'];
      if (command is! String ||
          command.isEmpty ||
          requestId is! String ||
          requestId.isEmpty ||
          ownerToken is! String ||
          !_ownerToken.hasMatch(ownerToken)) {
        await _sendError(
          request.response,
          HttpStatus.badRequest,
          PatchbayDirectErrorCode.protocolError,
        );
        return;
      }
      result = await _handlers.cancelInvocation!(
        command,
        requestId,
        ownerToken,
        reason: 'explicitRequest',
      );
    } else {
      await _sendError(
        request.response,
        HttpStatus.badRequest,
        PatchbayDirectErrorCode.protocolError,
      );
      return;
    }
    await _sendSuccess(request.response, current, result);
  }

  Future<Uint8List?> _readBoundedBody(HttpRequest request) async {
    final int declaredLength = request.contentLength;
    if (declaredLength > config.maxRequestBodyBytes) return null;
    final BytesBuilder builder = BytesBuilder(copy: false);
    int length = 0;
    await for (final List<int> chunk in request) {
      length += chunk.length;
      if (length > config.maxRequestBodyBytes) return null;
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  Map<String, Object?>? _decodeMessage(Uint8List body) {
    try {
      final Object? decoded = jsonDecode(utf8.decode(body));
      if (decoded is! Map<String, dynamic>) return null;
      return Map<String, Object?>.from(decoded);
    } on FormatException {
      return null;
    }
  }

  bool _messageMatchesIdentity(
    Map<String, Object?> message,
    PatchbayDirectIdentity current,
  ) =>
      message['schemaVersion'] == current.schemaVersion &&
      message['applicationId'] == current.applicationId &&
      message['appInstanceId'] == current.appInstanceId;

  static bool _hasOnlyFields(
    Map<String, Object?> message,
    Set<String> allowed,
  ) => message.keys.every(allowed.contains) && message.length == allowed.length;

  /// Fields the snapshot message may carry beyond the common identity ones.
  static const Set<String> _snapshotFields = <String>{'request'};
  static final RegExp _ownerToken = RegExp(r'^[A-Za-z0-9_-]{22}$');

  /// Every [required] field present, and nothing outside [required] plus
  /// [optional].
  ///
  /// An operation with an optional field cannot use [_hasOnlyFields], whose
  /// exact-length rule is what makes the fixed-shape messages fail closed. The
  /// closed-set half is kept: an unknown key is still a protocol error rather
  /// than something quietly ignored.
  static bool _hasFields(
    Map<String, Object?> message,
    Set<String> required, {
    Set<String> optional = const <String>{},
  }) =>
      required.every(message.containsKey) &&
      message.keys.every(
        (String key) => required.contains(key) || optional.contains(key),
      );

  bool _isAuthorized(HttpRequest request) {
    final List<String>? values =
        request.headers[HttpHeaders.authorizationHeader];
    if (values == null || values.length != 1) return false;
    const String prefix = 'Bearer ';
    final String header = values.single;
    final String? expected = _bearerToken;
    if (!header.startsWith(prefix) || expected == null) return false;
    return _constantTimeEquals(header.substring(prefix.length), expected);
  }

  static bool _hasBrowserOrigin(HttpRequest request) =>
      request.headers['origin'] != null ||
      request.headers['access-control-request-method'] != null;

  Future<void> _sendSuccess(
    HttpResponse response,
    PatchbayDirectIdentity identity,
    Map<String, Object?> result,
  ) async {
    final Map<String, Object?> envelope = <String, Object?>{
      'schemaVersion': identity.schemaVersion,
      'identity': identity.toJson(),
      'result': result,
    };
    final List<int>? encoded = _encodeWithinLimit(envelope);
    if (encoded == null) {
      await _sendError(
        response,
        HttpStatus.internalServerError,
        PatchbayDirectErrorCode.responseTooLarge,
      );
      return;
    }
    response.statusCode = HttpStatus.ok;
    response.headers.contentType = ContentType.json;
    response.add(encoded);
    await response.close();
  }

  Future<void> _sendErrorIfOpen(
    HttpResponse response,
    int status,
    PatchbayDirectErrorCode code,
  ) async {
    try {
      await _sendError(response, status, code);
    } on StateError {
      // The response was already committed before an injected callback failed.
    }
  }

  Future<void> _sendError(
    HttpResponse response,
    int status,
    PatchbayDirectErrorCode code,
  ) async {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.add(
      utf8.encode(
        jsonEncode(<String, Object?>{
          'schemaVersion': _pinnedIdentity?.schemaVersion ?? 1,
          'error': <String, Object?>{'code': code.name},
        }),
      ),
    );
    await response.close();
  }

  List<int>? _encodeWithinLimit(Map<String, Object?> envelope) {
    final List<int> encoded = utf8.encode(jsonEncode(envelope));
    return encoded.length <= config.maxResponseBodyBytes ? encoded : null;
  }

  static bool _constantTimeEquals(String candidate, String expected) {
    final List<int> candidateUnits = candidate.codeUnits;
    final List<int> expectedUnits = expected.codeUnits;
    int difference = candidateUnits.length ^ expectedUnits.length;
    for (int index = 0; index < expectedUnits.length; index += 1) {
      final int candidateByte = index < candidateUnits.length
          ? candidateUnits[index]
          : 0;
      final int expectedByte = expectedUnits[index];
      difference |= candidateByte ^ expectedByte;
    }
    return difference == 0;
  }

  static String _newBearerToken() {
    final Random random = Random.secure();
    final Uint8List bytes = Uint8List.fromList(
      List<int>.generate(tokenBytes, (_) => random.nextInt(256)),
    );
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  static void _validateIdentity(PatchbayDirectIdentity identity) {
    if (identity.schemaVersion < 1 ||
        identity.applicationId.isEmpty ||
        identity.appInstanceId.isEmpty) {
      throw StateError('Patchbay direct identity is invalid');
    }
  }

  static void _ignoreServerError(Object _, StackTrace __) {}

  static DateTime _systemClock() => DateTime.now().toUtc();

  static PatchbayDirectExpiryCancellation _systemExpiryScheduler(
    Duration duration,
    void Function() callback,
  ) {
    final Timer timer = Timer(duration, callback);
    return timer.cancel;
  }
}
