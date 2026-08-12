import 'package:patchbay_cli/patchbay_cli.dart';
import 'package:test/test.dart';

void main() {
  test('friendly command paths are unique and every declaration resolves', () {
    final Set<String> paths = <String>{};
    for (final PatchbayFriendlyCommand spec in PatchbayFriendlyCommand.values) {
      expect(paths.add(spec.path.join(' ')), isTrue, reason: spec.name);
      final List<String> words = <String>[
        ...spec.path,
        ...switch (spec) {
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
    }
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
