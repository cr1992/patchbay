import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:patchbay/patchbay.dart';
import 'package:patchbay/src/host/invocation_coordinator.dart';
import 'package:test/test.dart';

// PB-050-37 keeps the reference model test-only: it describes the accepted
// lifecycle semantics without becoming a second runtime implementation. Each
// fixed-seed trace records only its last actions, so a failure is both bounded
// and reproducible through PATCHBAY_INVOCATION_SEED.
const int _defaultSeed = 0x5042494E; // ASCII `PBIN`.
const int _maxConcurrentInvocations = 4;

void main() {
  final int? replaySeed = int.tryParse(
    Platform.environment['PATCHBAY_INVOCATION_SEED'] ?? '',
  );
  final List<int> seeds = replaySeed == null
      ? List<int>.generate(
          32,
          (int index) => (_defaultSeed + index * 0x9E3779B1) & 0x7FFFFFFF,
          growable: false,
        )
      : <int>[replaySeed];

  setUpAll(() {
    printOnFailure(
      'Replay one trace with PATCHBAY_INVOCATION_SEED=<seed>; '
      'default base seed=$_defaultSeed',
    );
  });

  group('invocation lifecycle executable state model', () {
    test('seeded event traces preserve terminal and slot invariants', () async {
      for (final int seed in seeds) {
        final _LifecycleMachine machine = _LifecycleMachine(seed);
        await machine.run(steps: 96);
      }
    });

    test(
      'unconfirmed cancellation never releases execution capacity',
      () async {
        for (final PatchbayInvocationCancellationReason reason
            in PatchbayInvocationCancellationReason.values) {
          final InvocationCoordinator coordinator = InvocationCoordinator(
            maxConcurrentInvocations: 1,
            confirmationTimeout: Duration.zero,
          );
          final Completer<Map<String, Object?>> pipeline =
              Completer<Map<String, Object?>>();
          final PatchbayHostInvocationHandle first = coordinator.start(
            command: 'device.run',
            requestId: 'unconfirmed-${reason.name}',
            ownerToken: _ownerToken(reason.index),
            deadline: null,
            contextAware: true,
            pipeline: (_) => pipeline.future,
          );

          final PatchbayInvocationCancellationResult cancellation =
              await coordinator.cancel(
                command: 'device.run',
                requestId: 'unconfirmed-${reason.name}',
                ownerToken: _ownerToken(reason.index),
                reason: reason,
              );
          expect(
            cancellation.outcome,
            PatchbayInvocationCancellationOutcome.unconfirmed,
          );
          expect(
            cancellation.confirmation,
            PatchbayInvocationConfirmationState.pending,
          );
          expect(coordinator.running, 1);

          final PatchbayHostInvocationHandle blocked = coordinator.start(
            command: 'device.run',
            requestId: 'blocked-${reason.name}',
            ownerToken: _ownerToken(reason.index + 10),
            deadline: null,
            contextAware: true,
            pipeline: (_) =>
                fail('a capacity rejection must not run a handler'),
          );
          expect(
            _rejectionCode(await blocked.response),
            'invocationCapacityExceeded',
          );
          expect(coordinator.running, 1);

          pipeline.complete(_accepted('unconfirmed-${reason.name}'));
          await first.lifecycle;
          expect(coordinator.running, 0);
          expect(coordinator.activeOwners, 0);
        }
      },
    );

    test('drain rejects every later start without creating an owner', () async {
      final InvocationCoordinator coordinator = InvocationCoordinator(
        maxConcurrentInvocations: 2,
        confirmationTimeout: Duration.zero,
      );
      final Completer<Map<String, Object?>> pipeline =
          Completer<Map<String, Object?>>();
      final PatchbayHostInvocationHandle active = coordinator.start(
        command: 'device.run',
        requestId: 'before-dispose',
        ownerToken: _ownerToken(100),
        deadline: null,
        contextAware: true,
        pipeline: (_) => pipeline.future,
      );
      await coordinator.drain(Duration.zero);
      expect(coordinator.activeOwners, 1);
      expect(coordinator.running, 1);

      for (var index = 0; index < 32; index += 1) {
        final PatchbayHostInvocationHandle rejected = coordinator.start(
          command: 'device.run',
          requestId: 'after-dispose-$index',
          ownerToken: _ownerToken(index + 101),
          deadline: null,
          contextAware: index.isEven,
          pipeline: (_) => fail('drained coordinator accepted a new owner'),
        );
        expect(_rejectionCode(await rejected.response), 'hostDisposed');
        expect(coordinator.activeOwners, 1);
        expect(coordinator.running, 1);
      }

      pipeline.complete(_accepted('before-dispose'));
      await active.lifecycle;
      expect(coordinator.activeOwners, 0);
      expect(coordinator.running, 0);
    });
  });

  group('requestId replay property', () {
    test(
      'in-flight and settled retries never run a second side effect',
      () async {
        for (final int seed in seeds) {
          final Random random = Random(seed);
          final bool idempotent = seed.isEven;
          final Map<String, Completer<Map<String, Object?>>> providers =
              <String, Completer<Map<String, Object?>>>{};
          final Map<String, int> sideEffects = <String, int>{};
          final PatchbayServiceHost host = _replayHost(
            idempotent: idempotent,
            invoke: (_, _, String requestId) {
              sideEffects.update(
                requestId,
                (int count) => count + 1,
                ifAbsent: () => 1,
              );
              return providers[requestId]!.future;
            },
          );

          final int requestCount = 6 + random.nextInt(7);
          for (var request = 0; request < requestCount; request += 1) {
            final String requestId = 'seed-$seed-request-$request';
            final Map<String, Object?> arguments = <String, Object?>{
              'value': random.nextInt(1000),
            };
            providers[requestId] = Completer<Map<String, Object?>>();

            final Future<Map<String, Object?>> first = host.dispatchInvoke(
              'device.write',
              arguments,
              requestId,
            );
            await _flushAsyncWork();
            expect(
              sideEffects[requestId],
              1,
              reason: 'seed=$seed request=$request did not acquire one owner',
            );

            final int retryCount = 1 + random.nextInt(4);
            final List<Future<Map<String, Object?>>> retries =
                <Future<Map<String, Object?>>>[];
            for (var retry = 0; retry < retryCount; retry += 1) {
              retries.add(
                host.dispatchInvoke('device.write', arguments, requestId),
              );
            }
            expect(
              sideEffects[requestId],
              1,
              reason: 'seed=$seed request=$request replayed in-flight work',
            );

            if (random.nextBool()) {
              final Map<String, Object?> conflict = await host.dispatchInvoke(
                'device.write',
                <String, Object?>{'value': -1},
                requestId,
              );
              expect(_rejectionCode(conflict), 'requestIdConflict');
              expect(sideEffects[requestId], 1);
            }

            providers[requestId]!.complete(
              PatchbayInvocation.accepted(
                requestId: requestId,
                payload: <String, Object?>{'effect': request},
              ).toJson(),
            );
            final Map<String, Object?> firstResult = await first;
            final List<Map<String, Object?>> retryResults = await Future.wait(
              retries,
            );
            for (final Map<String, Object?> result in retryResults) {
              if (idempotent) {
                expect(result, firstResult);
              } else {
                expect(_rejectionCode(result), 'duplicateRequestId');
              }
            }

            final Map<String, Object?> settledRetry = await host.dispatchInvoke(
              'device.write',
              arguments,
              requestId,
            );
            if (idempotent) {
              expect(settledRetry, firstResult);
            } else {
              expect(_rejectionCode(settledRetry), 'duplicateRequestId');
            }
            expect(
              sideEffects[requestId],
              1,
              reason: 'seed=$seed request=$request replayed settled work',
            );
          }

          expect(
            sideEffects.values,
            everyElement(1),
            reason: 'seed=$seed idempotent=$idempotent',
          );
        }
      },
    );
  });
}

