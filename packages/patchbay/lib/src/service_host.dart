import 'dart:convert';
import 'dart:developer';
import 'dart:isolate';
import 'dart:math';

import 'generated/core_wire.g.dart';

typedef PatchbayCatalogSource = Future<Map<String, Object?>> Function();
typedef PatchbaySnapshotSource = Future<Map<String, Object?>> Function();
typedef PatchbayInvocationSource =
    Future<Map<String, Object?>> Function(
      String command,
      Map<String, Object?> arguments,
      String requestId,
    );
typedef PatchbayExtensionRegistrar =
    void Function(String method, ServiceExtensionHandler handler);

/// Generic VM Service extension host. It has no Flutter or consumer imports.
final class PatchbayServiceHost {
  PatchbayServiceHost({
    required this.applicationId,
    required PatchbayCatalogSource catalog,
    required PatchbaySnapshotSource snapshot,
    required PatchbayInvocationSource invoke,
    String? appInstanceId,
    PatchbayExtensionRegistrar? registrar,
  }) : appInstanceId = appInstanceId ?? _nonce(),
       _catalog = catalog,
       _snapshot = snapshot,
       _invoke = invoke,
       _registrar = registrar ?? registerExtension;

  static const int schemaVersion = 1;
  static const String identityMethod = 'ext.patchbay.identity';
  static const String catalogMethod = 'ext.patchbay.catalog';
  static const String snapshotMethod = 'ext.patchbay.snapshot';
  static const String invokeMethod = 'ext.patchbay.invoke';

  final String applicationId;
  final String appInstanceId;
  final PatchbayCatalogSource _catalog;
  final PatchbaySnapshotSource _snapshot;
  final PatchbayInvocationSource _invoke;
  final PatchbayExtensionRegistrar _registrar;
  bool _registered = false;

  /// Transport-neutral dispatch seam used by alternate, explicitly enabled
  /// hosts. VM Service registration and direct transports must call these
  /// same handlers instead of rebuilding command routing.
  Future<Map<String, Object?>> dispatchCatalog() async => <String, Object?>{
    'schemaVersion': schemaVersion,
    ...await _catalog(),
  };

  Future<Map<String, Object?>> dispatchSnapshot() async => <String, Object?>{
    'schemaVersion': schemaVersion,
    ...await _snapshot(),
  };

  Future<Map<String, Object?>> dispatchInvoke(
    String command,
    Map<String, Object?> arguments,
    String requestId,
  ) => _invoke(command, arguments, requestId);

  void register() {
    if (_registered) return;
    _registered = true;
    _registrar(identityMethod, handleIdentity);
    _registrar(catalogMethod, handleCatalog);
    _registrar(snapshotMethod, handleSnapshot);
    _registrar(invokeMethod, handleInvoke);
  }

  Future<ServiceExtensionResponse> handleSnapshot(
    String method,
    Map<String, String> parameters,
  ) async {
    if (method != snapshotMethod || _hasUserParameters(parameters)) {
      return _invalidParams('snapshot does not accept parameters');
    }
    return _result(await dispatchSnapshot());
  }

  Future<ServiceExtensionResponse> handleIdentity(
    String method,
    Map<String, String> parameters,
  ) async {
    if (method != identityMethod || _hasUserParameters(parameters)) {
      return _invalidParams('identity does not accept parameters');
    }
    return _result(
      PatchbayIdentityWire(
        schemaVersion: schemaVersion,
        applicationId: applicationId,
        appInstanceId: appInstanceId,
        isolateId: Service.getIsolateId(Isolate.current),
      ).toJson(),
    );
  }

  Future<ServiceExtensionResponse> handleCatalog(
    String method,
    Map<String, String> parameters,
  ) async {
    if (method != catalogMethod || _hasUserParameters(parameters)) {
      return _invalidParams('catalog does not accept parameters');
    }
    return _result(await dispatchCatalog());
  }

  Future<ServiceExtensionResponse> handleInvoke(
    String _,
    Map<String, String> parameters,
  ) async {
    final String? command = parameters['command'];
    final String requestId = parameters['requestId'] ?? _nonce();
    if (command == null || command.isEmpty) {
      return _invalidParams('command is required');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(parameters['args'] ?? '{}');
    } on FormatException {
      return _invalidParams('args must be a JSON object');
    }
    if (decoded is! Map<String, dynamic>) {
      return _invalidParams('args must be a JSON object');
    }
    return _result(
      await dispatchInvoke(
        command,
        Map<String, Object?>.from(decoded),
        requestId,
      ),
    );
  }

  static ServiceExtensionResponse _result(Map<String, Object?> value) =>
      ServiceExtensionResponse.result(jsonEncode(value));

  static ServiceExtensionResponse _invalidParams(String message) =>
      ServiceExtensionResponse.error(
        ServiceExtensionResponse.invalidParams,
        jsonEncode(<String, Object?>{'message': message}),
      );

  /// `VmService.callServiceExtension` carries the routed isolate id in the
  /// handler parameter map. It is VM metadata, not a Patchbay RPC argument.
  static bool _hasUserParameters(Map<String, String> parameters) =>
      parameters.keys.any((String key) => key != 'isolateId');

  static String _nonce() {
    final Random random = Random.secure();
    return List<int>.generate(
      16,
      (_) => random.nextInt(256),
    ).map((int byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  }
}
