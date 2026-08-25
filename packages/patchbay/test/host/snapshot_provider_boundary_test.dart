import 'dart:convert';
import 'dart:developer';

import 'package:patchbay/patchbay.dart';
import 'package:patchbay/src/host/host_snapshot.dart';
import 'package:patchbay/src/host/snapshot_payload.dart';
import 'package:test/test.dart';

Map<String, Object?> _rejection(Map<String, Object?> response) =>
    response['rejection']! as Map<String, Object?>;

Map<String, Object?> _details(Map<String, Object?> response) =>
    _rejection(response)['details']! as Map<String, Object?>;

PatchbaySnapshotPayloadViolation _violationOf(Object? payload) {
  return _violationWith(const PatchbaySnapshotPayloadFreezer(), payload);
}

PatchbaySnapshotPayloadViolation _violationWith(
  PatchbaySnapshotPayloadFreezer freezer,
  Object? payload,
) {
  try {
    freezer.freeze(payload);
  } on PatchbaySnapshotPayloadViolation catch (error) {
    return error;
  }
  fail('expected a snapshot payload violation');
}

void main() {
  group('snapshot payload freezer', () {
    test('keeps insertion order while canonical equality sorts keys', () {
      final Map<String, Object?> source = <String, Object?>{
        'z': <Object?>[true, null, 1.5],
        'a': <String, Object?>{'second': 2, 'first': 1},
      };

      final PatchbayFrozenSnapshotPayload frozen =
          const PatchbaySnapshotPayloadFreezer().freeze(source);

      expect(frozen.body.keys, <String>['z', 'a']);
      expect((frozen.body['a']! as Map<String, Object?>).keys, <String>[
        'second',
        'first',
      ]);
      expect(
        frozen.canonical,
        '{"a":{"first":1,"second":2},"z":[true,null,1.5]}',
      );
    });

    test('matches the existing canonical JSON bytes for valid payloads', () {
      final Map<String, Object?> source = <String, Object?>{
        'z': 'quote " slash \\ control \b\n',
        'emoji': '🙂',
        'lineSeparator': '\u2028',
        'a': <Object?>[-0.0, 1.25e20, '雪'],
      };

      final PatchbayFrozenSnapshotPayload frozen =
          const PatchbaySnapshotPayloadFreezer().freeze(source);

      expect(frozen.canonical, patchbayCanonicalJson(source));
      expect(
        utf8.encode(frozen.canonical),
        utf8.encode(patchbayCanonicalJson(source)),
      );
    });

    test('cuts every mutable container away from the consumer graph', () {
      final List<Object?> shared = <Object?>[1];
      final Map<String, Object?> source = <String, Object?>{
        'left': shared,
        'right': shared,
      };

      final PatchbayFrozenSnapshotPayload frozen =
          const PatchbaySnapshotPayloadFreezer().freeze(source);
      shared[0] = 9;
      source['late'] = true;

      expect(frozen.body, <String, Object?>{
        'left': <Object?>[1],
        'right': <Object?>[1],
      });
      expect(identical(frozen.body['left'], frozen.body['right']), isFalse);
      expect(
        () => (frozen.body['left']! as List<Object?>).add(2),
        throwsUnsupportedError,
      );
    });

    test('rejects unsupported values without calling toString', () {
      final PatchbaySnapshotPayloadViolation violation = _violationOf(
        <String, Object?>{'createdAt': DateTime.utc(2026)},
      );

      expect(
        violation.details,
        containsPair('reason', 'snapshotPayloadInvalid'),
      );
      expect(violation.details, containsPair('failure', 'unsupportedType'));
      expect(violation.details, containsPair('path', r'$.createdAt'));
      expect(violation.details, containsPair('type', 'DateTime'));
      expect(violation.details.values, isNot(contains(DateTime.utc(2026))));
    });

    test('rejects a non-string key at its parent path', () {
      final PatchbaySnapshotPayloadViolation violation = _violationOf(
        <Object?, Object?>{1: 'not json'},
      );

      expect(violation.details, containsPair('failure', 'nonStringKey'));
      expect(violation.details, containsPair('path', r'$'));
      expect(violation.details, containsPair('type', 'int'));
    });

    test('rejects every non-finite JSON number', () {
      for (final double value in <double>[
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        final PatchbaySnapshotPayloadViolation violation = _violationOf(
          <String, Object?>{'reading': value},
        );
        expect(violation.details, containsPair('failure', 'nonFiniteNumber'));
        expect(violation.details, containsPair('path', r'$.reading'));
      }
    });

    test('detects direct and indirect active-path cycles', () {
      final List<Object?> direct = <Object?>[];
      direct.add(direct);
      expect(
        _violationOf(<String, Object?>{'loop': direct}).details,
        containsPair('failure', 'cycleDetected'),
      );

      final Map<String, Object?> left = <String, Object?>{};
      final List<Object?> right = <Object?>[left];
      left['right'] = right;
      final PatchbaySnapshotPayloadViolation indirect = _violationOf(
        <String, Object?>{'left': left},
      );
      expect(indirect.details, containsPair('failure', 'cycleDetected'));
      expect(indirect.details['path'], r'$.left.right[0]');
    });

    test('allows depth 128 and rejects depth 129 without recursion', () {
      Object? atDepth(int depth) {
        Object? value = 0;
        for (var index = 0; index < depth; index += 1) {
          value = <Object?>[value];
        }
        return <String, Object?>{'value': value};
      }

      expect(
        const PatchbaySnapshotPayloadFreezer().freeze(atDepth(128)).body,
        contains('value'),
      );
      final PatchbaySnapshotPayloadViolation violation = _violationOf(
        atDepth(129),
      );
      expect(violation.details, containsPair('failure', 'nestingTooDeep'));
    });

    test('enforces expanded occurrence boundary on the attempted node', () {
      const PatchbaySnapshotPayloadLimits allowed =
          PatchbaySnapshotPayloadLimits(
            maxContainerDepth: 128,
            maxExpandedOccurrences: 3,
            maxCanonicalBytes: 64,
          );
      const PatchbaySnapshotPayloadLimits refused =
          PatchbaySnapshotPayloadLimits(
            maxContainerDepth: 128,
            maxExpandedOccurrences: 2,
            maxCanonicalBytes: 64,
          );

      expect(
        const PatchbaySnapshotPayloadFreezer(
          limits: allowed,
        ).freeze(<String, Object?>{'a': 1}).canonical,
        '{"a":1}',
      );
      final PatchbaySnapshotPayloadViolation violation = _violationWith(
        const PatchbaySnapshotPayloadFreezer(limits: refused),
        <String, Object?>{'a': 1},
      );
      expect(violation.details, containsPair('failure', 'payloadTooLarge'));
      expect(violation.details, containsPair('limitKind', 'expandedNodes'));
      expect(violation.details, containsPair('limit', 2));
      expect(violation.details, containsPair('observed', 3));
    });

    test('stops exponential shared-DAG expansion at the occurrence budget', () {
      Object? shared = 0;
      for (var depth = 0; depth < 20; depth += 1) {
        shared = <String, Object?>{'left': shared, 'right': shared};
      }
      const PatchbaySnapshotPayloadLimits limits =
          PatchbaySnapshotPayloadLimits(
            maxContainerDepth: 128,
            maxExpandedOccurrences: 64,
            maxCanonicalBytes: 1024 * 1024,
          );

      final PatchbaySnapshotPayloadViolation violation = _violationWith(
        const PatchbaySnapshotPayloadFreezer(limits: limits),
        <String, Object?>{'shared': shared},
      );

      expect(violation.details, containsPair('limitKind', 'expandedNodes'));
      expect(violation.details, containsPair('limit', 64));
      expect(violation.details, containsPair('observed', 65));
    });

    test(
      'enforces canonical UTF-8 boundary before constructing the string',
      () {
        const PatchbaySnapshotPayloadLimits allowed =
            PatchbaySnapshotPayloadLimits(
              maxContainerDepth: 128,
              maxExpandedOccurrences: 100,
              maxCanonicalBytes: 7,
            );
        const PatchbaySnapshotPayloadLimits refused =
            PatchbaySnapshotPayloadLimits(
              maxContainerDepth: 128,
              maxExpandedOccurrences: 100,
              maxCanonicalBytes: 6,
            );

        expect(
          const PatchbaySnapshotPayloadFreezer(
            limits: allowed,
          ).freeze(<String, Object?>{'a': 1}).canonical,
          '{"a":1}',
        );
        final PatchbaySnapshotPayloadViolation violation = _violationWith(
          const PatchbaySnapshotPayloadFreezer(limits: refused),
          <String, Object?>{'a': 1},
        );
        expect(violation.details, containsPair('limitKind', 'canonicalBytes'));
        expect(violation.details, containsPair('limit', 6));
        expect(violation.details, containsPair('observed', 7));
      },
    );

    test('counts exact UTF-8 bytes for multibyte payloads', () {
      final Map<String, Object?> source = <String, Object?>{'雪': '🙂'};
      final int encodedBytes = utf8.encode(jsonEncode(source)).length;
      final PatchbaySnapshotPayloadLimits allowed =
          PatchbaySnapshotPayloadLimits(
            maxContainerDepth: 128,
            maxExpandedOccurrences: 100,
            maxCanonicalBytes: encodedBytes,
          );
      final PatchbaySnapshotPayloadLimits refused =
          PatchbaySnapshotPayloadLimits(
            maxContainerDepth: 128,
            maxExpandedOccurrences: 100,
            maxCanonicalBytes: encodedBytes - 1,
          );

      expect(
        PatchbaySnapshotPayloadFreezer(
          limits: allowed,
        ).freeze(source).canonical,
        jsonEncode(source),
      );
      final PatchbaySnapshotPayloadViolation violation = _violationWith(
        PatchbaySnapshotPayloadFreezer(limits: refused),
        source,
      );
      expect(violation.details, containsPair('limitKind', 'canonicalBytes'));
      expect(violation.details, containsPair('limit', encodedBytes - 1));
      expect(violation.details, containsPair('observed', encodedBytes));
    });

    test('canonical bytes win when one occurrence crosses both limits', () {
      const PatchbaySnapshotPayloadLimits limits =
          PatchbaySnapshotPayloadLimits(
            maxContainerDepth: 128,
            maxExpandedOccurrences: 2,
            maxCanonicalBytes: 5,
          );

      final PatchbaySnapshotPayloadViolation violation = _violationWith(
        const PatchbaySnapshotPayloadFreezer(limits: limits),
        <String, Object?>{'a': 1},
      );

      expect(violation.details, containsPair('limitKind', 'canonicalBytes'));
      expect(violation.details, containsPair('observed', 6));
    });

    test('production ceilings admit the densest scalar array', () {
      final int maximumDenseScalars =
          (patchbaySnapshotMaxCanonicalBytes - 1) ~/ 2;
      final int denseArrayOccurrences = 1 + maximumDenseScalars;

      expect(
        patchbaySnapshotMaxExpandedOccurrences,
        greaterThanOrEqualTo(denseArrayOccurrences),
      );
    });
  });

  group('host snapshot provider boundary', () {
    test(
      'does not let an invalid sample mutate revision or retention',
      () async {
        Object? current = <String, Object?>{'value': 1};
        final HostSnapshotHandler handler = HostSnapshotHandler(
          snapshotSource: () async => current! as Map<String, Object?>,
        );

        final Map<String, Object?> first = await handler.dispatchSnapshot();
        current = <String, Object?>{'bad': DateTime.utc(2026)};
        final Map<String, Object?> invalid = await handler.dispatchSnapshot();
        current = <String, Object?>{'value': 2};
        final Map<String, Object?> diff = await handler.dispatchSnapshot(
          <String, Object?>{'fromRevision': 1},
        );

        expect(first['snapshotRevision'], 1);
        expect(_rejection(invalid)['code'], 'providerProtocolViolation');
        expect(
          _details(invalid),
          containsPair('reason', 'snapshotPayloadInvalid'),
        );
        expect(diff['snapshotRevision'], 2);
        expect(diff['changed'], <Object?>[
          <String, Object?>{'path': '/value', 'before': 1, 'after': 2},
        ]);
      },
    );

    test(
      'whole response and later selectors use the same frozen view',
      () async {
        final Map<String, Object?> nested = <String, Object?>{'value': 1};
        final HostSnapshotHandler handler = HostSnapshotHandler(
          snapshotSource: () async => <String, Object?>{'nested': nested},
        );

        final Map<String, Object?> whole = await handler.dispatchSnapshot();
        nested['value'] = 2;

        expect(whole['nested'], <String, Object?>{'value': 1});
        expect(
          () => (whole['nested']! as Map<String, Object?>)['value'] = 3,
          throwsUnsupportedError,
        );
      },
    );

    test(
      'projects freezer failures without leaking messages or payloads',
      () async {
        for (final PatchbaySnapshotPayloadStage stage
            in PatchbaySnapshotPayloadStage.values) {
          final HostSnapshotHandler handler = HostSnapshotHandler(
            snapshotSource: () async => <String, Object?>{'secret': 'payload'},
            snapshotFreezer: PatchbaySnapshotPayloadFreezer(
              testStageHook: (PatchbaySnapshotPayloadStage current) {
                if (current == stage) {
                  throw StateError('secret failure message');
                }
              },
            ),
          );

          final Map<String, Object?> response = await handler
              .dispatchSnapshot();
          expect(_rejection(response)['code'], 'providerProtocolViolation');
          expect(
            _details(response),
            containsPair('reason', 'snapshotPayloadInvalid'),
          );
          expect(jsonEncode(response), isNot(contains('secret')));
        }
      },
    );

    test(
      'VM Service and direct dispatch share the same rejection details',
      () async {
        Future<Map<String, Object?>> invalidSource() async => <String, Object?>{
          'value': double.nan,
        };
        final PatchbayServiceHost host = PatchbayServiceHost(
          applicationId: 'dev.patchbay.test',
          registrar: (_, _) {},
          catalog: () async => const <String, Object?>{'commands': <Object?>[]},
          snapshot: invalidSource,
          invoke: (_, _, String requestId) async =>
              PatchbayInvocation.accepted(requestId: requestId).toJson(),
        );

        final Map<String, Object?> direct = await host.dispatchSnapshot();
        final ServiceExtensionResponse wire = await host.handleSnapshot(
          PatchbayServiceHost.snapshotMethod,
          const <String, String>{'isolateId': 'isolates/1'},
        );
        final Map<String, Object?> vm = Map<String, Object?>.from(
          jsonDecode(wire.result!) as Map<String, dynamic>,
        );

        expect(_rejection(direct)['code'], 'providerProtocolViolation');
        expect(_details(vm), _details(direct));
      },
    );
  });
}
