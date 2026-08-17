import 'dart:convert';

import 'package:patchbay_cli/patchbay_cli.dart';
import 'package:test/test.dart';

import 'fixture/fake_client.dart';

/// A catalog that publishes both inspect commands the way the Flutter host does.
FakePatchbayClient _client({
  bool inspectRegistered = true,
  Map<String, Object?> Function(Map<String, Object?> arguments)? select,
}) => FakePatchbayClient(
  commands: <Map<String, Object?>>[
    if (inspectRegistered) ...<Map<String, Object?>>[
      <String, Object?>{
        'name': 'ui.inspect.status',
        'mode': 'readOnly',
        'sideEffect': 'none',
      },
      <String, Object?>{
        'name': 'ui.inspect.select',
        'mode': 'immediate',
        'sideEffect': 'appState',
        'parameters': <Object?>[
          <String, Object?>{'name': 'enabled', 'type': 'boolean'},
          <String, Object?>{
            'name': 'ttlMs',
            'type': 'integer',
            'default': 300000,
          },
        ],
      },
    ],
  ],
  handle: (String command, Map<String, Object?> arguments) async =>
      switch (command) {
        'ui.inspect.status' when inspectRegistered =>
          fakeAccepted(const <String, Object?>{
            'outcome': 'observed',
            'source': 'appRecorded',
            'selectMode': false,
            'selectionOnTap': true,
            'managed': false,
          }),
        'ui.inspect.select' when inspectRegistered =>
          select?.call(arguments) ??
              fakeAccepted(<String, Object?>{
                'outcome': 'applied',
                'source': 'appRecorded',
                'selectMode': arguments['enabled'],
                'selectionOnTap': true,
                'managed': arguments['enabled'],
              }),
        _ => fakeCommandNotRegistered(),
      },
);

Future<({int exitCode, String out, String err, FakePatchbayClient client})>
_run(List<String> arguments, {FakePatchbayClient? client}) async {
  final FakePatchbayClient connection = client ?? _client();
  final StringBuffer out = StringBuffer();
  final StringBuffer err = StringBuffer();
  final int exitCode = await runPatchbayCli(
    arguments,
    connect: (_) async => connection,
    output: out,
    errorOutput: err,
  );
  return (
    exitCode: exitCode,
    out: out.toString(),
    err: err.toString(),
    client: connection,
  );
}

Map<String, Object?> _document(String out) =>
    jsonDecode(out) as Map<String, Object?>;

void main() {
  test('on, off and status send the arguments the App declares', () async {
    final FakePatchbayClient client = _client();

    expect(
      (await _run(<String>['ui', 'inspect', 'on'], client: client)).exitCode,
      PatchbayExitCode.accepted,
    );
    expect(
      (await _run(<String>['ui', 'inspect', 'off'], client: client)).exitCode,
      PatchbayExitCode.accepted,
    );
    expect(
      (await _run(<String>[
        'ui',
        'inspect',
        'status',
      ], client: client)).exitCode,
      PatchbayExitCode.accepted,
    );

    expect(client.calls.map((FakeInvocation call) => call.command), <String>[
      'ui.inspect.select',
      'ui.inspect.select',
      'ui.inspect.status',
    ]);
    expect(
      client.calls.map((FakeInvocation call) => call.arguments),
      // `on` sends no `ttlMs` at all: omitting it is what makes the App's
      // declared default the single source of the lease length.
      <Map<String, Object?>>[
        <String, Object?>{'enabled': true},
        <String, Object?>{'enabled': false},
        <String, Object?>{},
      ],
    );
  });

  test('--ttl-ms rides along with the enable only', () async {
    final FakePatchbayClient client = _client();
    await _run(<String>[
      'ui',
      'inspect',
      'on',
      '--ttl-ms',
      '60000',
    ], client: client);
    expect(client.calls.single.arguments, <String, Object?>{
      'enabled': true,
      'ttlMs': 60000,
    });

    for (final List<String> argv in <List<String>>[
      <String>['ui', 'inspect', 'off', '--ttl-ms', '60000'],
      <String>['ui', 'inspect', 'status', '--ttl-ms', '60000'],
    ]) {
      final result = await _run(argv);
      expect(result.exitCode, PatchbayExitCode.usage, reason: argv.join(' '));
      expect(result.err, contains('--ttl-ms is not valid'));
    }
  });

  test('a non-positive lease is refused before a request goes out', () async {
    final FakePatchbayClient client = _client();
    final result = await _run(<String>[
      'ui',
      'inspect',
      'on',
      '--ttl-ms',
      '0',
    ], client: client);
    expect(result.exitCode, PatchbayExitCode.usage);
    expect(result.err, contains('--ttl-ms must be positive'));
    expect(client.calls, isEmpty);
  });

  test(
    'an App without the switch answers commandNotRegistered, not silence',
    () async {
      final FakePatchbayClient client = _client(inspectRegistered: false);
      final result = await _run(<String>[
        '--json',
        'ui',
        'inspect',
        'on',
      ], client: client);

      // Absent from the catalog is a protocol answer, not a CLI-side guess: the
      // command exists as syntax and the App is what decides availability.
      expect(result.exitCode, PatchbayExitCode.protocol);
      final Map<String, Object?> rejection =
          _document(result.out)['rejection']! as Map<String, Object?>;
      expect(rejection['code'], 'commandNotRegistered');
    },
  );

  test('an App rejection keeps its code, details and exit class', () async {
    final FakePatchbayClient client = _client(
      select: (Map<String, Object?> arguments) => <String, Object?>{
        'admission': 'rejected',
        'rejection': <String, Object?>{
          'code': 'inspectorUnavailable',
          'details': <String, Object?>{'reason': 'notDebugBuild'},
        },
      },
    );
    final result = await _run(<String>[
      '--json',
      'ui',
      'inspect',
      'on',
    ], client: client);

    expect(result.exitCode, PatchbayExitCode.rejected);
    final Map<String, Object?> rejection =
        _document(result.out)['rejection']! as Map<String, Object?>;
    expect(rejection['code'], 'inspectorUnavailable');
    expect(
      (rejection['details']! as Map<String, Object?>)['reason'],
      'notDebugBuild',
    );
  });

  test('help reaches both spellings and names the one protocol command', () {
    final parser = patchbayCliParser();
    final String group = PatchbayCommandHelp.render(parser, <String>[
      'ui',
      'inspect',
    ]);
    for (final String path in <String>[
      'ui inspect on',
      'ui inspect off',
      'ui inspect status',
    ]) {
      expect(group, contains(path), reason: path);
    }

    // The catalog name an operator reads in a response resolves to the two
    // paths that send it, rather than to "unknown help topic".
    final String byName = PatchbayCommandHelp.render(parser, <String>[
      'ui.inspect.select',
    ]);
    expect(byName, contains('Service command: ui.inspect.select'));
    expect(byName, contains('ui inspect on'));
    expect(byName, contains('ui inspect off'));
    expect(
      PatchbayCommandHelp.render(parser, <String>['ui.inspect.status']),
      contains('Usage: patchbay ui inspect status'),
    );
  });
}
