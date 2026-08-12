import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:patchbay_transport/patchbay_transport.dart';
import 'package:test/test.dart';

void main() {
  const PatchbayDirectIdentity identity = PatchbayDirectIdentity(
    schemaVersion: 1,
    applicationId: 'dev.patchbay.transport.test',
    appInstanceId: 'instance-a',
  );

  group('configuration boundary', () {
    test('construction is inert and defaults to loopback', () async {
      final PatchbayDirectHost host = _host(identity: identity);
      expect(host.isRunning, isFalse);
      expect(host.config.bindAddress.isLoopback, isTrue);
      expect(host.config.lanExposure, PatchbayLanExposure.disabled);
      expect(await _canConnect(InternetAddress.loopbackIPv4, 9), isFalse);
    });

    test('non-loopback bind requires explicit experimental LAN opt-in', () {
      expect(
        () => PatchbayDirectHostConfig(bindAddress: InternetAddress.anyIPv4),
        throwsA(
          isA<PatchbayDirectConfigurationException>().having(
            (PatchbayDirectConfigurationException error) => error.code,
            'code',
            PatchbayDirectConfigurationError.lanOptInRequired,
          ),
        ),
      );
      final PatchbayDirectHostConfig config = PatchbayDirectHostConfig(
        bindAddress: InternetAddress.anyIPv4,
        lanExposure: PatchbayLanExposure.experimentalSameTrustedNetworkOnly,
      );
      expect(config.bindAddress, InternetAddress.anyIPv4);
    });
  });

  group('real socket protocol', () {
    late PatchbayDirectHost host;
    late PatchbayDirectSession session;
    late PatchbayDirectClient client;

    setUp(() async {
      host = _host(identity: identity);
      session = await host.start();
      client = PatchbayDirectClient(session: session);
    });

    tearDown(() async {
      client.close(force: true);
      await host.stop();
    });

    test(
      'client covers identity, catalog, snapshot, and allowlisted invoke',
      () async {
        expect(await client.identity(), identity.toJson());
        expect(await client.catalog(), <String, Object?>{
          'commands': <Object?>['probe.read'],
        });
        expect(await client.snapshot(), <String, Object?>{'state': 'ready'});
        expect(
          await client.invoke(
            command: 'probe.read',
            arguments: <String, Object?>{'value': 7},
            requestId: 'request-1',
          ),
          <String, Object?>{
            'command': 'probe.read',
            'arguments': <String, Object?>{'value': 7},
            'requestId': 'request-1',
          },
        );
      },
    );

    test(
      'one client performs sequential requests despite server connection close',
      () async {
        expect(await client.catalog(), isNotEmpty);
        expect(await client.snapshot(), isNotEmpty);
        expect(await client.identity(), identity.toJson());
      },
    );

    test(
      'missing and incorrect bearer are typed unauthorized failures',
      () async {
        for (final String? token in <String?>[null, 'incorrect']) {
          final _WireResponse response = await _post(
            session.endpoint.resolve('${session.endpoint.path}/identity'),
            identity.toJson(),
            token: token,
          );
          expect(response.statusCode, HttpStatus.unauthorized);
          expect(response.errorCode, PatchbayDirectErrorCode.unauthorized.name);
        }
      },
    );

    test('request identity mismatch is typed without stopping host', () async {
      final _WireResponse response = await _post(
        session.endpoint.resolve('${session.endpoint.path}/snapshot'),
        <String, Object?>{
          ...identity.toJson(),
          'appInstanceId': 'stale-instance',
        },
        token: session.bearerToken,
      );
      expect(response.statusCode, HttpStatus.conflict);
      expect(response.errorCode, PatchbayDirectErrorCode.identityMismatch.name);
      expect(host.isRunning, isTrue);
    });

    test('browser Origin is rejected without CORS response headers', () async {
      final _WireResponse response = await _post(
        session.endpoint.resolve('${session.endpoint.path}/identity'),
        identity.toJson(),
        token: session.bearerToken,
        headers: <String, String>{'Origin': 'https://example.test'},
      );
      expect(response.statusCode, HttpStatus.forbidden);
      expect(response.errorCode, PatchbayDirectErrorCode.originDenied.name);
      expect(response.headers['access-control-allow-origin'], isNull);
    });

    test(
      'content type, query, non-object JSON, and unknown keys fail closed',
      () async {
        final Uri uri = session.endpoint.resolve(
          '${session.endpoint.path}/identity',
        );
        final List<_WireResponse> responses = <_WireResponse>[
          await _post(
            uri,
            identity.toJson(),
            token: session.bearerToken,
            contentType: ContentType.text,
          ),
          await _post(
            uri.replace(queryParameters: <String, String>{'token': 'x'}),
            identity.toJson(),
            token: session.bearerToken,
          ),
          await _postRaw(uri, '[]', token: session.bearerToken),
          await _post(uri, <String, Object?>{
            ...identity.toJson(),
            'extra': true,
          }, token: session.bearerToken),
        ];
        expect(
          responses.map((_WireResponse response) => response.errorCode),
          everyElement(PatchbayDirectErrorCode.protocolError.name),
        );
      },
    );

    test('oversized chunked request body is rejected', () async {
      final HttpClient socketClient = HttpClient();
      try {
        final HttpClientRequest request = await socketClient.postUrl(
          session.endpoint.resolve('${session.endpoint.path}/identity'),
        );
        request.headers.contentType = ContentType.json;
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'Bearer ${session.bearerToken}',
        );
        request.add(List<int>.filled(70 * 1024, 65));
        final HttpClientResponse response = await request.close();
        final Map<String, Object?> body = await _readJson(response);
        expect(response.statusCode, HttpStatus.requestEntityTooLarge);
        expect(_errorCode(body), PatchbayDirectErrorCode.bodyTooLarge.name);
      } finally {
        socketClient.close(force: true);
      }
    });

    test('stop closes the listener and redacts credentials', () async {
      final int port = session.endpoint.port;
      expect(session.endpoint.query, isEmpty);
      expect(session.toString(), isNot(contains(session.bearerToken)));
      expect(client.toString(), isNot(contains(session.bearerToken)));
      await host.stop();
      expect(await _canConnect(InternetAddress.loopbackIPv4, port), isFalse);
    });

    test(
      'client auth errors and diagnostics never expose either token or URI',
      () async {
        const String wrongToken = 'wrong-secret-token';
        final PatchbayDirectClient wrongClient = PatchbayDirectClient(
          session: PatchbayDirectSession.create(
            endpoint: session.endpoint,
            bearerToken: wrongToken,
            expiresAt: session.expiresAt,
            identity: session.identity,
            lanExposure: session.lanExposure,
          ),
        );
        try {
          await wrongClient.identity();
          fail('wrong bearer must fail');
        } on PatchbayDirectClientException catch (error) {
          final String diagnostic = error.toString();
          expect(error.code, PatchbayDirectErrorCode.unauthorized.name);
          expect(diagnostic, isNot(contains(wrongToken)));
          expect(diagnostic, isNot(contains(session.bearerToken)));
          expect(diagnostic, isNot(contains(session.endpoint.toString())));
        } finally {
          wrongClient.close(force: true);
        }
      },
    );

    test('client preserves typed responseTooLarge failure', () async {
      final PatchbayDirectClient limited = PatchbayDirectClient(
        session: session,
        maxResponseBodyBytes: 16,
      );
      try {
        await expectLater(
          limited.identity(),
          throwsA(
            isA<PatchbayDirectClientException>().having(
              (PatchbayDirectClientException error) => error.code,
              'code',
              PatchbayDirectErrorCode.responseTooLarge.name,
            ),
          ),
        );
      } finally {
        limited.close(force: true);
      }
    });
  });

  test(
    'secure random bearer has 256-bit input and rotates per start',
    () async {
      final PatchbayDirectHost first = _host(identity: identity);
      final PatchbayDirectHost second = _host(identity: identity);
      final PatchbayDirectSession firstSession = await first.start();
      final PatchbayDirectSession secondSession = await second.start();
      expect(PatchbayDirectHost.tokenBytes, 32);
      expect(firstSession.bearerToken, hasLength(43));
      expect(secondSession.bearerToken, isNot(firstSession.bearerToken));
      await first.stop();
      await second.stop();
    },
  );

  test(
    'concurrency limit returns busy while one handler owns the permit',
    () async {
      final Completer<void> entered = Completer<void>();
      final Completer<void> release = Completer<void>();
      final PatchbayDirectHost host = _host(
        identity: identity,
        snapshot: () async {
          entered.complete();
          await release.future;
          return <String, Object?>{'released': true};
        },
      );
      final PatchbayDirectSession session = await host.start();
      final PatchbayDirectClient first = PatchbayDirectClient(session: session);
      final Future<Map<String, Object?>> pending = first.snapshot();
      await entered.future;
      final _WireResponse busy = await _post(
        session.endpoint.resolve('${session.endpoint.path}/catalog'),
        identity.toJson(),
        token: session.bearerToken,
      );
      expect(busy.statusCode, HttpStatus.tooManyRequests);
      expect(busy.errorCode, PatchbayDirectErrorCode.busy.name);
      release.complete();
      expect(await pending, <String, Object?>{'released': true});
      first.close(force: true);
      await host.stop();
    },
  );

  test('response limit is typed and does not send a partial success', () async {
    final PatchbayDirectHost host = _host(
      identity: identity,
      config: PatchbayDirectHostConfig(maxResponseBodyBytes: 128),
      snapshot: () async => <String, Object?>{'value': 'x' * 256},
    );
    final PatchbayDirectSession session = await host.start();
    final _WireResponse response = await _post(
      session.endpoint.resolve('${session.endpoint.path}/snapshot'),
      identity.toJson(),
      token: session.bearerToken,
    );
    expect(response.statusCode, HttpStatus.internalServerError);
    expect(response.errorCode, PatchbayDirectErrorCode.responseTooLarge.name);
    await host.stop();
  });

  test('handler timeout is typed and closes the host', () async {
    final Completer<Map<String, Object?>> never =
        Completer<Map<String, Object?>>();
    final PatchbayDirectHost host = _host(
      identity: identity,
      config: PatchbayDirectHostConfig(
        requestTimeout: const Duration(milliseconds: 100),
      ),
      snapshot: () => never.future,
    );
    final PatchbayDirectSession session = await host.start();
    final _WireResponse response = await _post(
      session.endpoint.resolve('${session.endpoint.path}/snapshot'),
      identity.toJson(),
      token: session.bearerToken,
    );
    expect(response.statusCode, HttpStatus.gatewayTimeout);
    expect(response.errorCode, PatchbayDirectErrorCode.timeout.name);
    await _eventually(() => !host.isRunning);
    expect(host.stopReason, PatchbayDirectStopReason.requestTimeout);
  });

  test('identity drift returns typed error then closes host', () async {
    PatchbayDirectIdentity current = identity;
    final PatchbayDirectHost host = _host(identitySource: () async => current);
    final PatchbayDirectSession session = await host.start();
    current = const PatchbayDirectIdentity(
      schemaVersion: 1,
      applicationId: 'dev.patchbay.transport.test',
      appInstanceId: 'instance-b',
    );
    final _WireResponse response = await _post(
      session.endpoint.resolve('${session.endpoint.path}/identity'),
      identity.toJson(),
      token: session.bearerToken,
    );
    expect(response.statusCode, HttpStatus.conflict);
    expect(response.errorCode, PatchbayDirectErrorCode.identityDrift.name);
    await _eventually(() => !host.isRunning);
    expect(host.stopReason, PatchbayDirectStopReason.identityDrift);
  });

  test('injectable clock makes expiry deterministic and closes host', () async {
    DateTime now = DateTime.utc(2026, 8, 12);
    void Function()? expire;
    final PatchbayDirectHost host = _host(
      identity: identity,
      clock: () => now,
      expiryScheduler: (Duration _, void Function() callback) {
        expire = callback;
        return () {};
      },
    );
    final PatchbayDirectSession session = await host.start();
    now = now.add(const Duration(minutes: 11));
    final _WireResponse response = await _post(
      session.endpoint.resolve('${session.endpoint.path}/identity'),
      identity.toJson(),
      token: session.bearerToken,
    );
    expect(response.errorCode, PatchbayDirectErrorCode.expired.name);
    await _eventually(() => !host.isRunning);
    expect(host.stopReason, PatchbayDirectStopReason.tokenExpired);
    expire?.call();
  });

  test('background and identity-change hooks close immediately', () async {
    for (final Future<void> Function(PatchbayDirectHost) close
        in <Future<void> Function(PatchbayDirectHost)>[
          (PatchbayDirectHost host) => host.notifyBackgrounded(),
          (PatchbayDirectHost host) => host.notifyIdentityChanged(),
        ]) {
      final PatchbayDirectHost host = _host(identity: identity);
      final PatchbayDirectSession session = await host.start();
      await close(host);
      expect(
        await _canConnect(InternetAddress.loopbackIPv4, session.endpoint.port),
        isFalse,
      );
    }
  });
}

