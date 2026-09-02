import 'dart:convert';

import 'package:patchbay_cli/src/cli.dart';
import 'package:patchbay_cli/src/command_registry.dart';
import 'package:patchbay_cli/src/commands/command_parser.dart';
import 'package:patchbay_cli/src/direct_connection.dart';
import 'package:patchbay_cli/src/result.dart';
import 'package:patchbay_transport/patchbay_transport.dart';
import 'package:test/test.dart';

import 'fixture/fake_client.dart';

PatchbayFriendlyInvocation _resolve(
  List<String> argv, {
  String Function()? stdin,
}) {
  final parsed = patchbayCliParser().parse(argv);
  final PatchbayFriendlyInvocation? invocation =
      PatchbayFriendlyCommandRegistry.resolve(
        parsed.rest,
        parsed,
        readSensitiveInput:
            stdin ?? () => fail('sensitive stdin must not be read here'),
      );
  expect(invocation, isNotNull, reason: argv.join(' '));
  return invocation!;
}

void _expectRoute(
  PatchbayFriendlyInvocation invocation, {
  required String selectorKind,
  required String executionPath,
  required String serviceCommand,
}) {
  expect(invocation.serviceCommand, serviceCommand);
  expect(invocation.localRoute, <String, Object?>{
    'selectorKind': selectorKind,
    'executionPath': executionPath,
    'serviceCommand': serviceCommand,
  });
}

final class _Run {
  const _Run(this.exitCode, this.out, this.err, this.client);

  final int exitCode;
  final String out;
  final String err;
  final FakePatchbayClient client;

  Map<String, Object?> get json => jsonDecode(out) as Map<String, Object?>;
}

Future<_Run> _run(
  List<String> arguments, {
  List<Map<String, Object?>> commands = const <Map<String, Object?>>[],
  Future<Map<String, Object?>> Function(
    String command,
    Map<String, Object?> arguments,
  )?
  handle,
  Iterable<String>? replInput,
}) async {
  final FakePatchbayClient client = FakePatchbayClient(
    commands: commands,
    handle:
        handle ??
        (String command, Map<String, Object?> arguments) async =>
            fakeCommandNotRegistered(),
  );
  final StringBuffer out = StringBuffer();
  final StringBuffer err = StringBuffer();
  final int exitCode = await runPatchbayCliWithSeams(
    arguments,
    connect: (_) async => client,
    replInput: replInput == null
        ? null
        : Stream<String>.fromIterable(replInput),
    output: out,
    errorOutput: err,
  );
  return _Run(exitCode, out.toString(), err.toString(), client);
}

