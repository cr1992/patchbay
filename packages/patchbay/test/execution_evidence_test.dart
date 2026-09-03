import 'dart:convert';
import 'dart:developer';

import 'package:patchbay/patchbay_host.dart';
import 'package:patchbay/patchbay_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('execution descriptor contract', () {
    test('serializes additive fields without changing wire covers', () {
      final PatchbayCommandDescriptor descriptor = _descriptor(
        unchangedMaxAgeMs: 5000,
        confirmationBudgetMs: 3000,
        weakConfirmationCompletes: true,
      );

      expect(
        descriptor.toJson(),
        containsPair('unchangedEvidenceMaxAgeMs', 5000),
      );
      expect(descriptor.toJson(), containsPair('confirmationBudgetMs', 3000));
      expect(
        descriptor.toJson(),
        containsPair('weakConfirmationCompletes', true),
      );
      expect(
        PatchbayCatalogDigest.ofCommands(<Object?>[descriptor.toJson()]).covers,
        <String>['commands'],
      );
    });

    for (final ({String name, PatchbayCommandDescriptor descriptor}) fixture
        in <({String name, PatchbayCommandDescriptor descriptor})>[
          (
            name: 'unchanged lower bound',
            descriptor: _descriptor(unchangedMaxAgeMs: 0),
          ),
          (
            name: 'unchanged upper bound',
            descriptor: _descriptor(unchangedMaxAgeMs: 300001),
          ),
          (
            name: 'confirmation lower bound',
            descriptor: _descriptor(confirmationBudgetMs: 0),
          ),
          (
            name: 'confirmation upper bound',
            descriptor: _descriptor(confirmationBudgetMs: 120001),
          ),
          (
            name: 'weak completion without budget',
            descriptor: _descriptor(weakConfirmationCompletes: true),
          ),
        ]) {
      test('rejects ${fixture.name}', () {
        expect(() => _registry(fixture.descriptor), throwsArgumentError);
      });
    }

    test('rejects weak completion on an immediate descriptor', () {
      expect(
        () => _registry(
          _descriptor(
            mode: PatchbayCommandMode.immediate,
            confirmationBudgetMs: 3000,
            weakConfirmationCompletes: true,
          ),
        ),
        throwsArgumentError,
      );
    });

    test('rejects weak completion in a non-job catalog row', () {
      expect(
        () => PatchbayExecutionContract.fromCatalogRow(<String, Object?>{
          'mode': 'immediate',
          'factSources': <String>['commandEcho'],
          'confirmationBudgetMs': 3000,
          'weakConfirmationCompletes': true,
        }),
        throwsFormatException,
      );
    });
  });

  group('execution evidence semantics', () {
    const int nowMs = 10000;
    final PatchbayExecutionContract normal = PatchbayExecutionContract(
      factSources: const <PatchbayFactSource>{
        PatchbayFactSource.appRecorded,
        PatchbayFactSource.commandEcho,
        PatchbayFactSource.deviceReported,
        PatchbayFactSource.uiObserved,
        PatchbayFactSource.unknown,
      },
      unchangedEvidenceMaxAgeMs: 5000,
      confirmationBudgetMs: 3000,
    );

    for (final ({String phase, Map<String, Object?> payload}) fixture
        in <({String phase, Map<String, Object?> payload})>[
          (phase: 'failed', payload: _evidence('notSent', 'appRecorded')),
          (
            phase: 'failed',
            payload: _evidence('sentUnconfirmed', 'commandEcho'),
          ),
          (
            phase: 'completed',
            payload: _evidence(
              'unchanged',
              'appRecorded',
              priorSource: 'deviceReported',
              priorAtMs: 9000,
            ),
          ),
          (
            phase: 'completed',
            payload: _evidence('deviceConfirmed', 'deviceReported'),
          ),
        ]) {
      test('${fixture.payload['execution']} is phase-compatible', () {
        expect(
          validatePatchbayExecutionEvidence(
            normal,
            fixture.payload,
            terminalPhase: fixture.phase,
            nowMs: nowMs,
          ).issues,
          isEmpty,
        );
      });
    }

    test('weak confirmation explicitly permits completed', () {
      final PatchbayExecutionValidationResult result =
          validatePatchbayExecutionEvidence(
            PatchbayExecutionContract(
              factSources: normal.factSources,
              confirmationBudgetMs: 3000,
              weakConfirmationCompletes: true,
            ),
            _evidence('sentUnconfirmed', 'commandEcho'),
            terminalPhase: 'completed',
            nowMs: nowMs,
          );
      expect(result.issues, isEmpty);
    });

    test('uiObserved cannot claim deviceConfirmed', () {
      final PatchbayExecutionValidationResult result =
          validatePatchbayExecutionEvidence(
            normal,
            _evidence('deviceConfirmed', 'uiObserved'),
            terminalPhase: 'completed',
            nowMs: nowMs,
          );
      expect(result.issues, contains(_issue('unknownVariant', 'factSource')));
    });

    test('unchanged requires fresh prior source and timestamp', () {
      final PatchbayExecutionValidationResult missing =
          validatePatchbayExecutionEvidence(
            normal,
            _evidence('unchanged', 'appRecorded'),
            terminalPhase: 'completed',
            nowMs: nowMs,
          );
      expect(
        missing.issues,
        contains(_issue('missingField', 'priorObservedAtMs')),
      );
      final PatchbayExecutionValidationResult stale =
          validatePatchbayExecutionEvidence(
            normal,
            _evidence(
              'unchanged',
              'appRecorded',
              priorSource: 'appRecorded',
              priorAtMs: 4000,
            ),
            terminalPhase: 'completed',
            nowMs: nowMs,
          );
      expect(
        stale.issues,
        contains(_issue('unknownVariant', 'priorObservedAtMs')),
      );
    });

    test('terminal phase wins over optimistic classifications', () {
      for (final ({String classification, String phase}) fixture
          in <({String classification, String phase})>[
            (classification: 'notSent', phase: 'completed'),
            (classification: 'sentUnconfirmed', phase: 'completed'),
            (classification: 'unchanged', phase: 'failed'),
            (classification: 'deviceConfirmed', phase: 'failed'),
          ]) {
        final Map<String, Object?> payload =
            fixture.classification == 'unchanged'
            ? _evidence(
                fixture.classification,
                'appRecorded',
                priorSource: 'appRecorded',
                priorAtMs: 9000,
              )
            : _evidence(
                fixture.classification,
                fixture.classification == 'deviceConfirmed'
                    ? 'deviceReported'
                    : 'appRecorded',
              );
        expect(
          validatePatchbayExecutionEvidence(
            normal,
            payload,
            terminalPhase: fixture.phase,
            nowMs: nowMs,
          ).issues,
          contains(_issue('unknownVariant', 'classification')),
        );
      }
    });

    test('typed execution wins and records legacy dispatched conflict', () {
      final Map<String, Object?> payload = _evidence(
        'deviceConfirmed',
        'deviceReported',
      )..['dispatched'] = false;
      final PatchbayExecutionValidationResult result =
          validatePatchbayExecutionEvidence(normal, payload, nowMs: nowMs);
      expect(result.issues, isEmpty);
      expect(result.legacyDispatchedConflict, isTrue);
    });
  });

  test(
    'job ledger replaces phase-incompatible evidence before storage',
    () async {
      final PatchbayCommandRegistry commands = _registry(
        _descriptor(confirmationBudgetMs: 3000),
      );
      final PatchbayJobRegistry jobs = PatchbayJobRegistry(
        commandRegistry: commands,
        now: () => DateTime.fromMillisecondsSinceEpoch(10000, isUtc: true),
      );
      final String jobId = jobs.startBoundToCommand(
        command: 'patchbay.fixturejob',
        source: PatchbayFactSource.appRecorded,
        body: () async =>
            _evidence('notSent', 'appRecorded')..['password'] = 'ledger-secret',
      );
      final PatchbayJobWaitResult result = (await jobs.waitForChange(
        jobId,
        afterSequence: 1,
        timeout: const Duration(seconds: 1),
      ))!;

      expect(result.snapshot.events.last.phase, PatchbayJobPhase.completed);
      expect(result.snapshot.events.last.reason, 'providerProtocolViolation');
      expect(
        result.snapshot.toJson().toString(),
        isNot(contains('ledger-secret')),
      );
    },
  );

  test(
    'dispatch scope applies both originating response and execution contracts',
    () async {
      late PatchbayJobRegistry jobs;
      final Map<String, Object?> betaPayload = <String, Object?>{
        'betaResult': 'would-pass-beta',
        ..._evidence('sentUnconfirmed', 'appRecorded'),
      };
      late String jobId;
      final PatchbayCommandRegistry commands = PatchbayCommandRegistry(
        <PatchbayCommandRegistration<Object?>>[
          PatchbayCommandRegistration<Map<String, Object?>>(
            descriptor: _bindingDescriptor(
              name: 'patchbay.alpha',
              resultField: 'alphaResult',
              factSources: const <PatchbayFactSource>{
                PatchbayFactSource.deviceReported,
              },
            ),
            decode: (arguments) => arguments,
            handle: (_, requestId) {
              jobId = jobs.start(
                source: PatchbayFactSource.appRecorded,
                body: () async => betaPayload,
              );
              return PatchbayInvocation.accepted(
                requestId: requestId,
                jobId: jobId,
              ).toJson();
            },
          ),
          PatchbayCommandRegistration<Map<String, Object?>>(
            descriptor: _bindingDescriptor(
              name: 'patchbay.beta',
              resultField: 'betaResult',
              factSources: const <PatchbayFactSource>{
                PatchbayFactSource.appRecorded,
              },
              weakConfirmationCompletes: true,
            ),
            decode: (arguments) => arguments,
            handle: (_, requestId) =>
                PatchbayInvocation.accepted(requestId: requestId).toJson(),
          ),
        ],
      );
      jobs = PatchbayJobRegistry(commandRegistry: commands);

      await commands.dispatch(
        'patchbay.alpha',
        const <String, Object?>{},
        'request-origin-contracts',
      );
      await _settled(jobs, jobId);

      final PatchbayJobEvent terminal = jobs.snapshot(jobId)!.events.last;
      expect(terminal.reason, 'providerProtocolViolation');
      final Map<Object?, Object?> details =
          ((terminal.payload['rejection']! as Map<Object?, Object?>)['details']!
              as Map<Object?, Object?>);
      final List<Object?> violations = details['violations']! as List<Object?>;
      expect(
        violations.toString(),
        allOf(contains(r'$.payload.alphaResult'), contains('factSource')),
      );
      expect(terminal.payload.toString(), isNot(contains('would-pass-beta')));
    },
  );

  test(
    'forged command cannot select another response or execution contract',
    () async {
      late PatchbayJobRegistry jobs;
      var bodyCalled = false;
      final PatchbayCommandRegistry commands = PatchbayCommandRegistry(
        <PatchbayCommandRegistration<Object?>>[
          PatchbayCommandRegistration<Map<String, Object?>>(
            descriptor: _bindingDescriptor(
              name: 'patchbay.alpha',
              resultField: 'alphaResult',
              factSources: const <PatchbayFactSource>{
                PatchbayFactSource.deviceReported,
              },
            ),
            decode: (arguments) => arguments,
            handle: (_, requestId) {
              jobs.start(
                command: 'patchbay.beta',
                source: PatchbayFactSource.appRecorded,
                body: () async {
                  bodyCalled = true;
                  return <String, Object?>{
                    'betaResult': 'must-not-start',
                    ..._evidence('sentUnconfirmed', 'appRecorded'),
                  };
                },
              );
              return PatchbayInvocation.accepted(requestId: requestId).toJson();
            },
          ),
          PatchbayCommandRegistration<Map<String, Object?>>(
            descriptor: _bindingDescriptor(
              name: 'patchbay.beta',
              resultField: 'betaResult',
              factSources: const <PatchbayFactSource>{
                PatchbayFactSource.appRecorded,
              },
              weakConfirmationCompletes: true,
            ),
            decode: (arguments) => arguments,
            handle: (_, requestId) =>
                PatchbayInvocation.accepted(requestId: requestId).toJson(),
          ),
        ],
      );
      jobs = PatchbayJobRegistry(commandRegistry: commands);

      await expectLater(
        commands.dispatch(
          'patchbay.alpha',
          const <String, Object?>{},
          'request-forged-command',
        ),
        throwsArgumentError,
      );
      expect(jobs.totalJobs, 0);
      expect(bodyCalled, isFalse);
    },
  );

  test(
    'foreign registry cannot supply alternate response or execution contracts',
    () async {
      var bodyCalled = false;
      final PatchbayCommandRegistry foreignCommands = PatchbayCommandRegistry(
        <PatchbayCommandRegistration<Object?>>[
          PatchbayCommandRegistration<Map<String, Object?>>(
            descriptor: _bindingDescriptor(
              name: 'patchbay.beta',
              resultField: 'betaResult',
              factSources: const <PatchbayFactSource>{
                PatchbayFactSource.appRecorded,
              },
              weakConfirmationCompletes: true,
            ),
            decode: (arguments) => arguments,
            handle: (_, requestId) =>
                PatchbayInvocation.accepted(requestId: requestId).toJson(),
          ),
        ],
      );
      final PatchbayJobRegistry foreignJobs = PatchbayJobRegistry(
        commandRegistry: foreignCommands,
      );
      final PatchbayCommandRegistry activeCommands = PatchbayCommandRegistry(
        <PatchbayCommandRegistration<Object?>>[
          PatchbayCommandRegistration<Map<String, Object?>>(
            descriptor: _bindingDescriptor(
              name: 'patchbay.alpha',
              resultField: 'alphaResult',
              factSources: const <PatchbayFactSource>{
                PatchbayFactSource.deviceReported,
              },
            ),
            decode: (arguments) => arguments,
            handle: (_, requestId) {
              foreignJobs.startBoundToCommand(
                command: 'patchbay.beta',
                source: PatchbayFactSource.appRecorded,
                body: () async {
                  bodyCalled = true;
                  return <String, Object?>{
                    'betaResult': 'must-not-start',
                    ..._evidence('sentUnconfirmed', 'appRecorded'),
                  };
                },
              );
              return PatchbayInvocation.accepted(requestId: requestId).toJson();
            },
          ),
        ],
      );

      await expectLater(
        activeCommands.dispatch(
          'patchbay.alpha',
          const <String, Object?>{},
          'request-foreign-contracts',
        ),
        throwsStateError,
      );
      expect(foreignJobs.totalJobs, 0);
      expect(bodyCalled, isFalse);
    },
  );

  test('host validates execution identically on direct and VM paths', () async {
    final PatchbayCommandRegistry commands = _registry(
      _descriptor(confirmationBudgetMs: 3000),
      payload: _evidence('deviceConfirmed', 'uiObserved'),
    );
    final PatchbayServiceHost host = PatchbayServiceHost(
      applicationId: 'execution-test',
      registrar: (_, _) {},
      registry: commands,
      catalog: () async => const <String, Object?>{},
      snapshot: () async => const <String, Object?>{},
      invoke: (_, _, requestId) async =>
          PatchbayInvocation.accepted(requestId: requestId).toJson(),
    );
    final Map<String, Object?> direct = await host.dispatchInvoke(
      'patchbay.fixturejob',
      const <String, Object?>{},
      'request-1',
    );
    final ServiceExtensionResponse vmResponse = await host.handleInvoke(
      PatchbayServiceHost.invokeMethod,
      const <String, String>{
        'command': 'patchbay.fixturejob',
        'args': '{}',
        'requestId': 'request-1',
      },
    );
    final Map<String, Object?> vm = Map<String, Object?>.from(
      jsonDecode(vmResponse.result!) as Map<String, dynamic>,
    );

    expect(vm, direct);
    expect(direct['admission'], 'rejected');
    expect(
      (direct['rejection']! as Map<Object?, Object?>)['code'],
      'providerProtocolViolation',
    );
  });

  test('external catalog rejects an out-of-range execution contract', () async {
    final PatchbayServiceHost host = PatchbayServiceHost(
      applicationId: 'execution-catalog-test',
      catalog: () async => <String, Object?>{
        'commands': <Object?>[
          <String, Object?>{
            'name': 'device.refresh',
            'confirmationBudgetMs': 120001,
          },
        ],
      },
      snapshot: () async => const <String, Object?>{},
      invoke: (_, _, requestId) async =>
          PatchbayInvocation.accepted(requestId: requestId).toJson(),
    );

    final Map<String, Object?> catalog = await host.dispatchCatalog();
    expect(catalog.containsKey('commands'), isFalse);
    expect(catalog.toString(), contains('invalidExecutionContract'));
  });

  test('host records conflict while keeping execution authoritative', () async {
    final Map<String, Object?> payload = _evidence(
      'deviceConfirmed',
      'deviceReported',
    )..['dispatched'] = false;
    final PatchbayServiceHost host = PatchbayServiceHost(
      applicationId: 'execution-conflict-test',
      registry: _registry(
        _descriptor(confirmationBudgetMs: 3000),
        payload: payload,
      ),
      catalog: () async => const <String, Object?>{},
      snapshot: () async => const <String, Object?>{},
      invoke: (_, _, requestId) async =>
          PatchbayInvocation.accepted(requestId: requestId).toJson(),
    );

    final Map<String, Object?> response = await host.dispatchInvoke(
      'patchbay.fixturejob',
      const <String, Object?>{},
      'request-conflict',
    );

    expect(response['admission'], 'accepted');
    expect(response['details'], containsPair('legacyDispatchedConflict', true));
    expect(
      (response['payload']! as Map<Object?, Object?>)['execution'],
      containsPair('classification', 'deviceConfirmed'),
    );
  });
}

