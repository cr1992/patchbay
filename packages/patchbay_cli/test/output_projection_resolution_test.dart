// PB-050-40: which declaration a dispatch runs under, and what happens when a
// provider publishes one the CLI cannot read.
//
// The goldens in `brief_view_test.dart` pin the *output*; this file pins the
// *resolution* that produces it — that the host wins over the frozen fallback,
// that the frozen fallback covers exactly the 0.5.0 command set and no more,
// that the CLI option surface still derives from a declaration rather than
// from a second hand-maintained table, and that a malformed declaration takes
// the whole catalog down instead of being dropped.
import 'package:patchbay/patchbay.dart';
import 'package:patchbay_cli/src/client.dart';
import 'package:patchbay_cli/src/command_registry.dart';
import 'package:patchbay_cli/src/output/brief_view.dart';
import 'package:patchbay_cli/src/output/output_projection_resolver.dart';
import 'package:patchbay_cli/src/result.dart';
import 'package:test/test.dart';

Map<String, Object?> _catalogDeclaring(
  String command,
  Map<String, Object?> projection,
) => <String, Object?>{
  'commands': <Object?>[
    <String, Object?>{'name': command, 'outputProjection': projection},
  ],
};

PatchbayFriendlyCommandSpec _spec(List<String> path) {
  final PatchbayFriendlyCommandSpec? spec =
      PatchbayFriendlyCommandRegistry.specFor(path);
  expect(spec, isNotNull, reason: path.join(' '));
  return spec!;
}

