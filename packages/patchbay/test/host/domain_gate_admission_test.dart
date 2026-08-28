import 'dart:async';
import 'dart:convert';
import 'dart:developer';

import 'package:patchbay/patchbay.dart';
import 'package:test/test.dart';

/// PB-050-25：domain-plane 写命令的 gate 强制执行。
///
/// 闸点冻结在 `HostInvokerHandler._dispatchInvoke` 的受理序列内：sensitive-stdin
/// 校验之后、registry / external 路由之前，判据是「registry 未处理 + 目录行判为
/// 写」。本文件锁的是这条受理闸的全部可观察后果——求值语义、缺省投影、次序、
/// 门后目录复核、replay 接缝与审计取值。
void main() {
  group('read-only domain commands stay ungated', () {
    test('a sideEffect:none row never reaches the base gate', () async {
      final _RecordingGates gates = _RecordingGates(baseAllowed: false);
      final List<String> executed = <String>[];
      final PatchbayServiceHost host = _host(
        commands: <Map<String, Object?>>[
          _row('device.status', sideEffect: 'none', gates: <String>['write']),
        ],
        domainGates: gates.evaluator,
        executed: executed,
      );

      final Map<String, Object?> response = await host.dispatchInvoke(
        'device.status',
        const <String, Object?>{},
        'req-read',
      );

      expect(response['admission'], 'accepted');
      expect(executed, <String>['device.status']);
      expect(gates.baseCalls, 0);
      expect(gates.consumerCalls, isEmpty);
      expect(host.auditEvents.single.gateResult, 'notEvaluated');
    });
  });

  group('write commands evaluate the declared gates', () {
    test('an empty gates set still runs the base gate', () async {
      final _RecordingGates gates = _RecordingGates();
      final List<String> executed = <String>[];
      final PatchbayServiceHost host = _host(
        commands: <Map<String, Object?>>[_row('device.write')],
        domainGates: gates.evaluator,
        executed: executed,
      );

      final Map<String, Object?> response = await host.dispatchInvoke(
        'device.write',
        const <String, Object?>{},
        'req-empty',
      );

      expect(response['admission'], 'accepted');
      expect(gates.baseCalls, 1);
      expect(gates.consumerCalls, isEmpty);
      expect(executed, <String>['device.write']);
      expect(host.auditEvents.single.gateResult, 'passed');
    });

    test('a rejecting base gate stops the write before the adapter', () async {
      final _RecordingGates gates = _RecordingGates(
        baseAllowed: false,
        baseCode: 'dependenciesNotReady',
        baseNotice: 'The example transport is not attached yet.',
      );
      final List<String> executed = <String>[];
      final PatchbayServiceHost host = _host(
        commands: <Map<String, Object?>>[
          _row('device.write', gates: <String>['example.write']),
        ],
        domainGates: gates.evaluator,
        executed: executed,
      );

      final Map<String, Object?> response = await host.dispatchInvoke(
        'device.write',
        const <String, Object?>{},
        'req-base-closed',
      );

      expect(response['admission'], 'rejected');
      expect(response['payload'], isEmpty);
      expect(response['notice'], 'The example transport is not attached yet.');
      expect(_code(response), 'dependenciesNotReady');
      expect(_details(response), <String, Object?>{'gateId': 'patchbay.base'});
      expect(gates.consumerCalls, isEmpty);
      expect(executed, isEmpty);
      expect(host.auditEvents.single.gateResult, 'rejected');
    });

    test('declared gates run in gateId order and stop at the first '
        'rejection', () async {
      final _RecordingGates gates = _RecordingGates(
        rejectedGateIds: const <String>{'mGate', 'zGate'},
      );
      final List<String> executed = <String>[];
      final PatchbayServiceHost host = _host(
        commands: <Map<String, Object?>>[
          _row(
            'device.write',
            gates: <String>['zGate', 'aGate', 'mGate', 'aGate'],
          ),
        ],
        domainGates: gates.evaluator,
        executed: executed,
      );

      final Map<String, Object?> response = await host.dispatchInvoke(
        'device.write',
        const <String, Object?>{},
        'req-ordered',
      );

      expect(gates.consumerCalls, <String>['aGate', 'mGate']);
      expect(_code(response), 'consumerGateRejected');
      expect(_details(response), <String, Object?>{'gateId': 'mGate'});
      expect(executed, isEmpty);
    });

    test('a consumer gate keeps its own code and notice', () async {
      final _RecordingGates gates = _RecordingGates(
        rejectedGateIds: const <String>{'example.write'},
        consumerCode: 'writeGateClosedByDefault',
        consumerNotice: 'This write gate stays closed until authorized.',
      );
      final PatchbayServiceHost host = _host(
        commands: <Map<String, Object?>>[
          _row('device.write', gates: <String>['example.write']),
        ],
        domainGates: gates.evaluator,
      );

      final Map<String, Object?> response = await host.dispatchInvoke(
        'device.write',
        const <String, Object?>{},
        'req-consumer-closed',
      );

      expect(_code(response), 'writeGateClosedByDefault');
      expect(
        response['notice'],
        'This write gate stays closed until authorized.',
      );
      expect(_details(response), <String, Object?>{'gateId': 'example.write'});
    });

    test('appState is gated exactly like external', () async {
      final _RecordingGates gates = _RecordingGates(baseAllowed: false);
      final PatchbayServiceHost host = _host(
        commands: <Map<String, Object?>>[
          _row('device.touch', sideEffect: 'appState'),
        ],
        domainGates: gates.evaluator,
      );

      expect(
        _code(
          await host.dispatchInvoke(
            'device.touch',
            const <String, Object?>{},
            'req-appstate',
          ),
        ),
        'baseGateRejected',
      );
    });
  });

  group('a host without an evaluator', () {
    test('rejects a write that declares gates nobody can evaluate', () async {
      final List<String> executed = <String>[];
      final PatchbayServiceHost host = _host(
        commands: <Map<String, Object?>>[
          _row('device.write', gates: <String>['zGate', 'aGate']),
        ],
        executed: executed,
      );

      final Map<String, Object?> response = await host.dispatchInvoke(
        'device.write',
        const <String, Object?>{},
        'req-no-evaluator',
      );

      expect(response['admission'], 'rejected');
      expect(_code(response), 'consumerGateRejected');
      expect(_details(response), <String, Object?>{
        'gateId': 'aGate',
        'reason': 'gateEvaluatorUnavailable',
      });
      expect(executed, isEmpty);
      expect(host.auditEvents.single.gateResult, 'rejected');
    });

    test('leaves a gate-free write byte-for-byte unchanged', () async {
      final List<String> executed = <String>[];
      final PatchbayServiceHost host = _host(
        commands: <Map<String, Object?>>[_row('device.write')],
        executed: executed,
      );

      final Map<String, Object?> response = await host.dispatchInvoke(
        'device.write',
        const <String, Object?>{},
        'req-legacy',
      );

      expect(response['admission'], 'accepted');
      expect(executed, <String>['device.write']);
      expect(host.auditEvents.single.gateResult, 'notEvaluated');
    });
  });

  group('sideEffect projection is fail-closed', () {
    Future<Map<String, Object?>> reply(Map<String, Object?> row) async => _host(
      commands: <Map<String, Object?>>[row],
    ).dispatchInvoke('device.write', const <String, Object?>{}, 'req-fc');

    test('a missing sideEffect key counts as a write', () async {
      final Map<String, Object?> row = _row(
        'device.write',
        gates: <String>['write'],
      )..remove('sideEffect');
      expect(_code(await reply(row)), 'consumerGateRejected');
    });

    test('an unknown sideEffect value counts as a write without '
        'invalidating the catalog', () async {
      final Map<String, Object?> response = await reply(
        _row(
          'device.write',
          sideEffect: 'mutatesEverything',
          gates: <String>['write'],
        ),
      );
      expect(_code(response), 'consumerGateRejected');
      expect(_details(response)['reason'], 'gateEvaluatorUnavailable');
    });

    test('a command missing from the catalog counts as a write', () async {
      final _RecordingGates gates = _RecordingGates(baseAllowed: false);
      final List<String> executed = <String>[];
      final PatchbayServiceHost host = _host(
        commands: <Map<String, Object?>>[
          _row('device.status', sideEffect: 'none'),
        ],
        domainGates: gates.evaluator,
        executed: executed,
      );

      final Map<String, Object?> response = await host.dispatchInvoke(
        'device.undeclared',
        const <String, Object?>{},
        'req-undeclared',
      );

      expect(_code(response), 'baseGateRejected');
      expect(executed, isEmpty);
    });

    test('a non-string gates array degrades to the empty set', () async {
      final _RecordingGates gates = _RecordingGates();
      final PatchbayServiceHost host = _host(
        commands: <Map<String, Object?>>[
          <String, Object?>{
            'name': 'device.write',
            'mode': 'immediate',
            'sideEffect': 'external',
            'factSources': <String>['appRecorded'],
            'gates': <Object?>['write', 7],
          },
        ],
        domainGates: gates.evaluator,
      );

      expect(
        (await host.dispatchInvoke(
          'device.write',
          const <String, Object?>{},
          'req-bad-gates',
        ))['admission'],
        'accepted',
      );
      expect(gates.baseCalls, 1);
      expect(gates.consumerCalls, isEmpty);
    });
  });

  group('admission order', () {
    test('sensitive-stdin rejection precedes the gate', () async {
      final _RecordingGates gates = _RecordingGates(baseAllowed: false);
      final PatchbayServiceHost host = _host(
        commands: <Map<String, Object?>>[
          <String, Object?>{
            ..._row('device.bind', gates: <String>['write']),
            'parameters': <Object?>[
              <String, Object?>{
                'name': 'password',
                'type': 'string',
                'sensitive': true,
              },
            ],
          },
        ],
        domainGates: gates.evaluator,
      );

      final Map<String, Object?> response = await host.dispatchInvoke(
        'device.bind',
        const <String, Object?>{'password': 'hunter2'},
        'req-sensitive',
      );

      expect(_code(response), 'sensitiveInputRequiresStdin');
      expect(gates.baseCalls, 0);
    });

    test('registry-owned commands keep their own gate stage', () async {
      final _RecordingGates gates = _RecordingGates(baseAllowed: false);
      final PatchbayCommandRegistry registry = PatchbayCommandRegistry(
        <PatchbayCommandRegistration<Object?>>[
          PatchbayCommandRegistration<Map<String, Object?>>(
            descriptor: const PatchbayCommandDescriptor(
              name: 'patchbay.registered',
              summary: 'Registry-owned write.',
              plane: PatchbayPlane.domain,
              mode: PatchbayCommandMode.immediate,
              sideEffect: PatchbaySideEffect.appState,
              factSources: <PatchbayFactSource>{PatchbayFactSource.appRecorded},
              gates: <String>{'registryGate'},
            ),
            decode: (Map<String, Object?> arguments) => arguments,
            handle: (Map<String, Object?> _, String requestId) =>
                PatchbayInvocation.accepted(requestId: requestId).toJson(),
          ),
        ],
      );
      final PatchbayServiceHost host = _host(
        commands: const <Map<String, Object?>>[],
        domainGates: gates.evaluator,
        registry: registry,
      );

      final Map<String, Object?> response = await host.dispatchInvoke(
        'patchbay.registered',
        const <String, Object?>{},
        'req-registry',
      );

      expect(response['admission'], 'accepted');
      expect(gates.baseCalls, 0);
    });

    test('requestId ledger replay runs before new admission', () async {
      var open = true;
      final List<String> executed = <String>[];
      final PatchbayServiceHost host = _host(
        commands: <Map<String, Object?>>[
          <String, Object?>{
            ..._row('device.write', gates: <String>['write']),
            'retryPolicy': <String, Object?>{'maxAttempts': 3, 'backoffMs': 10},
          },
        ],
        domainGates: PatchbayGateEvaluator(
          baseGate: () => const PatchbayGateDecision.allow(),
          consumerGate: (String _) => open
              ? const PatchbayGateDecision.allow()
              : const PatchbayGateDecision.reject(code: 'writeGateClosed'),
        ),
        executed: executed,
      );

      expect(
        (await host.dispatchInvoke(
          'device.write',
          const <String, Object?>{},
          'req-replay',
        ))['admission'],
        'accepted',
      );
      open = false;
      final Map<String, Object?> second = await host.dispatchInvoke(
        'device.write',
        const <String, Object?>{},
        'req-replay',
      );

      expect(second['admission'], 'accepted');
      expect(executed, <String>['device.write']);
    });

    test(
      'a first-time gate rejection does not claim a prior request',
      () async {
        final PatchbayServiceHost host = _host(
          commands: <Map<String, Object?>>[
            _row('device.write', gates: <String>['write']),
          ],
          domainGates: _RecordingGates(
            rejectedGateIds: const <String>{'write'},
          ).evaluator,
        );

        expect(
          _details(
            await host.dispatchInvoke(
              'device.write',
              const <String, Object?>{},
              'req-first',
            ),
          ),
          <String, Object?>{'gateId': 'write'},
        );
      },
    );

    test('a parked gate does not consume external ledger capacity', () async {
      final Completer<void> release = Completer<void>();
      final PatchbayServiceHost host = _host(
        commands: <Map<String, Object?>>[
          _row('device.slow', gates: <String>['slow']),
          _row('device.fast'),
        ],
        domainGates: PatchbayGateEvaluator(
          baseGate: () => const PatchbayGateDecision.allow(),
          consumerGate: (String _) async {
            await release.future;
            return const PatchbayGateDecision.allow();
          },
        ),
        maxConcurrentInvocations: 256,
      );

      final List<Future<Map<String, Object?>>> parked =
          <Future<Map<String, Object?>>>[
            for (var index = 0; index < 255; index += 1)
              host.dispatchInvoke(
                'device.slow',
                const <String, Object?>{},
                'parked-$index',
              ),
          ];

      expect(
        (await host.dispatchInvoke(
          'device.fast',
          const <String, Object?>{},
          'req-fast',
        ))['admission'],
        'accepted',
      );

      release.complete();
      await Future.wait(parked);
    });
  });

  group('post-gate catalog recheck', () {
    test('rejects a gates drift observed while the gate awaited', () async {
      final _MutableProvider provider = _MutableProvider(
        commands: <Object?>[
          _row('device.write', gates: <String>['write']),
        ],
      );
      final List<String> executed = <String>[];
      var evaluations = 0;
      final PatchbayServiceHost host = _providerHost(
        provider: provider,
        executed: executed,
        domainGates: PatchbayGateEvaluator(
          baseGate: () => const PatchbayGateDecision.allow(),
          consumerGate: (String _) async {
            evaluations += 1;
            provider
              ..revision += 1
              ..commands = <Object?>[
                _row('device.write', gates: <String>['write', 'audit']),
              ];
            return const PatchbayGateDecision.allow();
          },
        ),
      );

      final Map<String, Object?> response = await host.dispatchInvoke(
        'device.write',
        const <String, Object?>{},
        'req-drift',
      );

      expect(_code(response), 'providerProtocolViolation');
      expect(_details(response), <String, Object?>{
        'reason': 'catalogGateDrift',
        'command': 'device.write',
      });
      expect(executed, isEmpty);
      expect(evaluations, 1, reason: 'drift must not re-evaluate the gate');
    });

    test(
      'rejects a write that turned read-only while the gate awaited',
      () async {
        final _MutableProvider provider = _MutableProvider(
          commands: <Object?>[
            _row('device.write', gates: <String>['write']),
          ],
        );
        final List<String> executed = <String>[];
        final PatchbayServiceHost host = _providerHost(
          provider: provider,
          executed: executed,
          domainGates: PatchbayGateEvaluator(
            baseGate: () => const PatchbayGateDecision.allow(),
            consumerGate: (String _) async {
              provider
                ..revision += 1
                ..commands = <Object?>[
                  _row(
                    'device.write',
                    sideEffect: 'none',
                    gates: <String>['write'],
                  ),
                ];
              return const PatchbayGateDecision.allow();
            },
          ),
        );

        expect(
          _details(
            await host.dispatchInvoke(
              'device.write',
              const <String, Object?>{},
              'req-became-read',
            ),
          )['reason'],
          'catalogGateDrift',
        );
        expect(executed, isEmpty);
      },
    );

    test(
      'a read-only row that later became a write is still dispatched',
      () async {
        // The admission decision is taken from the catalog read that admitted
        // this call. A read-only row never opens a gate window, so there is no
        // recheck to fail — the next call sees the new declaration instead.
        final _MutableProvider provider = _MutableProvider(
          commands: <Object?>[
            _row('device.probe', sideEffect: 'none', gates: <String>['write']),
          ],
        );
        final List<String> executed = <String>[];
        final PatchbayServiceHost host = _providerHost(
          provider: provider,
          executed: executed,
          domainGates: PatchbayGateEvaluator(
            baseGate: () => const PatchbayGateDecision.allow(),
            consumerGate: (String _) =>
                const PatchbayGateDecision.reject(code: 'writeGateClosed'),
          ),
        );

        expect(
          (await host.dispatchInvoke(
            'device.probe',
            const <String, Object?>{},
            'req-probe',
          ))['admission'],
          'accepted',
        );
        provider
          ..revision += 1
          ..commands = <Object?>[
            _row('device.probe', gates: <String>['write']),
          ];
        expect(
          _code(
            await host.dispatchInvoke(
              'device.probe',
              const <String, Object?>{},
              'req-probe-2',
            ),
          ),
          'writeGateClosed',
        );
        expect(executed, <String>['device.probe']);
      },
    );

    test(
      'reports a catalog that went invalid while the gate awaited',
      () async {
        final _MutableProvider provider = _MutableProvider(
          commands: <Object?>[
            _row('device.write', gates: <String>['write']),
          ],
        );
        final PatchbayServiceHost host = _providerHost(
          provider: provider,
          domainGates: PatchbayGateEvaluator(
            baseGate: () => const PatchbayGateDecision.allow(),
            consumerGate: (String _) async {
              provider
                ..revision += 1
                ..commands = <Object?>[
                  <String, Object?>{'name': 'device.invalid-name'},
                ];
              return const PatchbayGateDecision.allow();
            },
          ),
        );

        final Map<String, Object?> response = await host.dispatchInvoke(
          'device.write',
          const <String, Object?>{},
          'req-invalid',
        );

        expect(_code(response), 'providerProtocolViolation');
        // Same shape the pre-gate catalog read already produces: the outer
        // reason names the stage, the nested `catalog` carries the violation.
        expect(_details(response)['reason'], 'catalogUnavailable');
        expect(
          (_details(response)['catalog']! as Map<Object?, Object?>)['reason'],
          'invalidCatalogCommands',
        );
      },
    );

    test(
      'dispatches when the projection survives an unrelated revision',
      () async {
        final _MutableProvider provider = _MutableProvider(
          commands: <Object?>[
            _row('device.write', gates: <String>['write']),
          ],
        );
        final List<String> executed = <String>[];
        final PatchbayServiceHost host = _providerHost(
          provider: provider,
          executed: executed,
          domainGates: PatchbayGateEvaluator(
            baseGate: () => const PatchbayGateDecision.allow(),
            consumerGate: (String _) async {
              provider
                ..revision += 1
                ..commands = <Object?>[
                  _row('device.write', gates: <String>['write']),
                  _row('device.added', sideEffect: 'none'),
                ];
              return const PatchbayGateDecision.allow();
            },
          ),
        );

        expect(
          (await host.dispatchInvoke(
            'device.write',
            const <String, Object?>{},
            'req-stable',
          ))['admission'],
          'accepted',
        );
        expect(executed, <String>['device.write']);
      },
    );
  });

  group('audit', () {
    test('records one event per gate outcome and no gate identity', () async {
      final PatchbayServiceHost host = _host(
        commands: <Map<String, Object?>>[
          _row('device.status', sideEffect: 'none'),
          _row('device.open', gates: <String>['unlockedGate']),
          _row('device.denied', gates: <String>['sealedGate']),
        ],
        domainGates: _RecordingGates(
          rejectedGateIds: const <String>{'sealedGate'},
        ).evaluator,
      );

      await host.dispatchInvoke(
        'device.status',
        const <String, Object?>{},
        'audit-read',
      );
      await host.dispatchInvoke(
        'device.open',
        const <String, Object?>{},
        'audit-open',
      );
      await host.dispatchInvoke(
        'device.denied',
        const <String, Object?>{},
        'audit-denied',
      );

      expect(
        host.auditEvents
            .map((PatchbayAuditEvent event) => event.gateResult)
            .toList(),
        <String>['notEvaluated', 'passed', 'rejected'],
      );
      expect(
        host.auditEvents.last.toJson().toString(),
        isNot(contains('sealedGate')),
      );
    });

    test('a replayed invocation still records nothing', () async {
      final PatchbayServiceHost host = _host(
        commands: <Map<String, Object?>>[
          <String, Object?>{
            ..._row('device.write', gates: <String>['write']),
            'retryPolicy': <String, Object?>{'maxAttempts': 2, 'backoffMs': 10},
          },
        ],
        domainGates: _RecordingGates().evaluator,
      );

      await host.dispatchInvoke(
        'device.write',
        const <String, Object?>{},
        'audit-replay',
      );
      await host.dispatchInvoke(
        'device.write',
        const <String, Object?>{},
        'audit-replay',
      );

      expect(host.auditEvents, hasLength(1));
      expect(host.auditEvents.single.gateResult, 'passed');
    });
  });

  group('VM Service and direct share one gate', () {
    test('both transports reply with the same envelope and audit', () async {
      final Map<String, ServiceExtensionHandler> handlers =
          <String, ServiceExtensionHandler>{};
      PatchbayServiceHost build([PatchbayExtensionRegistrar? registrar]) =>
          _host(
            commands: <Map<String, Object?>>[
              _row('device.write', gates: <String>['write']),
            ],
            domainGates: _RecordingGates(
              rejectedGateIds: const <String>{'write'},
              consumerCode: 'writeGateClosedByDefault',
              consumerNotice: 'closed by default',
            ).evaluator,
            registrar: registrar,
          );

      final PatchbayServiceHost directHost = build();
      final PatchbayServiceHost vmHost = build((
        String method,
        ServiceExtensionHandler handler,
      ) {
        handlers[method] = handler;
      })..register();

      final Map<String, Object?> direct = await directHost.dispatchInvoke(
        'device.write',
        const <String, Object?>{},
        'req-parity',
      );
      final ServiceExtensionResponse raw =
          await handlers[PatchbayServiceHost.invokeMethod]!(
            PatchbayServiceHost.invokeMethod,
            <String, String>{
              'command': 'device.write',
              'args': '{}',
              'requestId': 'req-parity',
            },
          );
      final Map<String, Object?> vm = Map<String, Object?>.from(
        jsonDecode(raw.result!) as Map<String, dynamic>,
      );

      expect(vm, direct);
      expect(
        vmHost.auditEvents.single.toJson(),
        directHost.auditEvents.single.toJson(),
      );
    });
  });
}

