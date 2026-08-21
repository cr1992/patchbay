import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:patchbay/patchbay.dart';

export '../support/catalog_descriptor.dart';

import '../client.dart';
import '../command_registry.dart';
import '../request_id.dart';
import '../support/catalog_descriptor.dart';
import '../rpc_timeout.dart';
import '../runners/job_runner.dart';
import '../trace.dart';
import '../trace/trace_context.dart';
import '../ui_manifest.dart';

/// Invoker responsible for catalog command dispatch, RPC execution, retries, trace admission, and validation.
abstract final class CatalogInvoker {
  /// Invokes a command against the catalog, optionally waiting for job termination.
  static Future<Map<String, Object?>> invokeCataloged(
    PatchbayClient connection,
    Map<String, Object?> catalog,
    String command,
    Map<String, Object?> arguments, {
    required bool wait,
  }) async {
    final CatalogCommandDescriptor? descriptor = CatalogCommandDescriptor.find(
      catalog,
      command,
    );
    final Map<String, Object?> admission = await invokeAgainstCatalog(
      connection,
      catalog,
      command,
      arguments,
      deadline: declaredWait(arguments),
    );
    final bool serverWaitAvailable =
        CatalogCommandDescriptor.find(catalog, 'patchbay.job.wait') != null;
    if (!wait) return admission;
    final Map<String, Object?> terminal = await JobRunner.waitForJob(
      connection,
      catalog,
      admission,
      descriptor?.suggestedWaitTimeout,
      serverWaitAvailable: serverWaitAvailable,
      invokeAgainstCatalog: invokeAgainstCatalog,
    );
    return validateTerminalPayload(terminal, descriptor);
  }

  /// Low-level invocation against catalog, executing retries and tracing.
  static Future<Map<String, Object?>> invokeAgainstCatalog(
    PatchbayClient connection,
    Map<String, Object?> catalog,
    String command,
    Map<String, Object?> arguments, {
    Duration? deadline,
  }) async {
    final bool cataloged =
        CatalogCommandDescriptor.find(catalog, command) != null;
    final PatchbayRetryPolicy? retryPolicy = retryPolicyFor(catalog, command);
    final PatchbayTraceRecorder? trace = PatchbayTraceContext.currentRecorder;
    String? issuedRequestId;
    final Map<String, Object?> response;
    if (retryPolicy == null) {
      issuedRequestId = trace == null ? null : patchbayCliRequestId('trace');
      response = await connection.invoke(
        command: command,
        arguments: arguments,
        requestId: issuedRequestId,
        deadline: deadline,
      );
    } else {
      final String requestId = patchbayCliRequestId('retry');
      issuedRequestId = requestId;
      Map<String, Object?>? answer;
      for (var attempt = 1; attempt <= retryPolicy.maxAttempts; attempt += 1) {
        try {
          answer = await connection.invoke(
            command: command,
            arguments: arguments,
            requestId: requestId,
            deadline: deadline,
          );
          break;
        } on PatchbayTransportException catch (failure) {
          if (!_isRetryableTransportFailure(failure)) rethrow;
          if (attempt == retryPolicy.maxAttempts) rethrow;
          if (retryPolicy.backoffMs > 0) {
            await Future<void>.delayed(
              Duration(milliseconds: retryPolicy.backoffMs),
            );
          }
        }
      }
      response = answer!;
    }
    if (!cataloged && !_isCommandNotRegistered(response)) {
      throw PatchbayProtocolException(
        'catalogInvocationDrift',
        details: driftDetails(command, catalog, response),
      );
    }
    final CatalogCommandDescriptor? descriptor = CatalogCommandDescriptor.find(
      catalog,
      command,
    );
    final PatchbayResponseSchema? responseSchema = descriptor?.responseSchema;
    PatchbayExecutionValidationResult execution =
        const PatchbayExecutionValidationResult();
    final List<PatchbayResponseValidationIssue> issues =
        <PatchbayResponseValidationIssue>[];
    if (response['admission'] == 'accepted') {
      if (responseSchema != null) {
        issues.addAll(
          validatePatchbayResponsePayload(
            responseSchema.accepted,
            response['payload'],
          ),
        );
      }
      if (issues.isEmpty && descriptor != null) {
        execution = validatePatchbayExecutionEvidence(
          descriptor.executionContract,
          response['payload'],
          nowMs: evidenceNowMs(response['payload']),
        );
        issues.addAll(execution.issues);
      }
    }
    final Map<String, Object?> result = issues.isNotEmpty
        ? cliResponseSchemaViolation(response, issues)
        : withCliExecutionDetails(<String, Object?>{
            ...response,
            'schemaMode': responseSchema == null
                ? 'legacyUnvalidated'
                : 'validated',
          }, execution);
    if (trace != null) {
      final Object? rawRow = catalogRow(catalog, command);
      final String descriptorDigest = rawRow == null
          ? 'uncataloged'
          : PatchbayCatalogDigest.ofCommands(<Object?>[rawRow]).value;
      final Object? responseRequestId = result['requestId'];
      final String requestId = responseRequestId is String
          ? responseRequestId
          : issuedRequestId ?? '';
      trace.admission(
        command: command,
        requestId: requestId,
        arguments: arguments,
        sensitiveParameters:
            descriptor?.sensitiveParameters ?? const <String>{},
        descriptorDigest: descriptorDigest,
        response: result,
        includeLegacyPayload: PatchbayTraceContext.includesLegacyPayload,
      );
    }
    return result;
  }