void main() {
  group('resolution order', () {
    test('a host declaration wins over the frozen 0.5.0 fallback', () {
      final PatchbayOutputProjection? resolved =
          resolvePatchbayOutputProjection(
            spec: _spec(<String>['ui', 'semantics', 'tree']),
            catalog: _catalogDeclaring('ui.semantics.tree', <String, Object?>{
              'brief': <String, Object?>{
                'id': 'ui.semantics.tree.v2',
                'omit': <String>[r'$.payload.nodes', r'$.payload.rootNodeId'],
              },
            }),
          );
      expect(resolved!.brief!.id, 'ui.semantics.tree.v2');
      expect(resolved.brief!.omit, hasLength(2));
      expect(
        resolved.artifact,
        isNull,
        reason:
            'the host declaration is used as published, never merged with the '
            "CLI's legacy rules",
      );
    });

    test(
      'a host that declares nothing falls back to the frozen 0.5.0 entry',
      () {
        final PatchbayOutputProjection? resolved =
            resolvePatchbayOutputProjection(
              spec: _spec(<String>['ui', 'semantics', 'tree']),
              catalog: <String, Object?>{
                'commands': <Object?>[
                  <String, Object?>{'name': 'ui.semantics.tree'},
                ],
              },
            );
        expect(resolved!.brief!.id, 'ui.semantics.tree');
        expect(resolved.brief!.omit, <String>[r'$.payload.nodes']);
        expect(
          resolved.artifact!.kind,
          PatchbayOutputArtifactKind.renderedMember,
        );
      },
    );

    test('a CLI-local command never consults a catalog', () {
      for (final List<String> path in <List<String>>[
        <String>['catalog'],
        <String>['ui', 'widget-tree'],
        <String>['ui', 'render-tree'],
        <String>['ui', 'focus-tree'],
      ]) {
        final PatchbayOutputProjection? resolved =
            resolvePatchbayOutputProjection(
              spec: _spec(path),
              catalog: _catalogDeclaring('catalog', <String, Object?>{
                'brief': <String, Object?>{
                  'id': 'impostor',
                  'omit': <String>[r'$.commands'],
                },
              }),
            );
        expect(resolved?.brief?.id, isNot('impostor'), reason: path.join(' '));
      }
    });

    test('a command nobody declares projects nothing at all', () {
      final PatchbayOutputProjection? resolved =
          resolvePatchbayOutputProjection(
            spec: _spec(<String>['snapshot']),
            catalog: <String, Object?>{'commands': <Object?>[]},
          );
      expect(resolved, isNull);
    });

    test('a canonical ui perform façade reads its service descriptor', () {
      final PatchbayFriendlyCommandSpec spec = _spec(<String>[
        'ui',
        'perform',
        'set-text',
      ]);
      expect(spec.serviceCommand, 'ui.text.set');
      final PatchbayOutputProjection? resolved =
          resolvePatchbayOutputProjection(
            spec: spec,
            catalog: _catalogDeclaring('ui.text.set', <String, Object?>{
              'brief': <String, Object?>{
                'id': 'ui.text.set',
                'omit': <String>[r'$.payload.diff'],
              },
            }),
          );
      expect(
        resolved?.brief?.id,
        'ui.text.set',
        reason:
            'the façade is a CLI route; DG-060-01 maps it onto an existing '
            'service command, so it reuses that descriptor rather than '
            'carrying a copy per spelling',
      );
    });
  });

  group('the frozen fallback is read-only', () {
    test('it covers exactly the 0.5.0 command set', () {
      expect(
        patchbayFrozen050OutputProjections.keys.toSet(),
        <String>{
          'ui.semantics.tree',
          'logs.query',
          'logs.export',
          'ui.capture',
        },
        reason: '0.6.0 commands declare on their descriptor, not here',
      );
    });

    test('each entry equals the descriptor declaration it stands in for', () {
      final Map<String, PatchbayCommandDescriptor?> descriptors =
          <String, PatchbayCommandDescriptor?>{
            'ui.semantics.tree': patchbayUiSemanticsTreeCommandDescriptor,
            'ui.capture': patchbayUiCaptureCommandDescriptor,
          };
      for (final MapEntry<String, PatchbayCommandDescriptor?> entry
          in descriptors.entries) {
        expect(
          entry.value!.outputProjection!.toJson(),
          patchbayFrozen050OutputProjections[entry.key]!.toJson(),
          reason:
              '${entry.key}: a 0.5.0 host and a 0.6.0 host must project the '
              'same command the same way',
        );
      }
    });

    test('every CLI-local declaration is within its own bounds', () {
      var declared = 0;
      for (final PatchbayFriendlyCommand command
          in PatchbayFriendlyCommand.values) {
        final PatchbayOutputProjection? projection =
            command.localOutputProjection;
        if (projection == null) continue;
        declared += 1;
        expect(projection.validate, returnsNormally, reason: command.name);
      }
      expect(declared, greaterThanOrEqualTo(6));
    });

    test('every frozen entry is within its own bounds', () {
      for (final MapEntry<String, PatchbayOutputProjection> entry
          in patchbayFrozen050OutputProjections.entries) {
        expect(entry.value.validate, returnsNormally, reason: entry.key);
      }
    });
  });

  group('the CLI option surface still derives from one declaration', () {
    test(
      'the reachable renderedMember commands are exactly the 0.5.0 four',
      () {
        final Set<String> rendered = <String>{
          for (final PatchbayFriendlyCommandSpec spec
              in PatchbayFriendlyCommandRegistry.commands)
            if (spec.artifact == PatchbayArtifactDisposition.renderedMember)
              spec.path.join(' '),
        };
        expect(rendered, <String>{
          'ui semantics tree',
          'ui widget-tree',
          'ui render-tree',
          'ui focus-tree',
        });
      },
    );

    test('spilledMember is now a restricted path, derived from the same '
        'declaration', () {
      expect(
        _spec(<String>['ui', 'semantics', 'tree']).spilledMember,
        r'$.payload.nodes',
      );
      for (final String tree in <String>[
        'widget-tree',
        'render-tree',
        'focus-tree',
      ]) {
        expect(_spec(<String>['ui', tree]).spilledMember, r'$.data');
      }
    });

    test('the blob dispositions are unchanged', () {
      expect(
        _spec(<String>['logs', 'export']).artifact,
        PatchbayArtifactDisposition.payloadBlob,
      );
      expect(
        _spec(<String>['capture', 'root']).artifact,
        PatchbayArtifactDisposition.payloadBlob,
      );
      expect(
        _spec(<String>['capture', 'target']).artifact,
        PatchbayArtifactDisposition.payloadBlob,
      );
      expect(
        _spec(<String>['blob', 'get']).artifact,
        PatchbayArtifactDisposition.responseBlob,
      );
    });

    test('blob metadata calls the same service command and still downloads '
        'nothing', () {
      expect(
        _spec(<String>['blob', 'metadata']).serviceCommand,
        'blob.metadata',
      );
      expect(
        _spec(<String>['blob', 'metadata']).artifact,
        PatchbayArtifactDisposition.none,
        reason:
            'the download belongs to the `blob get` spelling; putting it on '
            "`blob.metadata`'s descriptor would hand it to both",
      );
    });

    test('ui semantics tree still advertises the spill options', () {
      expect(
        _spec(<String>['ui', 'semantics', 'tree']).usageSuffix,
        '[--output <path>] [--force] [--max-inline-bytes <n>]',
      );
    });
  });

  group('an unreadable declaration fails the catalog whole', () {
    Map<String, Object?> catalogWith(Object? projection) => <String, Object?>{
      'commands': <Object?>[
        <String, Object?>{
          'name': 'navigation.current',
          'summary': 'still perfectly readable',
        },
        <String, Object?>{
          'name': 'ui.semantics.tree',
          'outputProjection': projection,
        },
      ],
    };

    for (final MapEntry<String, Object?> entry in <String, Object?>{
      'an unknown key': const <String, Object?>{
        'brief': <String, Object?>{
          'id': 'x',
          'omit': <String>[r'$.a'],
        },
        'formatter': 'shell',
      },
      'a wrong type': const <String, Object?>{'brief': 7},
      'an empty object': const <String, Object?>{},
      'an unknown artifact kind': const <String, Object?>{
        'artifact': <String, Object?>{'kind': 'wholeDisk'},
      },
      'a path outside the grammar': const <String, Object?>{
        'brief': <String, Object?>{
          'id': 'x',
          'omit': <String>[r'$..*'],
        },
      },
      'not an object at all': 'brief',
    }.entries) {
      test('${entry.key} is refused, and no row survives it', () {
        expect(
          () => validatePatchbayCatalogOutputProjections(
            catalogWith(entry.value),
          ),
          throwsA(
            isA<PatchbayProtocolException>().having(
              (PatchbayProtocolException failure) => failure.code,
              'code',
              patchbayCatalogOutputProjectionInvalid,
            ),
          ),
          reason: entry.key,
        );
      });
    }

    test('a clean catalog passes', () {
      expect(
        () => validatePatchbayCatalogOutputProjections(
          catalogWith(const <String, Object?>{
            'brief': <String, Object?>{
              'id': 'ui.semantics.tree',
              'omit': <String>[r'$.payload.nodes'],
            },
          }),
        ),
        returnsNormally,
      );
    });

    test('resolution refuses too, so a skipped validation cannot fall back', () {
      expect(
        () => resolvePatchbayOutputProjection(
          spec: _spec(<String>['ui', 'semantics', 'tree']),
          catalog: catalogWith(const <String, Object?>{'brief': 7}),
        ),
        throwsA(isA<PatchbayProtocolException>()),
        reason:
            'silently dropping to the frozen fallback would let a broken host '
            'look like an old one',
      );
    });
  });

  group('a 0.6.0 catalog is an additive diff of the 0.5.0 one', () {
    Map<String, Object?> row({required bool declares}) => <String, Object?>{
      'name': 'ui.semantics.tree',
      'summary': 'Observe the current Flutter Semantics tree.',
      'plane': 'flutterUi',
      'mode': 'readOnly',
      'sideEffect': 'none',
      'factSources': <String>['uiObserved'],
      'gates': <String>[],
      'parameters': <Object?>[],
      'weakConfirmationCompletes': false,
      if (declares)
        'outputProjection': patchbayUiSemanticsTreeCommandDescriptor
            .outputProjection!
            .toJson(),
    };

    test('the new host adds exactly one key and changes nothing else', () {
      final Map<String, Object?> old = row(declares: false);
      final Map<String, Object?> fresh = row(declares: true);
      expect(fresh.keys.toSet().difference(old.keys.toSet()), <String>{
        'outputProjection',
      });
      for (final String key in old.keys) {
        expect(fresh[key], old[key], reason: key);
      }
    });

    test('both hosts project the same response the same way', () {
      final Map<String, Object?> response = <String, Object?>{
        'schemaVersion': 1,
        'admission': 'accepted',
        'notice': 'read 2 nodes',
        'payload': <String, Object?>{
          'outcome': 'observed',
          'nodeCount': 2,
          'nodes': <Object?>[
            <String, Object?>{'nodeId': 1},
          ],
        },
      };
      Map<String, Object?> briefAgainst({required bool declares}) =>
          projectPatchbayBriefView(
            projection: resolvePatchbayOutputProjection(
              spec: _spec(<String>['ui', 'semantics', 'tree']),
              catalog: <String, Object?>{
                'commands': <Object?>[row(declares: declares)],
              },
            ),
            response: response,
            exitCode: PatchbayExitCode.accepted,
          );
      expect(briefAgainst(declares: true), briefAgainst(declares: false));
      expect(
        (briefAgainst(declares: false)['localView']!
            as Map<String, Object?>)['omitted'],
        <String>[r'$.notice', r'$.payload.nodes'],
        reason: 'the frozen 0.5.0 pattern literals and their order',
      );
    });
  });

  group('the interpreter honours declaration order and list traversal', () {
    test('omitted echoes the declared literals in declaration order', () {
      const PatchbayOutputProjection projection = PatchbayOutputProjection(
        brief: PatchbayOutputBriefProjection(
          id: 'ordered',
          omit: <String>[r'$.c', r'$.a', r'$.b'],
        ),
      );
      final Map<String, Object?> brief = projectPatchbayBriefView(
        projection: projection,
        response: <String, Object?>{'a': 1, 'b': 2, 'c': 3},
        exitCode: PatchbayExitCode.accepted,
      );
      expect((brief['localView']! as Map<String, Object?>)['omitted'], <String>[
        r'$.c',
        r'$.a',
        r'$.b',
      ]);
    });

    test('a nested list traversal deletes inside every element', () {
      const PatchbayOutputProjection projection = PatchbayOutputProjection(
        brief: PatchbayOutputBriefProjection(
          id: 'nested',
          omit: <String>[r'$.outer[].inner[].drop'],
        ),
      );
      final Map<String, Object?> brief = projectPatchbayBriefView(
        projection: projection,
        response: <String, Object?>{
          'outer': <Object?>[
            <String, Object?>{
              'inner': <Object?>[
                <String, Object?>{'drop': 'gone', 'keep': 'here'},
              ],
            },
          ],
        },
        exitCode: PatchbayExitCode.accepted,
      );
      final Map<String, Object?> outer =
          (brief['outer']! as List<Object?>).single as Map<String, Object?>;
      final List<Object?> innerList = outer['inner']! as List<Object?>;
      final Map<String, Object?> inner =
          innerList.single as Map<String, Object?>;
      expect(inner.containsKey('drop'), isFalse);
      expect(inner['keep'], 'here');
    });

    test(
      'a declaration with only an artifact still reports projection: null',
      () {
        final Map<String, Object?> brief = projectPatchbayBriefView(
          projection: const PatchbayOutputProjection(
            artifact: PatchbayOutputArtifactProjection.payloadBlob(),
          ),
          response: <String, Object?>{'notice': 'gone', 'payload': 1},
          exitCode: PatchbayExitCode.accepted,
        );
        final Map<String, Object?> localView =
            brief['localView']! as Map<String, Object?>;
        expect(localView['projection'], isNull);
        expect(localView['omitted'], <String>[r'$.notice']);
      },
    );
  });
}