final class _LifecycleMachine {
  _LifecycleMachine(this.seed)
    : _random = Random(seed),
      _coordinator = InvocationCoordinator(
        maxConcurrentInvocations: _maxConcurrentInvocations,
        confirmationTimeout: Duration.zero,
      ),
      _model = _LifecycleReference(_maxConcurrentInvocations);

  final int seed;
  final Random _random;
  final InvocationCoordinator _coordinator;
  final _LifecycleReference _model;
  final Map<int, _ControlledInvocation> _actual =
      <int, _ControlledInvocation>{};
  final List<String> _recentTrace = <String>[];
  var _nextId = 0;

  Future<void> run({required int steps}) async {
    final int drainStep = steps * 2 ~/ 3 + _random.nextInt(steps ~/ 3);
    for (var step = 0; step < steps; step += 1) {
      if (step == drainStep) {
        await _drain();
      } else if (_actual.isEmpty) {
        await _start();
      } else {
        final int action = _random.nextInt(100);
        if (action < 36) {
          await _start();
        } else if (action < 65) {
          await _cancel();
        } else if (action < 80) {
          _completeConfirmation();
        } else {
          _settle();
        }
      }
      await _flushAsyncWork();
      _assertInvariants(step);
    }

    for (final _ControlledInvocation invocation in _actual.values) {
      if (!invocation.pipeline.isCompleted) {
        invocation.pipeline.complete(_accepted(invocation.requestId));
        _model.settle(invocation.id);
      }
    }
    await _flushAsyncWork();
    _assertInvariants(steps);
    expect(
      _coordinator.running,
      0,
      reason: _reason(steps, 'the final settlement leaked a slot'),
    );
    expect(
      _coordinator.activeOwners,
      0,
      reason: _reason(steps, 'the final settlement leaked an owner'),
    );
    for (final _ControlledInvocation invocation in _actual.values) {
      expect(
        invocation.terminalCount,
        1,
        reason: _reason(steps, 'owner ${invocation.id} terminal count'),
      );
      expect(
        invocation.releaseCount,
        1,
        reason: _reason(steps, 'owner ${invocation.id} release count'),
      );
    }
  }

