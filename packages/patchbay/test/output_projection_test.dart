// PB-050-40: the declaration type's bounds, its wire form and its fail-closed
// decode.
//
// The malformed group follows PB-060-06's convention rather than its harness:
// that harness owns the *transport's* decode boundary and states outright that
// it never mutates inside a forwarded object, and `outputProjection` is decoded
// one layer up, by `package:patchbay`. What carries over is the reproducibility
// contract — one seeded [Random], a fixed default seed, overridable through
// `PATCHBAY_MALFORMED_SEED` — so a failing case replays exactly.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:patchbay/patchbay.dart';
import 'package:test/test.dart';

/// Same default as `packages/patchbay_transport/test/malformed_payload_harness.dart`:
/// `0x50424D50` is ASCII `PBMP`.
const int defaultMalformedSeed = 0x50424D50;

int _seed() {
  final String? override = Platform.environment['PATCHBAY_MALFORMED_SEED'];
  if (override == null || override.isEmpty) return defaultMalformedSeed;
  return int.tryParse(override) ?? defaultMalformedSeed;
}

/// A well-formed declaration, used as the base every malformation mutates.
Map<String, Object?> _validWire() => <String, Object?>{
  'brief': <String, Object?>{
    'id': 'ui.semantics.tree',
    'omit': <String>[r'$.payload.nodes'],
  },
  'artifact': <String, Object?>{
    'kind': 'renderedMember',
    'member': r'$.payload.nodes',
    'encoding': 'json',
    'mediaType': 'application/json',
    'extension': 'json',
    'automaticSpill': true,
  },
};

