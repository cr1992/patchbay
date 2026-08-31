// PB-060-06: property tests over every public decoder of the direct transport.
//
// The generators, the operation registry and the closed rejection sets live in
// `malformed_payload_harness.dart`. This file only states the invariants:
//
//   typed        every rejection carries a status and an `error.code` from the
//                closed sets — never `internalError`, never an untyped 500;
//   no partial   a rejected payload reaches no application handler;
//   no hang      every case answers inside a bounded budget and the host keeps
//                serving afterwards;
//   no echo      no response quotes the payload or the bearer token.
//
// Cases that the transport is *allowed* to forward (an oversized value in a
// field whose vocabulary belongs to the consumer) still owe the last three.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:patchbay_transport/patchbay_transport.dart';
import 'package:test/test.dart';

import 'malformed_payload_harness.dart';

/// Budget for one malformed request. Generous enough for a loopback round trip,
/// small enough that a wedged decoder fails instead of stalling the suite.
const Duration _caseBudget = Duration(seconds: 5);

void main() {
  final int seed = resolveMalformedSeed();

  setUpAll(() {
    // Printed once so a red run states the seed needed to replay it.
    printOnFailure('PATCHBAY_MALFORMED_SEED=$seed');
  });

  group('decoder registry closure', () {
    test('registry covers every operation the host serves', () {
      expect(
        wireOperations.map((WireOperation operation) => operation.name).toSet(),
        hostOperationsInSource(),
        reason:
            'a new host operation must be registered in wireOperations before '
            'it ships, otherwise its decoder is never fuzzed',
      );
    });

    test('registry covers every operation the client calls', () {
      expect(
        wireOperations.map((WireOperation operation) => operation.name).toSet(),
        clientOperationsInSource(),
      );
    });

    test('every registered operation has a reachable valid form', () async {
      final _Harness harness = await _Harness.start();
      addTearDown(harness.dispose);

      for (final WireOperation operation in wireOperations) {
        final _RawResponse response = await harness.post(
          operation.name,
          utf8.encode(jsonEncode(operation.validBody())),
        );
        expect(
          response.statusCode,
          HttpStatus.ok,
          reason:
              'the harness must fuzz a genuinely valid ${operation.name} body; '
              'got ${response.text}',
        );
      }
    });
  });

  group('host request decoders', () {
    test('same seed produces the same cases', () {
      final List<MalformedCase> first = MalformedPayloadGenerator(
        seed: 12345,
      ).generate();
      final List<MalformedCase> second = MalformedPayloadGenerator(
        seed: 12345,
      ).generate();

      expect(
        second.map((MalformedCase item) => item.toString()),
        first.map((MalformedCase item) => item.toString()),
      );
      expect(
        second.map((MalformedCase item) => item.bytes.length),
        first.map((MalformedCase item) => item.bytes.length),
      );
      expect(first, isNotEmpty);
    });

    test('a different seed moves the truncation offsets', () {
      Iterable<String> truncationLabels(int seed) =>
          MalformedPayloadGenerator(seed: seed)
              .generate()
              .where(
                (MalformedCase item) =>
                    item.malformation == MalformationClass.byteTruncation,
              )
              .map((MalformedCase item) => item.label);

      expect(truncationLabels(1).toList(), isNot(truncationLabels(2).toList()));
    });

    for (final MalformationClass malformation in MalformationClass.values) {
      test('${malformation.name} fails closed on every decoder', () async {
        final _Harness harness = await _Harness.start();
        addTearDown(harness.dispose);

        final List<MalformedCase> cases = MalformedPayloadGenerator(seed: seed)
            .generate()
            .where((MalformedCase item) => item.malformation == malformation)
            .toList();
        expect(cases, isNotEmpty, reason: 'generator produced no cases');

        for (final MalformedCase item in cases) {
          final int handlerCallsBefore = harness.handlerCalls;
          final _RawResponse response = await harness
              .post(item.operation, item.bytes)
              .timeout(
                _caseBudget,
                onTimeout: () =>
                    fail('no answer within $_caseBudget for $item'),
              );

          expect(
            response.text,
            isNot(contains(harness.bearerToken)),
            reason: 'response leaked the bearer token for $item',
          );

          if (!item.mustBeRejected) {
            // A forwarded oversized value is legitimate; it must still be a
            // typed answer rather than a fault. No echo assertion here: once
            // the transport hands the value to the application, whether the
            // result quotes it back is the handler's contract, not this
            // boundary's — the harness handler deliberately echoes `requestId`
            // exactly as the real protocol does.
            expect(
              response.errorCode,
              isNot(PatchbayDirectErrorCode.internalError.name),
              reason: 'forwarded payload degraded into a fault for $item',
            );
            continue;
          }

          // A typed refusal must not quote the payload back. Only rejections
          // are held to this: it is the transport's own message that must stay
          // free of caller-controlled bytes.
          expect(
            response.text,
            isNot(contains(payloadSentinel)),
            reason: 'rejection echoed the payload for $item',
          );
          expect(
            closedRejectionStatuses,
            contains(response.statusCode),
            reason:
                'status ${response.statusCode} is outside the closed set '
                'for $item: ${response.text}',
          );
          expect(
            closedRejectionCodes,
            contains(response.errorCode),
            reason:
                'code ${response.errorCode} is outside the closed set '
                'for $item',
          );
          expect(
            harness.handlerCalls,
            handlerCallsBefore,
            reason: 'rejected payload reached an application handler for $item',
          );
        }

        // Liveness: the whole batch must leave the host serving.
        final _RawResponse survivor = await harness.post(
          'identity',
          utf8.encode(jsonEncode(harnessIdentity.toJson())),
        );
        expect(survivor.statusCode, HttpStatus.ok);
      });
    }

    test('each malformation class actually reaches its rejection kind', () async {
      // Without this, the suite could pass by generating nothing, or by every
      // case degenerating into one code. It asserts the *observed* outcome set
      // per class, so a decoder that stopped classifying identity drift (or a
      // generator that stopped producing truncations) turns red.
      final _Harness harness = await _Harness.start();
      addTearDown(harness.dispose);

      final List<MalformedCase> cases = MalformedPayloadGenerator(
        seed: seed,
      ).generate();
      final Map<MalformationClass, Set<String>> observed =
          <MalformationClass, Set<String>>{};
      final Map<MalformationClass, int> volume = <MalformationClass, int>{};

      for (final MalformedCase item in cases) {
        final _RawResponse response = await harness.post(
          item.operation,
          item.bytes,
        );
        observed
            .putIfAbsent(item.malformation, () => <String>{})
            .add('${response.statusCode}/${response.errorCode ?? 'none'}');
        volume.update(
          item.malformation,
          (int value) => value + 1,
          ifAbsent: () => 1,
        );
      }

      const String protocolError = '400/protocolError';
      const String identityMismatch = '409/identityMismatch';

      expect(observed[MalformationClass.byteTruncation], <String>{
        protocolError,
      });
      expect(
        observed[MalformationClass.fieldTypeSubstitution],
        <String>{protocolError, identityMismatch},
        reason:
            'type substitution must reach both the shape and the identity '
            'decoder',
      );
      expect(
        observed[MalformationClass.boundedOversizedString],
        containsAll(<String>[identityMismatch, protocolError]),
      );
      expect(observed[MalformationClass.overLimitBody], <String>{
        '413/bodyTooLarge',
      });

      // Volume floors, not exact counts: the generators may grow, but a silent
      // collapse to a handful of cases must not pass.
      expect(
        volume[MalformationClass.byteTruncation],
        truncationsPerOperation * wireOperations.length,
      );
      expect(
        volume[MalformationClass.fieldTypeSubstitution],
        greaterThanOrEqualTo(100),
      );
      expect(
        volume[MalformationClass.boundedOversizedString],
        greaterThanOrEqualTo(wireOperations.length),
      );
      expect(volume[MalformationClass.overLimitBody], wireOperations.length);
    });

    test(
      'over-limit body is refused by the cap, not by a field decoder',
      () async {
        final _Harness harness = await _Harness.start();
        addTearDown(harness.dispose);

        final List<MalformedCase> cases = MalformedPayloadGenerator(seed: seed)
            .generate()
            .where(
              (MalformedCase item) =>
                  item.malformation == MalformationClass.overLimitBody,
            )
            .toList();
        expect(cases, hasLength(wireOperations.length));

        for (final MalformedCase item in cases) {
          final _RawResponse response = await harness.post(
            item.operation,
            item.bytes,
          );
          expect(
            response.errorCode,
            PatchbayDirectErrorCode.bodyTooLarge.name,
            reason: 'for $item',
          );
          expect(response.statusCode, HttpStatus.requestEntityTooLarge);
        }
        expect(harness.handlerCalls, 0);
      },
    );

    test(
      'malformed deadline headers fall back to the configured budget',
      () async {
        final _Harness harness = await _Harness.start();
        addTearDown(harness.dispose);

        const List<String> malformed = <String>[
          '',
          'abc',
          '-1',
          '0',
          '1.5',
          '1e9',
          '99999999999999999999',
          payloadSentinel,
        ];
        for (final String raw in malformed) {
          final _RawResponse response = await harness
              .post(
                'identity',
                utf8.encode(jsonEncode(harnessIdentity.toJson())),
                headers: <String, String>{
                  PatchbayDirectHost.deadlineHeader: raw,
                },
              )
              .timeout(
                _caseBudget,
                onTimeout: () => fail('deadline header "$raw" wedged the host'),
              );
          expect(
            response.statusCode,
            HttpStatus.ok,
            reason: 'deadline header "$raw" must be ignored, not fatal',
          );
          expect(response.text, isNot(contains(payloadSentinel)));
        }
      },
    );
  });

  group('client response decoders', () {
    test('malformed success envelopes are typed and quiet', () async {
      final _StubHost stub = await _StubHost.start();
      addTearDown(stub.dispose);

      final Map<String, Object?> validEnvelope = <String, Object?>{
        'schemaVersion': harnessIdentity.schemaVersion,
        'identity': harnessIdentity.toJson(),
        'result': <String, Object?>{'ok': true},
      };
      final List<int> validBytes = utf8.encode(jsonEncode(validEnvelope));

      final Map<String, List<int>> cases = <String, List<int>>{
        'truncated-envelope': validBytes.sublist(0, validBytes.length ~/ 2),
        'non-object-json': utf8.encode('[]'),
        'string-json': utf8.encode('"$payloadSentinel"'),
        'null-json': utf8.encode('null'),
        'not-json': utf8.encode(payloadSentinel),
        'identity-missing': utf8.encode(
          jsonEncode(<String, Object?>{...validEnvelope}..remove('identity')),
        ),
        'identity-wrong-type': utf8.encode(
          jsonEncode(<String, Object?>{
            ...validEnvelope,
            'identity': payloadSentinel,
          }),
        ),
        'identity-field-wrong-type': utf8.encode(
          jsonEncode(<String, Object?>{
            ...validEnvelope,
            'identity': <String, Object?>{
              'schemaVersion': '1',
              'applicationId': harnessIdentity.applicationId,
              'appInstanceId': harnessIdentity.appInstanceId,
            },
          }),
        ),
        'identity-other-runtime': utf8.encode(
          jsonEncode(<String, Object?>{
            ...validEnvelope,
            'identity': <String, Object?>{
              'schemaVersion': harnessIdentity.schemaVersion,
              'applicationId': 'com.example.other',
              'appInstanceId': payloadSentinel,
            },
          }),
        ),
        'schema-version-wrong-type': utf8.encode(
          jsonEncode(<String, Object?>{...validEnvelope, 'schemaVersion': '1'}),
        ),
        'result-wrong-type': utf8.encode(
          jsonEncode(<String, Object?>{
            ...validEnvelope,
            'result': payloadSentinel,
          }),
        ),
        'result-missing': utf8.encode(
          jsonEncode(<String, Object?>{...validEnvelope}..remove('result')),
        ),
      };

      for (final MapEntry<String, List<int>> entry in cases.entries) {
        stub.reply(statusCode: HttpStatus.ok, body: entry.value);
        final PatchbayDirectClient client = stub.newClient();
        try {
          await client.identity().timeout(
            _caseBudget,
            onTimeout: () => fail('client hung on ${entry.key}'),
          );
          fail('client accepted malformed envelope ${entry.key}');
        } on PatchbayDirectClientException catch (error) {
          expect(
            closedClientRejectionCodes,
            contains(error.code),
            reason:
                'code ${error.code} is outside the closed set '
                'for ${entry.key}',
          );
          expect(error.toString(), isNot(contains(payloadSentinel)));
          expect(error.toString(), isNot(contains(stub.bearerToken)));
        } finally {
          client.close(force: true);
        }
      }
    });

    test('malformed error envelopes still yield a typed code', () async {
      final _StubHost stub = await _StubHost.start();
      addTearDown(stub.dispose);

      final Map<String, List<int>> cases = <String, List<int>>{
        'error-not-object': utf8.encode(
          jsonEncode(<String, Object?>{'error': payloadSentinel}),
        ),
        'error-code-not-string': utf8.encode(
          jsonEncode(<String, Object?>{
            'error': <String, Object?>{'code': 42},
          }),
        ),
        'error-missing': utf8.encode(jsonEncode(<String, Object?>{})),
        'error-truncated': utf8.encode('{"error":{"code":"prot'),
      };

      for (final MapEntry<String, List<int>> entry in cases.entries) {
        stub.reply(statusCode: HttpStatus.badRequest, body: entry.value);
        final PatchbayDirectClient client = stub.newClient();
        try {
          await client.catalog();
          fail('client accepted error envelope ${entry.key}');
        } on PatchbayDirectClientException catch (error) {
          expect(closedClientRejectionCodes, contains(error.code));
          expect(error.toString(), isNot(contains(payloadSentinel)));
        } finally {
          client.close(force: true);
        }
      }
    });

    test('bounded oversized response is refused by the client cap', () async {
      final _StubHost stub = await _StubHost.start();
      addTearDown(stub.dispose);

      final StringBuffer filler = StringBuffer();
      while (filler.length < maxGeneratedStringBytes) {
        filler.write(payloadSentinel);
      }
      stub.reply(
        statusCode: HttpStatus.ok,
        body: utf8.encode(
          jsonEncode(<String, Object?>{
            'schemaVersion': harnessIdentity.schemaVersion,
            'identity': harnessIdentity.toJson(),
            'result': <String, Object?>{'filler': filler.toString()},
          }),
        ),
      );
      final PatchbayDirectClient client = stub.newClient(
        maxResponseBodyBytes: 1024,
      );
      try {
        await client.identity();
        fail('client accepted a response past its own cap');
      } on PatchbayDirectClientException catch (error) {
        expect(error.code, 'responseTooLarge');
        expect(error.toString(), isNot(contains(payloadSentinel)));
      } finally {
        client.close(force: true);
      }
    });
  });
}

