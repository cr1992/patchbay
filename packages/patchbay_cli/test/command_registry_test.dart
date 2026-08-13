import 'package:patchbay_cli/patchbay_cli.dart';
import 'package:test/test.dart';

/// Resolves [argv] with an injected sensitive reader so the shapes that accept
/// `--stdin` stay testable without a TTY.
PatchbayFriendlyInvocation _resolve(
  List<String> argv, {
  String Function()? stdin,
}) {
  final parsed = patchbayCliParser().parse(argv);
  final PatchbayFriendlyInvocation? resolved =
      PatchbayFriendlyCommandRegistry.resolve(
        parsed.rest,
        parsed,
        readSensitiveInput:
            stdin ?? () => fail('sensitive stdin must not be read here'),
      );
  expect(resolved, isNotNull, reason: argv.join(' '));
  return resolved!;
}

void main() {
  test('friendly command paths are unique and every declaration resolves', () {
    final Set<String> paths = <String>{};
    for (final PatchbayFriendlyCommand spec in PatchbayFriendlyCommand.values) {
      expect(paths.add(spec.path.join(' ')), isTrue, reason: spec.name);
      final List<String> words = <String>[
        ...spec.path,
        ...switch (spec) {
          PatchbayFriendlyCommand.exec => <String>['fixture.command'],
          PatchbayFriendlyCommand.jobGet ||
          PatchbayFriendlyCommand.jobCancel => <String>['job-id'],
          PatchbayFriendlyCommand.uiTextSet ||
          PatchbayFriendlyCommand.uiTextEnter => <String>[
            'field.id',
            '3',
            'hello',
          ],
          PatchbayFriendlyCommand.uiSemanticsAction => <String>[
            '42',
            '7',
            'tap',
          ],
          PatchbayFriendlyCommand.navigationGo ||
          PatchbayFriendlyCommand.navigationPush => <String>['settings'],
          PatchbayFriendlyCommand.uiWaitSemanticsMounted ||
          PatchbayFriendlyCommand.uiWaitSemanticsUnmounted ||
          PatchbayFriendlyCommand.uiWaitDestination => <String>['screen.id'],
          PatchbayFriendlyCommand.uiWaitSemanticsValue => <String>[
            'field.id',
            'ready',
          ],
          PatchbayFriendlyCommand.uiWaitTreeRevision ||
          PatchbayFriendlyCommand.uiWaitFrameRevision => <String>['7'],
          PatchbayFriendlyCommand.captureTarget => <String>['capture.id', '2'],
          PatchbayFriendlyCommand.blobGet ||
          PatchbayFriendlyCommand.blobMetadata => <String>['blob-id'],
          _ => const <String>[],
        },
      ];
      final List<String> options = <String>[
        if (spec == PatchbayFriendlyCommand.navigationGo ||
            spec == PatchbayFriendlyCommand.navigationPush ||
            spec == PatchbayFriendlyCommand.navigationBack) ...<String>[
          '--revision',
          '1',
        ],
        if (spec.artifact != PatchbayArtifactDisposition.none) ...<String>[
          '--output',
          '/tmp/output',
        ],
        ...words,
      ];
      final parsed = patchbayCliParser().parse(options);
      final resolved = PatchbayFriendlyCommandRegistry.resolve(
        parsed.rest,
        parsed,
      );
      expect(resolved?.spec, spec, reason: spec.name);
      expect(
        resolved?.serviceCommand,
        spec.target == PatchbayCommandTarget.callerServiceCommand
            ? 'fixture.command'
            : spec.serviceCommand,
        reason: spec.name,
      );
    }
  });

  test('every command the CLI dispatches is declared, not pattern matched', () {
    // These five groups used to be matched by a hand-written pattern table in
    // `cli.dart`, so they executed but had no help entry at all.
    for (final List<String> words in <List<String>>[
      <String>['identity'],
      <String>['catalog'],
      <String>['snapshot'],
      <String>['exec', 'fixture.command'],
      <String>['job', 'get', 'job-id'],
      <String>['job', 'cancel', 'job-id'],
      <String>['ui', 'text', 'set', 'field.id', '3', 'hi'],
      <String>['ui', 'text', 'enter', 'field.id', '3', 'hi'],
      <String>['ui', 'semantics', 'tree'],
      <String>['ui', 'semantics', 'action', '42', '7', 'tap'],
      <String>['ui', 'widget-tree'],
      <String>['ui', 'render-tree'],
      <String>['ui', 'focus-tree'],
    ]) {
      expect(
        _resolve(words).spec.path,
        words.take(_resolve(words).spec.path.length),
      );
    }
  });

  test('client targets never claim a catalog service command', () {
    for (final PatchbayFriendlyCommand spec in PatchbayFriendlyCommand.values) {
      expect(
        spec.serviceCommand != null,
        spec.target == PatchbayCommandTarget.declaredServiceCommand,
        reason: spec.name,
      );
    }
  });

  test('ui text keeps the variadic trailing text and generation parsing', () {
    final PatchbayFriendlyInvocation set = _resolve(<String>[
      'ui',
      'text',
      'set',
      'field.id',
      '3',
      'hello',
      'world',
    ]);
    expect(set.serviceCommand, 'ui.text.set');
    expect(set.arguments, <String, Object?>{
      'id': 'field.id',
      'generation': 3,
      'text': 'hello world',
      'inputWasStdin': false,
    });
    expect(
      () => _resolve(<String>['ui', 'text', 'enter', 'field.id']),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => _resolve(<String>['ui', 'text', 'set', 'field.id', 'not-an-int']),
      throwsA(isA<FormatException>()),
    );
  });

  test('ui text --stdin replaces the trailing text with one no-echo line', () {
    final PatchbayFriendlyInvocation entered = _resolve(<String>[
      '--stdin',
      'ui',
      'text',
      'enter',
      'field.id',
      '3',
    ], stdin: () => 'sensitive-value');
    expect(entered.serviceCommand, 'ui.text.enter');
    expect(entered.arguments['text'], 'sensitive-value');
    expect(entered.arguments['inputWasStdin'], true);
  });

  test('ui semantics action carries text only for setText', () {
    expect(
      _resolve(<String>[
        'ui',
        'semantics',
        'action',
        '42',
        '7',
        'tap',
      ]).arguments,
      <String, Object?>{
        'nodeId': 42,
        'generation': 7,
        'action': 'tap',
        'inputWasStdin': false,
      },
    );
    expect(
      _resolve(<String>[
        'ui',
        'semantics',
        'action',
        '5',
        '1',
        'setText',
        'hello',
        'there',
      ]).arguments['text'],
      'hello there',
    );
  });

  test('exec takes its service command from the caller, args from JSON', () {
    final PatchbayFriendlyInvocation invocation = _resolve(<String>[
      '--args',
      '{"value":42}',
      'exec',
      'fixture.command',
    ]);
    expect(invocation.serviceCommand, 'fixture.command');
    expect(invocation.arguments, <String, Object?>{'value': 42});
    expect(() => _resolve(<String>['exec']), throwsA(isA<FormatException>()));
    expect(
      () => _resolve(<String>['--args', '[1]', 'exec', 'fixture.command']),
      throwsA(isA<FormatException>()),
    );
  });

  test('newly declared commands fail closed on irrelevant options', () {
    expect(
      () => _resolve(<String>['--cursor', 'ignored', 'identity']),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => _resolve(<String>['--args', '{}', 'job', 'get', 'job-id']),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => _resolve(<String>['identity', 'unexpected']),
      throwsA(isA<FormatException>()),
    );
  });

  test('friendly mappings preserve stable service command names', () {
    expect(
      PatchbayFriendlyCommand.values
          .where((value) => value.path.first == 'navigation')
          .map((value) => value.serviceCommand),
      containsAll(<String>{
        'navigation.catalog',
        'navigation.current',
        'navigation.go',
        'navigation.push',
        'navigation.back',
      }),
    );
    expect(
      PatchbayFriendlyCommand.values
          .where((value) => value.path.first == 'logs')
          .map((value) => value.serviceCommand),
      containsAll(<String>{'logs.query', 'logs.tail', 'logs.export'}),
    );
  });

  test('friendly commands fail closed on irrelevant options', () {
    final parsed = patchbayCliParser().parse(<String>[
      '--cursor',
      'ignored',
      'navigation',
      'current',
    ]);
    expect(
      () => PatchbayFriendlyCommandRegistry.resolve(parsed.rest, parsed),
      throwsA(isA<FormatException>()),
    );
  });

  test('parser has no direct token argv option', () {
    expect(
      () => patchbayCliParser().parse(const <String>[
        '--direct-token',
        'must-not-be-accepted',
      ]),
      throwsA(isA<FormatException>()),
    );
  });
}
