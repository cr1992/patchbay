import 'package:args/args.dart';

import '../client.dart';
import '../direct_connection.dart';
import '../sensitive_input.dart';
import '../session.dart';

/// Utilities for connecting to a Patchbay host across direct and VM Service transports.
abstract final class PatchbayConnector {
  /// The per-RPC budget this invocation runs under.
  static Duration rpcTimeout(ArgResults parsed) =>
      Duration(milliseconds: positiveOption(parsed, 'transport-timeout-ms'));

  /// Validates the global mutual exclusivity and required options for transports.
  static void validateGlobalShape(ArgResults parsed) {
    final bool direct = parsed.option('direct-endpoint') != null;
    final bool hasVmSelection =
        parsed.option('ws-uri') != null || parsed.option('session') != null;
    if (parsed.option('ws-uri') != null && parsed.option('session') != null) {
      throw const FormatException(
        '--ws-uri and --session are mutually exclusive',
      );
    }
    if (direct && hasVmSelection) {
      throw const FormatException(
        '--direct-endpoint is mutually exclusive with VM session options',
      );
    }
    if (parsed.flag('direct-token-stdin') != direct ||
        (parsed.option('direct-application-id') != null) != direct ||
        (parsed.option('direct-app-instance-id') != null) != direct) {
      throw const FormatException(
        'direct mode requires --direct-endpoint, --direct-token-stdin, '
        '--direct-application-id and --direct-app-instance-id together',
      );
    }
    if (parsed.flag('stdin') && parsed.flag('direct-token-stdin')) {
      throw const FormatException(
        '--stdin and --direct-token-stdin cannot consume the same stdin',
      );
    }
    if (parsed.flag('allow-non-tty-legacy-payload') &&
        !parsed.flag('include-legacy-payload')) {
      throw const FormatException(
        '--allow-non-tty-legacy-payload requires --include-legacy-payload',
      );
    }
  }

  /// Connects to the host configured by [parsed] options.
  static Future<PatchbayClient> connect(ArgResults parsed) async {
    final String? directEndpoint = parsed.option('direct-endpoint');
    if (directEndpoint != null) {
      final Uri endpoint = Uri.parse(directEndpoint);
      if (endpoint.scheme != 'http' ||
          endpoint.host.isEmpty ||
          endpoint.userInfo.isNotEmpty ||
          endpoint.hasQuery ||
          endpoint.fragment.isNotEmpty ||
          endpoint.path != PatchbayDirectConnection.protocolPath) {
        throw const FormatException(
          '--direct-endpoint must be a credential-free http URL',
        );
      }
      final int schemaVersion = positiveOption(parsed, 'direct-schema-version');
      return PatchbayDirectConnection(
        endpoint: endpoint,
        bearerToken: readSensitiveStdinLine(),
        schemaVersion: schemaVersion,
        applicationId: parsed.option('direct-application-id')!,
        appInstanceId: parsed.option('direct-app-instance-id')!,
        timeout: rpcTimeout(parsed),
      );
    }

    final String? uriText = parsed.option('ws-uri');
    if (uriText != null) return PatchbayConnection.connect(Uri.parse(uriText));
    final PatchbaySessionStore sessionStore = PatchbaySessionStore(
      parsed.option('session-dir'),
    );
    final PatchbayDiscoveredSession discovered = await PatchbaySessionResolver(
      store: sessionStore,
    ).resolve(sessionId: parsed.option('session'));
    try {
      return await PatchbayConnection.connect(
        Uri.parse(discovered.record.wsUri!),
        expectedIdentity: discovered.identity,
      );
    } on PatchbayProtocolException {
      sessionStore.remove(discovered.record.sessionId);
      throw const PatchbayProtocolException('sessionIdentityMismatch');
    } on Object {
      sessionStore.remove(discovered.record.sessionId);
      throw const PatchbaySessionException('sessionStaleTransport');
    }
  }

  /// Parses a required positive integer option from [options].
  static int positiveOption(ArgResults options, String name) {
    final int? value = int.tryParse(options.option(name)!);
    if (value == null || value <= 0) {
      throw FormatException('--$name must be a positive integer');
    }
    return value;
  }
}
