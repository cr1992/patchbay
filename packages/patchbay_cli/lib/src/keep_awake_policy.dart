import 'client.dart';
import 'result.dart';

const String patchbayKeepAwakeEnvironmentKey = 'PATCHBAY_KEEP_AWAKE';
const Duration patchbayKeepAwakeDefaultLease = Duration(minutes: 10);
const Duration patchbayKeepAwakeMaximumLease = Duration(hours: 2);

final class PatchbayKeepAwakePolicy {
  const PatchbayKeepAwakePolicy({
    required this.enabled,
    this.lease = patchbayKeepAwakeDefaultLease,
  });

  factory PatchbayKeepAwakePolicy.resolve({
    required bool? commandLine,
    required Map<String, String> environment,
  }) {
    if (commandLine != null) {
      return PatchbayKeepAwakePolicy(enabled: commandLine);
    }
    final String? raw = environment[patchbayKeepAwakeEnvironmentKey]
        ?.trim()
        .toLowerCase();
    return switch (raw) {
      null ||
      '' ||
      '0' ||
      'false' ||
      'off' => const PatchbayKeepAwakePolicy(enabled: false),
      '1' || 'true' || 'on' => const PatchbayKeepAwakePolicy(enabled: true),
      _ => throw const FormatException(
        'PATCHBAY_KEEP_AWAKE must be true/false, on/off, or 1/0',
      ),
    };
  }

  final bool enabled;
  final Duration lease;

  Duration get renewalCadence =>
      Duration(milliseconds: lease.inMilliseconds ~/ 2);
}

final class PatchbayKeepAwakeAttempt {
  const PatchbayKeepAwakeAttempt({
    required this.success,
    required this.state,
    this.reasonCode,
  });

  final bool success;
  final String state;
  final String? reasonCode;

  Map<String, Object?> toJson() => <String, Object?>{
    'state': state,
    'success': success,
    if (reasonCode != null) 'reasonCode': reasonCode,
  };
}

Future<PatchbayKeepAwakeAttempt> requestPatchbayKeepAwake(
  PatchbayClient client, {
  required bool enabled,
  Duration lease = patchbayKeepAwakeDefaultLease,
}) async {
  if (lease <= Duration.zero || lease > patchbayKeepAwakeMaximumLease) {
    throw const FormatException('keep-awake lease is outside the App bounds');
  }
  try {
    final Map<String, Object?> response = await client.invoke(
      command: 'ui.keepAwake.set',
      arguments: <String, Object?>{
        'enabled': enabled,
        if (enabled) 'leaseMs': lease.inMilliseconds,
      },
    );
    if (patchbayExitCodeFor(response) != PatchbayExitCode.accepted) {
      final Object? rejection = response['rejection'];
      final Object? code = rejection is Map ? rejection['code'] : null;
      return PatchbayKeepAwakeAttempt(
        success: false,
        state: enabled ? 'renewalRejected' : 'releaseRejected',
        reasonCode: code is String ? code : 'keepAwakeRequestFailed',
      );
    }
    final Object? payload = response['payload'];
    final Object? outcome = payload is Map ? payload['outcome'] : null;
    return PatchbayKeepAwakeAttempt(
      success: true,
      state: outcome is String
          ? outcome
          : enabled
          ? 'renewed'
          : 'released',
    );
  } on Object {
    return PatchbayKeepAwakeAttempt(
      success: false,
      state: enabled ? 'renewalUnconfirmed' : 'releaseUnconfirmed',
      reasonCode: 'keepAwakeTransportUnavailable',
    );
  }
}