PatchbayDirectHost _host({
  PatchbayDirectIdentity? identity,
  PatchbayDirectIdentitySource? identitySource,
  PatchbayDirectHostConfig? config,
  PatchbayDirectSnapshotSource? snapshot,
  PatchbayDirectClock? clock,
  PatchbayDirectExpiryScheduler? expiryScheduler,
}) => PatchbayDirectHost(
  config: config,
  clock: clock,
  expiryScheduler: expiryScheduler,
  handlers: PatchbayDirectHandlers(
    identity: identitySource ?? () async => identity!,
    catalog: () async => <String, Object?>{
      'commands': <Object?>['probe.read'],
    },
    snapshot: snapshot ?? () async => <String, Object?>{'state': 'ready'},
    invoke:
        (
          String command,
          Map<String, Object?> arguments,
          String requestId,
        ) async => <String, Object?>{
          'command': command,
          'arguments': arguments,
          'requestId': requestId,
        },
  ),
);

Future<_WireResponse> _post(
  Uri uri,
  Map<String, Object?> body, {
  String? token,
  Map<String, String> headers = const <String, String>{},
  ContentType? contentType,
}) => _postRaw(
  uri,
  jsonEncode(body),
  token: token,
  headers: headers,
  contentType: contentType ?? ContentType.json,
);