Matcher _issue(String reason, String fieldSuffix) =>
    isA<PatchbayResponseValidationIssue>()
        .having(
          (PatchbayResponseValidationIssue issue) => issue.reason,
          'reason',
          reason,
        )
        .having(
          (PatchbayResponseValidationIssue issue) => issue.field,
          'field',
          endsWith(fieldSuffix),
        );

Map<String, Object?> _evidence(
  String classification,
  String factSource, {
  String? priorSource,
  int? priorAtMs,
}) => <String, Object?>{
  'execution': <String, Object?>{
    'classification': classification,
    'factSource': factSource,
    'observedAtMs': null,
    'reasonCode': null,
    if (priorSource != null) 'priorValueSource': priorSource,
    if (priorAtMs != null) 'priorObservedAtMs': priorAtMs,
  },
};

PatchbayCommandDescriptor _descriptor({
  PatchbayCommandMode mode = PatchbayCommandMode.job,
  int? unchangedMaxAgeMs,
  int? confirmationBudgetMs,
  bool weakConfirmationCompletes = false,
}) => PatchbayCommandDescriptor(
  name: 'patchbay.fixturejob',
  summary: 'Fixture job.',
  plane: PatchbayPlane.domain,
  mode: mode,
  sideEffect: PatchbaySideEffect.external,
  factSources: const <PatchbayFactSource>{
    PatchbayFactSource.appRecorded,
    PatchbayFactSource.commandEcho,
    PatchbayFactSource.deviceReported,
    PatchbayFactSource.uiObserved,
  },
  unchangedEvidenceMaxAgeMs: unchangedMaxAgeMs,
  confirmationBudgetMs: confirmationBudgetMs,
  weakConfirmationCompletes: weakConfirmationCompletes,
);