Map<String, Object?> _row(
  String name, {
  String sideEffect = 'external',
  List<String>? gates,
}) => <String, Object?>{
  'name': name,
  'mode': 'immediate',
  'sideEffect': sideEffect,
  'factSources': <String>['appRecorded'],
  if (gates != null) 'gates': gates,
};

PatchbayServiceHost _host({
  required List<Map<String, Object?>> commands,
  PatchbayGateEvaluator? domainGates,
  PatchbayCommandRegistry? registry,
  List<String>? executed,
  PatchbayExtensionRegistrar? registrar,
  int maxConcurrentInvocations = 8,
}) => PatchbayServiceHost(
  applicationId: 'dev.patchbay.domain-gate-test',
  registrar: registrar ?? (_, _) {},
  registry: registry,
  maxConcurrentInvocations: maxConcurrentInvocations,
  domainGates: domainGates,
  catalog: () async => <String, Object?>{'commands': commands},
  snapshot: () async => const <String, Object?>{},
  invoke: (String command, Map<String, Object?> _, String requestId) async {
    executed?.add(command);
    return PatchbayInvocation.accepted(requestId: requestId).toJson();
  },
);

PatchbayServiceHost _providerHost({
  required _MutableProvider provider,
  PatchbayGateEvaluator? domainGates,
  List<String>? executed,
}) => PatchbayServiceHost.withCatalogProvider(
  applicationId: 'dev.patchbay.domain-gate-test',
  registrar: (_, _) {},
  domainGates: domainGates,
  catalogProvider: provider,
  snapshot: () async => const <String, Object?>{},
  invoke: (String command, Map<String, Object?> _, String requestId) async {
    executed?.add(command);
    return PatchbayInvocation.accepted(requestId: requestId).toJson();
  },
);

