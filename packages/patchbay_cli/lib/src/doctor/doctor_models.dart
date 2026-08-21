import '../result.dart';

/// The four things that have to hold before any other command can work.
enum PatchbayDoctorCheck {
  /// The local launcher session directory: which records exist, which one a
  /// command without `--session` would pick.
  session,

  /// Dialling the App and completing the identity handshake.
  connection,

  /// Reading the capability listing the App serves.
  catalog,

  /// Whether the App is `resumed`, i.e. whether the UI plane will answer.
  lifecycle,
}

/// What one check concluded.
enum PatchbayCheckVerdict {
  /// Nothing to do.
  ok,

  /// Usable, but something will bite later — an ambiguous session directory,
  /// a gate that is closed, an App that registers no commands.
  warning,

  /// This check is why the CLI cannot drive the App right now.
  failed,

  /// Not run, either because an earlier check failed or because it does not
  /// apply to this invocation. Never a verdict about the thing itself.
  skipped,
}

/// One check's outcome, phrased as observation → cause → action.
final class PatchbayDoctorFinding {
  const PatchbayDoctorFinding({
    required this.check,
    required this.verdict,
    required this.observed,
    this.cause,
    this.action,
    this.details = const <String, Object?>{},
  });

  final PatchbayDoctorCheck check;
  final PatchbayCheckVerdict verdict;

  /// What doctor saw. A fact, never an inference.
  final String observed;

  /// The likeliest explanation, when one check cannot prove which it is.
  final String? cause;

  /// The next thing to try, phrased as something the operator can run or do.
  final String? action;

  /// Machine-readable specifics: codes, counts, the lifecycle state.
  final Map<String, Object?> details;

  Map<String, Object?> toJson() => <String, Object?>{
    'check': check.name,
    'verdict': verdict.name,
    'observed': observed,
    if (cause case final String value) 'cause': value,
    if (action case final String value) 'action': value,
    if (details.isNotEmpty) 'details': details,
  };
}

/// Something doctor noticed that is not one of the four checks.
final class PatchbayDoctorWarning {
  const PatchbayDoctorWarning({
    required this.kind,
    required this.message,
    this.path,
  });

  /// A stable word a script can branch on.
  final String kind;

  /// The sentence an operator reads.
  final String message;

  /// Where in the snapshot the observation came from, when it came from there.
  final String? path;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind,
    'message': message,
    if (path case final String value) 'path': value,
  };
}

/// Stable warning kind: the App reports a live business session.
const String patchbayActiveSessionWarningKind = 'activeSession';

/// Stable warning kind: doctor could not read the snapshot at all.
const String patchbaySnapshotUnavailableWarningKind = 'snapshotUnavailable';

/// Stable warning kind: the host declared a capability its answers do not honour.
const String patchbayCapabilityNotHonouredWarningKind = 'capabilityNotHonoured';

/// The sentence every destructive-recovery warning ends with.
const String patchbayDestructiveRecoveryWarning =
    'do not force-stop, kill or uninstall the App to recover; that would '
    'interrupt live work on the device. Prefer waking the screen, bringing '
    'the App to the foreground, or waiting for the session to end.';

/// The protocol name doctor sends to find out whether the UI plane answers.
const String patchbayLifecycleProbeCommand = 'ui.semantics.tree';

/// Where the `lifecycleState` in a refusal came from — a closed vocabulary.
const String patchbayLifecycleStateHostReported = 'hostReported';
const String patchbayLifecycleStateFeatureUndeclared = 'featureUndeclared';
const String patchbayLifecycleStateNotHonoured = 'capabilityNotHonoured';

/// What to do about an App that is not resumed, per platform.
const String patchbayWakeAction =
    'Android: `adb shell input keyevent KEYCODE_WAKEUP` then unlock, and '
    '`adb shell svc power stayon usb` to stop it recurring. '
    'iOS: wake and unlock the device by hand (there is no system stay-awake '
    'command); on an unlocked device already paired with this Mac, '
    '`xcrun devicectl device process launch --device <udid> <bundle-id>` '
    'brings a backgrounded App back to the foreground. To stop the sleeping '
    'recurring takes the App itself: `patchbay ui keep-awake on`, if this App '
    'wired a keep-awake delegate (`ui keep-awake status` says). '
    'Desktop: click the App window — an unfocused window is not resumed.';

/// The whole diagnosis, in both the shapes the CLI prints.
final class PatchbayDoctorReport {
  const PatchbayDoctorReport({required this.findings, required this.warnings});

  final List<PatchbayDoctorFinding> findings;
  final List<PatchbayDoctorWarning> warnings;

  /// The worst verdict any check reached.
  PatchbayCheckVerdict get verdict {
    if (findings.any(_isFailed)) return PatchbayCheckVerdict.failed;
    if (findings.any(
      (PatchbayDoctorFinding finding) =>
          finding.verdict == PatchbayCheckVerdict.warning,
    )) {
      return PatchbayCheckVerdict.warning;
    }
    return warnings.isEmpty
        ? PatchbayCheckVerdict.ok
        : PatchbayCheckVerdict.warning;
  }

  /// The exit class of the *first* thing that broke.
  int get exitCode {
    for (final PatchbayDoctorFinding finding in findings) {
      if (!_isFailed(finding)) continue;
      return switch (finding.check) {
        PatchbayDoctorCheck.session ||
        PatchbayDoctorCheck.connection => PatchbayExitCode.transport,
        PatchbayDoctorCheck.catalog => PatchbayExitCode.protocol,
        PatchbayDoctorCheck.lifecycle => PatchbayExitCode.rejected,
      };
    }
    return PatchbayExitCode.accepted;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'doctor': <String, Object?>{
      'verdict': verdict.name,
      'checks': <Map<String, Object?>>[
        for (final PatchbayDoctorFinding finding in findings) finding.toJson(),
      ],
      'warnings': <Map<String, Object?>>[
        for (final PatchbayDoctorWarning warning in warnings) warning.toJson(),
      ],
    },
  };

  /// The human rendering: one line per check, indented cause/action beneath.
  String render() {
    final StringBuffer output = StringBuffer('patchbay doctor\n\n');
    for (final PatchbayDoctorFinding finding in findings) {
      output.writeln(
        '  ${finding.verdict.name.padRight(8)}'
        '${finding.check.name.padRight(12)}${finding.observed}',
      );
      if (finding.cause case final String cause) {
        output.writeln('  ${''.padRight(8)}cause       $cause');
      }
      if (finding.action case final String action) {
        output.writeln('  ${''.padRight(8)}action      $action');
      }
    }
    for (final PatchbayDoctorWarning warning in warnings) {
      output
        ..writeln()
        ..writeln('  !! ${warning.message}');
    }
    return (output
          ..writeln()
          ..writeln('  verdict: ${verdict.name}'))
        .toString();
  }

  static bool _isFailed(PatchbayDoctorFinding finding) =>
      finding.verdict == PatchbayCheckVerdict.failed;
}
