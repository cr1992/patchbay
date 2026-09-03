import 'dart:async';
import 'dart:convert';
import 'dart:developer';

import 'package:patchbay/patchbay_host.dart';
import 'package:patchbay/patchbay_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('PatchbayJobRegistry response schema binding', () {
    test(
      'registry handler binds and preserves a valid terminal payload',
      () async {
        late PatchbayJobRegistry jobs;
        final PatchbayCommandRegistry commands = _commands(
          handle: (_, requestId) {
            final String jobId = jobs.start(
              source: PatchbayFactSource.deviceReported,
              body: () async => const <String, Object?>{'result': 'ready'},
            );
            return PatchbayInvocation.accepted(
              requestId: requestId,
              jobId: jobId,
            ).toJson();
          },
        );
        jobs = PatchbayJobRegistry(commandRegistry: commands);

        final Map<String, Object?> admission = await commands.dispatch(
          'patchbay.fixturejob',
          const <String, Object?>{},
          'request-1',
        );
        final String jobId = admission['jobId']! as String;
        expect(admission['requestId'], 'request-1');
        await _settled(jobs, jobId);

        final PatchbayJobSnapshot snapshot = jobs.snapshot(jobId)!;
        expect(snapshot.jobId, jobId);
        expect(
          snapshot.events.map((PatchbayJobEvent event) => event.sequence),
          <int>[1, 2],
        );
        expect(
          snapshot.events.map((PatchbayJobEvent event) => event.operation),
          everyElement('patchbay.fixturejob'),
        );
        expect(snapshot.events.last.phase, PatchbayJobPhase.completed);
        expect(snapshot.events.last.reason, isNull);
        expect(snapshot.events.last.payload, <String, Object?>{
          'result': 'ready',
        });
        expect(
          PatchbayJobSnapshotWire.fromJson(snapshot.toJson()).jobId,
          jobId,
        );
      },
    );

    test(
      'matching command remains source-compatible inside dispatch',
      () async {
        late PatchbayJobRegistry jobs;
        final PatchbayCommandRegistry commands = _commands(
          handle: (_, requestId) {
            final String jobId = jobs.start(
              command: 'patchbay.fixturejob',
              source: PatchbayFactSource.appRecorded,
              body: () async => const <String, Object?>{'result': 'compatible'},
            );
            return PatchbayInvocation.accepted(
              requestId: requestId,
              jobId: jobId,
            ).toJson();
          },
        );
        jobs = PatchbayJobRegistry(commandRegistry: commands);

        final Map<String, Object?> admission = await commands.dispatch(
          'patchbay.fixturejob',
          const <String, Object?>{},
          'request-compatible',
        );
        final String jobId = admission['jobId']! as String;
        await _settled(jobs, jobId);
        expect(
          jobs.snapshot(jobId)!.events.last.payload,
          const <String, Object?>{'result': 'compatible'},
        );
      },
    );

    for (final bool explicitAdapterApi in <bool>[false, true]) {
      test(
        'handler cannot cross-bind another descriptor '
        '${explicitAdapterApi ? 'through adapter API' : 'through command'}',
        () async {
          late PatchbayJobRegistry jobs;
          var bodyCalled = false;
          final PatchbayCommandRegistry commands = _commandsWithHandlers(
            <String, PatchbayCommandHandler<Map<String, Object?>>>{
              'patchbay.alpha': (_, requestId) {
                final PatchbayJobBody body = () async {
                  bodyCalled = true;
                  return const <String, Object?>{'beta': 'must-not-start'};
                };
                if (explicitAdapterApi) {
                  jobs.startBoundToCommand(
                    command: 'patchbay.beta',
                    source: PatchbayFactSource.appRecorded,
                    body: body,
                  );
                } else {
                  jobs.start(
                    command: 'patchbay.beta',
                    source: PatchbayFactSource.appRecorded,
                    body: body,
                  );
                }
                return PatchbayInvocation.accepted(
                  requestId: requestId,
                ).toJson();
              },
              'patchbay.beta': (_, requestId) =>
                  PatchbayInvocation.accepted(requestId: requestId).toJson(),
            },
          );
          jobs = PatchbayJobRegistry(commandRegistry: commands);

          await expectLater(
            commands.dispatch(
              'patchbay.alpha',
              const <String, Object?>{},
              'request-cross-bind',
            ),
            throwsArgumentError,
          );
          expect(jobs.totalJobs, 0);
          expect(bodyCalled, isFalse);
        },
      );
    }

    for (final bool explicitAdapterApi in <bool>[false, true]) {
      test(
        'handler cannot use a ledger bound to another registry '
        '${explicitAdapterApi ? 'through adapter API' : 'with omitted command'}',
        () async {
          var bodyCalled = false;
          final PatchbayJobRegistry foreignJobs = PatchbayJobRegistry(
            commandRegistry: _commands(),
          );
          final PatchbayCommandRegistry commands = _commandsWithHandlers(
            <String, PatchbayCommandHandler<Map<String, Object?>>>{
              'patchbay.alpha': (_, requestId) {
                final PatchbayJobBody body = () async {
                  bodyCalled = true;
                  return const <String, Object?>{'result': 'must-not-start'};
                };
                if (explicitAdapterApi) {
                  foreignJobs.startBoundToCommand(
                    command: 'patchbay.fixturejob',
                    source: PatchbayFactSource.appRecorded,
                    body: body,
                  );
                } else {
                  foreignJobs.start(
                    source: PatchbayFactSource.appRecorded,
                    body: body,
                  );
                }
                return PatchbayInvocation.accepted(
                  requestId: requestId,
                ).toJson();
              },
            },
          );

          await expectLater(
            commands.dispatch(
              'patchbay.alpha',
              const <String, Object?>{},
              'request-foreign-registry',
            ),
            throwsStateError,
          );
          expect(foreignJobs.totalJobs, 0);
          expect(bodyCalled, isFalse);
        },
      );
    }

    test(
      'unbound legacy ledger remains usable in another registry scope',
      () async {
        final PatchbayJobRegistry jobs = PatchbayJobRegistry();
        late String jobId;
        final PatchbayCommandRegistry commands = _commandsWithHandlers(
          <String, PatchbayCommandHandler<Map<String, Object?>>>{
            'patchbay.alpha': (_, requestId) {
              jobId = jobs.start(
                source: PatchbayFactSource.appRecorded,
                body: () async => const <String, Object?>{
                  'consumerField': 'legacy-kept',
                },
              );
              return PatchbayInvocation.accepted(
                requestId: requestId,
                jobId: jobId,
              ).toJson();
            },
          },
        );

        await commands.dispatch(
          'patchbay.alpha',
          const <String, Object?>{},
          'request-unbound-foreign-scope',
        );
        await _settled(jobs, jobId);
        expect(jobs.snapshot(jobId)!.events.last.payload, <String, Object?>{
          'consumerField': 'legacy-kept',
        });
      },
    );

    test(
      'nested async dispatch restores the outer descriptor identity',
      () async {
        late PatchbayCommandRegistry commands;
        late PatchbayJobRegistry jobs;
        final Map<String, String> jobIds = <String, String>{};
        commands = _commandsWithHandlers(
          <String, PatchbayCommandHandler<Map<String, Object?>>>{
            'patchbay.outer': (_, requestId) async {
              await commands.dispatch(
                'patchbay.inner',
                const <String, Object?>{},
                'request-inner',
              );
              await Future<void>.delayed(Duration.zero);
              jobIds['outer'] = jobs.start(
                source: PatchbayFactSource.appRecorded,
                body: () async => const <String, Object?>{'outer': 'ready'},
              );
              return PatchbayInvocation.accepted(
                requestId: requestId,
                jobId: jobIds['outer'],
              ).toJson();
            },
            'patchbay.inner': (_, requestId) async {
              await Future<void>.delayed(Duration.zero);
              jobIds['inner'] = jobs.start(
                source: PatchbayFactSource.appRecorded,
                body: () async => const <String, Object?>{'inner': 'ready'},
              );
              return PatchbayInvocation.accepted(
                requestId: requestId,
                jobId: jobIds['inner'],
              ).toJson();
            },
          },
        );
        jobs = PatchbayJobRegistry(commandRegistry: commands);

        await commands.dispatch(
          'patchbay.outer',
          const <String, Object?>{},
          'request-outer',
        );
        await Future.wait<void>(<Future<void>>[
          _settled(jobs, jobIds['inner']!),
          _settled(jobs, jobIds['outer']!),
        ]);

        expect(
          jobs.snapshot(jobIds['inner']!)!.events.last.payload,
          const <String, Object?>{'inner': 'ready'},
        );
        expect(
          jobs.snapshot(jobIds['outer']!)!.events.last.payload,
          const <String, Object?>{'outer': 'ready'},
        );
      },
    );

    test(
      'concurrent async dispatches do not share descriptor identity',
      () async {
        late PatchbayJobRegistry jobs;
        final Completer<void> alphaEntered = Completer<void>();
        final Completer<void> betaEntered = Completer<void>();
        final Map<String, String> jobIds = <String, String>{};
        final PatchbayCommandRegistry commands = _commandsWithHandlers(
          <String, PatchbayCommandHandler<Map<String, Object?>>>{
            'patchbay.alpha': (_, requestId) async {
              alphaEntered.complete();
              await betaEntered.future;
              jobIds['alpha'] = jobs.start(
                source: PatchbayFactSource.appRecorded,
                body: () async => const <String, Object?>{'alpha': 'ready'},
              );
              return PatchbayInvocation.accepted(
                requestId: requestId,
                jobId: jobIds['alpha'],
              ).toJson();
            },
            'patchbay.beta': (_, requestId) async {
              betaEntered.complete();
              await alphaEntered.future;
              await Future<void>.delayed(Duration.zero);
              jobIds['beta'] = jobs.start(
                source: PatchbayFactSource.appRecorded,
                body: () async => const <String, Object?>{'beta': 'ready'},
              );
              return PatchbayInvocation.accepted(
                requestId: requestId,
                jobId: jobIds['beta'],
              ).toJson();
            },
          },
        );
        jobs = PatchbayJobRegistry(commandRegistry: commands);

        await Future.wait<Map<String, Object?>>(<Future<Map<String, Object?>>>[
          commands.dispatch(
            'patchbay.alpha',
            const <String, Object?>{},
            'request-alpha',
          ),
          commands.dispatch(
            'patchbay.beta',
            const <String, Object?>{},
            'request-beta',
          ),
        ]);
        await Future.wait<void>(<Future<void>>[
          _settled(jobs, jobIds['alpha']!),
          _settled(jobs, jobIds['beta']!),
        ]);

        expect(
          jobs.snapshot(jobIds['alpha']!)!.events.last.payload,
          const <String, Object?>{'alpha': 'ready'},
        );
        expect(
          jobs.snapshot(jobIds['beta']!)!.events.last.payload,
          const <String, Object?>{'beta': 'ready'},
        );
      },
    );

    test('outside-dispatch adapter opts into exact command lookup', () async {
      final PatchbayCommandRegistry commands = _commands();
      final PatchbayJobRegistry jobs = PatchbayJobRegistry(
        commandRegistry: commands,
      );
      final String jobId = jobs.startBoundToCommand(
        command: 'patchbay.fixturejob',
        source: PatchbayFactSource.appRecorded,
        body: () async => const <String, Object?>{'result': 'adapter-ready'},
      );

      await _settled(jobs, jobId);
      expect(jobs.snapshot(jobId)!.events.last.payload, const <String, Object?>{
        'result': 'adapter-ready',
      });
    });

    for (final _InvalidTerminal fixture in <_InvalidTerminal>[
      _InvalidTerminal(
        name: 'completed missing field',
        phase: PatchbayJobPhase.completed,
        run: () async => const <String, Object?>{
          'password': 'completed-secret',
        },
        reason: 'missingField',
        field: r'$.payload.result',
        secret: 'completed-secret',
      ),
      _InvalidTerminal(
        name: 'failed wrong field type',
        phase: PatchbayJobPhase.failed,
        run: () async => throw const PatchbayJobFailure(
          reason: 'deviceFailed',
          payload: <String, Object?>{
            'errorCode': 7,
            'password': 'failed-secret',
          },
        ),
        reason: 'wrongType',
        field: r'$.payload.errorCode',
        secret: 'failed-secret',
      ),
      _InvalidTerminal(
        name: 'cancelled unknown field',
        phase: PatchbayJobPhase.cancelled,
        run: () async => throw const PatchbayJobCancellationSignal(
          reason: 'userCancelled',
          payload: <String, Object?>{
            'cancelledBy': 'user',
            'password': 'cancelled-secret',
          },
        ),
        reason: 'unknownField',
        field: r'$.payload.password',
        secret: 'cancelled-secret',
      ),
    ]) {
      test('${fixture.name} is sanitized before ledger commit', () async {
        final PatchbayCommandRegistry commands = _commands();
        final PatchbayJobRegistry jobs = PatchbayJobRegistry(
          commandRegistry: commands,
        );
        final String jobId = jobs.startBoundToCommand(
          command: 'patchbay.fixturejob',
          source: PatchbayFactSource.appRecorded,
          body: fixture.run,
        );

        await _settled(jobs, jobId);
        final PatchbayJobSnapshot snapshot = jobs.snapshot(jobId)!;
        final PatchbayJobEvent terminal = snapshot.events.last;
        final Map<Object?, Object?> rejection =
            terminal.payload['rejection']! as Map<Object?, Object?>;
        final Map<Object?, Object?> details =
            rejection['details']! as Map<Object?, Object?>;

        expect(snapshot.jobId, jobId);
        expect(snapshot.events, hasLength(2));
        expect(terminal.sequence, 2);
        expect(terminal.phase, fixture.phase);
        expect(terminal.reason, 'providerProtocolViolation');
        expect(rejection['code'], 'providerProtocolViolation');
        expect(details['reason'], fixture.reason);
        expect(details['field'], fixture.field);
        expect(snapshot.toJson().toString(), isNot(contains(fixture.secret)));
      });
    }

    test('schema is frozen when the job starts', () async {
      final Map<String, PatchbayResponseValueSchema> completedProperties =
          <String, PatchbayResponseValueSchema>{
            'result': const PatchbayResponseValueSchema(
              type: PatchbayResponseType.string,
            ),
          };
      final PatchbayResponseSchema responseSchema = PatchbayResponseSchema(
        accepted: _emptyObject,
        terminal: <String, PatchbayResponseValueSchema>{
          'completed': PatchbayResponseValueSchema(
            type: PatchbayResponseType.object,
            properties: completedProperties,
            required: const <String>{'result'},
          ),
          'failed': _terminalObject('errorCode'),
          'cancelled': _terminalObject('cancelledBy'),
        },
      );
      final PatchbayCommandRegistry commands = _commands(
        responseSchema: responseSchema,
      );
      final PatchbayJobRegistry jobs = PatchbayJobRegistry(
        commandRegistry: commands,
      );
      final Completer<Map<String, Object?>> body =
          Completer<Map<String, Object?>>();
      final String jobId = jobs.startBoundToCommand(
        command: 'patchbay.fixturejob',
        source: PatchbayFactSource.appRecorded,
        body: () => body.future,
      );

      completedProperties
        ..clear()
        ..['password'] = const PatchbayResponseValueSchema(
          type: PatchbayResponseType.string,
        );
      body.complete(const <String, Object?>{'password': 'late-secret'});
      await _settled(jobs, jobId);

      final PatchbayJobEvent terminal = jobs.snapshot(jobId)!.events.last;
      expect(terminal.reason, 'providerProtocolViolation');
      expect(terminal.payload.toString(), isNot(contains('late-secret')));
      expect(
        ((terminal.payload['rejection']! as Map<Object?, Object?>)['details']!
            as Map<Object?, Object?>)['field'],
        r'$.payload.result',
      );
    });

    test('VM and direct adapters expose the same sanitized terminal', () async {
      const String secret = 'transport-secret';
      final PatchbayCommandRegistry commands = _commands();
      final PatchbayJobRegistry jobs = PatchbayJobRegistry(
        commandRegistry: commands,
      );
      final String jobId = jobs.startBoundToCommand(
        command: 'patchbay.fixturejob',
        source: PatchbayFactSource.appRecorded,
        body: () async => const <String, Object?>{'password': secret},
      );
      await _settled(jobs, jobId);
      final PatchbayServiceHost host = PatchbayServiceHost(
        applicationId: 'job-schema-parity',
        registrar: (_, _) {},
        catalog: () async => <String, Object?>{
          'commands': <Object?>[
            <String, Object?>{
              'name': 'patchbay.job.get',
              'sideEffect': 'external',
              'retryPolicy': <String, Object?>{
                'maxAttempts': 2,
                'backoffMs': 0,
              },
            },
          ],
        },
        snapshot: () async => const <String, Object?>{},
        invoke: (_, _, requestId) async => PatchbayInvocation.accepted(
          requestId: requestId,
          jobId: jobId,
          payload: jobs.snapshot(jobId)!.toJson(),
        ).toJson(),
      );

      final Map<String, Object?> direct = await host.dispatchInvoke(
        'patchbay.job.get',
        const <String, Object?>{},
        'request-parity',
      );
      final ServiceExtensionResponse vmResponse = await host.handleInvoke(
        PatchbayServiceHost.invokeMethod,
        <String, String>{
          'command': 'patchbay.job.get',
          'args': '{}',
          'requestId': 'request-parity',
        },
      );
      final Map<String, Object?> vm = Map<String, Object?>.from(
        jsonDecode(vmResponse.result!) as Map<String, dynamic>,
      );

      expect(vm, direct);
      expect(direct['requestId'], 'request-parity');
      expect(direct['jobId'], jobId);
      expect(direct.toString(), isNot(contains(secret)));
      expect(direct.toString(), contains('providerProtocolViolation'));
    });

    for (final bool registryConfigured in <bool>[false, true]) {
      test(
        'legacy jobs keep free payloads outside dispatch '
        '${registryConfigured ? 'with a registry' : 'without a registry'}',
        () async {
          final PatchbayJobRegistry jobs = PatchbayJobRegistry(
            commandRegistry: registryConfigured ? _commands() : null,
          );
          final String jobId = jobs.start(
            source: PatchbayFactSource.appRecorded,
            body: () async => const <String, Object?>{
              'consumerField': 'kept-for-0.3',
            },
          );

          await _settled(jobs, jobId);
          expect(jobs.snapshot(jobId)!.events.last.payload, <String, Object?>{
            'consumerField': 'kept-for-0.3',
          });
        },
      );
    }

    test('outside-dispatch binding requires the explicit adapter API', () {
      final PatchbayCommandRegistry commands = _commands();
      final PatchbayJobRegistry bound = PatchbayJobRegistry(
        commandRegistry: commands,
      );

      expect(
        () => bound.start(
          command: 'patchbay.fixturejob',
          source: PatchbayFactSource.appRecorded,
          body: () async => const <String, Object?>{},
        ),
        throwsArgumentError,
      );
      expect(bound.totalJobs, 0);

      final PatchbayJobRegistry jobs = PatchbayJobRegistry();

      expect(
        () => jobs.startBoundToCommand(
          command: 'patchbay.fixturejob',
          source: PatchbayFactSource.appRecorded,
          body: () async => const <String, Object?>{},
        ),
        throwsArgumentError,
      );
      expect(jobs.totalJobs, 0);
    });
  });
}