/// A running [PatchbayDirectHost] with counted application handlers.
///
/// The identity handler is deliberately not counted: the host reads the pinned
/// runtime on every authorized request before dispatch, so it is part of the
/// decode path rather than an application side effect.
final class _Harness {
  _Harness._(this._host, this._session, this._client);

  static Future<_Harness> start() async {
    late final _Harness harness;
    final PatchbayDirectHost host = PatchbayDirectHost(
      handlers: PatchbayDirectHandlers(
        identity: () async => harnessIdentity,
        catalog: () async {
          harness._handlerCalls += 1;
          return <String, Object?>{
            'commands': <Object?>['probe.read'],
          };
        },
        snapshot: ([Map<String, Object?>? request]) async {
          harness._handlerCalls += 1;
          return <String, Object?>{'state': 'ready'};
        },
        invokeWithContext:
            (
              String command,
              Map<String, Object?> arguments,
              String requestId, {
              String? ownerToken,
              Duration? deadline,
            }) {
              harness._handlerCalls += 1;
              final Future<Map<String, Object?>> response =
                  Future<Map<String, Object?>>.value(<String, Object?>{
                    'requestId': requestId,
                  });
              return PatchbayDirectInvocationHandle(
                response: response,
                lifecycle: response.then<void>((_) {}),
              );
            },
        cancelInvocation:
            (
              String command,
              String requestId,
              String ownerToken, {
              required String reason,
            }) async {
              harness._handlerCalls += 1;
              return <String, Object?>{
                'requestId': requestId,
                'reason': reason,
              };
            },
      ),
    );
    final PatchbayDirectSession session = await host.start();
    harness = _Harness._(host, session, HttpClient());
    return harness;
  }