Future<_WireResponse> _postRaw(
  Uri uri,
  String body, {
  String? token,
  Map<String, String> headers = const <String, String>{},
  ContentType? contentType,
}) async {
  final HttpClient client = HttpClient();
  try {
    final HttpClientRequest request = await client.postUrl(uri);
    request.headers.contentType = contentType ?? ContentType.json;
    if (token != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    headers.forEach(request.headers.set);
    request.add(utf8.encode(body));
    final HttpClientResponse response = await request.close();
    final Map<String, String> responseHeaders = <String, String>{};
    response.headers.forEach((String name, List<String> values) {
      responseHeaders[name] = values.join(',');
    });
    return _WireResponse(
      statusCode: response.statusCode,
      headers: responseHeaders,
      body: await _readJson(response),
    );
  } finally {
    client.close(force: true);
  }
}

Future<Map<String, Object?>> _readJson(HttpClientResponse response) async {
  final String text = await utf8.decoder.bind(response).join();
  return Map<String, Object?>.from(jsonDecode(text) as Map<String, dynamic>);
}

String? _errorCode(Map<String, Object?> body) {
  final Object? error = body['error'];
  return error is Map<String, dynamic> ? error['code'] as String? : null;
}

Future<bool> _canConnect(InternetAddress address, int port) async {
  try {
    final Socket socket = await Socket.connect(
      address,
      port,
      timeout: const Duration(milliseconds: 100),
    );
    await socket.close();
    return true;
  } on SocketException {
    return false;
  }
}

Future<void> _eventually(bool Function() predicate) async {
  for (int attempt = 0; attempt < 50; attempt += 1) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('condition was not reached');
}

final class _WireResponse {
  const _WireResponse({
    required this.statusCode,
    required this.headers,
    required this.body,
  });

  final int statusCode;
  final Map<String, String> headers;
  final Map<String, Object?> body;

  String? get errorCode => _errorCode(body);
}