const PatchbayResponseValueSchema _emptyObject = PatchbayResponseValueSchema(
  type: PatchbayResponseType.object,
);

PatchbayResponseValueSchema _terminalObject(String field) =>
    PatchbayResponseValueSchema(
      type: PatchbayResponseType.object,
      properties: <String, PatchbayResponseValueSchema>{
        field: const PatchbayResponseValueSchema(
          type: PatchbayResponseType.string,
        ),
      },
      required: <String>{field},
    );

PatchbayResponseSchema _responseSchema() => PatchbayResponseSchema(
  accepted: _emptyObject,
  terminal: <String, PatchbayResponseValueSchema>{
    'completed': _terminalObject('result'),
    'failed': _terminalObject('errorCode'),
    'cancelled': _terminalObject('cancelledBy'),
  },
);

PatchbayResponseSchema _responseSchemaForCompletedField(String field) =>
    PatchbayResponseSchema(
      accepted: _emptyObject,
      terminal: <String, PatchbayResponseValueSchema>{
        'completed': _terminalObject(field),
        'failed': _terminalObject('errorCode'),
        'cancelled': _terminalObject('cancelledBy'),
      },
    );

PatchbayCommandRegistry _commandsWithHandlers(
  Map<String, PatchbayCommandHandler<Map<String, Object?>>> handlers,
) => PatchbayCommandRegistry(<PatchbayCommandRegistration<Object?>>[
  for (final MapEntry<String, PatchbayCommandHandler<Map<String, Object?>>>
      entry
      in handlers.entries)
    PatchbayCommandRegistration<Map<String, Object?>>(
      descriptor: PatchbayCommandDescriptor(
        name: entry.key,
        summary: 'Fixture ${entry.key}.',
        plane: PatchbayPlane.domain,
        mode: PatchbayCommandMode.job,
        sideEffect: PatchbaySideEffect.appState,
        factSources: const <PatchbayFactSource>{PatchbayFactSource.appRecorded},
        responseSchema: _responseSchemaForCompletedField(
          entry.key.substring(entry.key.lastIndexOf('.') + 1),
        ),
      ),
      decode: (arguments) => arguments,
      handle: entry.value,
    ),
]);