  final PatchbayDirectHost _host;
  final PatchbayDirectSession _session;
  final HttpClient _client;
  int _handlerCalls = 0;

  int get handlerCalls => _handlerCalls;
  String get bearerToken => _session.bearerToken;

  Future<_RawResponse> post(
    String operation,
    List<int> body, {
    Map<String, String> headers = const <String, String>{},
  }) async {
    final Uri uri = _session.endpoint.replace(
      path: '${_session.endpoint.path}/$operation',
    );
    final HttpClientRequest request = await _client.postUrl(uri);
    request.headers.contentType = ContentType.json;
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer ${_session.bearerToken}',
    );
    headers.forEach(request.headers.set);
    request.add(body);
    final HttpClientResponse response = await request.close();
    final String text = await utf8.decoder
        .bind(response)
        .join()
        .catchError((Object _) => '');
    return _RawResponse(statusCode: response.statusCode, text: text);
  }

  Future<void> dispose() async {
    _client.close(force: true);
    await _host.stop();
  }
}

final class _RawResponse {
  const _RawResponse({required this.statusCode, required this.text});

  final int statusCode;
  final String text;

  /// `error.code` when the body is a well-formed error envelope.
  String? get errorCode {
    try {
      final Object? decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) return null;
      final Object? error = decoded['error'];
      if (error is! Map<String, dynamic>) return null;
      final Object? code = error['code'];
      return code is String ? code : null;
    } on FormatException {
      return null;
    }
  }
}

