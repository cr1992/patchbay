import 'dart:convert';

import 'package:patchbay_cli/patchbay_cli.dart';
import 'package:test/test.dart';

import 'fixture/fake_client.dart';

/// A navigation host whose live revision is [liveRevision] and which reports
/// [reportedRevision] from `navigation.current`.
///
/// The two are separate on purpose: making them differ is how a test can show
/// that the App still refuses a stale fence even when the CLI is the one that
/// read it.
FakePatchbayClient _client({
  int liveRevision = 7,
  int? reportedRevision,
  Map<String, Object?>? currentResponse,
}) {
  final int reported = reportedRevision ?? liveRevision;
  return FakePatchbayClient(
    commands: <Map<String, Object?>>[
      for (final String name in <String>[
        'navigation.current',
        'navigation.go',
        'navigation.push',
        'navigation.back',
      ])
        <String, Object?>{'name': name},
    ],
    handle: (String command, Map<String, Object?> arguments) async {
      if (command == 'navigation.current') {
        return currentResponse ??
            fakeAccepted(<String, Object?>{
              'outcome': 'observed',
              'source': 'appRecorded',
              'navigationRevision': reported,
              'destinationId': 'home',
            });
      }
      if (arguments['revision'] != liveRevision) {
        return <String, Object?>{
          'admission': 'rejected',
          'rejection': <String, Object?>{
            'code': 'navigationRevisionStale',
            'details': <String, Object?>{
              'expected': arguments['revision'],
              'current': liveRevision,
            },
          },
        };
      }
      return fakeAccepted(<String, Object?>{
        'outcome': 'completed',
        'source': 'uiObserved',
        'arguments': arguments,
      });
    },
  );
}

Future<
  ({int exitCode, Map<String, Object?>? response, FakePatchbayClient client})
>
_run(List<String> arguments, {FakePatchbayClient? client}) async {
  final FakePatchbayClient fake = client ?? _client();
  final StringBuffer out = StringBuffer();
  final StringBuffer err = StringBuffer();
  final int exitCode = await runPatchbayCli(
    arguments,
    connect: (_) async => fake,
    output: out,
    errorOutput: err,
  );
  return (exitCode: exitCode, response: _decode(out.toString()), client: fake);
}

Map<String, Object?>? _decode(String out) =>
    out.trim().isEmpty ? null : jsonDecode(out) as Map<String, Object?>;

void main() {
  for (final (String name, List<String> words) in <(String, List<String>)>[
    ('go', <String>['navigation', 'go', 'settings']),
    ('push', <String>['navigation', 'push', 'details']),
    ('back', <String>['navigation', 'back']),
  ]) {
    test(
      '$name without --revision reads the current one and sends it',
      () async {
        final result = await _run(<String>['--json', ...words]);

        expect(result.exitCode, PatchbayExitCode.accepted);
        expect(
          result.client.calls.map((FakeInvocation call) => call.command),
          <String>['navigation.current', 'navigation.$name'],
        );
        // The fence travels: the App receives the revision it just reported, not
        // a request without one.
        expect(result.client.calls.last.arguments['revision'], 7);
        expect(result.response!['revisionSource'], 'navigation.current');
      },
    );
  }

  test('an explicit --revision is never second-guessed', () async {
    final result = await _run(<String>[
      '--json',
      '--revision',
      '7',
      'navigation',
      'go',
      'settings',
    ]);

    expect(result.exitCode, PatchbayExitCode.accepted);
    expect(
      result.client.calls.map((FakeInvocation call) => call.command),
      <String>['navigation.go'],
    );
    expect(result.response!.containsKey('revisionSource'), isFalse);
  });

  test('the App still refuses a fence that moved under the read', () async {
    // navigation.current answered 7, the tree is already at 8: the sugar
    // removes a round trip, never the race check.
    final result = await _run(<String>[
      '--json',
      'navigation',
      'go',
      'settings',
    ], client: _client(liveRevision: 8, reportedRevision: 7));

    expect(result.exitCode, PatchbayExitCode.rejected);
    expect(
      (result.response!['rejection']! as Map<String, Object?>)['code'],
      'navigationRevisionStale',
    );
  });

  test('a refused revision read is reported as itself', () async {
    final result = await _run(
      <String>['--json', 'navigation', 'go', 'settings'],
      client: _client(
        currentResponse: <String, Object?>{
          'admission': 'rejected',
          'rejection': <String, Object?>{'code': 'navigationNotReady'},
        },
      ),
    );

    expect(result.exitCode, PatchbayExitCode.rejected);
    expect(
      (result.response!['rejection']! as Map<String, Object?>)['code'],
      'navigationNotReady',
    );
    expect(result.response!['revisionSource'], 'navigation.current');
    // Nothing was dispatched on a fence the CLI never obtained.
    expect(
      result.client.calls.map((FakeInvocation call) => call.command),
      <String>['navigation.current'],
    );
  });

  test(
    'a revision-less navigation.current payload is a protocol error',
    () async {
      final result = await _run(
        <String>['--json', 'navigation', 'go', 'settings'],
        client: _client(
          currentResponse: fakeAccepted(<String, Object?>{
            'outcome': 'observed',
            'source': 'appRecorded',
            'destinationId': 'home',
          }),
        ),
      );

      expect(result.exitCode, PatchbayExitCode.protocol);
      expect(
        (result.response!['error']! as Map<String, Object?>)['code'],
        'navigationRevisionContractViolated',
      );
    },
  );
}
