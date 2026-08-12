import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'direct_host.dart';
import 'protocol.dart';

/// Consumer-neutral client for the fixed direct transport protocol.
///
/// Discovery and credential distribution are deliberately outside this API.
final class PatchbayDirectClient {
  PatchbayDirectClient({
    required PatchbayDirectSession session,
    this.timeout = const Duration(seconds: 10),
    this.maxResponseBodyBytes = 1024 * 1024,
    HttpClient? httpClient,
  }) : _endpoint = _validateSession(session, timeout, maxResponseBodyBytes),
       _bearerToken = session.bearerToken,
       _expectedIdentity = session.identity,
       _httpClient = httpClient ?? HttpClient();

  final Uri _endpoint;
  final String _bearerToken;
  final PatchbayDirectIdentity _expectedIdentity;
  final HttpClient _httpClient;
  final Duration timeout;
  final int maxResponseBodyBytes;
  bool _closed = false;

  Future<Map<String, Object?>> identity() =>
      _call('identity', _expectedIdentity.toJson());

  Future<Map<String, Object?>> catalog() =>
      _call('catalog', _expectedIdentity.toJson());

  Future<Map<String, Object?>> snapshot() =>
      _call('snapshot', _expectedIdentity.toJson());

  Future<Map<String, Object?>> invoke({
    required String command,
    required Map<String, Object?> arguments,
    required String requestId,
  }) => _call('invoke', <String, Object?>{
    ..._expectedIdentity.toJson(),
    'command': command,
    'arguments': arguments,
    'requestId': requestId,
  });

  void close({bool force = false}) {
    if (_closed) return;
    _closed = true;
    _httpClient.close(force: force);
  }

  Future<Map<String, Object?>> _call(
    String operation,
    Map<String, Object?> body,
  ) async {
    if (_closed) throw const PatchbayDirectClientException('clientClosed');
    final Uri uri = _endpoint.replace(
      path: '${PatchbayDirectHost.protocolPathPrefix}/$operation',
    );
    try {
      final HttpClientRequest request = await _httpClient
          .postUrl(uri)
          .timeout(timeout);
      request.headers.contentType = ContentType.json;
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $_bearerToken',
      );
      request.add(utf8.encode(jsonEncode(body)));
      final HttpClientResponse response = await request.close().timeout(
        timeout,
      );
      final List<int> bytes = await _readBounded(response).timeout(timeout);
      final Object? decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map<String, dynamic>) {
        throw const PatchbayDirectClientException('protocolError');
      }
      final Map<String, Object?> envelope = Map<String, Object?>.from(decoded);
      if (response.statusCode != HttpStatus.ok) {
        final Object? error = envelope['error'];
        final Object? code = error is Map<String, dynamic>
            ? error['code']
            : null;
        throw PatchbayDirectClientException(
          code is String ? code : 'protocolError',
          statusCode: response.statusCode,
        );
      }
      final PatchbayDirectIdentity responseIdentity = _readIdentity(
        envelope['identity'],
      );
      if (!responseIdentity.hasSameRuntimeAs(_expectedIdentity) ||
          envelope['schemaVersion'] != _expectedIdentity.schemaVersion) {
        throw const PatchbayDirectClientException('identityMismatch');
      }
      final Object? result = envelope['result'];
      if (result is! Map<String, dynamic>) {
        throw const PatchbayDirectClientException('protocolError');
      }
      return Map<String, Object?>.from(result);
    } on PatchbayDirectClientException {
      rethrow;
    } on TimeoutException {
      throw const PatchbayDirectClientException('timeout');
    } on Object {
      throw const PatchbayDirectClientException('transportError');
    }
  }

  Future<List<int>> _readBounded(HttpClientResponse response) async {
    final BytesBuilder builder = BytesBuilder(copy: false);
    int length = 0;
    await for (final List<int> chunk in response) {
      length += chunk.length;
      if (length > maxResponseBodyBytes) {
        throw const PatchbayDirectClientException('responseTooLarge');
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  static PatchbayDirectIdentity _readIdentity(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const PatchbayDirectClientException('protocolError');
    }
    final Object? schemaVersion = value['schemaVersion'];
    final Object? applicationId = value['applicationId'];
    final Object? appInstanceId = value['appInstanceId'];
    if (schemaVersion is! int ||
        applicationId is! String ||
        appInstanceId is! String) {
      throw const PatchbayDirectClientException('protocolError');
    }
    return PatchbayDirectIdentity(
      schemaVersion: schemaVersion,
      applicationId: applicationId,
      appInstanceId: appInstanceId,
    );
  }

  static Uri _validateSession(
    PatchbayDirectSession session,
    Duration timeout,
    int maxResponseBodyBytes,
  ) {
    final Uri endpoint = session.endpoint;
    if (endpoint.scheme != 'http' ||
        endpoint.host.isEmpty ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.query.isNotEmpty ||
        endpoint.fragment.isNotEmpty ||
        endpoint.path != PatchbayDirectHost.protocolPathPrefix ||
        session.bearerToken.isEmpty) {
      throw ArgumentError.value(session.endpoint, 'session.endpoint');
    }
    if (timeout <= Duration.zero || maxResponseBodyBytes < 1) {
      throw ArgumentError('Client timeout and response limit must be positive');
    }
    return endpoint;
  }

  @override
  String toString() =>
      'PatchbayDirectClient(endpoint: $_endpoint, bearerToken: <redacted>)';
}

/// Typed client failure that contains no request body, URI query, or token.
final class PatchbayDirectClientException implements Exception {
  const PatchbayDirectClientException(this.code, {this.statusCode});

  final String code;
  final int? statusCode;

  @override
  String toString() =>
      'PatchbayDirectClientException(code: $code, statusCode: $statusCode)';
}
