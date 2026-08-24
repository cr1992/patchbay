import 'package:args/args.dart';
import 'package:patchbay/patchbay.dart';

import '../rpc_timeout.dart';

/// Constructs the CLI option parser with all supported flags and options.
ArgParser patchbayCliParser() => ArgParser()
  ..addFlag(
    'help',
    abbr: 'h',
    negatable: false,
    help: 'Show root, group, or command help without connecting to an App.',
  )
  ..addOption('ws-uri', help: 'VM Service http(s) or ws(s) URI.')
  ..addOption('session', help: 'Select one discovered Patchbay session ID.')
  ..addOption(
    'trace',
    help: 'Append this command to an explicit local debug trace ID.',
  )
  ..addOption(
    'trace-dir',
    help: 'Override the local Patchbay trace directory.',
    hide: true,
  )
  ..addFlag(
    'include-legacy-payload',
    defaultsTo: false,
    help:
        'Persist re-redacted values from legacy hosts after explicit '
        'confirmation.',
  )
  ..addFlag(
    'allow-non-tty-legacy-payload',
    defaultsTo: false,
    help: 'Explicitly allow legacy payload persistence without a TTY.',
    hide: true,
  )
  ..addOption(
    'session-dir',
    help: 'Override the Patchbay launcher session directory.',
    hide: true,
  )
  ..addOption(
    'direct-endpoint',
    help: 'Experimental cleartext direct endpoint (never contains a token).',
  )
  ..addFlag(
    'direct-token-stdin',
    defaultsTo: false,
    help: 'Read the direct bearer token from no-echo stdin.',
  )
  ..addOption('direct-application-id', help: 'Expected direct App identity.')
  ..addOption('direct-app-instance-id', help: 'Expected direct App instance.')
  ..addOption(
    'direct-schema-version',
    defaultsTo: '1',
    help: 'Expected direct protocol schema version.',
  )
  ..addOption(
    'transport-timeout-ms',
    defaultsTo: '${patchbayDefaultRpcTimeout.inMilliseconds}',
    help:
        'Per-RPC timeout in milliseconds, on every transport. A command that '
        'asks the App to wait (--timeout-ms) extends its own request by this '
        'much rather than being cut short by it.',
  )
  ..addOption(
    'path',
    help:
        'Dot path into the snapshot (a.b.c); answers that field or subtree '
        'instead of the whole snapshot.',
  )
  ..addOption(
    'from',
    help: 'Retained snapshot revision used as the diff baseline.',
  )
  ..addOption('args', help: 'JSON object passed to a domain command.')
  ..addFlag(
    'stdin',
    defaultsTo: false,
    help: 'Read one no-echo stdin line; JSON merges over --args, stdin wins.',
  )
  ..addFlag(
    'wait',
    defaultsTo: false,
    help: 'Wait for a returned jobId to reach a terminal event.',
  )
  ..addFlag('json', defaultsTo: false, help: 'Print stable JSON.')
  ..addFlag(
    'keep-awake',
    defaultsTo: false,
    help:
        'Renew the App keep-awake lease after successful commands; launch '
        'also holds it for the supervised session. Disabled by default.',
  )
  ..addOption('revision', help: 'Observed navigation revision.')
  ..addOption(
    'generation',
    help: 'Expected semantics generation; refuses a target that already moved.',
  )
  ..addOption('start', help: 'JSON target-local normalized gesture point.')
  ..addOption('gesture-path', help: 'JSON array of target-local drag points.')
  ..addOption('velocity', help: 'JSON normalized fling velocity vector.')
  ..addOption(
    'duration-ms',
    help:
        'Bounded gesture duration, or performance profile window, '
        'in milliseconds.',
  )
  ..addOption('timeout-ms', help: 'Operation timeout in milliseconds.')
  ..addOption('cursor', help: 'Opaque structured-log cursor.')
  ..addOption(
    'direction',
    allowed: const <String>['forward', 'backward'],
    help: 'Structured-log traversal direction.',
  )
  ..addOption('limit', help: 'Maximum number of log records.')
  ..addOption('levels', help: 'Comma-separated log levels.')
  ..addOption('categories', help: 'Comma-separated log categories.')
  ..addOption('since', help: 'ISO-8601 lower log time bound.')
  ..addOption(
    'until',
    help:
        'logs query|export: ISO-8601 upper time bound. snapshot wait: the '
        'condition to wait for (exists|absent|equals).',
  )
  ..addOption(
    'ttl-ms',
    help: 'Artifact lifetime, or inspect select-mode lease, in milliseconds.',
  )
  ..addOption(
    'lease-ms',
    help:
        'Keep-awake lease in milliseconds; the App releases the screen on its '
        'own when it runs out. Omit to use the App-declared default.',
  )
  ..addOption('pixel-ratio', help: 'Positive Flutter capture pixel ratio.')
  ..addOption(
    'sample-limit',
    help: 'Maximum VM timeline events summarized (1..10000).',
  )
  ..addOption(
    'after-frames',
    help: 'Capture after this many Patchbay-observed Flutter frames (1..120).',
  )
  ..addOption('output', help: 'Local artifact output path.')
  ..addOption('name', help: 'Human-readable local trace name.')
  ..addFlag(
    'activate',
    defaultsTo: false,
    help: 'Select the new trace for this workspace.',
  )
  ..addFlag(
    'pin',
    defaultsTo: false,
    help: 'Exclude the new trace from retention pruning.',
  )
  ..addFlag(
    'dry-run',
    defaultsTo: false,
    help: 'Report retention candidates without deleting them.',
  )
  ..addFlag(
    'include-artifacts',
    defaultsTo: true,
    help: 'Include content-addressed artifacts in a trace export.',
  )
  ..addFlag('force', defaultsTo: false, help: 'Replace an existing output.')
  ..addFlag(
    'clear',
    defaultsTo: false,
    help: 'Unpin the selected session instead of selecting one.',
  )
  ..addOption(
    'permission-driver',
    help: 'Explicit external permission driver executable path.',
  )
  ..addOption('device-id', help: 'Explicit platform device selection.')
  ..addOption('application-id', help: 'Explicit platform application ID.')
  ..addOption(
    'state',
    allowed: <String>[
      for (final PatchbayPermissionState state
          in PatchbayPermissionState.values)
        state.name,
    ],
    help: 'Desired or required closed permission state.',
  )
  ..addOption(
    'decision',
    allowed: <String>[
      for (final PatchbayPermissionDecision decision
          in PatchbayPermissionDecision.values)
        decision.name,
    ],
    help: 'System permission decision for exercise.',
  )
  ..addFlag(
    'confirm-system-permission',
    defaultsTo: false,
    negatable: false,
    help: 'Explicitly confirm an exercise allow system permission action.',
  )
  ..addFlag(
    'emit-manifest',
    defaultsTo: false,
    negatable: false,
    help: 'Emit a v2 draft covering only targets mounted right now.',
  )
  ..addFlag(
    'navigate',
    defaultsTo: false,
    negatable: false,
    help: 'Opt in to navigation side effects and verify every destination.',
  )
  ..addFlag(
    'continue-on-error',
    defaultsTo: false,
    negatable: false,
    help: 'Continue the destination walkthrough after a screen fails.',
  )
  ..addFlag(
    'restore',
    defaultsTo: false,
    negatable: false,
    help: 'Try to restore the initial destination after a walkthrough.',
  )
  ..addOption(
    'screen-timeout-ms',
    help: 'Per-destination walkthrough budget (default 5000, max 120000).',
  )
  ..addOption(
    'total-timeout-ms',
    help: 'Whole walkthrough budget (default 120000, max 600000).',
  );
