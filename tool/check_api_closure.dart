// 公共入口「自足」门禁（PB-060-02 / DG-060-02 裁决修订②）。
//
// `check_api_surface.dart` 回答「这个入口导出了哪些名字」，靠正则展开 export/show。
// 它答不了另一个问题：**只 import 这一个入口，导出的东西真的能用吗？** 一个类被导出、
// 它构造函数的参数类型却没被导出，使用者就会拿到 `undefined_class` —— 入口看起来完整、
// 实际不自足。0.6.0 分层的第一版正是这样：`PatchbayLogSource` 在默认面，它的
// `PatchbayCancellationSignal`、`PatchbayLogLevelWire` 不在。
//
// 因此本工具用 analyzer 的 element model（编译器口径，不是正则口径）算「公共签名闭包」：
//
//   一个公共 library 导出的每个符号，其**公共签名**里出现的 Patchbay 类型必须由**同一个**
//   library 导出。
//
// 公共签名 = 超类 / 接口 / mixin / on 子句、公共构造函数的形参、公共字段与 getter 的类型、
// 公共 setter 与方法的形参和返回类型、类型参数上界、typedef 的 aliased type、extension 的
// extendedType，以及上述类型的全部类型实参。`dart:` 与 `package:flutter` 的类型不计。
//
//   dart run tool/check_api_closure.dart            五个公共入口逐个校验，违规即判红
//   dart run tool/check_api_closure.dart --json     打印每个入口的违规与依赖边（重算集合用）
//
// 闭包优先于「`Wire` 后缀归 protocol」这类命名规则：命名规则只是初始分组，自足是硬约束。
import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';

/// 需要自足的五个公共入口，按包相对路径。
const Map<String, List<String>> publicEntries = <String, List<String>>{
  'patchbay': <String>[
    'lib/patchbay.dart',
    'lib/patchbay_host.dart',
    'lib/patchbay_protocol.dart',
  ],
  'patchbay_flutter': <String>[
    'lib/patchbay_flutter.dart',
    'lib/patchbay_flutter_host.dart',
  ],
};

/// 参与闭包计算的 package 前缀；其余（`dart:`、`package:flutter`…）不计。
bool _isPatchbayLibrary(LibraryElement? library) {
  if (library == null) return false;
  final String uri = library.uri.toString();
  return uri.startsWith('package:patchbay/') ||
      uri.startsWith('package:patchbay_flutter/') ||
      uri.startsWith('package:patchbay_transport/') ||
      uri.startsWith('package:patchbay_cli/');
}

bool _isPublicName(String? name) => name != null && !name.startsWith('_');

/// 一个符号的公共签名里引用到的 Patchbay 元素。
final class SignatureScan {
  SignatureScan(this.owner);

  final String owner;
  final Map<String, String> referenced = <String, String>{};

  void addType(DartType? type, String where, {Set<DartType>? seen}) {
    if (type == null) return;
    seen ??= <DartType>{};
    if (!seen.add(type)) return;
    switch (type) {
      case InterfaceType():
        final Element element = type.element;
        if (_isPatchbayLibrary(element.library) &&
            _isPublicName(element.name)) {
          referenced.putIfAbsent(element.name!, () => where);
        }
        for (final DartType argument in type.typeArguments) {
          addType(argument, where, seen: seen);
        }
      case FunctionType():
        addType(type.returnType, where, seen: seen);
        for (final FormalParameterElement parameter in type.formalParameters) {
          addType(parameter.type, where, seen: seen);
        }
        for (final TypeParameterElement parameter in type.typeParameters) {
          addType(parameter.bound, where, seen: seen);
        }
      case TypeParameterType():
        addType(type.bound, where, seen: seen);
      case RecordType():
        for (final RecordTypePositionalField field in type.positionalFields) {
          addType(field.type, where, seen: seen);
        }
        for (final RecordTypeNamedField field in type.namedFields) {
          addType(field.type, where, seen: seen);
        }
      default:
        // dynamic / void / Never / invalid：没有可追的元素。
        break;
    }
    // typedef 别名：`PatchbayFoo = void Function(...)` 这类引用也算数。
    final Element? alias = type.alias?.element;
    if (alias != null &&
        _isPatchbayLibrary(alias.library) &&
        _isPublicName(alias.name)) {
      referenced.putIfAbsent(alias.name!, () => where);
    }
  }

