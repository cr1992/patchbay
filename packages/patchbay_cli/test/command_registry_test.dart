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
  test('launch preserves the consumer command after the option boundary', () {
    final PatchbayFriendlyInvocation invocation = _resolve(<String>[
      'launch',
      '--',
      'flutter',
      'run',
      '--vmservice-out-file',
      '.dart_tool/patchbay/vmservice.txt',
    ]);

    expect(invocation.spec, PatchbayFriendlyCommand.launch);
    expect(invocation.arguments['command'], <String>[
      'flutter',
      'run',
      '--vmservice-out-file',
      '.dart_tool/patchbay/vmservice.txt',
    ]);
  });

  test('friendly command paths are unique and every declaration resolves', () {
    final Set<String> paths = <String>{};
    for (final PatchbayFriendlyCommand spec in PatchbayFriendlyCommand.values) {
      expect(paths.add(spec.path.join(' ')), isTrue, reason: spec.name);
      final List<String> words = <String>[
        ...spec.path,
        ...switch (spec) {
          PatchbayFriendlyCommand.launch => <String>['fake-consumer'],
          PatchbayFriendlyCommand.exec ||
          PatchbayFriendlyCommand.describe => <String>['fixture.command'],
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
          PatchbayFriendlyCommand.uiTap => <String>['login.submit'],
          PatchbayFriendlyCommand.snapshotWait => <String>['call.session'],
          PatchbayFriendlyCommand.sessionUse => <String>['worktree-a'],
          PatchbayFriendlyCommand.permissionStatus ||
          PatchbayFriendlyCommand.permissionReset ||
          PatchbayFriendlyCommand.permissionNormalize ||
          PatchbayFriendlyCommand.permissionExercise ||
          PatchbayFriendlyCommand.permissionFail => <String>['camera'],
          PatchbayFriendlyCommand.traceMark => <String>['operator-note'],
          PatchbayFriendlyCommand.traceShow ||
          PatchbayFriendlyCommand.traceExport => <String>[
            'tr_fixture_0123456789abcdef0123',
          ],
          PatchbayFriendlyCommand.traceDiff => <String>[
            'tr_before_0123456789abcdef0123',
            'tr_after_0123456789abcdef0123',
          ],
          PatchbayFriendlyCommand.uiVerifyManifest => <String>['targets.json'],
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
        if (spec == PatchbayFriendlyCommand.snapshotWait) ...<String>[
          '--until',
          'exists',
        ],
        if (spec == PatchbayFriendlyCommand.permissionNormalize ||
            spec == PatchbayFriendlyCommand.permissionFail) ...<String>[
          '--state',
          'granted',
        ],
        if (spec == PatchbayFriendlyCommand.permissionExercise) ...<String>[
          '--decision',
          'deny',
        ],
        if (spec == PatchbayFriendlyCommand.uiTargets) '--emit-manifest',
        if (spec == PatchbayFriendlyCommand.traceStart) ...<String>[
          '--name',
          'fixture-trace',
        ],
        if (spec == PatchbayFriendlyCommand.traceExport) ...<String>[
          '--output',
          '/tmp/trace-output',
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

  test('ui tap sends one identifier and no node coordinates', () {
    final PatchbayFriendlyInvocation tap = _resolve(<String>[
      'ui',
      'tap',
      'login.submit',
    ]);
    expect(tap.serviceCommand, 'ui.semantics.tap');
    // No nodeId and no generation: resolution is the App's job, which is the
    // whole point of the command. A CLI-side default would silently reinstate
    // the tree read.
    expect(tap.arguments, <String, Object?>{'identifier': 'login.submit'});
  });

  test('ui tap --generation forwards the caller-side fence', () {
    expect(
      _resolve(<String>[
        '--generation',
        '7',
        'ui',
        'tap',
        'login.submit',
      ]).arguments,
      <String, Object?>{'identifier': 'login.submit', 'generation': 7},
    );
    expect(
      () => _resolve(<String>['--generation', '-1', 'ui', 'tap', 'x.y']),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => _resolve(<String>['ui', 'tap']),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => _resolve(<String>['ui', 'tap', 'a.b', 'c.d']),
      throwsA(isA<FormatException>()),
    );
  });

  test('a ui wait condition name is accepted as the command name', () {
    for (final PatchbayFriendlyCommand spec in PatchbayFriendlyCommand.values) {
      if (spec.waitCondition case final String condition) {
        final List<String> tail = switch (spec) {
          PatchbayFriendlyCommand.uiWaitSemanticsValue => <String>[
            'field.id',
            'ready',
          ],
          PatchbayFriendlyCommand.uiWaitTreeRevision ||
          PatchbayFriendlyCommand.uiWaitFrameRevision => <String>['7'],
          _ => <String>['screen.id'],
        };
        final PatchbayFriendlyInvocation byCondition = _resolve(<String>[
          'ui',
          'wait',
          condition,
          ...tail,
        ]);
        // Same declaration, same request: the alias is a spelling, not a
        // second command with a life of its own.
        expect(byCondition.spec, spec, reason: condition);
        expect(
          byCondition.arguments,
          _resolve(<String>[...spec.path, ...tail]).arguments,
          reason: condition,
        );
        expect(byCondition.arguments['condition'], condition);
      }
    }
  });

  test('group aliases expand without inventing commands', () {
    expect(
      _resolve(<String>['navigate', 'current']).spec,
      PatchbayFriendlyCommand.navigationCurrent,
    );
    expect(
      _resolve(<String>['wait', 'semantics-mounted', 'app.ready']).spec,
      PatchbayFriendlyCommand.uiWaitSemanticsMounted,
    );
    expect(
      _resolve(<String>['tap', 'login.submit']).spec,
      PatchbayFriendlyCommand.uiTap,
    );
    // An alias word in an argument position stays an argument.
    expect(
      PatchbayFriendlyCommandRegistry.canonicalPath(<String>['exec', 'wait']),
      <String>['exec', 'wait'],
    );
    expect(
      PatchbayFriendlyCommandRegistry.canonicalPath(<String>[
        'ui',
        'tap',
        'nav',
      ]),
      <String>['ui', 'tap', 'nav'],
    );
  });

  test('--generation is refused by commands that do not fence a node', () {
    expect(
      () => _resolve(<String>['--generation', '7', 'ui', 'semantics', 'tree']),
      throwsA(isA<FormatException>()),
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

  test('--stdin merges over --args and wins on a shared key', () {
    final PatchbayFriendlyInvocation invocation = _resolve(<String>[
      '--args',
      '{"deviceId":"abc","retries":2}',
      '--stdin',
      'exec',
      'fixture.command',
    ], stdin: () => '{"token":"s3cret","retries":9}');
    expect(invocation.arguments, <String, Object?>{
      'deviceId': 'abc',
      'retries': 9,
      'token': 's3cret',
      'inputWasStdin': true,
    });
    // Only the argv half is reported as plaintext; the merged result must not
    // make the stdin keys look like they came from the command line.
    expect(invocation.plaintextArgumentKeys, <String>{'deviceId', 'retries'});
  });

  test('stdin alone still supplies the whole object, unchanged', () {
    final PatchbayFriendlyInvocation invocation = _resolve(<String>[
      '--stdin',
      'exec',
      'fixture.command',
    ], stdin: () => '{"token":"s3cret"}');
    expect(invocation.arguments, <String, Object?>{
      'token': 's3cret',
      'inputWasStdin': true,
    });
    expect(invocation.plaintextArgumentKeys, isEmpty);
  });

  test('a stdin payload cannot unset the no-echo marker', () {
    expect(
      _resolve(<String>[
        '--stdin',
        'exec',
        'fixture.command',
      ], stdin: () => '{"inputWasStdin":false}').arguments['inputWasStdin'],
      true,
    );
  });

  test('bare text and non-object JSON on stdin are still refused', () {
    for (final String payload in <String>['not json at all', '[1]', '"text"']) {
      expect(
        () => _resolve(<String>[
          '--stdin',
          'exec',
          'fixture.command',
        ], stdin: () => payload),
        throwsA(isA<FormatException>()),
        reason: payload,
      );
    }
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

  test('ui targets requires its explicit emission flag', () {
    expect(
      _resolve(<String>['ui', 'targets', '--emit-manifest']).spec,
      PatchbayFriendlyCommand.uiTargets,
    );
    expect(
      () => _resolve(<String>['ui', 'targets']),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => _resolve(<String>['--emit-manifest', 'catalog']),
      throwsA(isA<FormatException>()),
    );
  });

  test('keep-awake on and off are two spellings of one command', () {
    final PatchbayFriendlyInvocation on = _resolve(<String>[
      'ui',
      'keep-awake',
      'on',
    ]);
    final PatchbayFriendlyInvocation off = _resolve(<String>[
      'ui',
      'keep-awake',
      'off',
    ]);

    expect(on.serviceCommand, 'ui.keepAwake.set');
    expect(off.serviceCommand, 'ui.keepAwake.set');
    // `enabled` is set by which word was typed, never by an argument, so no
    // stray flag can turn `off` into an engagement.
    expect(on.arguments, <String, Object?>{'enabled': true});
    expect(off.arguments, <String, Object?>{'enabled': false});
  });

  test('keep-awake omits the lease so the App default is the only copy', () {
    expect(
      _resolve(<String>['ui', 'keep-awake', 'on']).arguments,
      isNot(contains('leaseMs')),
    );
    expect(
      _resolve(<String>[
        '--lease-ms',
        '120000',
        'ui',
        'keep-awake',
        'on',
      ]).arguments,
      <String, Object?>{'enabled': true, 'leaseMs': 120000},
    );
  });

  test('--lease-ms belongs to on alone', () {
    // A release takes no lease and a read takes nothing at all; accepting the
    // option would leave the operator to guess what it did.
    for (final List<String> path in <List<String>>[
      <String>['ui', 'keep-awake', 'off'],
      <String>['ui', 'keep-awake', 'status'],
    ]) {
      expect(
        () => _resolve(<String>['--lease-ms', '1000', ...path]),
        throwsA(isA<FormatException>()),
        reason: path.join(' '),
      );
    }
    expect(
      () => _resolve(<String>['--lease-ms', '0', 'ui', 'keep-awake', 'on']),
      throwsA(isA<FormatException>()),
    );
  });

  test('keep-awake status is a read that carries no arguments', () {
    final PatchbayFriendlyInvocation status = _resolve(<String>[
      'ui',
      'keep-awake',
      'status',
    ]);

    expect(status.serviceCommand, 'ui.keepAwake.status');
    expect(status.arguments, isEmpty);
    expect(
      () => _resolve(<String>['ui', 'keep-awake', 'status', 'extra']),
      throwsA(isA<FormatException>()),
    );
  });

  test('keep-awake is reachable without the ui prefix', () {
    expect(
      _resolve(<String>['keep-awake', 'on']).spec,
      _resolve(<String>['ui', 'keep-awake', 'on']).spec,
    );
    expect(
      _resolve(<String>['keep-awake', 'status']).serviceCommand,
      'ui.keepAwake.status',
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