/// A bare HTTP server that replays a caller-supplied response.
///
/// It exists so the *client's* decoder can be fuzzed: the real host can only
/// produce well-formed envelopes, so it cannot exercise this direction.
final class _StubHost {
  _StubHost._(this._server);

  static Future<_StubHost> start() async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final _StubHost stub = _StubHost._(server);
    server.listen(
      (HttpRequest request) async {
        await request.drain<void>();
        request.response.statusCode = stub._statusCode;
        request.response.headers.contentType = ContentType.json;
        request.response.add(stub._body);
        await request.response.close();
      },
      onError: (Object _, StackTrace _) {},
      cancelOnError: false,
    );
    return stub;
  }

  final HttpServer _server;
  int _statusCode = HttpStatus.ok;
  List<int> _body = const <int>[];

  String get bearerToken => 'stub-${payloadSentinel.hashCode}';

  void reply({required int statusCode, required List<int> body}) {
    _statusCode = statusCode;
    _body = body;
  }

  PatchbayDirectClient newClient({int maxResponseBodyBytes = 1024 * 1024}) =>
      PatchbayDirectClient(
        session: PatchbayDirectSession.create(
          endpoint: Uri(
            scheme: 'http',
            host: _server.address.address,
            port: _server.port,
            path: PatchbayDirectHost.protocolPathPrefix,
          ),
          bearerToken: bearerToken,
          expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 5)),
          identity: harnessIdentity,
          lanExposure: PatchbayLanExposure.disabled,
        ),
        timeout: _caseBudget,
        maxResponseBodyBytes: maxResponseBodyBytes,
      );

  Future<void> dispose() => _server.close(force: true);
}
