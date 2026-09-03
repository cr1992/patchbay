/// 跨版本协议面 golden：钉住「加字段」到底动了谁。
///
/// 本仓已经有两个真实 consumer，且它们**不同步升级**——一个 pin 旧 tag、一个跟新的。
/// 所以协议面上的改动分两类，代价差一个数量级：
///
/// - **加字段到松读面**（identity / catalog / snapshot 这些客户端逐键读的 map）：
///   老客户端读不认识的键会直接忽略，新客户端读不到就当「老 host 没这个能力」。
///   安全，`schemaVersion` 不用动。
/// - **加字段到严格解码面**（生成的 `XxxWire.fromJson`，遇未知键即 FormatException）：
///   只要有已发布客户端在解码这个类型，加字段就是**当场打断老 CLI**。
///
/// 两类在源码里长得一模一样（都是往 `contracts/core_wire.json` 里加一行），所以这里
/// 用 golden 把「面的形状」和「哪些类型正被客户端严格解码」一起钉住：改动本身不会被
/// 阻止，但它一定会在 diff 里现形，评审时能看出踩的是哪一类。
///
/// 更新 wire golden：从仓根运行 `wire_codegen.dart --write`；更新前先想清楚落在上面哪一类。
library;

import 'dart:convert';
import 'dart:io';

import 'package:patchbay/patchbay_host.dart';
import 'package:test/test.dart';

const String _contractPath = 'contracts/core_wire.json';
const String _wireSurfaceGolden = 'test/golden/wire_surface.json';
const String _hostSurfaceGolden = 'test/golden/host_surface.json';

/// 已发布客户端所在的包。严格解码调用出现在这里，就意味着「加字段会打断老版」。
const List<String> _clientLibPaths = <String>[
  '../patchbay_cli/lib',
  '../patchbay_transport/lib',
];

final RegExp _strictDecode = RegExp(r'\b(Patchbay[A-Za-z0-9]*Wire)\.fromJson');

const JsonEncoder _pretty = JsonEncoder.withIndent('  ');

/// 契约里每个 wire 类型的形状：enum 记值，object 记 wire 字段名。
Map<String, Object?> wireSurface(Map<String, Object?> contract) {
  final List<Object?> types = contract['types']! as List<Object?>;
  final Map<String, Object?> surface = <String, Object?>{};
  for (final Object? entry in types) {
    final Map<String, Object?> type = entry! as Map<String, Object?>;
    final String name = type['name']! as String;
    surface[name] = type['kind'] == 'enum'
        ? <String, Object?>{'kind': 'enum', 'values': type['values']}
        : <String, Object?>{
            'kind': 'object',
            'fields': <String>[
              for (final Object? entry in type['fields']! as List<Object?>)
                ((entry! as Map<String, Object?>)['wireName'] ??
                        (entry as Map<String, Object?>)['name']!)
                    as String,
            ],
          };
  }
  return surface;
}

/// 客户端源码里出现的严格解码类型名。
///
/// 抽不到任何名字时返回空集——调用方必须把空集判红，否则抽取式一失效这道闸就恒绿。
Set<String> strictlyDecodedTypes(Iterable<String> sources) => <String>{
  for (final String source in sources)
    for (final Match match in _strictDecode.allMatches(source)) match.group(1)!,
};

List<String> _dartSources(String directory) => Directory(directory)
    .listSync(recursive: true)
    .whereType<File>()
    .where((File file) => file.path.endsWith('.dart'))
    .map((File file) => file.readAsStringSync())
    .toList(growable: false);

/// 比对 golden。测试只读，避免测试进程成为另一条生成路径。
void expectGolden(
  String path,
  Map<String, Object?> actual, {
  required String reason,
}) {
  final String rendered = '${_pretty.convert(actual)}\n';
  final File golden = File(path);
  expect(
    golden.existsSync(),
    isTrue,
    reason: '$path 缺失；wire surface 用 wire_codegen.dart --write 生成',
  );
  expect(golden.readAsStringSync(), rendered, reason: reason);
}

void main() {
  final Map<String, Object?> contract =
      jsonDecode(File(_contractPath).readAsStringSync())
          as Map<String, Object?>;

  test('wire 面与客户端严格解码名单未被无声改动', () {
    final Set<String> declared = wireSurface(contract).keys.toSet();
    final Set<String> decoded = strictlyDecodedTypes(<String>[
      for (final String path in _clientLibPaths) ..._dartSources(path),
    ]).intersection(declared);

    expect(decoded, isNotEmpty, reason: '没从客户端源码抽到任何严格解码调用——抽取式已失效，这道闸当前形同虚设');

    expectGolden(
      _wireSurfaceGolden,
      <String, Object?>{
        'schemaVersion': PatchbayServiceHost.schemaVersion,
        // 名单里的类型加字段 = 打断已发布的老 CLI；松读面加字段则安全。
        'strictlyDecodedByShippedClients': (decoded.toList()..sort()),
        'types': wireSurface(contract),
      },
      reason:
          'wire 面变了。若变的类型在 strictlyDecodedByShippedClients 名单里，'
          '加字段会让老 CLI 当场 FormatException——先读 docs/design.md「协议演进」一节',
    );
  });

  test('identity 面没有任何客户端在严格解码——加字段才可能是安全的', () {
    final Set<String> decoded = strictlyDecodedTypes(<String>[
      for (final String path in _clientLibPaths) ..._dartSources(path),
    ]);

    expect(decoded, isNotEmpty, reason: '抽取式已失效：一个严格解码调用都没抽到，下面的断言会恒真');
    expect(
      decoded,
      isNot(contains('PatchbayIdentityWire')),
      reason:
          'identity 是本协议的加字段演进面：serverVersion / features 就落在这里。'
          '一旦有客户端改用生成的严格解码器读它，新 host 对老 CLI 就会从「多几个字段」'
          '变成「握手直接失败」',
    );
  });

  test('host 实际吐出的 identity / catalog 未被无声改动', () async {
    final PatchbayServiceHost host = PatchbayServiceHost(
      applicationId: 'dev.patchbay.golden',
      appInstanceId: 'golden-instance',
      registrar: (_, _) {},
      catalog: () async => <String, Object?>{
        'commands': <Object?>[
          <String, Object?>{'name': 'domain.ping', 'summary': 'ping'},
        ],
        'uiTargets': const <Object?>[],
      },
      snapshot: () async => const <String, Object?>{},
      invoke: (_, _, requestId) async => PatchbayInvocation.rejected(
        requestId: requestId,
        rejection: const PatchbayRejection(code: 'notRegistered'),
      ).toJson(),
      features: const <PatchbayFeature>{PatchbayFeature.lifecycleState},
    );

    final Map<String, Object?> identity = host.identityResponse();
    // 两个值每次运行都不同（版本随发版走、isolateId 由 VM 现给），钉死只会让
    // golden 假红。这里改钉「字段还在、且来源没换」：值本身另有断言看着。
    expect(identity['serverVersion'], patchbayPackageVersion);
    expect(identity['isolateId'], anyOf(isNull, isA<String>()));

    expectGolden(
      _hostSurfaceGolden,
      <String, Object?>{
        'identity': <String, Object?>{
          ...identity,
          'serverVersion': '<patchbayPackageVersion>',
          'isolateId': '<runtime>',
        },
        'catalog': await host.dispatchCatalog(),
      },
      reason:
          'host 服务出去的 identity / catalog 形状变了。两个 consumer 不同步升级，'
          '这里每加一个键都要先确认老客户端是逐键读、会忽略它',
    );
  });
}