void main() {
  group('canonical routing reuses protocol descriptor decoding', () {
    test('registered targets preserve identifier colons and text stdin', () {
      final PatchbayFriendlyInvocation setText = _resolve(<String>[
        'ui',
        'perform',
        'set-text',
        'target:form:email',
        '3',
        'hello',
        'world',
      ]);
      _expectRoute(
        setText,
        selectorKind: 'target',
        executionPath: 'directTarget',
        serviceCommand: 'ui.text.set',
      );
      expect(setText.arguments, <String, Object?>{
        'id': 'form:email',
        'generation': 3,
        'text': 'hello world',
        'inputWasStdin': false,
      });

      final PatchbayFriendlyInvocation enterText = _resolve(<String>[
        '--stdin',
        'ui',
        'perform',
        'enter-text',
        'target:search',
        '4',
      ], stdin: () => 'private input');
      _expectRoute(
        enterText,
        selectorKind: 'target',
        executionPath: 'directTarget',
        serviceCommand: 'ui.text.enter',
      );
      expect(enterText.arguments, <String, Object?>{
        'id': 'search',
        'generation': 4,
        'text': 'private input',
        'inputWasStdin': true,
      });
    });

    test('tap requires and preserves the selected execution channel', () {
      final PatchbayFriendlyInvocation semantics = _resolve(<String>[
        '--via',
        'semantics',
        'ui',
        'perform',
        'tap',
        'semantics:login:submit',
        '5',
      ]);
      _expectRoute(
        semantics,
        selectorKind: 'semantics',
        executionPath: 'semanticsAction',
        serviceCommand: 'ui.semantics.tap',
      );
      expect(semantics.arguments, <String, Object?>{
        'identifier': 'login:submit',
        'generation': 5,
      });

      final PatchbayFriendlyInvocation pointer = _resolve(<String>[
        '--via',
        'pointer',
        '--start',
        '{"x":0.25,"y":0.75}',
        'ui',
        'perform',
        'tap',
        'semantics:login:submit',
        '5',
      ]);
      _expectRoute(
        pointer,
        selectorKind: 'semantics',
        executionPath: 'pointerGesture',
        serviceCommand: 'ui.gesture.tap',
      );
      expect(pointer.arguments, <String, Object?>{
        'identifier': 'login:submit',
        'generation': 5,
        'start': <String, Object?>{'x': 0.25, 'y': 0.75},
      });
    });

    test('action selects identifier or node service without guessing', () {
      final PatchbayFriendlyInvocation byIdentifier = _resolve(<String>[
        'ui',
        'perform',
        'action',
        'semantics:profile:field',
        '6',
        'setText',
        'Ada',
      ]);
      _expectRoute(
        byIdentifier,
        selectorKind: 'semantics',
        executionPath: 'semanticsAction',
        serviceCommand: 'ui.semantics.actionByIdentifier',
      );
      expect(byIdentifier.arguments, <String, Object?>{
        'identifier': 'profile:field',
        'generation': 6,
        'action': 'setText',
        'text': 'Ada',
        'inputWasStdin': false,
      });

      final PatchbayFriendlyInvocation byNode = _resolve(<String>[
        'ui',
        'perform',
        'action',
        'node:42',
        '6',
        'focus',
      ]);
      _expectRoute(
        byNode,
        selectorKind: 'node',
        executionPath: 'semanticsAction',
        serviceCommand: 'ui.semantics.action',
      );
      expect(byNode.arguments, <String, Object?>{
        'nodeId': 42,
        'generation': 6,
        'action': 'focus',
        'inputWasStdin': false,
      });
    });

    test('pointer gestures and reveal inherit descriptor options/defaults', () {
      final List<
        ({
          List<String> argv,
          String command,
          String executionPath,
          Map<String, Object?> arguments,
        })
      >
      cases =
          <
            ({
              List<String> argv,
              String command,
              String executionPath,
              Map<String, Object?> arguments,
            })
          >[
            (
              argv: <String>[
                '--start',
                '{"x":0.5,"y":0.5}',
                'ui',
                'perform',
                'press-hold',
                'semantics:card',
                '7',
              ],
              command: 'ui.gesture.pressHold',
              executionPath: 'pointerGesture',
              arguments: <String, Object?>{
                'identifier': 'card',
                'generation': 7,
                'start': <String, Object?>{'x': 0.5, 'y': 0.5},
                'durationMs': 500,
              },
            ),
            (
              argv: <String>[
                '--start',
                '{"x":0.5,"y":0.5}',
                '--gesture-path',
                '[{"x":0.5,"y":0.2}]',
                'ui',
                'perform',
                'drag',
                'semantics:card',
                '7',
              ],
              command: 'ui.gesture.drag',
              executionPath: 'pointerGesture',
              arguments: <String, Object?>{
                'identifier': 'card',
                'generation': 7,
                'start': <String, Object?>{'x': 0.5, 'y': 0.5},
                'path': <Object?>[
                  <String, Object?>{'x': 0.5, 'y': 0.2},
                ],
                'durationMs': 300,
              },
            ),
            (
              argv: <String>[
                '--start',
                '{"x":0.5,"y":0.5}',
                '--velocity',
                '{"x":0,"y":-2}',
                'ui',
                'perform',
                'fling',
                'semantics:card',
                '7',
              ],
              command: 'ui.gesture.fling',
              executionPath: 'pointerGesture',
              arguments: <String, Object?>{
                'identifier': 'card',
                'generation': 7,
                'start': <String, Object?>{'x': 0.5, 'y': 0.5},
                'velocity': <String, Object?>{'x': 0, 'y': -2},
                'durationMs': 100,
              },
            ),
            (
              argv: <String>['ui', 'perform', 'reveal', 'semantics:row:42'],
              command: 'ui.reveal',
              executionPath: 'scrollReveal',
              arguments: <String, Object?>{
                'identifier': 'row:42',
                'direction': 'both',
                'maxSteps': 40,
                'timeoutMs': 5000,
              },
            ),
          ];

      for (final testCase in cases) {
        final PatchbayFriendlyInvocation invocation = _resolve(testCase.argv);
        _expectRoute(
          invocation,
          selectorKind: 'semantics',
          executionPath: testCase.executionPath,
          serviceCommand: testCase.command,
        );
        expect(
          invocation.arguments,
          testCase.arguments,
          reason: testCase.argv.join(' '),
        );
      }
    });
  });

  test(
    'canonical JSON reports localRoute without changing host fields',
    () async {
      final _Run result = await _run(
        <String>[
          '--json',
          'ui',
          'perform',
          'set-text',
          'target:field',
          '2',
          'hello',
        ],
        commands: <Map<String, Object?>>[
          <String, Object?>{'name': 'ui.text.set'},
        ],
        handle: (String command, Map<String, Object?> arguments) async =>
            fakeAccepted(<String, Object?>{
              'outcome': 'applied',
              'echo': arguments,
            }),
      );

      expect(result.exitCode, PatchbayExitCode.accepted);
      expect(result.err, isEmpty);
      expect(result.client.calls, hasLength(1));
      expect(result.client.calls.single.command, 'ui.text.set');
      expect(result.json, containsPair('requestId', 'fake-request'));
      expect(result.json, containsPair('admission', 'accepted'));
      expect(result.json['payload'], containsPair('outcome', 'applied'));
      expect(result.json['localRoute'], <String, Object?>{
        'selectorKind': 'target',
        'executionPath': 'directTarget',
        'serviceCommand': 'ui.text.set',
      });
    },
  );

  test(
    'canonical route reaches the same dispatcher over direct transport',
    () async {
      String? invokedCommand;
      Map<String, Object?>? invokedArguments;
      final PatchbayDirectHost host = PatchbayDirectHost(
        handlers: PatchbayDirectHandlers(
          identity: () async => const PatchbayDirectIdentity(
            schemaVersion: 1,
            applicationId: 'dev.patchbay.canonical-direct',
            appInstanceId: 'canonical-direct-instance',
          ),
          catalog: () async => <String, Object?>{
            'commands': <Object?>[
              <String, Object?>{'name': 'ui.text.set'},
            ],
            'uiTargets': const <Object?>[],
          },
          snapshot: ([_]) async => const <String, Object?>{},
          invoke:
              (
                String command,
                Map<String, Object?> arguments,
                requestId,
              ) async {
                invokedCommand = command;
                invokedArguments = arguments;
                return <String, Object?>{
                  'schemaVersion': 1,
                  'requestId': requestId,
                  'admission': 'accepted',
                  'payload': const <String, Object?>{'outcome': 'applied'},
                };
              },
        ),
      );
      final PatchbayDirectSession session = await host.start();
      addTearDown(host.stop);
      final PatchbayDirectConnection connection = PatchbayDirectConnection(
        endpoint: session.endpoint,
        bearerToken: session.bearerToken,
        schemaVersion: 1,
        applicationId: 'dev.patchbay.canonical-direct',
        appInstanceId: 'canonical-direct-instance',
      );
      final StringBuffer out = StringBuffer();
      final int exitCode = await runPatchbayCliWithSeams(
        <String>[
          '--json',
          'ui',
          'perform',
          'set-text',
          'target:field',
          '2',
          'hello',
        ],
        connect: (_) async => connection,
        output: out,
        errorOutput: StringBuffer(),
      );

      expect(exitCode, PatchbayExitCode.accepted);
      expect(invokedCommand, 'ui.text.set');
      expect(invokedArguments, <String, Object?>{
        'id': 'field',
        'generation': 2,
        'text': 'hello',
        'inputWasStdin': false,
      });
      final Map<String, Object?> response =
          jsonDecode(out.toString()) as Map<String, Object?>;
      expect(response['localRoute'], <String, Object?>{
        'selectorKind': 'target',
        'executionPath': 'directTarget',
        'serviceCommand': 'ui.text.set',
      });
    },
  );

  test('missing mapped service fails once without channel fallback', () async {
    final _Run result = await _run(
      <String>[
        '--json',
        '--via',
        'semantics',
        'ui',
        'perform',
        'tap',
        'semantics:submit',
        '9',
      ],
      commands: <Map<String, Object?>>[
        <String, Object?>{'name': 'ui.gesture.tap'},
      ],
    );

    expect(result.exitCode, PatchbayExitCode.protocol);
    expect(result.client.calls, hasLength(1));
    expect(result.client.calls.single.command, 'ui.semantics.tap');
    expect(result.json['rejection'], <String, Object?>{
      'code': 'commandNotRegistered',
    });
    expect(result.json['localRoute'], <String, Object?>{
      'selectorKind': 'semantics',
      'executionPath': 'semanticsAction',
      'serviceCommand': 'ui.semantics.tap',
    });
  });

  group('canonical usage rejects guessing and impossible selectors', () {
    for (final List<String> argv in <List<String>>[
      <String>['ui', 'perform', 'tap', 'semantics:submit', '1'],
      <String>[
        '--via',
        'semantics',
        'ui',
        'perform',
        'set-text',
        'target:field',
        '1',
      ],
      <String>['--via', 'pointer', 'ui', 'perform', 'tap', 'node:4', '1'],
      <String>['ui', 'perform', 'reveal', 'target:row'],
      <String>['ui', 'perform', 'action', 'target:field', '1', 'focus'],
      <String>['ui', 'perform', 'set-text', 'semantics:field', '1'],
      <String>['ui', 'perform', 'set-text', 'target:', '1'],
      <String>['ui', 'perform', 'action', 'node:-1', '1', 'focus'],
      <String>['ui', 'perform', 'action', 'label:submit', '1', 'tap'],
    ]) {
      test(argv.join(' '), () async {
        final _Run result = await _run(<String>['--json', ...argv]);

        expect(result.exitCode, PatchbayExitCode.usage);
        expect(result.json['error'], isA<Map<String, Object?>>());
        expect(result.client.calls, isEmpty);
      });
    }
  });

  test(
    'deprecated JSON entry keeps stdout and exit while warning once',
    () async {
      final _Run result = await _run(
        <String>['--json', 'ui', 'text', 'set', 'field', '2', 'hello'],
        commands: <Map<String, Object?>>[
          <String, Object?>{'name': 'ui.text.set'},
        ],
        handle: (String command, Map<String, Object?> arguments) async =>
            fakeAccepted(<String, Object?>{'outcome': 'applied'}),
      );

      expect(result.exitCode, PatchbayExitCode.accepted);
      expect(result.json.containsKey('localRoute'), isFalse);
      expect(result.out, '''{
  "schemaVersion": 1,
  "requestId": "fake-request",
  "admission": "accepted",
  "payload": {
    "outcome": "applied"
  },
  "schemaMode": "legacyUnvalidated"
}
''');
      expect(result.err.trim().split('\n'), hasLength(1));
      expect(result.err, contains('deprecated'));
      expect(result.err, contains('ui perform set-text target:<id>'));
    },
  );

  test('deprecated human entry keeps its summary and warns once', () async {
    final _Run result = await _run(
      <String>['ui', 'tap', 'submit', '--generation', '2'],
      commands: <Map<String, Object?>>[
        <String, Object?>{'name': 'ui.semantics.tap'},
      ],
      handle: (String command, Map<String, Object?> arguments) async =>
          fakeAccepted(<String, Object?>{'outcome': 'applied'}),
    );

    expect(result.exitCode, PatchbayExitCode.accepted);
    expect(result.out.trim(), startsWith('{"schemaVersion":1,'));
    expect(result.out, isNot(contains('localRoute')));
    expect(result.err.trim().split('\n'), hasLength(1));
    expect(result.err, contains('--via semantics'));
  });

  test('deprecated REPL entry warns once for its line', () async {
    final _Run result = await _run(
      <String>['--json', 'repl'],
      replInput: <String>['ui text set field 2 hello'],
      commands: <Map<String, Object?>>[
        <String, Object?>{'name': 'ui.text.set'},
      ],
      handle: (String command, Map<String, Object?> arguments) async =>
          fakeAccepted(<String, Object?>{'outcome': 'applied'}),
    );

    expect(result.exitCode, PatchbayExitCode.accepted);
    expect(result.client.calls, hasLength(1));
    expect(result.err.trim().split('\n'), hasLength(1));
    expect(result.err, contains('deprecated'));
    expect(result.out.trim().split('\n'), hasLength(1));
  });
}
