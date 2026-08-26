import 'dart:async';

import 'command_dispatch_scope.dart';
import 'command_descriptor.dart';
import 'execution_evidence.dart';
import 'invocation.dart';
import 'invocation_cancellation.dart';
import 'response_schema.dart';

typedef PatchbayCommandDecoder<T> = T Function(Map<String, Object?> arguments);
typedef PatchbayCommandGate<T> =
    FutureOr<Map<String, Object?>?> Function(T request, String requestId);
typedef PatchbayCommandHandler<T> =
    FutureOr<Map<String, Object?>> Function(T request, String requestId);
typedef PatchbayCommandFailureHandler =
    Map<String, Object?> Function(
      Object failure,
      Map<String, Object?> arguments,
      String requestId,
      PatchbayCommandDescriptor descriptor,
    );

/// One indivisible protocol-owned command registration.
///
/// The descriptor, request decoder, optional gate stage and handler live in
/// this object so the catalog and dispatcher cannot acquire separate command
/// name tables. Consumer-owned business commands intentionally stay outside
/// this type and use the host's external fallback.
final class PatchbayCommandRegistration<T> {
  const PatchbayCommandRegistration({
    required this.descriptor,
    required PatchbayCommandDecoder<T> decode,
    required PatchbayCommandHandler<T> handle,
    PatchbayCommandGate<T>? gate,
    PatchbayCommandFailureHandler? onDecodeFailure,
    PatchbayCommandFailureHandler? onExecutionFailure,
    this.available = true,
  }) : _decode = decode,
       _gate = gate,
       _handle = handle,
       _handleWithContext = null,
       _onDecodeFailure = onDecodeFailure,
       _onExecutionFailure = onExecutionFailure;

  const PatchbayCommandRegistration.contextAware({
    required this.descriptor,
    required PatchbayCommandDecoder<T> decode,
    required PatchbayContextCommandHandler<T> handle,
    PatchbayCommandGate<T>? gate,
    PatchbayCommandFailureHandler? onDecodeFailure,
    PatchbayCommandFailureHandler? onExecutionFailure,
    this.available = true,
  }) : _decode = decode,
       _gate = gate,
       _handle = null,
       _handleWithContext = handle,
       _onDecodeFailure = onDecodeFailure,
       _onExecutionFailure = onExecutionFailure;

  final PatchbayCommandDescriptor descriptor;
  final bool available;
  final PatchbayCommandDecoder<T> _decode;
  final PatchbayCommandGate<T>? _gate;
  final PatchbayCommandHandler<T>? _handle;
  final PatchbayContextCommandHandler<T>? _handleWithContext;
  final PatchbayCommandFailureHandler? _onDecodeFailure;
  final PatchbayCommandFailureHandler? _onExecutionFailure;

  Future<Map<String, Object?>> dispatch(
    Map<String, Object?> arguments,
    String requestId, {
    void Function(String result)? onGateResult,
    PatchbayInvocationContext? context,
  }) async {
    if (!available) {
      onGateResult?.call('notEvaluated');
      return PatchbayInvocation.rejected(
        requestId: requestId,
        rejection: const PatchbayRejection(code: 'commandNotRegistered'),
      ).toJson();
    }
    final T request;
    try {
      request = _decode(arguments);
    } on Object catch (failure) {
      onGateResult?.call('notEvaluated');
      final PatchbayCommandFailureHandler? recover = _onDecodeFailure;
      if (recover == null) rethrow;
      return recover(failure, arguments, requestId, descriptor);
    }
    final Map<String, Object?>? gateRejection = await _gate?.call(
      request,
      requestId,
    );
    if (gateRejection != null) {
      onGateResult?.call('rejected');
      return gateRejection;
    }
    onGateResult?.call(_gate == null ? 'notDeclared' : 'passed');
    try {
      final PatchbayContextCommandHandler<T>? contextHandler =
          _handleWithContext;
      if (contextHandler != null) {
        if (context == null) {
          throw StateError('context-aware registration requires a context');
        }
        return await contextHandler(request, requestId, context);
      }
      return await _handle!(request, requestId);
    } on Object catch (failure) {
      final PatchbayCommandFailureHandler? recover = _onExecutionFailure;
      if (recover == null) rethrow;
      return recover(failure, arguments, requestId, descriptor);
    }
  }
}