  static Map<String, Object?> withCliExecutionDetails(
    Map<String, Object?> response,
    PatchbayExecutionValidationResult validation,
  ) {
    if (!validation.legacyDispatchedConflict) return response;
    final Object? existing = response['details'];
    return <String, Object?>{
      ...response,
      'details': <String, Object?>{
        if (existing is Map<Object?, Object?>)
          for (final MapEntry<Object?, Object?> entry in existing.entries)
            if (entry.key is String) entry.key! as String: entry.value,
        'legacyDispatchedConflict': true,
      },
    };
  }

  static bool _isRetryableTransportFailure(
    PatchbayTransportException failure,
  ) => <String>{
    patchbayAppUnresponsiveCode,
    'transportError',
    'transportUnavailable',
    'socketClosed',
  }.contains(failure.code);

  static PatchbayRetryPolicy? retryPolicyFor(
    Map<String, Object?> catalog,
    String command,
  ) {
    final Map<Object?, Object?>? row = catalogRow(catalog, command);
    if (row == null || !row.containsKey('retryPolicy')) return null;
    if (row['sideEffect'] != 'external') {
      throw const PatchbayProtocolException('catalogRetryPolicyInvalid');
    }
    try {
      return PatchbayRetryPolicy.fromJson(row['retryPolicy']);
    } on FormatException {
      throw const PatchbayProtocolException('catalogRetryPolicyInvalid');
    }
  }

  static Map<String, Object?> describeCatalogCommand(
    Map<String, Object?> catalog,
    String command,
  ) {
    final Map<Object?, Object?>? row = catalogRow(catalog, command);
    if (row == null) {
      throw PatchbayProtocolException(
        'commandNotRegistered',
        details: <String, Object?>{'command': command},
      );
    }
    final String retryEligibility;
    if (row['sideEffect'] != 'external') {
      retryEligibility = 'notExternal';
    } else if (!row.containsKey('retryPolicy')) {
      retryEligibility = 'notDeclared';
    } else {
      retryPolicyFor(catalog, command);
      retryEligibility = 'eligible';
    }
    return <String, Object?>{
      'command': <String, Object?>{
        for (final MapEntry<Object?, Object?> entry in row.entries)
          '${entry.key}': entry.value,
      },
      'schemaMode': row.containsKey('responseSchema')
          ? 'validated'
          : 'legacyUnvalidated',
      'retryEligibility': retryEligibility,
    };
  }

  static Map<Object?, Object?>? catalogRow(
    Map<String, Object?> catalog,
    String command,
  ) {
    final Object? rows = catalog['commands'];
    if (rows is! List<Object?>) return null;
    for (final Object? row in rows) {
      if (row is Map<Object?, Object?> && row['name'] == command) return row;
    }
    return null;
  }

  static Map<String, Object?> cliResponseSchemaViolation(
    Map<String, Object?> response,
    List<PatchbayResponseValidationIssue> issues,
  ) {
    final List<PatchbayResponseValidationIssue> capped = issues
        .take(patchbayResponseValidationMaxIssues)
        .toList(growable: false);
    final PatchbayResponseValidationIssue first = capped.first;
    return <String, Object?>{
      'schemaVersion': response['schemaVersion'] ?? 1,
      'requestId': response['requestId'] ?? '',
      'admission': 'rejected',
      'payload': const <String, Object?>{},
      'notice': null,
      'jobId': response['jobId'],
      'rejection': <String, Object?>{
        'code': 'providerProtocolViolation',
        'details': <String, Object?>{
          'reason': first.reason,
          'field': first.field,
          if (first.expected != null) 'expected': first.expected!,
          'violations': capped
              .map((PatchbayResponseValidationIssue issue) => issue.toJson())
              .toList(growable: false),
        },
      },
      'schemaMode': 'validated',
    };
  }