PatchbayCommandDescriptor _bindingDescriptor({
  required String name,
  required String resultField,
  required Set<PatchbayFactSource> factSources,
  bool weakConfirmationCompletes = false,
}) => PatchbayCommandDescriptor(
  name: name,
  summary: 'Binding fixture.',
  plane: PatchbayPlane.domain,
  mode: PatchbayCommandMode.job,
  sideEffect: PatchbaySideEffect.external,
  factSources: factSources,
  responseSchema: PatchbayResponseSchema(
    accepted: const PatchbayResponseValueSchema(
      type: PatchbayResponseType.object,
    ),
    terminal: <String, PatchbayResponseValueSchema>{
      'completed': PatchbayResponseValueSchema(
        type: PatchbayResponseType.object,
        properties: <String, PatchbayResponseValueSchema>{
          resultField: const PatchbayResponseValueSchema(
            type: PatchbayResponseType.string,
          ),
        },
        required: <String>{resultField},
        additionalProperties: true,
      ),
      'failed': const PatchbayResponseValueSchema(
        type: PatchbayResponseType.object,
        additionalProperties: true,
      ),
      'cancelled': const PatchbayResponseValueSchema(
        type: PatchbayResponseType.object,
        additionalProperties: true,
      ),
    },
  ),
  confirmationBudgetMs: 3000,
  weakConfirmationCompletes: weakConfirmationCompletes,
);

Future<void> _settled(PatchbayJobRegistry jobs, String jobId) async {
  final PatchbayJobWaitResult result = (await jobs.waitForChange(
    jobId,
    afterSequence: 1,
    timeout: const Duration(seconds: 1),
  ))!;
  expect(result.outcome, PatchbayJobWaitOutcome.changed);
  expect(result.snapshot.terminal, isTrue);
}

PatchbayCommandRegistry _registry(
  PatchbayCommandDescriptor descriptor, {
  Map<String, Object?>? payload,
}) => PatchbayCommandRegistry(<PatchbayCommandRegistration<Object?>>[
  PatchbayCommandRegistration<Map<String, Object?>>(
    descriptor: descriptor,
    decode: (arguments) => arguments,
    handle: (_, requestId) => PatchbayInvocation.accepted(
      requestId: requestId,
      payload: payload ?? const <String, Object?>{},
    ).toJson(),
  ),
]);