  void addExecutable(ExecutableElement element, String where) {
    addType(element.returnType, where);
    for (final FormalParameterElement parameter in element.formalParameters) {
      addType(parameter.type, where);
    }
    for (final TypeParameterElement parameter in element.typeParameters) {
      addType(parameter.bound, where);
    }
  }

  void addInstanceMembers(InstanceElement element, String prefix) {
    for (final TypeParameterElement parameter in element.typeParameters) {
      addType(parameter.bound, '$prefix 的类型参数上界');
    }
    for (final FieldElement field in element.fields) {
      if (!_isPublicName(field.name)) continue;
      addType(field.type, '$prefix.${field.name} 字段类型');
    }
    for (final GetterElement getter in element.getters) {
      if (!_isPublicName(getter.name)) continue;
      addType(getter.returnType, '$prefix.${getter.name} getter 返回类型');
    }
    for (final SetterElement setter in element.setters) {
      if (!_isPublicName(setter.name)) continue;
      addExecutable(setter, '$prefix.${setter.name} setter 形参');
    }
    for (final MethodElement method in element.methods) {
      if (!_isPublicName(method.name)) continue;
      addExecutable(method, '$prefix.${method.name} 方法签名');
    }
  }
}

/// 计算 [element] 的公共签名引用集合：名字 -> 第一次出现的位置说明。
Map<String, String> publicSignatureOf(Element element) {
  final String owner = element.name ?? '<unnamed>';
  final SignatureScan scan = SignatureScan(owner);
  switch (element) {
    case InterfaceElement():
      scan.addType(element.supertype, '$owner 的超类');
      for (final InterfaceType type in element.interfaces) {
        scan.addType(type, '$owner 的 implements 子句');
      }
      for (final InterfaceType type in element.mixins) {
        scan.addType(type, '$owner 的 with 子句');
      }
      if (element is MixinElement) {
        for (final InterfaceType type in element.superclassConstraints) {
          scan.addType(type, '$owner 的 on 子句');
        }
      }
      for (final ConstructorElement constructor in element.constructors) {
        if (!_isPublicName(constructor.name)) continue;
        final String label = constructor.name == 'new'
            ? '$owner 的构造函数形参'
            : '$owner.${constructor.name} 构造函数形参';
        for (final FormalParameterElement parameter
            in constructor.formalParameters) {
          scan.addType(parameter.type, label);
        }
      }
      scan.addInstanceMembers(element, owner);
    case ExtensionElement():
      scan.addType(element.extendedType, '$owner 的 extended type');
      scan.addInstanceMembers(element, owner);
    case TypeAliasElement():
      scan.addType(element.aliasedType, '$owner 的 aliased type');
      for (final TypeParameterElement parameter in element.typeParameters) {
        scan.addType(parameter.bound, '$owner 的类型参数上界');
      }
    case TopLevelFunctionElement():
      scan.addExecutable(element, '$owner 的函数签名');
    case GetterElement():
      scan.addType(element.returnType, '$owner 的类型');
    case SetterElement():
      scan.addExecutable(element, '$owner 的类型');
    case TopLevelVariableElement():
      scan.addType(element.type, '$owner 的类型');
    default:
      break;
  }
  return scan.referenced;
}

final class EntryClosure {
  const EntryClosure({
    required this.package,
    required this.library,
    required this.exported,
    required this.edges,
    required this.violations,
  });

  final String package;
  final String library;
  final Set<String> exported;

  /// 导出符号 -> （被引用符号 -> 位置说明）。
  final Map<String, Map<String, String>> edges;

  /// 导出符号 -> （缺失符号 -> 位置说明）。
  final Map<String, Map<String, String>> violations;
}