/// Transport-neutral catalog and dispatch table for protocol-owned commands.
final class PatchbayCommandRegistry {
  PatchbayCommandRegistry(
    Iterable<PatchbayCommandRegistration<Object?>> registrations,
  ) : _registrations =
          Map<String, PatchbayCommandRegistration<Object?>>.unmodifiable(
            _index(registrations),
          );

  factory PatchbayCommandRegistry.combine(
    Iterable<PatchbayCommandRegistry> registries,
  ) => PatchbayCommandRegistry(
    registries.expand(
      (PatchbayCommandRegistry registry) => registry._registrations.values,
    ),
  );

  final Map<String, PatchbayCommandRegistration<Object?>> _registrations;

  bool get isEmpty => _registrations.isEmpty;

  bool get hasResponseSchemas => _registrations.values.any(
    (PatchbayCommandRegistration<Object?> registration) =>
        registration.available &&
        registration.descriptor.responseSchema != null,
  );

  PatchbayResponseSchema? responseSchemaFor(String command) =>
      _registrations[command]?.descriptor.responseSchema;

  PatchbayExecutionContract? executionContractFor(String command) =>
      _registrations[command]?.descriptor.executionContract;

  List<PatchbayCommandDescriptor> get descriptors =>
      List<PatchbayCommandDescriptor>.unmodifiable(
        _registrations.values
            .where(
              (PatchbayCommandRegistration<Object?> registration) =>
                  registration.available,
            )
            .map(
              (PatchbayCommandRegistration<Object?> registration) =>
                  registration.descriptor,
            ),
      );

  bool handles(String command) => _registrations.containsKey(command);

  bool isContextAware(String command) =>
      _registrations[command]?._handleWithContext != null;

  /// Dispatches a registered command, or returns null for the external layer.
  Future<Map<String, Object?>?> tryDispatch(
    String command,
    Map<String, Object?> arguments,
    String requestId, {
    void Function(String result)? onGateResult,
    PatchbayInvocationContext? context,
  }) async {
    final PatchbayCommandRegistration<Object?>? registration =
        _registrations[command];
    if (registration == null) return null;
    return runInPatchbayCommandDispatchScope<Map<String, Object?>>(
      registry: this,
      descriptor: registration.descriptor,
      body: () => registration.dispatch(
        arguments,
        requestId,
        onGateResult: onGateResult,
        context: context,
      ),
    );
  }

  /// Dispatches within this registry and types an unknown command as rejected.
  Future<Map<String, Object?>> dispatch(
    String command,
    Map<String, Object?> arguments,
    String requestId, {
    PatchbayInvocationContext? context,
  }) async =>
      await tryDispatch(command, arguments, requestId, context: context) ??
      PatchbayInvocation.rejected(
        requestId: requestId,
        rejection: PatchbayRejection(
          code: 'commandNotRegistered',
          details: <String, Object?>{'command': command},
        ),
      ).toJson();

  static Map<String, PatchbayCommandRegistration<Object?>> _index(
    Iterable<PatchbayCommandRegistration<Object?>> registrations,
  ) {
    final Map<String, PatchbayCommandRegistration<Object?>> indexed =
        <String, PatchbayCommandRegistration<Object?>>{};
    for (final PatchbayCommandRegistration<Object?> registration
        in registrations) {
      validatePatchbayExecutionContract(
        registration.descriptor.executionContract,
      );
      if (registration.descriptor.weakConfirmationCompletes &&
          registration.descriptor.mode != PatchbayCommandMode.job) {
        throw ArgumentError(
          'weakConfirmationCompletes is only valid for job commands',
        );
      }
      if (registration.descriptor.retryPolicy != null) {
        throw ArgumentError(
          'retryPolicy is only valid on consumer external fallback commands',
        );
      }
      if (registration.descriptor.responseSchema
          case final PatchbayResponseSchema schema) {
        validatePatchbayResponseSchema(schema);
        if (registration.descriptor.mode == PatchbayCommandMode.job &&
            !schema.terminal.keys.toSet().containsAll(const <String>{
              'completed',
              'failed',
              'cancelled',
            })) {
          throw ArgumentError(
            'job response schema must declare every terminal phase',
          );
        }
      }
      final String name = registration.descriptor.name;
      if (indexed.containsKey(name)) {
        throw ArgumentError.value(name, 'registrations', 'duplicate command');
      }
      indexed[name] = registration;
    }
    return indexed;
  }
}
