import 'dart:convert';

import 'package:patchbay/patchbay.dart';
import 'package:patchbay_cli/src/cli.dart';
import 'package:patchbay_cli/src/client.dart';
import 'package:patchbay_cli/src/result.dart';
import 'package:test/test.dart';

import 'fixture/fake_client.dart';

void main() {
  group('CLI idempotent retry', () {
    test('transport failures retry with one requestId', () async {
      var attempts = 0;
      final FakePatchbayClient client = _client(
        retryPolicy: const PatchbayRetryPolicy(maxAttempts: 3, backoffMs: 0),
        handle: (_, _) async {
          attempts += 1;
          if (attempts < 3) {
            throw const PatchbayTransportException('transportUnavailable');
          }
          return const <String, Object?>{
            'admission': 'accepted',
            'payload': <String, Object?>{'result': 'done'},
          };
        },
      );

      final _Run result = await _run(client, <String>[
        '--json',
        'exec',
        'device.write',
      ]);

      expect(result.exitCode, PatchbayExitCode.accepted);
      expect(client.calls, hasLength(3));
      expect(
        client.calls.map((FakeInvocation call) => call.requestId).toSet(),
        hasLength(1),
      );
      expect(client.calls.first.requestId, isNotNull);
      expect(result.json['schemaMode'], 'legacyUnvalidated');
    });

    test('a command without policy is never retried', () async {
      final FakePatchbayClient client = _client(
        handle: (_, _) async =>
            throw const PatchbayTransportException('transportUnavailable'),
      );

      final _Run result = await _run(client, <String>['exec', 'device.write']);

      expect(result.exitCode, PatchbayExitCode.transport);
      expect(client.calls, hasLength(1));
    });

    test('protocol errors and provider rejections are never retried', () async {
      for (final bool protocolError in <bool>[true, false]) {
        final FakePatchbayClient client = _client(
          retryPolicy: const PatchbayRetryPolicy(maxAttempts: 3, backoffMs: 0),
          handle: (_, _) async {
            if (protocolError) {
              throw const PatchbayProtocolException('badEnvelope');
            }
            return const <String, Object?>{
              'admission': 'rejected',
              'rejection': <String, Object?>{'code': 'providerRefused'},
            };
          },
        );

        final _Run result = await _run(client, <String>[
          'exec',
          'device.write',
        ]);

        expect(client.calls, hasLength(1));
        expect(
          result.exitCode,
          protocolError ? PatchbayExitCode.protocol : PatchbayExitCode.rejected,
        );
      }
    });

    for (final String code in <String>['expired', 'busy']) {
      test('$code is never retried as transport unavailability', () async {
        final FakePatchbayClient client = _client(
          retryPolicy: const PatchbayRetryPolicy(maxAttempts: 3, backoffMs: 0),
          handle: (_, _) async => throw PatchbayTransportException(code),
        );

        final _Run result = await _run(client, <String>[
          'exec',
          'device.write',
        ]);

        expect(result.exitCode, PatchbayExitCode.transport);
        expect(client.calls, hasLength(1));
      });
    }
  });

  group('CLI describe', () {
    test('reports the live row and never invokes it', () async {
      final FakePatchbayClient client = _client(
        retryPolicy: const PatchbayRetryPolicy(maxAttempts: 2, backoffMs: 100),
        responseSchema: const <String, Object?>{
          'accepted': <String, Object?>{
            'type': 'object',
            'properties': <String, Object?>{},
            'required': <String>[],
            'additionalProperties': false,
          },
        },
      );

      final _Run result = await _run(client, <String>[
        '--json',
        'describe',
        'device.write',
      ]);

      expect(result.exitCode, PatchbayExitCode.accepted);
      expect(client.calls, isEmpty);
      expect(client.catalogReads, 1);
      expect(result.json['schemaMode'], 'validated');
      expect(result.json['retryEligibility'], 'eligible');
      expect(
        (result.json['command']! as Map<String, Object?>)['retryPolicy'],
        const <String, Object?>{'maxAttempts': 2, 'backoffMs': 100},
      );
    });

    test('distinguishes notDeclared from notExternal', () async {
      for (final String sideEffect in <String>['external', 'appState']) {
        final FakePatchbayClient client = _client(sideEffect: sideEffect);
        final _Run result = await _run(client, <String>[
          '--json',
          'describe',
          'device.write',
        ]);

        expect(
          result.json['retryEligibility'],
          sideEffect == 'external' ? 'notDeclared' : 'notExternal',
        );
        expect(result.json['schemaMode'], 'legacyUnvalidated');
        expect(client.calls, isEmpty);
      }
    });
  });
}

FakePatchbayClient _client({
  PatchbayRetryPolicy? retryPolicy,
  String sideEffect = 'external',
  Map<String, Object?>? responseSchema,
  Future<Map<String, Object?>> Function(String, Map<String, Object?>)? handle,
}) => FakePatchbayClient(
  commands: <Map<String, Object?>>[
    <String, Object?>{
      'name': 'device.write',
      'sideEffect': sideEffect,
      if (retryPolicy != null) 'retryPolicy': retryPolicy.toJson(),
      if (responseSchema != null) 'responseSchema': responseSchema,
    },
  ],
  handle:
      handle ??
      (_, _) async => const <String, Object?>{
        'admission': 'accepted',
        'payload': <String, Object?>{},
      },
);

Future<_Run> _run(FakePatchbayClient client, List<String> arguments) async {
  final StringBuffer out = StringBuffer();
  final StringBuffer err = StringBuffer();
  final int exitCode = await runPatchbayCliWithSeams(
    arguments,
    connect: (_) async => client,
    output: out,
    errorOutput: err,
  );
  final String output = out.toString().trim();
  return _Run(
    exitCode,
    output.isEmpty
        ? const <String, Object?>{}
        : Map<String, Object?>.from(jsonDecode(output) as Map<String, dynamic>),
    err.toString(),
  );
}

final class _Run {
  const _Run(this.exitCode, this.json, this.error);

  final int exitCode;
  final Map<String, Object?> json;
  final String error;
}
