import 'dart:convert';
import 'dart:developer';
import 'dart:isolate';

import '../features.dart';
import '../generated/core_wire.g.dart';
import '../invocation_cancellation.dart';
import '../version.dart';
import 'host_catalog.dart';
import 'host_invoker.dart';
import 'host_models.dart';
import 'host_snapshot.dart';

final class HostVmServiceRegistrar {
  HostVmServiceRegistrar({
    required this.applicationId,
    required this.appInstanceId,
    required this.features,
    required HostCatalogHandler catalogHandler,
    required HostSnapshotHandler snapshotHandler,
    required HostInvokerHandler invokerHandler,
    PatchbayExtensionRegistrar? registrar,
  }) : _catalogHandler = catalogHandler,
       _snapshotHandler = snapshotHandler,
       _invokerHandler = invokerHandler,
       _registrar = registrar ?? registerExtension;

  static const String identityMethod = 'ext.patchbay.identity';
  static const String catalogMethod = 'ext.patchbay.catalog';
  static const String snapshotMethod = 'ext.patchbay.snapshot';
  static const String invokeMethod = 'ext.patchbay.invoke';
  static const String cancelInvocationMethod = 'ext.patchbay.cancelInvocation';
  static const String snapshotRequestKey = 'request';

  final String applicationId;
  final String appInstanceId;
  final Set<PatchbayFeature> features;
  final HostCatalogHandler _catalogHandler;
  final HostSnapshotHandler _snapshotHandler;
  final HostInvokerHandler _invokerHandler;
  final PatchbayExtensionRegistrar _registrar;
  bool _registered = false;

  void register() {
    if (_registered) return;
    _registered = true;
    _registrar(identityMethod, handleIdentity);
    _registrar(catalogMethod, handleCatalog);
    _registrar(snapshotMethod, handleSnapshot);
    _registrar(invokeMethod, handleInvoke);
    _registrar(cancelInvocationMethod, handleCancelInvocation);
  }

  Future<ServiceExtensionResponse> handleSnapshot(
    String method,
    Map<String, String> parameters,
  ) async {
    if (method != snapshotMethod ||
        parameters.keys.any(
          (String key) => key != 'isolateId' && key != snapshotRequestKey,
        )) {
      return invalidParams('snapshot received unknown parameters');
    }
    final String? encoded = parameters[snapshotRequestKey];
    if (encoded == null) {
      return result(await _snapshotHandler.dispatchSnapshot());
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(encoded);
    } on FormatException {
      return invalidParams('$snapshotRequestKey must be a JSON object');
    }
    if (decoded is! Map<String, dynamic>) {
      return invalidParams('$snapshotRequestKey must be a JSON object');
    }
    return result(
      await _snapshotHandler.dispatchSnapshot(
        Map<String, Object?>.from(decoded),
      ),
    );
  }

  Future<ServiceExtensionResponse> handleIdentity(
    String method,
    Map<String, String> parameters,
  ) async {
    if (method != identityMethod || hasUserParameters(parameters)) {
      return invalidParams('identity does not accept parameters');
    }
    return result(identityResponse());
  }

  Map<String, Object?> identityResponse() => PatchbayIdentityWire(
    schemaVersion: 1,
    serverVersion: patchbayPackageVersion,
    features:
        features
            .map((PatchbayFeature feature) => feature.name)
            .toList(growable: false)
          ..sort(),
    applicationId: applicationId,
    appInstanceId: appInstanceId,
    isolateId: Service.getIsolateId(Isolate.current),
  ).toJson();

  Future<ServiceExtensionResponse> handleCatalog(
    String method,
    Map<String, String> parameters,
  ) async {
    if (method != catalogMethod || hasUserParameters(parameters)) {
      return invalidParams('catalog does not accept parameters');
    }
    return result(await _catalogHandler.dispatchCatalog());
  }

  Future<ServiceExtensionResponse> handleInvoke(
    String method,
    Map<String, String> parameters,
  ) async {
    if (method != invokeMethod ||
        parameters.keys.any(
          (String key) =>
              key != 'isolateId' &&
              key != 'command' &&
              key != 'args' &&
              key != 'requestId' &&
              key != 'deadlineMs' &&
              key != 'ownerToken',
        )) {
      return invalidParams('invoke received unknown parameters');
    }
    final String? command = parameters['command'];
    final String requestId = parameters['requestId'] ?? patchbayGenerateNonce();
    if (command == null || command.isEmpty) {
      return invalidParams('command is required');
    }
    if (requestId.isEmpty) {
      return invalidParams('requestId must not be empty');
    }
    final String? rawDeadline = parameters['deadlineMs'];
    final int? deadlineMs = rawDeadline == null
        ? null
        : int.tryParse(rawDeadline);
    if (rawDeadline != null &&
        (deadlineMs == null || deadlineMs < 1 || deadlineMs > 300000)) {
      return invalidParams('deadlineMs must be between 1 and 300000');
    }
    final String? ownerToken = parameters['ownerToken'];
    if (ownerToken != null && !isValidPatchbayOwnerToken(ownerToken)) {
      return invalidParams('ownerToken must be a 128-bit base64url value');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(parameters['args'] ?? '{}');
    } on FormatException {
      return invalidParams('args must be a JSON object');
    }
    if (decoded is! Map<String, dynamic>) {
      return invalidParams('args must be a JSON object');
    }
    return result(
      await _invokerHandler.dispatchInvoke(
        command,
        Map<String, Object?>.from(decoded),
        requestId,
        ownerToken: ownerToken,
        deadline: deadlineMs == null
            ? null
            : Duration(milliseconds: deadlineMs),
      ),
    );
  }

  Future<ServiceExtensionResponse> handleCancelInvocation(
    String method,
    Map<String, String> parameters,
  ) async {
    if (method != cancelInvocationMethod ||
        parameters.keys.any(
          (String key) =>
              key != 'isolateId' &&
              key != 'command' &&
              key != 'requestId' &&
              key != 'ownerToken',
        )) {
      return invalidParams('cancelInvocation received unknown parameters');
    }
    final String? command = parameters['command'];
    final String? requestId = parameters['requestId'];
    final String? ownerToken = parameters['ownerToken'];
    if (command == null || command.isEmpty) {
      return invalidParams('command is required');
    }
    if (requestId == null || requestId.isEmpty) {
      return invalidParams('requestId is required');
    }
    if (ownerToken == null || !isValidPatchbayOwnerToken(ownerToken)) {
      return invalidParams('ownerToken must be a 128-bit base64url value');
    }
    return result(
      (await _invokerHandler.cancelInvocation(
        command: command,
        requestId: requestId,
        ownerToken: ownerToken,
      )).toJson(),
    );
  }

  static ServiceExtensionResponse result(Map<String, Object?> value) =>
      ServiceExtensionResponse.result(jsonEncode(value));

  static ServiceExtensionResponse invalidParams(String message) =>
      ServiceExtensionResponse.error(
        ServiceExtensionResponse.invalidParams,
        jsonEncode(<String, Object?>{'message': message}),
      );

  static bool hasUserParameters(Map<String, String> parameters) =>
      parameters.keys.any((String key) => key != 'isolateId');
}
