/// 协议演进面：serverVersion / feature capabilities / catalog digest。
///
/// 三者都是 `schemaVersion = 1` 之内的**加字段**，不是版本跳跃——用例要同时钉住
/// 「新字段确实出现」和「既有语义没被顺手改掉」两侧。
library;

import 'dart:convert';

import 'package:patchbay/patchbay.dart';
import 'package:test/test.dart';

PatchbayServiceHost _host({
  required Future<Map<String, Object?>> Function() catalog,
  Set<PatchbayFeature> features = const <PatchbayFeature>{},
}) => PatchbayServiceHost(
  applicationId: 'dev.patchbay.test',
  appInstanceId: 'instance-evolution',
  registrar: (_, _) {},
  catalog: catalog,
  snapshot: () async => const <String, Object?>{},
  invoke: (_, _, requestId) async => PatchbayInvocation.rejected(
    requestId: requestId,
    rejection: const PatchbayRejection(code: 'notRegistered'),
  ).toJson(),
  features: features,
);

Map<String, Object?> _command(String name, {String summary = 'x'}) =>
    <String, Object?>{'name': name, 'summary': summary};

void main() {
  group('serverVersion', () {
    test('identity 面报出 host 自己的包版本', () async {
      final Map<String, Object?> identity = _host(
        catalog: () async => const <String, Object?>{},
      ).identityResponse();

      expect(identity['serverVersion'], patchbayPackageVersion);
      // 加字段不动 schemaVersion：这是演进机制，不是协议版本跳跃。
      expect(identity['schemaVersion'], PatchbayServiceHost.schemaVersion);
      expect(identity['schemaVersion'], 1);
    });

    test('既有 identity 字段一个不少、语义不变', () async {
      final Map<String, Object?> identity = _host(
        catalog: () async => const <String, Object?>{},
      ).identityResponse();

      expect(
        identity.keys,
        containsAll(<String>['applicationId', 'appInstanceId', 'isolateId']),
      );
      expect(identity['applicationId'], 'dev.patchbay.test');
      expect(identity['appInstanceId'], 'instance-evolution');
    });
  });

  group('feature capabilities', () {
    test('核心能力由 host 自己声明，调用方给不给都在', () async {
      final Map<String, Object?> identity = _host(
        catalog: () async => const <String, Object?>{},
      ).identityResponse();

      expect(identity['features'], <String>[
        PatchbayFeature.catalogDigest.name,
      ]);
    });

    test('上层追加的能力与核心能力合并，并按名字排序', () async {
      final Map<String, Object?> identity = _host(
        catalog: () async => const <String, Object?>{},
        features: const <PatchbayFeature>{PatchbayFeature.lifecycleState},
      ).identityResponse();

      // 排序是为了两次握手能逐字节比对：features 变了才是能力变了，
      // 不能因为 Set 迭代顺序看起来变了。
      expect(identity['features'], <String>[
        PatchbayFeature.catalogDigest.name,
        PatchbayFeature.lifecycleState.name,
      ]);
    });

    test('上层无法把核心能力声明掉', () {
      final PatchbayServiceHost host = _host(
        catalog: () async => const <String, Object?>{},
        // 只给 lifecycleState，核心的 catalogDigest 仍必须在——
        // 客户端读到 Patchbay identity，就有权假定协议层自己实现的能力是真的。
        features: const <PatchbayFeature>{PatchbayFeature.lifecycleState},
      );

      expect(host.features, <PatchbayFeature>{
        PatchbayFeature.catalogDigest,
        PatchbayFeature.lifecycleState,
      });
    });
  });

  group('catalog digest', () {
    test('catalog 带上自描述的摘要', () async {
      final Map<String, Object?> catalog = await _host(
        catalog: () async => <String, Object?>{
          'commands': <Object?>[_command('domain.a')],
        },
      ).dispatchCatalog();

      final Map<String, Object?> digest =
          catalog['catalogDigest']! as Map<String, Object?>;
      expect(digest['algorithm'], patchbayDigestAlgorithmSha256);
      expect(digest['covers'], <String>[patchbayCatalogDigestScopeCommands]);
      expect(digest['value'], matches(RegExp(r'^[0-9a-f]{64}$')));
    });

    test('注册顺序变了摘要不变——换顺序不是能力变化', () async {
      Future<String> digestOf(List<Object?> commands) async {
        final Map<String, Object?> catalog = await _host(
          catalog: () async => <String, Object?>{'commands': commands},
        ).dispatchCatalog();
        return (catalog['catalogDigest']! as Map<String, Object?>)['value']!
            as String;
      }

      expect(
        await digestOf(<Object?>[_command('domain.a'), _command('domain.b')]),
        await digestOf(<Object?>[_command('domain.b'), _command('domain.a')]),
      );
    });

    test('descriptor 内容变了摘要就变', () async {
      Future<String> digestOf(List<Object?> commands) async {
        final Map<String, Object?> catalog = await _host(
          catalog: () async => <String, Object?>{'commands': commands},
        ).dispatchCatalog();
        return (catalog['catalogDigest']! as Map<String, Object?>)['value']!
            as String;
      }

      expect(
        await digestOf(<Object?>[_command('domain.a')]),
        isNot(await digestOf(<Object?>[_command('domain.a', summary: 'y')])),
      );
      expect(
        await digestOf(<Object?>[_command('domain.a')]),
        isNot(
          await digestOf(<Object?>[_command('domain.a'), _command('domain.b')]),
        ),
      );
    });

    test('uiTargets 挂载状态变化不动摘要', () async {
      Future<String> digestOf(List<Object?> uiTargets) async {
        final Map<String, Object?> catalog = await _host(
          catalog: () async => <String, Object?>{
            'commands': <Object?>[_command('domain.a')],
            'uiTargets': uiTargets,
          },
        ).dispatchCatalog();
        return (catalog['catalogDigest']! as Map<String, Object?>)['value']!
            as String;
      }

      // 导航一下就换一批 target 是常态；摘要若跟着翻，消费端只会学会忽略它。
      expect(
        await digestOf(const <Object?>[]),
        await digestOf(<Object?>[
          <String, Object?>{'id': 'login.phone', 'generation': 3},
        ]),
      );
    });

    test('consumer 自己写的 catalogDigest 被协议覆盖', () async {
      final Map<String, Object?> catalog = await _host(
        catalog: () async => <String, Object?>{
          'commands': <Object?>[_command('domain.a')],
          'catalogDigest': <String, Object?>{
            'algorithm': 'sha256',
            'covers': <String>['commands'],
            'value': 'f' * 64,
          },
        },
      ).dispatchCatalog();

      expect(
        (catalog['catalogDigest']! as Map<String, Object?>)['value'],
        isNot('f' * 64),
      );
    });

    test('被拒的 catalog 不带摘要——没有命令面可描述', () async {
      final Map<String, Object?> catalog = await _host(
        catalog: () async => <String, Object?>{
          'commands': <Object?>[
            <String, Object?>{'name': 'auth.switch-tenant'},
          ],
        },
      ).dispatchCatalog();

      expect(catalog['admission'], 'rejected');
      expect(catalog.containsKey('catalogDigest'), isFalse);
    });

    test('没有 commands 键与空 commands 是同一个声明面', () async {
      Future<String> digestOf(Map<String, Object?> declared) async {
        final Map<String, Object?> catalog = await _host(
          catalog: () async => declared,
        ).dispatchCatalog();
        return (catalog['catalogDigest']! as Map<String, Object?>)['value']!
            as String;
      }

      expect(
        await digestOf(const <String, Object?>{}),
        await digestOf(<String, Object?>{'commands': const <Object?>[]}),
      );
    });
  });

  group('canonical JSON', () {
    test('对象键递归排序，数组顺序保留', () {
      expect(
        patchbayCanonicalJson(<String, Object?>{
          'b': 1,
          'a': <String, Object?>{'d': 2, 'c': 3},
          'list': <Object?>['z', 'a'],
        }),
        '{"a":{"c":3,"d":2},"b":1,"list":["z","a"]}',
      );
    });

    test('同一内容不同书写顺序编码一致', () {
      expect(
        patchbayCanonicalJson(<String, Object?>{'x': 1, 'y': 2}),
        patchbayCanonicalJson(<String, Object?>{'y': 2, 'x': 1}),
      );
    });
  });

  group('PatchbayCatalogDigest 读取端', () {
    test('未知算法只是不可复算，不是解码失败', () {
      final PatchbayCatalogDigest? digest = PatchbayCatalogDigest.fromJson(
        jsonDecode('''
{"algorithm":"blake3","covers":["commands"],"value":"00"}
''')
            as Object?,
      );

      expect(digest, isNotNull);
      expect(digest!.isRecomputable, isFalse);
      expect(digest.algorithm, 'blake3');
    });

    test('更新版本多写的字段不会把读取端读崩', () {
      final PatchbayCatalogDigest? digest = PatchbayCatalogDigest.fromJson(
        jsonDecode('''
{"algorithm":"sha256","covers":["commands"],"value":"00","computedAt":"later"}
''')
            as Object?,
      );

      expect(digest, isNotNull);
      expect(digest!.isRecomputable, isTrue);
    });

    test('覆盖范围变宽时读取端不再认为自己能复算', () {
      final PatchbayCatalogDigest digest = PatchbayCatalogDigest.fromJson(
        <String, Object?>{
          'algorithm': patchbayDigestAlgorithmSha256,
          'covers': <String>['commands', 'uiTargets'],
          'value': '00',
        },
      )!;

      expect(digest.isRecomputable, isFalse);
    });

    test('缺字段或类型不对读成「没有摘要」', () {
      expect(PatchbayCatalogDigest.fromJson(null), isNull);
      expect(PatchbayCatalogDigest.fromJson('sha256:00'), isNull);
      expect(
        PatchbayCatalogDigest.fromJson(<String, Object?>{
          'algorithm': patchbayDigestAlgorithmSha256,
          'value': '00',
        }),
        isNull,
      );
    });
  });
}