  Future<void> _start() async {
    final int id = _nextId;
    _nextId += 1;
    final bool contextAware = _random.nextInt(5) != 0;
    final _ConfirmationMode mode = contextAware
        ? _ConfirmationMode.values[_random.nextInt(
            _ConfirmationMode.values.length,
          )]
        : _ConfirmationMode.absent;
    final _ControlledInvocation invocation = _ControlledInvocation(
      id: id,
      seed: seed,
      contextAware: contextAware,
      confirmationMode: mode,
    );
    final bool expectedAccepted = _model.canStart;
    final int ownersBefore = _coordinator.activeOwners;
    final PatchbayHostInvocationHandle handle = _coordinator.start(
      command: invocation.command,
      requestId: invocation.requestId,
      ownerToken: invocation.ownerToken,
      deadline: null,
      contextAware: contextAware,
      pipeline: invocation.run,
      onCancellationResponse: (_) => invocation.cancellationResponses += 1,
    );
    final bool accepted = _coordinator.activeOwners == ownersBefore + 1;
    _record('start($id,$contextAware,${mode.name})=$accepted');
    expect(
      accepted,
      expectedAccepted,
      reason: _reason(-1, 'model and coordinator disagreed on admission'),
    );
    if (!accepted) {
      final String? code = _rejectionCode(await handle.response);
      expect(
        code,
        _model.accepting ? 'invocationCapacityExceeded' : 'hostDisposed',
        reason: _reason(-1, 'unexpected start rejection'),
      );
      return;
    }

    handle.response.then<void>(
      (_) => invocation.terminalCount += 1,
      onError: (Object _, StackTrace __) => invocation.terminalCount += 1,
    );
    handle.lifecycle.then<void>((_) => invocation.releaseCount += 1);
    _actual[id] = invocation;
    _model.accept(invocation);
  }

  Future<void> _cancel() async {
    if (_actual.isEmpty) return;
    final List<_ControlledInvocation> active = _actual.values
        .where(
          (_ControlledInvocation invocation) =>
              !_model.owner(invocation.id).settled,
        )
        .toList(growable: false);
    final _ControlledInvocation invocation =
        active.isNotEmpty && _random.nextInt(5) != 0
        ? _pick(active)
        : _pick(_actual.values);
    final PatchbayInvocationCancellationReason reason =
        PatchbayInvocationCancellationReason.values[_random.nextInt(
          PatchbayInvocationCancellationReason.values.length,
        )];
    final PatchbayInvocationCancellationResult result = await _coordinator
        .cancel(
          command: invocation.command,
          requestId: invocation.requestId,
          ownerToken: invocation.ownerToken,
          reason: reason,
        );
    _record('cancel(${invocation.id},${reason.name})=${result.outcome.name}');
    _model.cancel(invocation.id);
  }

