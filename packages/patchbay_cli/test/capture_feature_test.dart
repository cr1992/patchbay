import 'dart:convert';

import 'package:patchbay/patchbay.dart';
import 'package:patchbay_cli/src/cli.dart';
import 'package:patchbay_cli/src/result.dart';
import 'package:test/test.dart';

import 'fixture/fake_client.dart';

Future<({Map<String, Object?> output, FakePatchbayClient client})> _runCapture({
  required Map<String, Object?> identity,
}) async {
  final FakePatchbayClient client = FakePatchbayClient(
    identityData: identity,
    commands: const <Map<String, Object?>>[
      <String, Object?>{'name': 'ui.capture'},
    ],
    handle: (_, _) async => <String, Object?>{
      'admission': 'rejected',
      'rejection': const <String, Object?>{'code': 'fixtureCaptureStopped'},
    },
  );
  final StringBuffer output = StringBuffer();
  final int exitCode = await runPatchbayCliWithSeams(
    const <String>[
      '--json',
      '--after-frames',
      '7',
      '--output',
      '/tmp/not-written.png',
      'capture',
      'root',
    ],
    connect: (_) async => client,
    output: output,
    errorOutput: StringBuffer(),
  );
  expect(exitCode, PatchbayExitCode.rejected);
  return (
    output: jsonDecode(output.toString()) as Map<String, Object?>,
    client: client,
  );
}

void main() {
  test(
    'declared afterFrames capability sends the requested frame count',
    () async {
      final result = await _runCapture(
        identity: <String, Object?>{
          ...legacyFakeIdentity,
          'features': <String>[PatchbayFeature.captureAfterFrames.name],
        },
      );

      expect(result.client.calls.single.arguments['afterFrames'], 7);
      expect(result.output['captureMode'], 'observedFrames');
    },
  );

  test(
    'undeclared capability degrades by omission, never error inference',
    () async {
      final result = await _runCapture(identity: legacyFakeIdentity);

      expect(
        result.client.calls.single.arguments,
        isNot(contains('afterFrames')),
      );
      expect(result.output['captureMode'], 'legacyImmediate');
      expect(result.output['captureNotice'], contains('captureAfterFrames'));
      expect(
        (result.output['rejection']! as Map<String, Object?>)['code'],
        'fixtureCaptureStopped',
      );
    },
  );

  test(
    'capture diff maps two blob ids to the shared service command',
    () async {
      final FakePatchbayClient client = FakePatchbayClient(
        commands: const <Map<String, Object?>>[
          <String, Object?>{'name': 'ui.capture.diff'},
        ],
        handle: (_, arguments) async => fakeAccepted(<String, Object?>{
          'outcome': 'compared',
          'source': 'uiObserved',
          'changedPixels': 1,
          'totalPixels': 2,
          'differenceRatio': 0.5,
          'arguments': arguments,
        }),
      );
      final StringBuffer output = StringBuffer();
      final int exitCode = await runPatchbayCliWithSeams(
        const <String>['--json', 'capture', 'diff', 'before', 'after'],
        connect: (_) async => client,
        output: output,
        errorOutput: StringBuffer(),
      );

      expect(exitCode, PatchbayExitCode.accepted);
      expect(client.calls.single.command, 'ui.capture.diff');
      expect(client.calls.single.arguments, <String, Object?>{
        'beforeBlobId': 'before',
        'afterBlobId': 'after',
      });
      final Map<String, Object?> response =
          jsonDecode(output.toString()) as Map<String, Object?>;
      expect(
        (response['payload']! as Map<String, Object?>)['differenceRatio'],
        0.5,
      );
    },
  );
}
