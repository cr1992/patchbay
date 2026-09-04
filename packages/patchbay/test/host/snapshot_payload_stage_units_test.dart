// PB-050-38：snapshot payload 五个阶段各自的失败注入。
//
// 表征测试证明的是「整条冻结管线对外没变」；这份测试证明拆分真的拆开了——限额模型、
// 路径与出现次数记账、有界字节 sink、冻结遍历、canonical 序列化五段逐个脱离
// `PatchbaySnapshotPayloadFreezer` 单独构造、单独注入失败、给出类型化结论。
//
// 拆分前这些断言大多写不出来：判定「字节越界该报契约失败还是资源拒绝」只能造一份真的
// 超预算 payload 从 `freeze` 整条打进去；判定「计数器越界之后计数不推进」根本没有观察
// 点；而「遍历用的是注入进去的那个 sink」这种接缝断言，在单文件里连表述都无从表述。
// 限额模型与 `PatchbaySnapshotPayloadFault` 经门面的 re-export 到达，和 host 侧其他
// 调用者走同一条路径，因此这里不额外 import `snapshot_payload_limits.dart`。
import 'dart:convert';
import 'dart:typed_data';

import 'package:patchbay/src/host/snapshot_payload.dart';
import 'package:patchbay/src/host/snapshot_payload_bytes.dart';
import 'package:patchbay/src/host/snapshot_payload_canonical.dart';
import 'package:patchbay/src/host/snapshot_payload_freeze.dart';
import 'package:patchbay/src/host/snapshot_payload_path.dart';
import 'package:test/test.dart';

PatchbaySnapshotPayloadLimits _limits({
  int depth = patchbaySnapshotMaxContainerDepth,
  int occurrences = patchbaySnapshotMaxExpandedOccurrences,
  int bytes = patchbaySnapshotMaxCanonicalBytes,
  int? runBytes,
}) => PatchbaySnapshotPayloadLimits(
  maxContainerDepth: depth,
  maxExpandedOccurrences: occurrences,
  maxCanonicalBytes: bytes,
  maxRunCanonicalBytes: runBytes,
);

PatchbaySnapshotPayloadFault _faultOf(void Function() body) {
  try {
    body();
  } on PatchbaySnapshotPayloadFault catch (error) {
    return error;
  }
  fail('expected a snapshot payload fault');
}

String _utf8(Uint8List bytes) => utf8.decode(bytes);

final class _Opaque {
  const _Opaque();
}