  static Map<String, Object?> driftDetails(
    String command,
    Map<String, Object?> catalog,
    Map<String, Object?> response,
  ) {
    final Map<Object?, Object?>? rejection = rejectionOf(response);
    final Object? details = rejection?['details'];
    final Object? reason = details is Map<Object?, Object?>
        ? details['reason']
        : null;
    final Object? violation = details is Map<Object?, Object?>
        ? details['catalog']
        : null;
    final Object? fromCatalog = rejectionOf(catalog)?['details'];
    return <String, Object?>{
      'command': command,
      if (rejection?['code'] case final String code) 'rejection': code,
      if (reason case final String value) 'reason': value,
      if (violation ?? fromCatalog case final Object value) 'catalog': value,
    };
  }

  static Map<Object?, Object?>? rejectionOf(Map<String, Object?> response) {
    if (response['admission'] != 'rejected') return null;
    final Object? rejection = response['rejection'];
    return rejection is Map<Object?, Object?> ? rejection : null;
  }

  static bool _isCommandNotRegistered(Map<String, Object?> response) =>
      rejectionOf(response)?['code'] == 'commandNotRegistered';

  static void refuseSensitiveArgv(
    Map<String, Object?> catalog,
    String command,
    Set<String> plaintextKeys,
  ) {
    if (plaintextKeys.isEmpty) return;
    final CatalogCommandDescriptor? descriptor = CatalogCommandDescriptor.find(
      catalog,
      command,
    );
    if (descriptor == null) return;
    for (final String name in plaintextKeys) {
      if (!descriptor.sensitiveParameters.contains(name)) continue;
      throw FormatException(
        '$command declares "$name" sensitive: it must come from --stdin, '
        'never from --args',
      );
    }
  }

  static Map<String, Object?> validateTerminalPayload(
    Map<String, Object?> response,
    CatalogCommandDescriptor? descriptor,
  ) {
    if (descriptor == null || response['admission'] != 'accepted') {
      return response;
    }
    final List<PatchbayResponseValidationIssue> issues =
        <PatchbayResponseValidationIssue>[];
    if (descriptor.responseSchema case final PatchbayResponseSchema schema) {
      issues.addAll(
        validatePatchbayTerminalPayload(schema, response['payload']),
      );
    }
    final PatchbayExecutionValidationResult execution =
        validateTerminalExecution(response, descriptor.executionContract);
    issues.addAll(execution.issues);
    if (issues.isNotEmpty) return cliResponseSchemaViolation(response, issues);
    return withCliExecutionDetails(<String, Object?>{
      ...response,
      'schemaMode': descriptor.responseSchema == null
          ? 'legacyUnvalidated'
          : 'validated',
    }, execution);
  }

  static PatchbayExecutionValidationResult validateTerminalExecution(
    Map<String, Object?> response,
    PatchbayExecutionContract contract,
  ) {
    final Object? payload = response['payload'];
    final Object? events = payload is Map<Object?, Object?>
        ? payload['events']
        : null;
    if (events is! List<Object?> || events.isEmpty) {
      return const PatchbayExecutionValidationResult();
    }
    final Object? event = events.last;
    if (event is! Map<Object?, Object?> || event['phase'] is! String) {
      return const PatchbayExecutionValidationResult();
    }
    final Object? rawAt = event['at'];
    final DateTime? at = rawAt is String ? DateTime.tryParse(rawAt) : null;
    final int eventIndex = events.length - 1;
    return validatePatchbayExecutionEvidence(
      contract,
      event['payload'],
      path:
          r'$.payload.events'
          '[$eventIndex].payload',
      terminalPhase: event['phase']! as String,
      nowMs:
          at?.millisecondsSinceEpoch ?? DateTime.now().millisecondsSinceEpoch,
    );
  }