Future<List<EntryClosure>> analyzeEntries(
  String repoRoot, {
  String? sdkPath,
}) async {
  final List<String> paths = <String>[
    for (final MapEntry<String, List<String>> entry in publicEntries.entries)
      for (final String library in entry.value)
        '$repoRoot/packages/${entry.key}/$library',
  ];
  final AnalysisContextCollection collection = AnalysisContextCollection(
    includedPaths: paths,
    sdkPath: sdkPath,
  );

  final List<EntryClosure> result = <EntryClosure>[];
  for (final MapEntry<String, List<String>> entry in publicEntries.entries) {
    for (final String library in entry.value) {
      final String path = '$repoRoot/packages/${entry.key}/$library';
      final SomeResolvedLibraryResult resolved = await collection
          .contextFor(path)
          .currentSession
          .getResolvedLibrary(path);
      if (resolved is! ResolvedLibraryResult) {
        throw StateError('无法解析 $library：$resolved');
      }
      final Map<String, Element> exportedNames =
          resolved.element.exportNamespace.definedNames2;
      final Set<String> exported = exportedNames.keys.toSet();
      final edges = <String, Map<String, String>>{};
      final violations = <String, Map<String, String>>{};
      for (final MapEntry<String, Element> named in exportedNames.entries) {
        final Map<String, String> referenced = publicSignatureOf(named.value);
        referenced.remove(named.key);
        if (referenced.isEmpty) continue;
        edges[named.key] = referenced;
        final missing = <String, String>{
          for (final MapEntry<String, String> reference in referenced.entries)
            if (!exported.contains(reference.key))
              reference.key: reference.value,
        };
        if (missing.isNotEmpty) violations[named.key] = missing;
      }
      result.add(
        EntryClosure(
          package: entry.key,
          library: library,
          exported: exported,
          edges: edges,
          violations: violations,
        ),
      );
    }
  }
  return result;
}

Future<void> main(List<String> args) async {
  final String repoRoot = Directory.current.path;
  final bool asJson = args.contains('--json');

  // 不指定 sdkPath：用当前 Dart SDK 即可。Flutter 的 `dart:ui` 由 package_config 里的
  // `sky_engine` 通过 `_embedder.yaml` 提供，analyzer 会自己接上。
  final List<EntryClosure> closures = await analyzeEntries(repoRoot);

  if (asJson) {
    stdout.writeln(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        for (final EntryClosure closure in closures)
          '${closure.package}/${closure.library}': <String, Object?>{
            'exported': (closure.exported.toList()..sort()),
            'edges': <String, Object?>{
              for (final String key in closure.edges.keys.toList()..sort())
                key: closure.edges[key],
            },
            'violations': <String, Object?>{
              for (final String key in closure.violations.keys.toList()..sort())
                key: closure.violations[key],
            },
          },
      }),
    );
    return;
  }

  final List<String> failures = <String>[];
  for (final EntryClosure closure in closures) {
    if (closure.violations.isEmpty) continue;
    final Set<String> missing = <String>{
      for (final Map<String, String> entry in closure.violations.values)
        ...entry.keys,
    };
    final StringBuffer buffer = StringBuffer()
      ..writeln(
        '${closure.package} ${closure.library}：'
        '${closure.violations.length} 个导出符号的公共签名引用了本入口没有导出的类型'
        '（共 ${missing.length} 个）',
      );
    for (final String owner in closure.violations.keys.toList()..sort()) {
      final Map<String, String> entry = closure.violations[owner]!;
      for (final String name in entry.keys.toList()..sort()) {
        buffer.writeln('      $name ← ${entry[name]}');
      }
    }
    failures.add(buffer.toString().trimRight());
  }

  if (failures.isNotEmpty) {
    stderr.writeln('公共入口不自足（只 import 该入口会拿到 undefined_class）：');
    for (final String failure in failures) {
      stderr.writeln('  - $failure');
    }
    stderr.writeln(
      '\n把缺失的符号加进该入口的 `show` 清单（闭包优先于命名分组），并同步 '
      'tool/api_surface.json；\n'
      '如果认为某个类型不该出现在公共签名里，那要改的是签名本身，不是这份清单。',
    );
    exitCode = 1;
    return;
  }

  stdout.writeln(
    '公共入口自足（${closures.map((c) => '${c.library.substring(4)} '
        '${c.exported.length}').join(' / ')}）',
  );
}
