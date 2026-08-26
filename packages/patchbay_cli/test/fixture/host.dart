import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:patchbay/patchbay.dart';

void main() {
  final PatchbayMemoryBlobStore blobs = PatchbayMemoryBlobStore(
    idFactory: () => 'fixture-blob',
  );
  PatchbayBlobMetadataWire artifact() {
    try {
      return blobs.metadata('fixture-blob');
    } on PatchbayBlobFailure {
      return blobs.put(
        Uint8List.fromList(utf8.encode('fixture artifact\n')),
        kind: PatchbayBlobSourceWire.logExport,
        source: PatchbayFactSourceWire.appRecorded,
        contentType: 'application/x-ndjson',
        filename: 'fixture.ndjson',
      );
    }
  }

  // Just enough keep-awake state for the cross-process test to prove the CLI
  // carries `enabled` and `leaseMs` through and reads the answer back. The
  // lease itself is the App's business and is not simulated here.
  var keepAwakeEnabled = false;
  int? keepAwakeLeaseMs;
  String? keepAwakeLastRelease;
  Map<String, Object?> keepAwakeState(String outcome) => <String, Object?>{
    'outcome': outcome,
    'source': 'appRecorded',
    'wired': true,
    'enabled': keepAwakeEnabled,
    'leaseMs': keepAwakeLeaseMs,
    'leaseRemainingMs': keepAwakeLeaseMs,
    if (keepAwakeLastRelease != null) 'lastRelease': keepAwakeLastRelease,
  };

  const List<String> commandNames = <String>[
    'fixture.typedFailure',
    'fixture.failedJob',
    'patchbay.job.get',
    'patchbay.job.wait',
    'ui.semantics.tree',
    'ui.semantics.action',
    'ui.semantics.tap',
    'ui.gesture.pressHold',
    'ui.gesture.drag',
    'ui.gesture.fling',
    'ui.reveal',
    'ui.text.set',
    'ui.text.enter',
    'navigation.catalog',
    'navigation.current',
    'navigation.go',
    'navigation.push',
    'navigation.back',
    'ui.wait',
    'logs.query',
    'logs.tail',
    'logs.export',
    'ui.capture',
    'ui.capture.diff',
    'ui.keepAwake.set',
    'ui.keepAwake.status',
    'ui.inspect.status',
    'ui.inspect.select',
    'blob.metadata',
    'blob.read',
  ];
  final PatchbayServiceHost host = PatchbayServiceHost(
    applicationId: 'dev.patchbay.fixture',
    appInstanceId: 'fixture-instance',
    catalog: () async => <String, Object?>{
      'commands': <Object?>[
        for (final String name in commandNames)
          <String, Object?>{
            'name': name,
            if (name == 'fixture.failedJob') 'suggestedWaitTimeoutMs': 5000,
          },
      ],
      'uiTargets': const <Object?>[],
    },
    snapshot: () async => <String, Object?>{
      'source': PatchbayFactSource.appRecorded.name,
    },
    invoke:
        (String command, Map<String, Object?> args, String requestId) async =>
            switch (command) {
              'fixture.typedFailure' => PatchbayInvocation.accepted(
                requestId: requestId,
                payload: const <String, Object?>{'outcome': 'failed'},
              ).toJson(),
              'fixture.failedJob' => PatchbayInvocation.accepted(
                requestId: requestId,
                jobId: 'fixture-job',
              ).toJson(),
              'navigation.catalog' => PatchbayInvocation.accepted(
                requestId: requestId,
                payload: const <String, Object?>{
                  'outcome': 'observed',
                  'source': 'appRecorded',
                  'navigationRevision': 7,
                  'destinations': <Object?>[
                    <String, Object?>{
                      'id': 'settings',
                      'operations': <String>['go'],
                      'gates': <String>[],
                      'ambiguous': false,
                    },
                  ],
                },
              ).toJson(),
              'navigation.current' => PatchbayInvocation.accepted(
                requestId: requestId,
                payload: const <String, Object?>{
                  'outcome': 'observed',
                  'source': 'appRecorded',
                  'navigationRevision': 7,
                  'destinationId': 'home',
                },
              ).toJson(),
              'navigation.go' ||
              'navigation.push' ||
              'navigation.back' => PatchbayInvocation.accepted(
                requestId: requestId,
                payload: <String, Object?>{
                  'outcome': 'completed',
                  'source': 'uiObserved',
                  'arguments': args,
                },
              ).toJson(),
              'ui.wait' => PatchbayInvocation.accepted(
                requestId: requestId,
                payload: <String, Object?>{
                  'outcome': 'observed',
                  'source': 'uiObserved',
                  ...args,
                  'frameRevision': 9,
                },
              ).toJson(),
              'logs.query' => PatchbayInvocation.accepted(
                requestId: requestId,
                payload: const <String, Object?>{
                  'outcome': 'records',
                  'source': 'appRecorded',
                  'records': <Object?>[
                    <String, Object?>{
                      'cursor': 'cursor-1',
                      'message': 'fixture log',
                    },
                  ],
                  'nextCursor': 'cursor-1',
                  'currentCursor': 'cursor-1',
                  'truncated': false,
                  'elapsedMs': 1,
                },
              ).toJson(),
              'logs.tail' => PatchbayInvocation.accepted(
                requestId: requestId,
                payload: const <String, Object?>{
                  'outcome': 'timedOut',
                  'source': 'appRecorded',
                  'records': <Object?>[],
                  'truncated': false,
                  'elapsedMs': 5,
                },
              ).toJson(),
              'logs.export' => PatchbayInvocation.accepted(
                requestId: requestId,
                payload: <String, Object?>{
                  'source': 'appRecorded',
                  'blob': artifact().toJson(),
                  'recordCount': 1,
                  'truncated': false,
                },
              ).toJson(),
              'ui.capture' => PatchbayInvocation.accepted(
                requestId: requestId,
                payload: <String, Object?>{
                  'outcome': 'captured',
                  'source': 'uiObserved',
                  'target': 'root',
                  'width': 1,
                  'height': 1,
                  'pixelRatio': 1,
                  'warnings': <String>['flutterSubtreeOnly'],
                  'blob': <String, Object?>{
                    ...artifact().toJson(),
                    if (args['pixelRatio'] == 3)
                      'sha256': List<String>.filled(64, '0').join(),
                  },
                },
              ).toJson(),
              'ui.capture.diff' => PatchbayInvocation.accepted(
                requestId: requestId,
                payload: <String, Object?>{
                  'outcome': 'compared',
                  'source': 'uiObserved',
                  'beforeBlobId': args['beforeBlobId'],
                  'afterBlobId': args['afterBlobId'],
                  'width': 1,
                  'height': 1,
                  'pixelFormat': 'rgba8888',
                  'changedPixels': 0,
                  'totalPixels': 1,
                  'differenceRatio': 0,
                  'warnings': const <String>['flutterSubtreeOnly'],
                },
              ).toJson(),
              'ui.keepAwake.set' => () {
                final bool enabled = args['enabled']! as bool;
                if (!enabled) {
                  final bool held = keepAwakeEnabled;
                  keepAwakeEnabled = false;
                  keepAwakeLeaseMs = null;
                  if (held) keepAwakeLastRelease = 'operatorRequest';
                  return PatchbayInvocation.accepted(
                    requestId: requestId,
                    payload: keepAwakeState(held ? 'released' : 'unchanged'),
                  ).toJson();
                }
                final bool renewed = keepAwakeEnabled;
                keepAwakeEnabled = true;
                keepAwakeLeaseMs = args['leaseMs'] as int? ?? 600000;
                return PatchbayInvocation.accepted(
                  requestId: requestId,
                  payload: keepAwakeState(renewed ? 'renewed' : 'engaged'),
                ).toJson();
              }(),
              'ui.keepAwake.status' => PatchbayInvocation.accepted(
                requestId: requestId,
                payload: keepAwakeState('observed'),
              ).toJson(),
              // Both inspect arms answer the shape the Flutter bridge answers,
              // so the cross-process test proves the CLI carries `enabled` and
              // `ttlMs` through and reads back an `appRecorded` state — not a
              // `uiObserved` one, which would claim a rendered overlay.
              'ui.inspect.status' => PatchbayInvocation.accepted(
                requestId: requestId,
                payload: const <String, Object?>{
                  'outcome': 'observed',
                  'source': 'appRecorded',
                  'selectMode': false,
                  'selectionOnTap': true,
                  'managed': false,
                },
              ).toJson(),
              'ui.inspect.select' =>
                args['enabled'] == true
                    ? PatchbayInvocation.accepted(
                        requestId: requestId,
                        payload: <String, Object?>{
                          'outcome': 'applied',
                          'source': 'appRecorded',
                          'selectMode': true,
                          'selectionOnTap': true,
                          'managed': true,
                          'previousSelectMode': false,
                          'restoresTo': false,
                          'leaseMs': args['ttlMs'] ?? 300000,
                        },
                      ).toJson()
                    : PatchbayInvocation.accepted(
                        requestId: requestId,
                        payload: const <String, Object?>{
                          'outcome': 'applied',
                          'source': 'appRecorded',
                          'selectMode': false,
                          'selectionOnTap': true,
                          'managed': false,
                          'previousSelectMode': true,
                          'lastRelease': 'explicitOff',
                        },
                      ).toJson(),
              'blob.metadata' => PatchbayInvocation.accepted(
                requestId: requestId,
                payload: artifact().toJson(),
              ).toJson(),
              'blob.read' => PatchbayInvocation.accepted(
                requestId: requestId,
                payload: blobs
                    .read(
                      blobId: args['blobId']! as String,
                      offset: args['offset']! as int,
                      limit: args['limit']! as int,
                    )
                    .toJson(),
              ).toJson(),
              'ui.semantics.tree' => PatchbayInvocation.accepted(
                requestId: requestId,
                payload: const <String, Object?>{
                  'outcome': 'observed',
                  'source': 'uiObserved',
                  'nodes': <Object?>[],
                },
              ).toJson(),
              'ui.semantics.action' => PatchbayInvocation.accepted(
                requestId: requestId,
                payload: <String, Object?>{
                  'outcome': 'dispatched',
                  'source': 'uiObserved',
                  'arguments': args,
                },
              ).toJson(),
              // Both arms exist so the cross-process test can prove the CLI
              // carries an identifier through and surfaces a rejection's
              // details instead of flattening it to a bare code.
              'ui.semantics.tap' =>
                args['identifier'] == 'fixture.absent'
                    ? PatchbayInvocation.rejected(
                        requestId: requestId,
                        rejection: PatchbayRejection(
                          code: 'uiSemanticsIdentifierNotFound',
                          details: <String, Object?>{
                            'identifier': args['identifier'],
                            'matchCount': 0,
                            'mountedIdentifiers': const <String>['fixture.tap'],
                          },
                        ),
                      ).toJson()
                    : PatchbayInvocation.accepted(
                        requestId: requestId,
                        payload: <String, Object?>{
                          'outcome': 'dispatched',
                          'source': 'uiObserved',
                          'arguments': args,
                        },
                      ).toJson(),
              'ui.text.set' || 'ui.text.enter' => PatchbayInvocation.accepted(
                requestId: requestId,
                payload: <String, Object?>{
                  'outcome': 'dispatched',
                  'source': 'uiObserved',
                  'arguments': args,
                },
              ).toJson(),
              'ui.gesture.pressHold' ||
              'ui.gesture.drag' ||
              'ui.gesture.fling' => PatchbayInvocation.accepted(
                requestId: requestId,
                payload: <String, Object?>{
                  'outcome': 'dispatched',
                  'source': 'uiObserved',
                  'arguments': args,
                },
              ).toJson(),
              // PB-050-17：回一个形状正确的 revealed payload，让跨进程测试能
              // 断言 CLI 把 identifier 与预算参数原样带过去，并把 `containers`
              // 这个复数字段完整透出。
              'ui.reveal' => PatchbayInvocation.accepted(
                requestId: requestId,
                payload: <String, Object?>{
                  'outcome': 'revealed',
                  'source': 'uiObserved',
                  'identifier': args['identifier'],
                  'steps': 1,
                  'elapsedMs': 3,
                  'containers': const <Object?>[
                    <String, Object?>{
                      'nodeId': 7,
                      'generation': 2,
                      'steps': 1,
                      'direction': 'forward',
                      'extentGrowthSteps': 0,
                    },
                  ],
                  'nodeId': 11,
                  'generation': 4,
                  'reachability': 'pointer',
                  'beforeTreeRevision': 1,
                  'afterTreeRevision': 2,
                  'arguments': args,
                },
              ).toJson(),
              'patchbay.job.get' => PatchbayInvocation.accepted(
                requestId: requestId,
                payload: const <String, Object?>{
                  'terminal': true,
                  'events': <Object?>[
                    <String, Object?>{'phase': 'running'},
                    <String, Object?>{'phase': 'failed'},
                  ],
                },
              ).toJson(),
              'patchbay.job.wait' => PatchbayInvocation.accepted(
                requestId: requestId,
                payload: const <String, Object?>{
                  'outcome': 'changed',
                  'snapshot': <String, Object?>{
                    'jobId': 'job-1',
                    'terminal': true,
                    'events': <Object?>[
                      <String, Object?>{
                        'sequence': 1,
                        'at': '2026-01-01T00:00:00Z',
                        'phase': 'running',
                        'source': 'appRecorded',
                        'operation': 'fixture.failedJob',
                        'payload': <String, Object?>{},
                      },
                      <String, Object?>{
                        'sequence': 2,
                        'at': '2026-01-01T00:00:01Z',
                        'phase': 'failed',
                        'source': 'appRecorded',
                        'operation': 'fixture.failedJob',
                        'payload': <String, Object?>{},
                        'reason': 'fixtureFailure',
                      },
                    ],
                  },
                },
              ).toJson(),
              _ => PatchbayInvocation.rejected(
                requestId: requestId,
                rejection: const PatchbayRejection(
                  code: 'commandNotRegistered',
                ),
              ).toJson(),
            },
  );
  host.register();
  Timer.periodic(const Duration(hours: 1), (_) {});
}