void main() {
  group('阶段一：限额模型与拒绝成型', () {
    test('非法限额在构造时就判红，不等到遍历', () {
      expect(() => _limits(depth: -1), throwsA(isA<AssertionError>()));
      expect(() => _limits(occurrences: 0), throwsA(isA<AssertionError>()));
      expect(() => _limits(bytes: 0), throwsA(isA<AssertionError>()));
      expect(
        () => _limits(bytes: 64, runBytes: 0),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => _limits(bytes: 64, runBytes: 65),
        throwsA(isA<AssertionError>()),
      );
    });

    test('深度 0 合法：根容器本身不算一层嵌套', () {
      expect(_limits(depth: 0).maxContainerDepth, 0);
    });

    test('三个工厂各自的 details 与 kind', () {
      final PatchbaySnapshotPayloadFault invalid =
          PatchbaySnapshotPayloadFault.invalid(
            failure: 'cycleDetected',
            path: r'$.a',
          );
      expect(invalid.kind, PatchbaySnapshotPayloadViolationKind.contract);
      expect(invalid.details.keys, <String>['reason', 'failure', 'path']);

      final PatchbaySnapshotPayloadFault typed =
          PatchbaySnapshotPayloadFault.invalid(
            failure: 'unsupportedType',
            path: r'$',
            type: 'DateTime',
          );
      expect(typed.details['type'], 'DateTime');

      final PatchbaySnapshotPayloadFault tooLarge =
          PatchbaySnapshotPayloadFault.tooLarge(
            path: r'$.a',
            limitKind: 'expandedNodes',
            limit: 4,
            observed: 5,
          );
      expect(tooLarge.kind, PatchbaySnapshotPayloadViolationKind.contract);
      expect(tooLarge.details.keys, <String>[
        'reason',
        'failure',
        'path',
        'limitKind',
        'limit',
        'observed',
      ]);

      final PatchbaySnapshotPayloadFault runBudget =
          PatchbaySnapshotPayloadFault.runBudget(limit: 8, observed: 9);
      expect(runBudget.kind, PatchbaySnapshotPayloadViolationKind.runBudget);
      expect(runBudget.details, <String, Object?>{
        'encodedBytesAtLeast': 9,
        'maxSnapshotBytes': 8,
      });
      expect(runBudget.details.containsKey('path'), isFalse);
    });
  });

  group('阶段二：路径与出现次数记账', () {
    test('路径只承载 key 与下标', () {
      const PatchbaySnapshotPath root = PatchbaySnapshotPath.root;
      expect(root.value, r'$');
      expect(
        root.objectKey('a').listIndex(2).objectKey('b').value,
        r'$.a[2].b',
      );
      expect(root.objectKey('_x9').value, r'$._x9');
    });

    test('不安全的 key 让路径就地封口，后代不再追加', () {
      const PatchbaySnapshotPath root = PatchbaySnapshotPath.root;
      for (final String unsafe in <String>[
        '',
        '0lead',
        'has space',
        'dot.ted',
        'k' * 129,
      ]) {
        final PatchbaySnapshotPath sealed = root.objectKey(unsafe);
        expect(sealed.value, r'$', reason: unsafe);
        expect(sealed.objectKey('safe').value, r'$');
        expect(sealed.listIndex(0).value, r'$');
      }
      expect(root.objectKey('k' * 128).value, '\$.${'k' * 128}');
    });

    test('计数器越界时抛出且计数不推进', () {
      final PatchbaySnapshotOccurrenceCounter counter =
          PatchbaySnapshotOccurrenceCounter(_limits(occurrences: 2));

      counter.count(PatchbaySnapshotPath.root);
      counter.count(PatchbaySnapshotPath.root.objectKey('a'));
      expect(counter.observed, 2);

      final PatchbaySnapshotPayloadFault fault = _faultOf(
        () => counter.count(PatchbaySnapshotPath.root.objectKey('b')),
      );
      expect(fault.details, <String, Object?>{
        'reason': 'snapshotPayloadInvalid',
        'failure': 'payloadTooLarge',
        'path': r'$.b',
        'limitKind': 'expandedNodes',
        'limit': 2,
        'observed': 3,
      });
      expect(counter.observed, 2);
    });

    test('同一条路径重复出现照样各计一次', () {
      final PatchbaySnapshotOccurrenceCounter counter =
          PatchbaySnapshotOccurrenceCounter(_limits());
      final PatchbaySnapshotPath path = PatchbaySnapshotPath.root.objectKey(
        'shared',
      );

      counter.count(path);
      counter.count(path);

      expect(counter.observed, 2);
    });
  });

  group('阶段三：有界字节 sink', () {
    test('预算之内照写，越界当场中止', () {
      final PatchbaySnapshotBoundedByteSink sink =
          PatchbaySnapshotBoundedByteSink(_limits(bytes: 4));

      sink.add(const <int>[1, 2, 3, 4]);
      expect(sink.length, 4);
      expect(() => sink.add(const <int>[5]), throwsA(isA<Exception>()));
      expect(sink.length, 4);
    });

    test('拒绝里的 path 就是调用方最后写下的 currentPath', () {
      final PatchbaySnapshotBoundedByteSink sink =
          PatchbaySnapshotBoundedByteSink(_limits(bytes: 1));
      sink.currentPath = r'$.deep[3].leaf';

      final PatchbaySnapshotPayloadFault fault = _faultOf(
        () => sink.add(const <int>[1, 2]),
      );

      expect(fault.details['path'], r'$.deep[3].leaf');
    });

    test('运行预算就是天花板时说话的是契约失败', () {
      final PatchbaySnapshotPayloadFault fault = _faultOf(
        () => PatchbaySnapshotBoundedByteSink(
          _limits(bytes: 4, runBytes: 4),
        ).add(const <int>[1, 2, 3, 4, 5, 6, 7, 8]),
      );

      expect(fault.kind, PatchbaySnapshotPayloadViolationKind.contract);
      expect(fault.details['limitKind'], 'canonicalBytes');
      expect(fault.details['limit'], 4);
      // 报的是天花板 +1，而不是这一次实际写了多少——契约失败不回显 payload 规模。
      expect(fault.details['observed'], 5);
    });

    test('运行预算更小时说话的是资源拒绝，并报实际 projected', () {
      final PatchbaySnapshotPayloadFault fault = _faultOf(
        () => PatchbaySnapshotBoundedByteSink(
          _limits(bytes: 4096, runBytes: 4),
        ).add(const <int>[1, 2, 3, 4, 5, 6, 7, 8]),
      );

      expect(fault.kind, PatchbaySnapshotPayloadViolationKind.runBudget);
      expect(fault.details, <String, Object?>{
        'encodedBytesAtLeast': 8,
        'maxSnapshotBytes': 4,
      });
    });

    test('close 只是零长写入，不会自己越界', () {
      final PatchbaySnapshotBoundedByteSink sink =
          PatchbaySnapshotBoundedByteSink(_limits(bytes: 1));
      sink.add(const <int>[1]);
      expect(sink.close, returnsNormally);
      expect(sink.length, 1);
    });

    test('不保留字节的 sink 只计费，takeBytes 为空', () {
      final PatchbaySnapshotBoundedByteSink sink =
          PatchbaySnapshotBoundedByteSink(_limits());
      sink.writeJsonScalar('abc');

      expect(sink.length, 5);
      expect(sink.takeBytes(), isEmpty);
    });

    test('标量编码可以连写多次——close 被吞掉', () {
      final PatchbaySnapshotBoundedByteSink sink =
          PatchbaySnapshotBoundedByteSink(_limits(), retainBytes: true);

      sink.writeContainerOpen(isMap: true);
      sink.writeJsonScalar('k');
      sink.writeColon();
      sink.writeJsonScalar(1);
      sink.writeComma();
      sink.writeJsonScalar('k2');
      sink.writeColon();
      sink.writeJsonScalar(<Object?>[]);
      sink.writeContainerClose(isMap: true);

      expect(_utf8(sink.takeBytes()), '{"k":1,"k2":[]}');
    });

    test('超长字符串在写到一半时就撞上预算', () {
      final PatchbaySnapshotBoundedByteSink sink =
          PatchbaySnapshotBoundedByteSink(_limits(bytes: 16));

      expect(
        () => sink.writeJsonScalar('x' * 4096),
        throwsA(isA<PatchbaySnapshotPayloadFault>()),
      );
      expect(sink.length, lessThanOrEqualTo(16));
    });
  });

  group('阶段四：冻结遍历', () {
    test('用的是注入进来的 sink，而不是自己按 limits 造的那个', () {
      final PatchbaySnapshotFreezingTraversal traversal =
          PatchbaySnapshotFreezingTraversal(
            _limits(),
            sink: PatchbaySnapshotBoundedByteSink(_limits(bytes: 7)),
          );

      final PatchbaySnapshotPayloadFault fault = _faultOf(
        () => traversal.freeze(<String, Object?>{'zzz': 1, 'aaa': 2}),
      );

      expect(fault.details['limitKind'], 'canonicalBytes');
      expect(fault.details['limit'], 7);
      // 插入顺序，不是 canonical 顺序——这一趟走的是 consumer 给的顺序。
      expect(fault.details['path'], r'$.zzz');
    });

    test('用的是注入进来的计数器，而不是自己按 limits 造的那个', () {
      final PatchbaySnapshotFreezingTraversal traversal =
          PatchbaySnapshotFreezingTraversal(
            _limits(),
            occurrences: PatchbaySnapshotOccurrenceCounter(
              _limits(occurrences: 2),
            ),
          );

      final PatchbaySnapshotPayloadFault fault = _faultOf(
        () => traversal.freeze(<String, Object?>{'a': 1}),
      );

      expect(fault.details['limitKind'], 'expandedNodes');
      expect(fault.details['limit'], 2);
      expect(fault.details['path'], r'$.a');
    });

    test('计费顺序是容器 → key → 值', () {
      final PatchbaySnapshotOccurrenceCounter counter =
          PatchbaySnapshotOccurrenceCounter(_limits());

      PatchbaySnapshotFreezingTraversal(_limits(), occurrences: counter).freeze(
        <String, Object?>{
          'a': <Object?>[1, 2],
        },
      );

      // 根 map、key 'a'、list、两个标量。
      expect(counter.observed, 5);
    });

    test('共享无环子树重新展开、重新计费', () {
      final Map<String, Object?> shared = <String, Object?>{'v': 1};
      final PatchbaySnapshotOccurrenceCounter counter =
          PatchbaySnapshotOccurrenceCounter(_limits());

      PatchbaySnapshotFreezingTraversal(
        _limits(),
        occurrences: counter,
      ).freeze(<String, Object?>{'a': shared, 'b': shared});

      // 根、a、{v:1}、v、1，再一遍 b、{v:1}、v、1。
      expect(counter.observed, 9);
    });

    test('环在进入点被拒，而不是被当成共享子树', () {
      final List<Object?> loop = <Object?>[];
      loop.add(loop);

      final PatchbaySnapshotPayloadFault fault = _faultOf(
        () => PatchbaySnapshotFreezingTraversal(
          _limits(),
        ).freeze(<String, Object?>{'l': loop}),
      );

      expect(fault.details['failure'], 'cycleDetected');
      expect(fault.details['path'], r'$.l[0]');
    });

    test('深度闸只数嵌套层数，根容器是第 0 层', () {
      expect(
        PatchbaySnapshotFreezingTraversal(
          _limits(depth: 0),
        ).freeze(<String, Object?>{'a': 1}),
        <String, Object?>{'a': 1},
      );

      final PatchbaySnapshotPayloadFault fault = _faultOf(
        () => PatchbaySnapshotFreezingTraversal(_limits(depth: 0)).freeze(
          <String, Object?>{
            'a': <String, Object?>{'b': 1},
          },
        ),
      );
      expect(fault.details['failure'], 'nestingTooDeep');
      expect(fault.details['path'], r'$.a');
    });

    test('显式栈：五千层嵌套不吃 Dart 调用栈', () {
      Object? node = 1;
      for (var i = 0; i < 5000; i++) {
        node = <String, Object?>{'k': node};
      }

      final Object? frozen = PatchbaySnapshotFreezingTraversal(
        _limits(depth: 10000),
      ).freeze(node);

      expect(frozen, isA<Map<String, Object?>>());
    });

    test('本阶段不判断根是不是 map——那是门面的事', () {
      final PatchbaySnapshotFreezingTraversal scalarRoot =
          PatchbaySnapshotFreezingTraversal(_limits());
      expect(scalarRoot.freeze(42), 42);

      final Object? listRoot = PatchbaySnapshotFreezingTraversal(
        _limits(),
      ).freeze(<Object?>[1]);
      expect(listRoot, <Object?>[1]);
      expect(
        () => (listRoot! as List<Object?>).add(2),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('nonStringKey 是本阶段的 Never，停在父路径', () {
      final PatchbaySnapshotPayloadFault fault = _faultOf(
        () => PatchbaySnapshotFreezingTraversal(
          _limits(),
        ).nonStringKey(PatchbaySnapshotPath.root.objectKey('m'), 3.5),
      );

      expect(fault.details, <String, Object?>{
        'reason': 'snapshotPayloadInvalid',
        'failure': 'nonStringKey',
        'path': r'$.m',
        'type': 'double',
      });
    });

    test('不支持的值类型在自己的路径上判红', () {
      final PatchbaySnapshotPayloadFault fault = _faultOf(
        () => PatchbaySnapshotFreezingTraversal(_limits()).freeze(
          <String, Object?>{
            'a': <Object?>[const _Opaque()],
          },
        ),
      );

      expect(fault.details['failure'], 'unsupportedType');
      expect(fault.details['path'], r'$.a[0]');
      expect(fault.details['type'], '_Opaque');
    });
  });

  group('阶段五：canonical 序列化', () {
    test('按 key 排序，不保留插入顺序', () {
      final Uint8List bytes = PatchbaySnapshotCanonicalJsonWriter(_limits())
          .encode(<String, Object?>{
            'b': 1,
            'a': <Object?>[
              2,
              <String, Object?>{'d': 3, 'c': 4},
            ],
          });

      expect(_utf8(bytes), '{"a":[2,{"c":4,"d":3}],"b":1}');
    });

    test('标量根与空容器都能独立编码', () {
      final PatchbaySnapshotPayloadLimits limits = _limits();
      expect(
        _utf8(PatchbaySnapshotCanonicalJsonWriter(limits).encode(42)),
        '42',
      );
      expect(
        _utf8(
          PatchbaySnapshotCanonicalJsonWriter(
            limits,
          ).encode(<String, Object?>{}),
        ),
        '{}',
      );
      expect(
        _utf8(PatchbaySnapshotCanonicalJsonWriter(limits).encode(<Object?>[])),
        '[]',
      );
    });

    test('用的是注入进来的 sink', () {
      final PatchbaySnapshotPayloadFault fault = _faultOf(
        () => PatchbaySnapshotCanonicalJsonWriter(
          _limits(),
          sink: PatchbaySnapshotBoundedByteSink(
            _limits(bytes: 4096, runBytes: 3),
            retainBytes: true,
          ),
        ).encode(<String, Object?>{'a': 1}),
      );

      expect(fault.kind, PatchbaySnapshotPayloadViolationKind.runBudget);
      expect(fault.details['maxSnapshotBytes'], 3);
    });

    test('越界路径按 canonical 顺序，而不是插入顺序', () {
      final PatchbaySnapshotPayloadFault fault = _faultOf(
        () => PatchbaySnapshotCanonicalJsonWriter(
          _limits(bytes: 7),
        ).encode(<String, Object?>{'zzz': 1, 'aaa': 2}),
      );

      expect(fault.details['path'], r'$.aaa');
    });

    test('本阶段不做合法性判断——非法标量以编码器异常逃逸', () {
      expect(
        () => PatchbaySnapshotCanonicalJsonWriter(
          _limits(),
        ).encode(<String, Object?>{'t': DateTime(2026)}),
        throwsA(isA<JsonUnsupportedObjectError>()),
      );
    });
  });

  group('门面：唯一的边界翻译点', () {
    test('阶段故障原样成为对外违规的 details 与 kind', () {
      final PatchbaySnapshotPayloadViolation violation;
      try {
        PatchbaySnapshotPayloadFreezer(
          limits: _limits(bytes: 4096, runBytes: 4),
        ).freeze(<String, Object?>{'a': 1});
        fail('expected a violation');
      } on PatchbaySnapshotPayloadViolation catch (error) {
        violation = error;
      }

      expect(violation.kind, PatchbaySnapshotPayloadViolationKind.runBudget);
      expect(violation.details, <String, Object?>{
        'encodedBytesAtLeast': 5,
        'maxSnapshotBytes': 4,
      });
      expect(
        () => violation.details['x'] = 1,
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('非 JSON 标量由冻结阶段拦下，canonical 阶段够不着', () {
      // 与上一组最后一条配对：单看 canonical 阶段，DateTime 会以原始
      // `JsonUnsupportedObjectError` 逃逸；整条管线之所以永远不会出现那种异常，
      // 靠的正是冻结阶段先在 `$.t` 上判红。阶段顺序本身就是一条安全不变量。
      final PatchbaySnapshotPayloadViolation violation;
      try {
        const PatchbaySnapshotPayloadFreezer().freeze(<String, Object?>{
          't': DateTime(2026),
        });
        fail('expected a violation');
      } on PatchbaySnapshotPayloadViolation catch (error) {
        violation = error;
      }

      expect(violation.details, <String, Object?>{
        'reason': 'snapshotPayloadInvalid',
        'failure': 'unsupportedType',
        'path': r'$.t',
        'type': 'DateTime',
      });
    });
  });
}
