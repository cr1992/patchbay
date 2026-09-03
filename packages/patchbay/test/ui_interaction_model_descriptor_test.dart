/// DG-060-05 「交互模型进入 catalog」：机检 catalog wire 上恰好哪些命令带
/// `interactionModel`、值是什么，以及 host 侧 fail-closed 语义。
///
/// PB-050-34 只交付这一半（声明 + direct-target 文档）；reveal 的三个拒绝码
/// 属于 PB-050-35，本文件不覆盖。
library;

import 'dart:math';

import 'package:patchbay/patchbay_protocol.dart';
import 'package:test/test.dart';

/// Deterministic-seed convention for malformed-input cases, mirroring
/// `patchbay_transport`'s `defaultMalformedSeed` (PB-060-06): a fixed seed so
/// a failing case reproduces byte for byte, restated locally here because
/// `interactionModel` is decoded inside a forwarded catalog row — explicitly
/// out of that shared harness's scope (it never mutates inside a forwarded
/// object) — so this package owns its own decode-boundary fuzz instead of
/// adding a `patchbay_transport` dependency for one constant.
const int _malformedSeed = 0x50424D50; // ASCII 'PBMP'.

/// 封闭表：这 10 条命令，且只有这 10 条，携带 `interactionModel`。
const Map<String, PatchbayInteractionModel> _expectedInteractionModels =
    <String, PatchbayInteractionModel>{
      'ui.text.set': PatchbayInteractionModel.directTarget,
      'ui.text.enter': PatchbayInteractionModel.directTarget,
      'ui.semantics.action': PatchbayInteractionModel.userLike,
      'ui.semantics.actionByIdentifier': PatchbayInteractionModel.userLike,
      'ui.semantics.tap': PatchbayInteractionModel.userLike,
      'ui.gesture.pressHold': PatchbayInteractionModel.userLike,
      'ui.gesture.drag': PatchbayInteractionModel.userLike,
      'ui.gesture.fling': PatchbayInteractionModel.userLike,
      'ui.gesture.tap': PatchbayInteractionModel.userLike,
      'ui.reveal': PatchbayInteractionModel.userLike,
    };

void main() {
  test('exactly the DG-060-05 write/reachability commands declare '
      'interactionModel, with the frozen values, and every other UI protocol '
      'command declares none', () {
    final Map<String, PatchbayInteractionModel?> actual =
        <String, PatchbayInteractionModel?>{
          for (final PatchbayCommandDescriptor descriptor
              in patchbayUiProtocolCliCommandDescriptors)
            descriptor.name: descriptor.interactionModel,
        };

    // 全表命令名不变：漏掉一条会让下面的逐条断言静默跳过它。
    expect(actual.keys.toSet(), <String>{
      'ui.text.set',
      'ui.text.enter',
      'ui.semantics.tree',
      'ui.semantics.action',
      'ui.semantics.actionByIdentifier',
      'ui.semantics.tap',
      'ui.gesture.pressHold',
      'ui.gesture.drag',
      'ui.gesture.fling',
      'ui.gesture.tap',
      'ui.reveal',
      'ui.wait',
      'ui.keepAwake.set',
      'ui.keepAwake.status',
      'ui.inspect.select',
      'ui.inspect.status',
      'ui.capture',
    });

    for (final MapEntry<String, PatchbayInteractionModel?> entry
        in actual.entries) {
      expect(
        entry.value,
        _expectedInteractionModels[entry.key],
        reason: entry.key,
      );
    }
  });

  test('catalog JSON carries interactionModel only on those 10 rows, with the '
      'exact frozen wire string', () {
    for (final PatchbayCommandDescriptor descriptor
        in patchbayUiProtocolCliCommandDescriptors) {
      final Map<String, Object?> json = descriptor.toJson();
      final PatchbayInteractionModel? expected =
          _expectedInteractionModels[descriptor.name];
      if (expected == null) {
        expect(
          json.containsKey('interactionModel'),
          isFalse,
          reason: descriptor.name,
        );
      } else {
        expect(
          json['interactionModel'],
          expected == PatchbayInteractionModel.directTarget
              ? 'directTarget'
              : 'userLike',
          reason: descriptor.name,
        );
      }
    }
  });

  test(
    'non-UI protocol commands (navigation) never carry interactionModel',
    () {
      for (final PatchbayCommandDescriptor descriptor
          in patchbayProtocolCliCommandDescriptors) {
        if (descriptor.plane != PatchbayPlane.domain) continue;
        expect(descriptor.interactionModel, isNull, reason: descriptor.name);
        expect(
          descriptor.toJson().containsKey('interactionModel'),
          isFalse,
          reason: descriptor.name,
        );
      }
    },
  );

  test(
    'PatchbayInteractionModel.fromCatalogRow returns null for an absent key, '
    'the declared value for a known one, and throws for an unknown one',
    () {
      expect(
        PatchbayInteractionModel.fromCatalogRow(const <Object?, Object?>{
          'name': 'ui.semantics.tree',
        }),
        isNull,
      );
      expect(
        PatchbayInteractionModel.fromCatalogRow(const <Object?, Object?>{
          'interactionModel': 'directTarget',
        }),
        PatchbayInteractionModel.directTarget,
      );
      expect(
        PatchbayInteractionModel.fromCatalogRow(const <Object?, Object?>{
          'interactionModel': 'userLike',
        }),
        PatchbayInteractionModel.userLike,
      );
      expect(
        () => PatchbayInteractionModel.fromCatalogRow(const <Object?, Object?>{
          'interactionModel': 'bogus',
        }),
        throwsFormatException,
      );
      expect(
        () => PatchbayInteractionModel.fromCatalogRow(const <Object?, Object?>{
          'interactionModel': 3,
        }),
        throwsFormatException,
      );
    },
  );

  test('fixed-seed malformed interactionModel values (random type '
      'substitutions and random near-miss strings) are all rejected as typed '
      'FormatException, never accepted or silently coerced — replayable with '
      'seed $_malformedSeed', () {
    final Random random = Random(_malformedSeed);
    // Same three malformation classes as PB-060-06's transport harness,
    // scaled down to this one field: type substitution, and a bounded
    // string that must not collide with the two real members.
    final List<Object?> typeSubstitutions = <Object?>[
      for (var i = 0; i < 20; i += 1)
        <Object? Function()>[
          () => random.nextInt(1 << 31),
          () => random.nextBool(),
          () => random.nextDouble(),
          () => <Object?>[],
          () => <String, Object?>{},
          () => null,
        ][random.nextInt(6)](),
    ];
    for (final Object? value in typeSubstitutions) {
      // `null` means the key is declared-but-null, which is still "not a
      // string" and must reject the same way; fromCatalogRow only treats
      // a genuinely *absent* key as legacyUnknown (tested above).
      expect(
        () => PatchbayInteractionModel.fromCatalogRow(<Object?, Object?>{
          'interactionModel': value,
        }),
        throwsFormatException,
        reason: 'type substitution: ${value.runtimeType} $value',
      );
    }

    const String alphabet =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
    for (var i = 0; i < 20; i += 1) {
      final int length = 1 + random.nextInt(24);
      final String candidate = String.fromCharCodes(<int>[
        for (var j = 0; j < length; j += 1)
          alphabet.codeUnitAt(random.nextInt(alphabet.length)),
      ]);
      if (candidate == 'directTarget' || candidate == 'userLike') continue;
      expect(
        () => PatchbayInteractionModel.fromCatalogRow(<Object?, Object?>{
          'interactionModel': candidate,
        }),
        throwsFormatException,
        reason: 'near-miss string: $candidate',
      );
    }
  });
}