PatchbayCommandRegistry _commands({
  PatchbayCommandHandler<Map<String, Object?>>? handle,
  PatchbayResponseSchema? responseSchema,
}) => PatchbayCommandRegistry(<PatchbayCommandRegistration<Object?>>[
  PatchbayCommandRegistration<Map<String, Object?>>(
    descriptor: PatchbayCommandDescriptor(
      name: 'patchbay.fixturejob',
      summary: 'Fixture job.',
      plane: PatchbayPlane.domain,
      mode: PatchbayCommandMode.job,
      sideEffect: PatchbaySideEffect.appState,
      factSources: const <PatchbayFactSource>{PatchbayFactSource.appRecorded},
      responseSchema: responseSchema ?? _responseSchema(),
    ),
    decode: (arguments) => arguments,
    handle:
        handle ??
        (_, requestId) =>
            PatchbayInvocation.accepted(requestId: requestId).toJson(),
  ),
]);

Future<void> _settled(PatchbayJobRegistry jobs, String jobId) async {
  final PatchbayJobWaitResult result = (await jobs.waitForChange(
    jobId,
    afterSequence: 1,
    timeout: const Duration(seconds: 1),
  ))!;
  expect(result.outcome, PatchbayJobWaitOutcome.changed);
  expect(result.snapshot.terminal, isTrue);
}

final class _InvalidTerminal {
  const _InvalidTerminal({
    required this.name,
    required this.phase,
    required this.run,
    required this.reason,
    required this.field,
    required this.secret,
  });

  final String name;
  final PatchbayJobPhase phase;
  final PatchbayJobBody run;
  final String reason;
  final String field;
  final String secret;
}
