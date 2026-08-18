import 'dart:convert';

import 'package:patchbay/patchbay.dart';
import 'package:patchbay_cli/patchbay_cli.dart';
import 'package:test/test.dart';

import 'fixture/fake_client.dart';

Map<String, Object?> _schema() => <String, Object?>{
  'accepted': <String, Object?>{
    'type': 'object',
    'properties': <String, Object?>{
      'session': <String, Object?>{'type': 'string'},
    },
    'required': <String>['session'],
    'additionalProperties': false,
  },
};

Future<Map<String, Object?>> _run(
  FakePatchbayClient client, {
  bool wait = false,
}) async {
  final StringBuffer out = StringBuffer();
  final StringBuffer err = StringBuffer();
  await runPatchbayCli(
    <String>['--json', if (wait) '--wait', 'exec', 'fixture.command'],
    connect: (_) async => client,
    output: out,
    errorOutput: err,
  );
  return jsonDecode(out.toString()) as Map<String, Object?>;
}

void main() {
  test(
    'new CLI revalidates catalog schema without echoing bad values',
    () async {
      final Map<String, Object?> response = await _run(
        FakePatchbayClient(
          commands: <Map<String, Object?>>[
            <String, Object?>{
              'name': 'fixture.command',
              'responseSchema': _schema(),
            },
          ],
          handle: (_, _) async => fakeAccepted(<String, Object?>{
            'session': 7,
            'password': 'top-secret',
          }),
        ),
      );

      expect(response['schemaMode'], 'validated');
      final Map<String, Object?> rejection =
          response['rejection']! as Map<String, Object?>;
      expect(rejection['code'], 'providerProtocolViolation');
      expect(response.toString(), isNot(contains('top-secret')));
    },
  );

  test('old host payload stays unchanged and is typed as legacy', () async {
    final Map<String, Object?> response = await _run(
      FakePatchbayClient(
        commands: const <Map<String, Object?>>[
          <String, Object?>{'name': 'fixture.command'},
        ],
        handle: (_, _) async =>
            fakeAccepted(<String, Object?>{'consumerField': 7}),
      ),
    );

    expect(response['schemaMode'], 'legacyUnvalidated');
    expect(response['payload'], <String, Object?>{'consumerField': 7});
  });

  test(
    'CLI validates the original job terminal schema after waiting',
    () async {
      final Map<String, Object?> response = await _run(
        FakePatchbayClient(
          commands: <Map<String, Object?>>[
            <String, Object?>{
              'name': 'fixture.command',
              'mode': 'job',
              'responseSchema': <String, Object?>{
                'accepted': <String, Object?>{
                  'type': 'object',
                  'properties': const <String, Object?>{},
                  'required': const <String>[],
                  'additionalProperties': false,
                },
                'terminal': <String, Object?>{
                  for (final String phase in <String>[
                    'completed',
                    'failed',
                    'cancelled',
                  ])
                    phase: <String, Object?>{
                      'type': 'object',
                      'properties': <String, Object?>{
                        'session': <String, Object?>{'type': 'string'},
                      },
                      'required': <String>['session'],
                      'additionalProperties': false,
                    },
                },
              },
            },
            const <String, Object?>{'name': 'patchbay.job.wait'},
          ],
          handle: (String command, _) async {
            if (command == 'fixture.command') {
              return <String, Object?>{
                'admission': 'accepted',
                'payload': const <String, Object?>{},
                'jobId': 'job-1',
              };
            }
            return fakeAccepted(
              PatchbayJobWaitResult(
                outcome: PatchbayJobWaitOutcome.changed,
                snapshot: PatchbayJobSnapshot(
                  jobId: 'job-1',
                  events: <PatchbayJobEvent>[
                    PatchbayJobEvent(
                      sequence: 1,
                      at: DateTime.utc(2026),
                      phase: PatchbayJobPhase.completed,
                      source: PatchbayFactSource.appRecorded,
                      payload: const <String, Object?>{'session': 7},
                    ),
                  ],
                ),
              ).toJson(),
            );
          },
        ),
        wait: true,
      );

      expect(response['schemaMode'], 'validated');
      expect(response['admission'], 'rejected');
      expect(response.toString(), contains(r'$.payload.session'));
    },
  );
}