void main() {
  group('restricted paths', () {
    for (final String pattern in <String>[
      r'$.notice',
      r'$.payload.nodes',
      r'$.commands[].parameters',
      r'$.a[].b[].c',
      r'$.a_1.b2',
    ]) {
      test('accepts $pattern', () {
        expect(PatchbayOutputProjectionPath.parse(pattern).pattern, pattern);
      });
    }

    for (final MapEntry<String, String> entry in <String, String>{
      r'payload.nodes': 'no leading root',
      r'$': 'root names no field',
      r'$.': 'empty field',
      r'$.9bad': 'field must start with a letter',
      r'$.a-b': 'hyphen is not a field character',
      r'$.a.b[]': 'a leaf may not traverse',
      r'$.a[0]': 'indices are not part of the grammar',
      r'$.a.*': 'no wildcards',
      r'$..a': 'no recursive descent',
    }.entries) {
      test('rejects ${entry.key} (${entry.value})', () {
        expect(
          () => PatchbayOutputProjectionPath.parse(entry.key),
          throwsFormatException,
        );
      });
    }

    test('rejects a path past the byte ceiling', () {
      final String long =
          r'$.' + List<String>.filled(200, 'abcdefghij').join('.');
      expect(long.length, greaterThan(patchbayOutputProjectionMaxPathBytes));
      expect(
        () => PatchbayOutputProjectionPath.parse(long),
        throwsFormatException,
      );
    });

    test('an artifact member may not traverse a list', () {
      expect(
        () => PatchbayOutputProjectionPath.parse(
          r'$.commands[].parameters',
          allowListTraversal: false,
        ),
        throwsFormatException,
      );
    });
  });

  group('brief declaration bounds', () {
    test('accepts the frozen 0.5.0 ids', () {
      for (final String id in <String>[
        'catalog',
        'ui.semantics.tree',
        'logs.query',
        // 0.5.0 froze this id with an uppercase letter in stable JSON; the id
        // class has to admit it or the frozen golden could not be reproduced.
        'diagnosticTree',
      ]) {
        expect(
          () => PatchbayOutputBriefProjection(
            id: id,
            omit: const <String>[r'$.notice'],
          ).validate(),
          returnsNormally,
          reason: id,
        );
      }
    });

    for (final MapEntry<String, PatchbayOutputBriefProjection> entry
        in <String, PatchbayOutputBriefProjection>{
          'an empty id': const PatchbayOutputBriefProjection(
            id: '',
            omit: <String>[r'$.notice'],
          ),
          'an id with a separator': const PatchbayOutputBriefProjection(
            id: 'ui/semantics',
            omit: <String>[r'$.notice'],
          ),
          'an id with whitespace': const PatchbayOutputBriefProjection(
            id: 'ui semantics',
            omit: <String>[r'$.notice'],
          ),
          'an empty omit list': const PatchbayOutputBriefProjection(
            id: 'x',
            omit: <String>[],
          ),
          'a repeated rule': const PatchbayOutputBriefProjection(
            id: 'x',
            omit: <String>[r'$.notice', r'$.notice'],
          ),
          'a malformed rule': const PatchbayOutputBriefProjection(
            id: 'x',
            omit: <String>[r'$.notice', 'nope'],
          ),
        }.entries) {
      test('rejects ${entry.key}', () {
        expect(entry.value.validate, throwsFormatException);
      });
    }

    test('rejects an id past the length ceiling', () {
      expect(
        () => PatchbayOutputBriefProjection(
          id: 'a' * (patchbayOutputProjectionMaxIdLength + 1),
          omit: const <String>[r'$.notice'],
        ).validate(),
        throwsFormatException,
      );
    });

    test('rejects more rules than the ceiling allows', () {
      expect(
        () => PatchbayOutputBriefProjection(
          id: 'x',
          omit: <String>[
            for (var i = 0; i <= patchbayOutputProjectionMaxOmitRules; i += 1)
              r'$.f'
                  '$i',
          ],
        ).validate(),
        throwsFormatException,
      );
    });
  });

  group('artifact declaration', () {
    test('a blob kind declares nothing else', () {
      const PatchbayOutputArtifactProjection blob =
          PatchbayOutputArtifactProjection.payloadBlob();
      expect(blob.member, isNull);
      expect(blob.encoding, isNull);
      expect(blob.automaticSpill, isFalse);
      expect(blob.toJson(), <String, Object?>{'kind': 'payloadBlob'});
    });

    test('a renderedMember derives its media type and extension', () {
      const PatchbayOutputArtifactProjection rendered =
          PatchbayOutputArtifactProjection.renderedMember(
            member: r'$.payload.nodes',
            encoding: PatchbayOutputArtifactEncoding.json,
          );
      expect(rendered.mediaType, 'application/json');
      expect(rendered.extension, 'json');
      expect(rendered.automaticSpill, isTrue);
      expect(rendered.toJson()['automaticSpill'], isTrue);
    });

    test('utf8Text pins the text media type and extension', () {
      const PatchbayOutputArtifactProjection rendered =
          PatchbayOutputArtifactProjection.renderedMember(
            member: r'$.data',
            encoding: PatchbayOutputArtifactEncoding.utf8Text,
          );
      expect(rendered.mediaType, 'text/plain; charset=utf-8');
      expect(rendered.extension, 'txt');
    });

    test(
      'the CLI-local encoding is refused on the wire in both directions',
      () {
        const PatchbayOutputArtifactProjection local =
            PatchbayOutputArtifactProjection.renderedMember(
              member: r'$.data',
              encoding: PatchbayOutputArtifactEncoding.jsonOrDecodedText,
            );
        expect(local.encoding!.isWireDeclarable, isFalse);
        expect(local.toJson, throwsStateError);
        expect(
          () => PatchbayOutputArtifactProjection.fromJson(<String, Object?>{
            'kind': 'renderedMember',
            'member': r'$.data',
            'encoding': 'jsonOrDecodedText',
            'mediaType': 'application/json',
            'extension': 'json',
            'automaticSpill': true,
          }),
          throwsFormatException,
        );
      },
    );

    test('it resolves the 0.5.0 shape-directed media type', () {
      const PatchbayOutputArtifactEncoding encoding =
          PatchbayOutputArtifactEncoding.jsonOrDecodedText;
      expect(encoding.resolveFor(memberIsString: true), (
        'text/plain; charset=utf-8',
        'txt',
      ));
      expect(encoding.resolveFor(memberIsString: false), (
        'application/json',
        'json',
      ));
    });
  });

  group('wire round trip', () {
    test('a full declaration survives toJson/fromJson', () {
      final Map<String, Object?> wire = _validWire();
      final PatchbayOutputProjection decoded =
          PatchbayOutputProjection.fromJson(wire);
      expect(decoded.toJson(), wire);
      expect(decoded.brief!.id, 'ui.semantics.tree');
      expect(decoded.artifact!.kind, PatchbayOutputArtifactKind.renderedMember);
    });

    test('either half may be omitted, but not both', () {
      expect(
        PatchbayOutputProjection.fromJson(<String, Object?>{
          'brief': _validWire()['brief'],
        }).artifact,
        isNull,
      );
      expect(
        PatchbayOutputProjection.fromJson(<String, Object?>{
          'artifact': _validWire()['artifact'],
        }).brief,
        isNull,
      );
      expect(
        () => PatchbayOutputProjection.fromJson(const <String, Object?>{}),
        throwsFormatException,
      );
    });

    test(
      'a row without the key decodes to null, not to an empty projection',
      () {
        expect(
          PatchbayOutputProjection.fromCatalogRow(const <Object?, Object?>{
            'name': 'ui.semantics.tree',
          }),
          isNull,
        );
      },
    );
  });

  group('malformed declarations are refused, never repaired', () {
    /// The malformation classes the version plan names, applied to the one
    /// declaration shape: unknown key, wrong type, over-long string, repeated
    /// rule, illegal combination.
    final Map<String, Map<String, Object?> Function(Map<String, Object?>)>
    mutations = <String, Map<String, Object?> Function(Map<String, Object?>)>{
      'unknown top-level key': (Map<String, Object?> wire) => <String, Object?>{
        ...wire,
        'summary': 'not declarable',
      },
      'unknown brief key': (Map<String, Object?> wire) => <String, Object?>{
        ...wire,
        'brief': <String, Object?>{
          ...wire['brief']! as Map<String, Object?>,
          'keep': <String>[r'$.payload'],
        },
      },
      'unknown artifact key': (Map<String, Object?> wire) => <String, Object?>{
        ...wire,
        'artifact': <String, Object?>{
          ...wire['artifact']! as Map<String, Object?>,
          'outputPath': '/tmp/anywhere',
        },
      },
      'blob kind with extra fields': (Map<String, Object?> wire) =>
          <String, Object?>{
            ...wire,
            'artifact': <String, Object?>{
              'kind': 'payloadBlob',
              'member': r'$.payload.blob',
            },
          },
      'brief is not an object': (Map<String, Object?> wire) =>
          <String, Object?>{...wire, 'brief': <Object?>[]},
      'id is not a string': (Map<String, Object?> wire) => <String, Object?>{
        ...wire,
        'brief': <String, Object?>{
          'id': 7,
          'omit': <String>[r'$.a'],
        },
      },
      'omit is not a list': (Map<String, Object?> wire) => <String, Object?>{
        ...wire,
        'brief': <String, Object?>{'id': 'x', 'omit': r'$.a'},
      },
      'omit entry is not a string': (Map<String, Object?> wire) =>
          <String, Object?>{
            ...wire,
            'brief': <String, Object?>{
              'id': 'x',
              'omit': <Object?>[42],
            },
          },
      'unknown artifact kind': (Map<String, Object?> wire) => <String, Object?>{
        ...wire,
        'artifact': <String, Object?>{'kind': 'wholeResponse'},
      },
      'member traverses a list': (Map<String, Object?> wire) =>
          <String, Object?>{
            ...wire,
            'artifact': <String, Object?>{
              ...wire['artifact']! as Map<String, Object?>,
              'member': r'$.commands[].parameters',
            },
          },
      'mediaType disagrees with encoding': (Map<String, Object?> wire) =>
          <String, Object?>{
            ...wire,
            'artifact': <String, Object?>{
              ...wire['artifact']! as Map<String, Object?>,
              'mediaType': 'text/plain; charset=utf-8',
            },
          },
      'extension disagrees with encoding': (Map<String, Object?> wire) =>
          <String, Object?>{
            ...wire,
            'artifact': <String, Object?>{
              ...wire['artifact']! as Map<String, Object?>,
              'extension': 'txt',
            },
          },
      'automaticSpill is false': (Map<String, Object?> wire) =>
          <String, Object?>{
            ...wire,
            'artifact': <String, Object?>{
              ...wire['artifact']! as Map<String, Object?>,
              'automaticSpill': false,
            },
          },
      'repeated omit rule': (Map<String, Object?> wire) => <String, Object?>{
        ...wire,
        'brief': <String, Object?>{
          'id': 'x',
          'omit': <String>[r'$.a', r'$.a'],
        },
      },
    };

    for (final MapEntry<
          String,
          Map<String, Object?> Function(Map<String, Object?>)
        >
        entry
        in mutations.entries) {
      test('${entry.key} is refused', () {
        expect(
          () => PatchbayOutputProjection.fromJson(entry.value(_validWire())),
          throwsFormatException,
          reason: entry.key,
        );
      });
    }

    test('an over-long id or rule is refused, at a bounded size', () {
      final Random random = Random(_seed());
      for (var trial = 0; trial < 8; trial += 1) {
        final int overshoot = 1 + random.nextInt(64);
        final Map<String, Object?> wire = _validWire();
        expect(
          () => PatchbayOutputProjection.fromJson(<String, Object?>{
            ...wire,
            'brief': <String, Object?>{
              'id': 'a' * (patchbayOutputProjectionMaxIdLength + overshoot),
              'omit': <String>[r'$.a'],
            },
          }),
          throwsFormatException,
          reason: 'id overshoot $overshoot',
        );
        expect(
          () => PatchbayOutputProjection.fromJson(<String, Object?>{
            ...wire,
            'brief': <String, Object?>{
              'id': 'x',
              'omit': <String>[
                r'$.'
                    '${'a' * (patchbayOutputProjectionMaxPathBytes + overshoot)}',
              ],
            },
          }),
          throwsFormatException,
          reason: 'rule overshoot $overshoot',
        );
      }
    });

    test('one bad row fails the whole catalog, it is not dropped', () {
      final Map<String, Object?> catalog = <String, Object?>{
        'commands': <Object?>[
          <String, Object?>{
            'name': 'ui.semantics.tree',
            'outputProjection': _validWire(),
          },
          <String, Object?>{
            'name': 'evil.command',
            'outputProjection': const <String, Object?>{
              'artifact': <String, Object?>{'kind': 'wholeDisk'},
            },
          },
        ],
      };
      expect(
        () => patchbayDecodeCatalogOutputProjections(catalog),
        throwsA(
          isA<FormatException>().having(
            (FormatException failure) => failure.message,
            'message',
            contains('evil.command'),
          ),
        ),
      );
    });

    test('a clean catalog decodes only the rows that declare one', () {
      final Map<String, PatchbayOutputProjection> decoded =
          patchbayDecodeCatalogOutputProjections(<String, Object?>{
            'commands': <Object?>[
              <String, Object?>{
                'name': 'ui.semantics.tree',
                'outputProjection': _validWire(),
              },
              <String, Object?>{'name': 'navigation.current'},
            ],
          });
      expect(decoded.keys, <String>['ui.semantics.tree']);
    });
  });

  group('descriptor carries the declaration as a loose catalog sibling', () {
    test('ui.semantics.tree publishes brief and artifact', () {
      final Map<String, Object?> json = patchbayUiSemanticsTreeCommandDescriptor
          .toJson();
      expect(json['outputProjection'], <String, Object?>{
        'brief': <String, Object?>{
          'id': 'ui.semantics.tree',
          'omit': <String>[r'$.payload.nodes'],
        },
        'artifact': <String, Object?>{
          'kind': 'renderedMember',
          'member': r'$.payload.nodes',
          'encoding': 'json',
          'mediaType': 'application/json',
          'extension': 'json',
          'automaticSpill': true,
        },
      });
    });

    test('a descriptor without a declaration omits the key entirely', () {
      expect(
        patchbayNavigationCurrentCommandDescriptor.toJson(),
        isNot(contains('outputProjection')),
      );
    });

    test('the declaration survives a runtime override', () {
      final PatchbayCommandDescriptor overridden =
          patchbayUiSemanticsTreeCommandDescriptor.withRuntimeOverrides(
            gates: const <String>{'requiresMounted'},
          );
      expect(
        overridden.outputProjection?.brief?.id,
        'ui.semantics.tree',
        reason:
            'a runtime adapter specializes gates and defaults; dropping the '
            'projection would silently change what the CLI publishes',
      );
    });

    test(
      'the declaration is JSON and stays inside the catalog digest input',
      () {
        // The digest is taken over whole command objects, so no separate opt-in
        // is needed — this only pins that the value is encodable at all.
        expect(
          () => jsonEncode(patchbayUiSemanticsTreeCommandDescriptor.toJson()),
          returnsNormally,
        );
      },
    );

    test('every compiled-in declaration is within its own bounds', () {
      final List<PatchbayCommandDescriptor> descriptors =
          <PatchbayCommandDescriptor>[
            ...patchbayProtocolCliCommandDescriptors,
            ...patchbayUiProtocolCliCommandDescriptors,
          ];
      expect(descriptors, isNotEmpty);
      for (final PatchbayCommandDescriptor descriptor in descriptors) {
        expect(
          () => descriptor.outputProjection?.validate(),
          returnsNormally,
          reason: descriptor.name,
        );
      }
    });
  });
}