String? _code(Map<String, Object?> response) {
  final Object? rejection = response['rejection'];
  return rejection is Map<Object?, Object?>
      ? rejection['code'] as String?
      : null;
}

Map<String, Object?> _details(Map<String, Object?> response) {
  final Map<Object?, Object?> rejection =
      response['rejection']! as Map<Object?, Object?>;
  return Map<String, Object?>.from(
    rejection['details']! as Map<Object?, Object?>,
  );
}

/// A gate evaluator that reports exactly which stages a dispatch reached.
final class _RecordingGates {
  _RecordingGates({
    this.baseAllowed = true,
    this.baseCode,
    this.baseNotice,
    this.rejectedGateIds = const <String>{},
    this.consumerCode,
    this.consumerNotice,
  });

  final bool baseAllowed;
  final String? baseCode;
  final String? baseNotice;
  final Set<String> rejectedGateIds;
  final String? consumerCode;
  final String? consumerNotice;

  int baseCalls = 0;
  final List<String> consumerCalls = <String>[];

  PatchbayGateEvaluator get evaluator =>
      PatchbayGateEvaluator(baseGate: _base, consumerGate: _consumer);

  FutureOr<PatchbayGateDecision> _base() {
    baseCalls += 1;
    if (baseAllowed) return const PatchbayGateDecision.allow();
    final String? code = baseCode;
    return code == null
        ? PatchbayGateDecision.reject(
            code: 'baseGateRejected',
            notice: baseNotice,
          )
        : PatchbayGateDecision.reject(code: code, notice: baseNotice);
  }

  FutureOr<PatchbayGateDecision> _consumer(String gateId) {
    consumerCalls.add(gateId);
    if (!rejectedGateIds.contains(gateId)) {
      return const PatchbayGateDecision.allow();
    }
    return PatchbayGateDecision.reject(
      code: consumerCode ?? 'consumerGateRejected',
      notice: consumerNotice,
    );
  }
}

final class _MutableProvider implements PatchbayCatalogProvider {
  _MutableProvider({required this.commands});

  int revision = 0;
  List<Object?> commands;

  @override
  int get commandsRevision => revision;

  @override
  Future<PatchbayCatalogSample> readCatalog() async => PatchbayCatalogSample(
    commandsRevision: revision,
    catalog: <String, Object?>{'commands': commands},
  );
}