  static int evidenceNowMs(Object? payload) {
    if (payload is Map<Object?, Object?>) {
      final Object? execution = payload['execution'];
      if (execution is Map<Object?, Object?>) {
        final Object? observedAtMs = execution['observedAtMs'];
        if (observedAtMs is int) return observedAtMs;
      }
    }
    return DateTime.now().millisecondsSinceEpoch;
  }

  static Duration? declaredWait(Map<String, Object?> arguments) {
    final Object? declared = arguments['timeoutMs'];
    return declared is int && declared > 0
        ? Duration(milliseconds: declared)
        : null;
  }

  static Map<String, Object?> withRevisionSource(
    Map<String, Object?> response,
  ) => withSource(response, 'revisionSource');

  static Map<String, Object?> withSource(
    Map<String, Object?> response,
    String field,
  ) => <String, Object?>{...response, field: 'navigation.current'};

  static int navigationRevision(Map<String, Object?> response) {
    final Object? payload = response['payload'];
    final Object? revision = payload is Map<Object?, Object?>
        ? payload['navigationRevision']
        : null;
    if (revision is! int || revision < 0) {
      throw const PatchbayProtocolException(
        'navigationRevisionContractViolated',
      );
    }
    return revision;
  }

  static String? navigationDestination(Map<String, Object?> response) {
    final Object? payload = response['payload'];
    if (payload is! Map<Object?, Object?>) {
      throw const PatchbayProtocolException(
        'navigationDestinationContractViolated',
      );
    }
    final Object? destination = payload['destinationId'];
    if (destination != null && destination is! String) {
      throw const PatchbayProtocolException(
        'navigationDestinationContractViolated',
      );
    }
    return destination as String?;
  }

  static PatchbayUiManifestSemanticsRuntime manifestSemanticsRuntime(
    Map<String, Object?> response,
  ) {
    final Object? payload = response['payload'];
    if (payload is! Map<String, Object?>) {
      throw const PatchbayProtocolException(
        'manifestSemanticsContractViolated',
        details: <String, Object?>{
          'reason': 'ui.semantics.tree did not return an object payload',
        },
      );
    }
    return decodePatchbayManifestSemantics(payload);
  }

  static PatchbayUiManifest? preReadUiManifest(ArgResults parsed) {
    if (PatchbayFriendlyCommandRegistry.specFor(parsed.rest)?.target !=
        PatchbayCommandTarget.localManifestVerification) {
      return null;
    }
    final PatchbayFriendlyInvocation? friendly =
        PatchbayFriendlyCommandRegistry.resolve(parsed.rest, parsed);
    if (friendly?.manifestPath case final String path) {
      return readUiManifest(path);
    }
    return null;
  }

  static PatchbayUiManifest readUiManifest(String path) {
    final PatchbayUiManifestFormat format = switch (path) {
      final String value when value.endsWith('.json') =>
        PatchbayUiManifestFormat.json,
      final String value
          when value.endsWith('.yaml') || value.endsWith('.yml') =>
        PatchbayUiManifestFormat.yaml,
      _ => throw PatchbayUiManifestException(
        'manifestFormatUnsupported',
        details: const <String, Object?>{
          'reason': 'manifest extension must be .json, .yaml, or .yml',
        },
      ),
    };
    final List<int> bytes;
    try {
      final RandomAccessFile file = File(path).openSync();
      try {
        bytes = file.readSync(patchbayUiManifestMaximumBytes + 1);
      } finally {
        file.closeSync();
      }
    } on FileSystemException catch (failure) {
      throw PatchbayUiManifestException(
        'manifestUnreadable',
        details: <String, Object?>{
          'path': path,
          'reason': ?failure.osError?.message,
        },
      );
    } on Object catch (failure) {
      throw PatchbayUiManifestException(
        'manifestUnreadable',
        details: <String, Object?>{
          'path': path,
          'reason': '${failure.runtimeType}',
        },
      );
    }
    if (bytes.length > patchbayUiManifestMaximumBytes) {
      throw const PatchbayUiManifestException(
        'manifestResourceLimit',
        details: <String, Object?>{
          'reason': 'manifest byte limit exceeded',
          'limit': patchbayUiManifestMaximumBytes,
        },
      );
    }
    final String source;
    try {
      source = utf8.decode(bytes);
    } on FormatException {
      throw const PatchbayUiManifestException(
        'manifestInvalid',
        details: <String, Object?>{
          'reason': 'manifest must be valid UTF-8',
          'line': 1,
          'column': 1,
        },
      );
    }
    return PatchbayUiManifest.parseSource(source, format: format);
  }
}