  void _completeConfirmation() {
    final List<_ControlledInvocation> candidates = _actual.values
        .where(
          (_ControlledInvocation invocation) =>
              invocation.confirmationMode == _ConfirmationMode.controlled &&
              !invocation.confirmation.isCompleted,
        )
        .toList(growable: false);
    if (candidates.isEmpty) return;
    final _ControlledInvocation invocation = _pick(candidates);
    invocation.confirmation.complete();
    _model.confirm(invocation.id);
    _record('confirm(${invocation.id})');
  }

  void _settle() {
    final List<_ControlledInvocation> candidates = _actual.values
        .where(
          (_ControlledInvocation invocation) =>
              !invocation.pipeline.isCompleted,
        )
        .toList(growable: false);
    if (candidates.isEmpty) return;
    final _ControlledInvocation invocation = _pick(candidates);
    invocation.pipeline.complete(_accepted(invocation.requestId));
    _model.settle(invocation.id);
    _record('settle(${invocation.id})');
  }

  Future<void> _drain() async {
    await _coordinator.drain(Duration.zero);
    _model.drain();
    _record('drain()');
  }

  void _assertInvariants(int step) {
    expect(
      _coordinator.running,
      _model.running,
      reason: _reason(step, 'execution slot accounting diverged'),
    );
    expect(
      _coordinator.activeOwners,
      _model.activeOwners,
      reason: _reason(step, 'active owner accounting diverged'),
    );
    expect(
      _coordinator.running,
      inInclusiveRange(0, _maxConcurrentInvocations),
      reason: _reason(step, 'running count left its closed range'),
    );

    for (final _ControlledInvocation invocation in _actual.values) {
      final _ModelInvocation expected = _model.owner(invocation.id);
      expect(
        invocation.terminalCount,
        expected.terminal ? 1 : 0,
        reason: _reason(step, 'owner ${invocation.id} terminal arbitration'),
      );
      expect(
        invocation.terminalCount,
        lessThanOrEqualTo(1),
        reason: _reason(step, 'owner ${invocation.id} completed twice'),
      );
      expect(
        invocation.releaseCount,
        expected.released ? 1 : 0,
        reason: _reason(step, 'owner ${invocation.id} slot release'),
      );
      expect(
        invocation.releaseCount,
        lessThanOrEqualTo(1),
        reason: _reason(step, 'owner ${invocation.id} released twice'),
      );
      expect(
        invocation.confirmationCalls,
        expected.expectedConfirmationCalls,
        reason: _reason(step, 'owner ${invocation.id} confirmation calls'),
      );
      expect(
        invocation.cancellationResponses,
        expected.cancellationRequested ? 1 : 0,
        reason: _reason(step, 'owner ${invocation.id} cancellation response'),
      );
      if (expected.cancellationRequested &&
          !expected.released &&
          !expected.settled) {
        expect(
          invocation.releaseCount,
          0,
          reason: _reason(
            step,
            'unconfirmed owner ${invocation.id} released capacity',
          ),
        );
      }
    }
  }

  T _pick<T>(Iterable<T> values) {
    final List<T> candidates = values.toList(growable: false);
    return candidates[_random.nextInt(candidates.length)];
  }

  void _record(String action) {
    _recentTrace.add(action);
    if (_recentTrace.length > 16) _recentTrace.removeAt(0);
  }

  String _reason(int step, String message) =>
      '$message; seed=$seed step=$step trace=${_recentTrace.join(' -> ')}';
}

enum _ConfirmationMode { absent, immediate, controlled, failing }

final class _ControlledInvocation {
  _ControlledInvocation({
    required this.id,
    required this.seed,
    required this.contextAware,
    required this.confirmationMode,
  });

  final int id;
  final int seed;
  final bool contextAware;
  final _ConfirmationMode confirmationMode;
  final Completer<Map<String, Object?>> pipeline =
      Completer<Map<String, Object?>>();
  final Completer<void> confirmation = Completer<void>();
  var terminalCount = 0;
  var releaseCount = 0;
  var confirmationCalls = 0;
  var cancellationResponses = 0;

  String get command => 'device.run';
  String get requestId => 'seed-$seed-owner-$id';
  String get ownerToken => _ownerToken(id);

