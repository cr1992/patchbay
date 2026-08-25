import 'dart:convert';
import 'dart:io';

import 'package:patchbay_cli/patchbay_cli.dart';
import 'package:patchbay_cli/src/output/brief_view.dart';
import 'package:test/test.dart';

/// PB-050-21: `--view brief` projection.
///
/// The golden pairs under `test/golden/view_brief/` are the frozen contract
/// from `docs/proposals/0.5.0/brief-view.md`'s section 5 table — one pair per
/// rule family, plus one pair (`identity`) for a command the table
/// deliberately does not project. `patchbayBriefViewRulePatternsForTesting`
/// exposes the same private table `projectPatchbayBriefView` runs against, so
/// the ratchet test below can assert the table and the checked-in pairs
/// cover each other in both directions, not just that each pair happens to
/// pass.
Map<String, Object?> _readGolden(String name) =>
    jsonDecode(File('test/golden/view_brief/$name.json').readAsStringSync())
        as Map<String, Object?>;

void main() {
  group('golden pairs (frozen projection contract)', () {
    final Map<String, PatchbayFriendlyCommandSpec?>
    specByFixture = <String, PatchbayFriendlyCommandSpec?>{
      'catalog': PatchbayFriendlyCommandRegistry.specFor(<String>['catalog']),
      'ui_semantics_tree': PatchbayFriendlyCommandRegistry.specFor(<String>[
        'ui',
        'semantics',
        'tree',
      ]),
      'diagnostic_tree': PatchbayFriendlyCommandRegistry.specFor(<String>[
        'ui',
        'widget-tree',
      ]),
      'logs_query': PatchbayFriendlyCommandRegistry.specFor(<String>[
        'logs',
        'query',
      ]),
      'identity': PatchbayFriendlyCommandRegistry.specFor(<String>['identity']),
    };

    for (final MapEntry<String, PatchbayFriendlyCommandSpec?> entry
        in specByFixture.entries) {
      test('${entry.key}: brief matches the checked-in golden', () {
        final Map<String, Object?> full = _readGolden('${entry.key}.full');
        final Map<String, Object?> expectedBrief = _readGolden(
          '${entry.key}.brief',
        );
        final Map<String, Object?> actualBrief = projectPatchbayBriefView(
          spec: entry.value,
          response: full,
          exitCode: PatchbayExitCode.accepted,
        );
        expect(actualBrief, equals(expectedBrief));
      });
    }

    test('render-tree and focus-tree share the diagnostic-tree family', () {
      final Map<String, Object?> full = _readGolden('diagnostic_tree.full');
      for (final List<String> path in <List<String>>[
        <String>['ui', 'render-tree'],
        <String>['ui', 'focus-tree'],
      ]) {
        final Map<String, Object?> brief = projectPatchbayBriefView(
          spec: PatchbayFriendlyCommandRegistry.specFor(path),
          response: full,
          exitCode: PatchbayExitCode.accepted,
        );
        expect(
          (brief['localView']! as Map<String, Object?>)['projection'],
          'diagnosticTree',
        );
        expect(brief.containsKey('data'), isFalse);
      }
    });

    test('table <-> golden ratchet: every rule has golden coverage, every '
        'golden deletion is in the table', () {
      final Map<String, List<String>> table =
          patchbayBriefViewRulePatternsForTesting();
      final Set<String> tablePatterns = <String>{
        for (final List<String> patterns in table.values) ...patterns,
      };
      final Set<String> goldenPatterns = <String>{};
      for (final String fixture in specByFixture.keys) {
        final Map<String, Object?> brief = _readGolden('$fixture.brief');
        final Map<String, Object?> localView =
            brief['localView']! as Map<String, Object?>;
        goldenPatterns.addAll(
          (localView['omitted']! as List<Object?>).cast<String>(),
        );
      }
      expect(
        tablePatterns.difference(goldenPatterns),
        isEmpty,
        reason: 'a rule in the table has no golden pair exercising it',
      );
      expect(
        goldenPatterns.difference(tablePatterns),
        isEmpty,
        reason:
            'a golden pair deletes a path the table does not declare — it '
            'cannot be recomputed from the frozen rules',
      );
    });
  });

  group('table self-assertions', () {
    test('no rule touches a redaction or admission-identity key', () {
      final Map<String, List<String>> table =
          patchbayBriefViewRulePatternsForTesting();
      const Set<String> forbiddenLeafNames = <String>{
        'redaction',
        'valueRedacted',
        'sensitive',
        'admission',
        'requestId',
        'jobId',
        'rejection',
        'localArtifact',
        'localKeepAwake',
      };
      for (final List<String> patterns in table.values) {
        for (final String pattern in patterns) {
          final String leaf = pattern.split('.').last.replaceAll('[]', '');
          expect(
            forbiddenLeafNames.contains(leaf) ||
                leaf.toLowerCase().startsWith('sensitive'),
            isFalse,
            reason: '$pattern removes a key the table must never touch',
          );
        }
      }
    });
  });

  group('projection gate: only accepted responses are ever thinned', () {
    const List<int> nonAcceptedExitCodes = <int>[
      PatchbayExitCode.rejected,
      PatchbayExitCode.protocol,
      PatchbayExitCode.typedFailure,
      PatchbayExitCode.transport,
    ];

    for (final int exitCode in nonAcceptedExitCodes) {
      test(
        'exitCode=$exitCode is identity plus an empty-omitted localView',
        () {
          final Map<String, Object?> response = <String, Object?>{
            'admission': 'rejected',
            'rejection': const <String, Object?>{
              'code': 'uiSemanticsIdentifierNotFound',
              'notice': 'not found',
              'details': <String, Object?>{'identifier': 'absent.id'},
            },
            'notice': 'should never be pruned on this path',
          };
          final Map<String, Object?> brief = projectPatchbayBriefView(
            spec: PatchbayFriendlyCommandRegistry.specFor(<String>[
              'ui',
              'semantics',
              'tree',
            ]),
            response: response,
            exitCode: exitCode,
          );
          expect(brief['notice'], response['notice']);
          expect(brief['rejection'], response['rejection']);
          expect(brief['localView'], <String, Object?>{
            'view': 'brief',
            'projection': null,
            'omitted': const <String>[],
            'expand': '--view full',
          });
        },
      );
    }
  });

  group('projection is a total function', () {
    test('malformed catalog commands (not a list) is left untouched', () {
      final Map<String, Object?> response = <String, Object?>{
        'commands': 'not-a-list',
        'uiTargets': const <Object?>[],
      };
      final Map<String, Object?> brief = projectPatchbayBriefView(
        spec: PatchbayFriendlyCommandRegistry.specFor(<String>['catalog']),
        response: response,
        exitCode: PatchbayExitCode.accepted,
      );
      expect(brief['commands'], 'not-a-list');
      expect((brief['localView']! as Map<String, Object?>)['omitted'], isEmpty);
    });

    test(
      'malformed ui.semantics.tree payload (not a map) is left untouched',
      () {
        final Map<String, Object?> response = <String, Object?>{
          'admission': 'accepted',
          'payload': 'not-a-map',
        };
        final Map<String, Object?> brief = projectPatchbayBriefView(
          spec: PatchbayFriendlyCommandRegistry.specFor(<String>[
            'ui',
            'semantics',
            'tree',
          ]),
          response: response,
          exitCode: PatchbayExitCode.accepted,
        );
        expect(brief['payload'], 'not-a-map');
      },
    );

    test('unknown top-level and consumer keys survive untouched', () {
      final Map<String, Object?> response = <String, Object?>{
        'admission': 'accepted',
        'payload': <String, Object?>{
          'outcome': 'observed',
          'nodes': const <Object?>[],
          'consumerExtra': <String, Object?>{'anything': true},
        },
        'futureProtocolField': 'kept',
      };
      final Map<String, Object?> brief = projectPatchbayBriefView(
        spec: PatchbayFriendlyCommandRegistry.specFor(<String>[
          'ui',
          'semantics',
          'tree',
        ]),
        response: response,
        exitCode: PatchbayExitCode.accepted,
      );
      expect(brief['futureProtocolField'], 'kept');
      final Map<String, Object?> payload =
          brief['payload']! as Map<String, Object?>;
      expect(payload['consumerExtra'], <String, Object?>{'anything': true});
      expect(payload.containsKey('nodes'), isFalse);
    });
  });

  group('families the table deliberately does not project', () {
    test('snapshot, describe and job responses are identity', () {
      for (final List<String> path in <List<String>>[
        <String>['snapshot'],
        <String>['describe'],
        <String>['job', 'get'],
      ]) {
        final Map<String, Object?> response = <String, Object?>{
          'schemaVersion': 1,
          'payload': <String, Object?>{'anything': 'here'},
        };
        final Map<String, Object?> brief = projectPatchbayBriefView(
          spec: PatchbayFriendlyCommandRegistry.specFor(path),
          response: response,
          exitCode: PatchbayExitCode.accepted,
        );
        expect(brief['payload'], response['payload'], reason: path.join(' '));
        expect(
          (brief['localView']! as Map<String, Object?>)['projection'],
          isNull,
          reason: path.join(' '),
        );
      }
    });
  });

  test('localView is a stable four-key shape appended at the end', () {
    final Map<String, Object?> brief = projectPatchbayBriefView(
      spec: PatchbayFriendlyCommandRegistry.specFor(<String>['identity']),
      response: const <String, Object?>{'schemaVersion': 1},
      exitCode: PatchbayExitCode.accepted,
    );
    expect(brief.keys.last, 'localView');
    expect((brief['localView']! as Map<String, Object?>).keys, <String>[
      'view',
      'projection',
      'omitted',
      'expand',
    ]);
  });
}