  Future<Map<String, Object?>> run(PatchbayInvocationContext context) {
    if (contextAware) {
      switch (confirmationMode) {
        case _ConfirmationMode.absent:
          break;
        case _ConfirmationMode.immediate:
          context.registerCancellationConfirmation((_) async {
            confirmationCalls += 1;
          });
        case _ConfirmationMode.controlled:
          context.registerCancellationConfirmation((_) {
            confirmationCalls += 1;
            return confirmation.future;
          });
        case _ConfirmationMode.failing:
          context.registerCancellationConfirmation((_) async {
            confirmationCalls += 1;
            throw StateError('expected model confirmation failure');
          });
      }
    }
    return pipeline.future;
  }
}

final class _LifecycleReference {
  _LifecycleReference(this.maxConcurrentInvocations);

  final int maxConcurrentInvocations;
  final Map<int, _ModelInvocation> _owners = <int, _ModelInvocation>{};
  var accepting = true;

  int get running =>
      _owners.values.where((_ModelInvocation owner) => !owner.released).length;
  int get activeOwners =>
      _owners.values.where((_ModelInvocation owner) => !owner.settled).length;
  bool get canStart => accepting && running < maxConcurrentInvocations;

  _ModelInvocation owner(int id) => _owners[id]!;

  void accept(_ControlledInvocation actual) {
    _owners[actual.id] = _ModelInvocation(
      contextAware: actual.contextAware,
      confirmationMode: actual.confirmationMode,
    );
  }

  void cancel(int id) {
    final _ModelInvocation owner = _owners[id]!;
    if (owner.settled || owner.cancellationRequested) return;
    owner
      ..cancellationRequested = true
      ..terminal = true;
    if (!owner.contextAware) return;
    switch (owner.confirmationMode) {
      case _ConfirmationMode.absent:
      case _ConfirmationMode.failing:
        break;
      case _ConfirmationMode.immediate:
        owner.released = true;
      case _ConfirmationMode.controlled:
        if (owner.confirmationReady) owner.released = true;
    }
  }

  void confirm(int id) {
    final _ModelInvocation owner = _owners[id]!;
    owner.confirmationReady = true;
    if (!owner.settled && owner.cancellationRequested) owner.released = true;
  }

  void settle(int id) {
    final _ModelInvocation owner = _owners[id]!;
    if (owner.settled) return;
    owner
      ..terminal = true
      ..released = true
      ..settled = true;
  }

  void drain() {
    if (!accepting) return;
    accepting = false;
    for (final int id in _owners.keys.toList(growable: false)) {
      cancel(id);
    }
  }
}

final class _ModelInvocation {
  _ModelInvocation({
    required this.contextAware,
    required this.confirmationMode,
  });

  final bool contextAware;
  final _ConfirmationMode confirmationMode;
  var cancellationRequested = false;
  var confirmationReady = false;
  var terminal = false;
  var released = false;
  var settled = false;

  int get expectedConfirmationCalls =>
      cancellationRequested &&
          contextAware &&
          confirmationMode != _ConfirmationMode.absent
      ? 1
      : 0;
}

PatchbayServiceHost _replayHost({
  required bool idempotent,
  required PatchbayInvocationSource invoke,
}) => PatchbayServiceHost(
  applicationId: 'com.example.invocation-model',
  registrar: (_, _) {},
  catalog: () async => <String, Object?>{
    'commands': <Object?>[
      PatchbayCommandDescriptor(
        name: 'device.write',
        summary: 'Property-test side effect.',
        plane: PatchbayPlane.domain,
        mode: PatchbayCommandMode.immediate,
        sideEffect: PatchbaySideEffect.external,
        factSources: const <PatchbayFactSource>{
          PatchbayFactSource.deviceReported,
        },
        retryPolicy: idempotent
            ? const PatchbayRetryPolicy(maxAttempts: 3, backoffMs: 0)
            : null,
      ).toJson(),
    ],
  },
  snapshot: () async => const <String, Object?>{},
  invoke: invoke,
);

Future<void> _flushAsyncWork() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

String _ownerToken(int id) => id.toRadixString(36).padLeft(22, 'A');

Map<String, Object?> _accepted(String requestId) =>
    PatchbayInvocation.accepted(requestId: requestId).toJson();

String? _rejectionCode(Map<String, Object?> response) {
  final Object? rejection = response['rejection'];
  return rejection is Map<Object?, Object?>
      ? rejection['code'] as String?
      : null;
}
