import 'dart:io';

/// Verdict of comparing a recorded launch signature against a freshly probed
/// one, in the same three states the rest of the session-liveness stack uses.
///
/// The third state is the one that matters. Two signatures that cannot be
/// meaningfully compared -- different formats, or a format this build does not
/// know -- must not collapse into "not equal", because the caller reads "not
/// equal" as "this PID was recycled" and deletes the record of a session whose
/// App is running.
enum PatchbayStartTimeMatch {
  /// Same scheme, identical payload: this is the same launch.
  same,

  /// Same scheme, different payload: the PID belongs to something else now.
  different,

  /// Not comparable, so nothing may be concluded in either direction.
  unverifiable,
}

/// Abstraction over platform process execution for testability and cross-platform consistency.
abstract interface class ProcessRunner {
  /// Runs [executable] and waits for it.
  ///
  /// [environment] overlays the inherited environment rather than replacing
  /// it (`includeParentEnvironment: true`), because the one caller that uses
  /// it needs to pin exactly two variables -- `TZ` and `LC_ALL` -- without
  /// stripping `PATH` and everything else the child still needs.
  ProcessResult runSync(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
  });
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  });
}

/// Default [ProcessRunner] delegating directly to [Process].
final class SystemProcessRunner implements ProcessRunner {
  const SystemProcessRunner();

  @override
  ProcessResult runSync(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
  }) => Process.runSync(executable, arguments, environment: environment);

  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) => Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
    includeParentEnvironment: includeParentEnvironment,
    runInShell: runInShell,
    mode: mode,
  );
}

/// Cross-platform process and filesystem permission utilities.
abstract final class PlatformProcessUtils {
  static const ProcessRunner defaultRunner = SystemProcessRunner();

  /// Where procfs is mounted on Linux.
  static const String defaultProcRoot = '/proc';

  /// Whether the process with [processId] is currently running -- in three
  /// states, and the third one is the whole point.
  ///
  /// * `true` -- the OS confirmed the process is there.
  /// * `false` -- the OS confirmed it is not.
  /// * `null` -- the question could not be *asked*: the probing tool is not
  ///   on `PATH`, or the query failed for a reason that says nothing about
  ///   the process.
  ///
  /// Callers must treat `null` as "cannot verify", never as "dead", for
  /// exactly the reason [processStartTimeSignature] already documents. A
  /// `bool` return made that mistake unrepresentable in the type and
  /// therefore invisible: Debian/Ubuntu `-slim`, distroless and most
  /// language base images (including `dart:stable`) ship no `procps`, so
  /// `kill` and `ps` do not exist as executables there, `Process.runSync`
  /// threw `ProcessException`, and every live session on such a host was
  /// reported stale and had its record deleted.
  ///
  /// On Linux the answer comes from `/proc/<pid>` and costs no subprocess at
  /// all; `kill -0` / `tasklist` stay the fallback for everything else, and
  /// for a Linux sandbox with no procfs mounted.
  static bool? isProcessAlive(
    int processId, {
    ProcessRunner runner = defaultRunner,
    bool? isWindows,
    bool? isLinux,
    String procRoot = defaultProcRoot,
  }) {
    final windows = isWindows ?? Platform.isWindows;
    if (!windows && (isLinux ?? Platform.isLinux)) {
      final bool? fromProcfs = _procfsLiveness(processId, procRoot);
      if (fromProcfs != null) return fromProcfs;
    }
    try {
      if (windows) {
        final result = runner.runSync('tasklist', [
          '/FI',
          'PID eq $processId',
          '/NH',
        ]);
        // A filtered `tasklist` reports "no such task" on *stdout* and still
        // exits 0, so a non-zero exit means the tool itself failed -- which
        // is a statement about `tasklist`, not about the process.
        if (result.exitCode != 0) return null;
        return RegExp(
          '(?:^|\\s)$processId(?:\\s|\$)',
          multiLine: true,
        ).hasMatch(result.stdout.toString());
      }
      // `kill` did run and answered: a non-zero exit is a real "not yours to
      // signal" verdict (ESRCH, or EPERM for another user's process -- the
      // pre-existing reading, and session files are owner-only anyway).
      return runner.runSync('kill', ['-0', '$processId']).exitCode == 0;
    } on ProcessException {
      // The tool could not be launched at all. Nothing was learned.
      return null;
    }
  }

  /// Liveness straight from procfs, or `null` when procfs cannot answer.
  ///
  /// The guard is `<procRoot>/<our own pid>`, not `<procRoot>` and not
  /// `<procRoot>/self`. Two different misconfigurations have to be caught,
  /// and only the self-PID lookup catches both:
  ///
  /// * A chroot or sandbox with no procfs at all, or an empty `/proc`
  ///   directory — `<procRoot>` alone would look fine and every PID would
  ///   read as dead.
  /// * A procfs belonging to a *different* PID namespace, bind-mounted in.
  ///   `<procRoot>/self` still resolves there — it is a magic symlink that
  ///   answers for whichever namespace owns the mount — so it proves nothing
  ///   about whether the PIDs this process knows mean anything in it. Every
  ///   `<procRoot>/<recorded pid>` lookup would then be answering a question
  ///   about someone else's PID space, and `kill -0` (which does run in our
  ///   namespace) would have got it right.
  ///
  /// Finding our own PID is a necessary condition, not a proof of namespace
  /// identity: two namespaces can both contain the same PID number. It rules
  /// out the misconfigurations above, which is what it is here to do; when it
  /// fails, the tool-based probe takes over rather than anything being
  /// declared dead.
  static bool? _procfsLiveness(int processId, String procRoot) {
    try {
      if (!Directory('$procRoot/$pid').existsSync()) return null;
      return Directory('$procRoot/$processId').existsSync();
    } on FileSystemException {
      return null;
    }
  }

  /// Scheme tag of the procfs signature: kernel `starttime` ticks pinned to
  /// the boot they are counted from. No formatting, no clock, no locale.
  static const String linuxStartTimeScheme = 'v2-linux';

  /// Scheme tag of the `ps` fallback signature, taken with `TZ`/`LC_ALL`
  /// pinned so the rendering cannot drift with the caller's environment.
  static const String posixStartTimeScheme = 'v2-posix';

  /// Scheme tag of the Windows signature: `DateTime` in UTC, round-trip
  /// (`"o"`) format, which is culture-invariant and carries no local offset.
  static const String windowsStartTimeScheme = 'v2-win';

  /// Every scheme this build knows how to compare. Anything else -- including
  /// the unprefixed strings written during 0.5.0 development -- is
  /// [PatchbayStartTimeMatch.unverifiable] by construction.
  static const Set<String> knownStartTimeSchemes = <String>{
    linuxStartTimeScheme,
    posixStartTimeScheme,
    windowsStartTimeScheme,
  };

  /// Environment pinned onto the `ps` fallback so its rendering is a property
  /// of the process being probed and nothing else.
  ///
  /// Both variables are load-bearing, and each was measured separately on
  /// macOS 26 BSD `ps` and Debian bookworm GNU procps:
  ///
  /// * `TZ` — same PID, same instant: `TZ=UTC` gives
  ///   `Fri Aug 28 01:52:46 2026`, `TZ=Asia/Taipei` gives
  ///   `Fri Aug 28 09:52:46 2026`, `TZ=America/New_York` gives
  ///   `Thu Aug 27 21:52:46 2026`.
  /// * `LC_ALL` — with `TZ` already pinned to UTC, the *same* instant still
  ///   renders as `Fri Aug 28 …` under `C`, `Fr. 28 Aug. …` under
  ///   `de_DE.UTF-8` and `ven. 28 août …` under `fr_FR.UTF-8`. Pinning only
  ///   the timezone would have left this second, independent way for two
  ///   readers of the same record to disagree.
  static const Map<String, String> _stableFormattingEnvironment =
      <String, String>{'TZ': 'UTC', 'LC_ALL': 'C'};

  /// Captures [processId]'s launch identity as a scheme-tagged, timezone- and
  /// locale-independent signature, or `null` when it cannot be captured.
  ///
  /// The signature is `<scheme>:<payload>` and is compared **only** through
  /// [compareStartTimeSignatures] — never with `==`. The scheme tag is the
  /// whole point: it is what lets a reader that sees a payload it cannot
  /// interpret say "cannot verify" instead of "not equal, therefore this PID
  /// was recycled, therefore delete this live session's record".
  ///
  /// Three sources, in preference order:
  ///
  /// 1. **Linux procfs** — `<procRoot>/<pid>/stat` field 22 (`starttime`, in
  ///    kernel ticks since boot) joined to `<procRoot>/sys/kernel/random/boot_id`.
  ///    Kernel-native integers: nothing formats them, so there is nothing for
  ///    a timezone, a locale or a DST transition to change. `boot_id` is what
  ///    makes the tick count unique across reboots — without it a PID
  ///    reissued at the same offset into a *later* boot would read as the
  ///    same launch. Costs no subprocess.
  /// 2. **`ps -o lstart= -p <pid>`**, run with [_stableFormattingEnvironment]
  ///    pinned — for macOS and for a Linux host whose procfs cannot answer.
  /// 3. **PowerShell** `(Get-Process -Id <pid>).StartTime.ToUniversalTime().ToString("o")`
  ///    on Windows. `ToUniversalTime()` is what removes the local offset;
  ///    `"o"` is culture-invariant.
  ///
  /// Returns `null` when the OS declines to answer: the tool is missing,
  /// exits non-zero, prints nothing, or the process exited between the
  /// caller's liveness check and this call. Callers must treat `null` as
  /// "cannot verify", never as "this is a different process" — that
  /// distinction is what keeps a missing `ps`/PowerShell from fail-closed
  /// killing a live session.
  ///
  /// "The tool is missing" is not hypothetical: slim and distroless Linux
  /// images ship no `procps`, so `ps` is simply absent there. Those are
  /// exactly the hosts where source 1 applies, so on Linux the probe now
  /// keeps working where it used to degrade to PID-only.
  static String? processStartTimeSignature(
    int processId, {
    ProcessRunner runner = defaultRunner,
    bool? isWindows,
    bool? isLinux,
    String procRoot = defaultProcRoot,
  }) {
    final windows = isWindows ?? Platform.isWindows;
    if (!windows && (isLinux ?? Platform.isLinux)) {
      final String? fromProcfs = _procfsStartTimeSignature(processId, procRoot);
      if (fromProcfs != null) return fromProcfs;
    }
    try {
      final ProcessResult result = windows
          ? runner.runSync('powershell', [
              '-NoProfile',
              '-NonInteractive',
              '-Command',
              '(Get-Process -Id $processId).StartTime'
                  '.ToUniversalTime().ToString("o")',
            ])
          : runner.runSync('ps', [
              '-o',
              'lstart=',
              '-p',
              '$processId',
            ], environment: _stableFormattingEnvironment);
      if (result.exitCode != 0) return null;
      // Collapsed, not merely trimmed: BSD `ps` pads `lstart` on both sides
      // and single-digit days render as a double space. Neither is
      // information, and both would otherwise be baked into a persisted
      // identity.
      final String payload = result.stdout.toString().trim().replaceAll(
        RegExp(r'\s+'),
        ' ',
      );
      if (payload.isEmpty) return null;
      return windows
          ? '$windowsStartTimeScheme:$payload'
          : '$posixStartTimeScheme:$payload';
    } on ProcessException {
      return null;
    }
  }

  /// The kernel's own answer, or `null` when procfs cannot give it.
  ///
  /// The `<procRoot>/<our own pid>` guard is the one [_procfsLiveness]
  /// documents, and for the same two reasons: an absent or empty procfs, and
  /// a procfs bind-mounted in from a different PID namespace, in which every
  /// recorded PID means something else entirely.
  static String? _procfsStartTimeSignature(int processId, String procRoot) {
    try {
      if (!Directory('$procRoot/$pid').existsSync()) return null;
      final File statFile = File('$procRoot/$processId/stat');
      if (!statFile.existsSync()) return null;
      final String? ticks = _startTimeTicks(statFile.readAsStringSync());
      if (ticks == null) return null;
      final File bootIdFile = File('$procRoot/sys/kernel/random/boot_id');
      if (!bootIdFile.existsSync()) return null;
      final String bootId = bootIdFile.readAsStringSync().trim();
      // Without a boot identity the tick count is only unique *within* one
      // boot, so a PID reissued at the same offset into a later boot would
      // read as the same launch. Falling back to `ps` is strictly better than
      // shipping a signature that can collide.
      if (bootId.isEmpty) return null;
      return '$linuxStartTimeScheme:$bootId:$ticks';
    } on FileSystemException {
      return null;
    }
  }

  /// Field 22 of a `/proc/<pid>/stat` line, or `null` if it is not there.
  ///
  /// Parsing starts after the **last** `)`, never at the first, and never by
  /// splitting the whole line on whitespace. Field 2 is `comm`, the
  /// executable's basename truncated to 15 bytes and wrapped in parentheses,
  /// and the kernel neither escapes nor rejects spaces or parentheses inside
  /// it: a process named `my app (beta)` produces
  /// `1234 (my app (beta)) S 1 …`. A naive split would shift every subsequent
  /// field and read some other number as the start time — which, being a
  /// number that changes, would look exactly like a PID-reuse collision.
  static String? _startTimeTicks(String stat) {
    final int commEnd = stat.lastIndexOf(')');
    if (commEnd < 0) return null;
    final List<String> fields = stat
        .substring(commEnd + 1)
        .trim()
        .split(RegExp(r'\s+'));
    // The remainder starts at field 3 (`state`), so field 22 is index 19.
    const int startTimeIndex = 19;
    if (fields.length <= startTimeIndex) return null;
    final String ticks = fields[startTimeIndex];
    return int.tryParse(ticks) == null ? null : ticks;
  }

  /// Compares a signature read off a record against one just probed.
  ///
  /// This is the only sanctioned comparison. Raw `==` on two signatures is a
  /// bug: it collapses "different launch" and "written by a build whose
  /// signature format I cannot interpret" into the same `false`, and the
  /// caller acts on `false` by deleting the record of a live session.
  ///
  /// * Either side carrying no scheme, or a scheme this build does not know,
  ///   is [PatchbayStartTimeMatch.unverifiable] — including when the two
  ///   strings happen to be equal. Session records written during 0.5.0
  ///   development carry raw `ps`/PowerShell output with no scheme tag, and
  ///   those are precisely the values that must not be trusted in either
  ///   direction.
  /// * Either side carrying a payload its *own* scheme could not have
  ///   written is unverifiable for the same reason. A scheme tag says which
  ///   format a string claims to be in, not that it is in it: a truncated or
  ///   otherwise corrupted record such as `v2-linux:garbage` would otherwise
  ///   compare "same scheme, unequal payload" against a perfectly good probe
  ///   and retire a session whose App is still running. Recognising a format
  ///   is a precondition for concluding anything from it, so the payload
  ///   contracts in [_parseSignature] are part of the comparison, not
  ///   decoration.
  /// * Two *different* known schemes are also unverifiable: a Linux host that
  ///   wrote a procfs signature and later reads it with procfs unavailable
  ///   gets a `v2-posix` probe back, and the two are not comparable. Not
  ///   comparable is not the same as not equal.
  /// * Only when both sides are well-formed *and* share a scheme does
  ///   inequality mean what PB-050-18 says it means: the PID was recycled and
  ///   this record's process is gone.
  static PatchbayStartTimeMatch compareStartTimeSignatures(
    String recorded,
    String observed,
  ) {
    final ({String scheme, String payload})? left = _parseSignature(recorded);
    final ({String scheme, String payload})? right = _parseSignature(observed);
    if (left == null || right == null) {
      return PatchbayStartTimeMatch.unverifiable;
    }
    if (left.scheme != right.scheme) {
      return PatchbayStartTimeMatch.unverifiable;
    }
    return left.payload == right.payload
        ? PatchbayStartTimeMatch.same
        : PatchbayStartTimeMatch.different;
  }

  /// Splits [signature] into a scheme this build knows and a payload that
  /// scheme could actually have produced, or `null` when it is neither.
  ///
  /// The split is on the *first* `:` because every payload may contain more
  /// of them — `v2-linux` joins a UUID to a tick count, `v2-posix` carries a
  /// clock time, `v2-win` an ISO-8601 timestamp.
  ///
  /// The payload contracts are read back off the three writers in
  /// [processStartTimeSignature], and are deliberately no stricter than what
  /// those writers can emit — a legal signature rejected here would silently
  /// cost the PID-reuse guard. They are exactly strict enough to recognise a
  /// value that is *not* one of ours:
  ///
  /// * `v2-linux` — `<boot_id>:<ticks>`, one `:`, a UUID and a run of decimal
  ///   digits. Not "positive": PID 1 legitimately starts at tick 0.
  /// * `v2-posix` — whatever `ps -o lstart=` printed, *after* this file's own
  ///   trim-and-collapse, so: non-empty, no ASCII control characters (`\s`
  ///   ones were collapsed away, the rest are corruption), no edge spaces and
  ///   no doubled spaces. Nothing about the shape of a date is asserted: BSD
  ///   and GNU `ps` disagree on it, and pinning that shape here would judge
  ///   the *renderer* rather than the process.
  /// * `v2-win` — a round-trip (`"o"`) rendering of a UTC `DateTime`, which
  ///   is culture-invariant and therefore fully specified: `Z`-suffixed, with
  ///   the fractional second the only part .NET versions may render
  ///   differently.
  ///
  /// Being over-strict here can only ever cost a `different` verdict and
  /// leave a stale record behind; being over-lax can delete a live session's
  /// record. That asymmetry is why the doubt goes this way.
  static ({String scheme, String payload})? _parseSignature(String signature) {
    final int separator = signature.indexOf(':');
    if (separator <= 0) return null;
    final String scheme = signature.substring(0, separator);
    if (!knownStartTimeSchemes.contains(scheme)) return null;
    final String payload = signature.substring(separator + 1);
    final bool wellFormed = switch (scheme) {
      linuxStartTimeScheme => _isProcfsPayload(payload),
      posixStartTimeScheme => _isCollapsedSingleLine(payload),
      windowsStartTimeScheme => _windowsInstantPattern.hasMatch(payload),
      // A scheme listed in [knownStartTimeSchemes] with no payload contract
      // here is unverifiable by construction rather than trusted by default.
      _ => false,
    };
    return wellFormed ? (scheme: scheme, payload: payload) : null;
  }

  /// `<boot_id>:<ticks>` as [_procfsStartTimeSignature] assembles it.
  static bool _isProcfsPayload(String payload) {
    final int separator = payload.indexOf(':');
    if (separator < 0) return false;
    return _bootIdPattern.hasMatch(payload.substring(0, separator)) &&
        _startTimeTicksPattern.hasMatch(payload.substring(separator + 1));
  }

  /// Whether [payload] survives this file's own normalisation unchanged.
  ///
  /// Expressed as the properties that normalisation guarantees rather than as
  /// a re-run of it, so that a value which merely *looks* normalised but
  /// carries a NUL or a bell — neither of which is `\s`, so neither of which
  /// the collapse would have removed — is still recognised as corrupt.
  static bool _isCollapsedSingleLine(String payload) {
    if (payload.isEmpty) return false;
    for (final int unit in payload.codeUnits) {
      if (unit < 0x20 || unit == 0x7f) return false;
    }
    if (payload.startsWith(' ') || payload.endsWith(' ')) return false;
    return !payload.contains('  ');
  }

  /// The canonical rendering of `/proc/sys/kernel/random/boot_id`: a UUID,
  /// which is the only thing the kernel prints there. Hex case is not
  /// asserted — being stricter than the digits themselves would buy nothing
  /// and could cost the guard on a host that renders them differently.
  static final RegExp _bootIdPattern = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}'
    r'-[0-9a-fA-F]{12}$',
  );

  /// Field 22 of `/proc/<pid>/stat` as the kernel prints it: decimal digits,
  /// nothing else. `int.tryParse` would also accept `+7`, `-7` and ` 7`,
  /// which that field can never be and a corrupted record can.
  static final RegExp _startTimeTicksPattern = RegExp(r'^[0-9]+$');

  /// `DateTime.ToUniversalTime().ToString("o")`: an ISO-8601 instant whose
  /// `Kind` is UTC, so it always ends in `Z` and never carries a local
  /// offset — an offset here is the Windows shape of the PB-050-31 defect
  /// itself, and must not be read as a comparable identity.
  static final RegExp _windowsInstantPattern = RegExp(
    r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,7})?Z$',
  );

  /// Creates [path] empty and owner-only (`0600` on POSIX) **before** any content is written.
  static File createRestrictedFileSync(
    String path, {
    ProcessRunner runner = defaultRunner,
    bool? isWindows,
  }) {
    final file = File(path);
    file.createSync(exclusive: true);
    final windows = isWindows ?? Platform.isWindows;
    if (!windows) {
      runner.runSync('chmod', ['600', file.path]);
    }
    return file;
  }

  /// Ensures a directory has owner-only permissions (`0700` on POSIX).
  static Directory ensureRestrictedDirectorySync(
    Directory directory, {
    ProcessRunner runner = defaultRunner,
    bool? isWindows,
  }) {
    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
    }
    final windows = isWindows ?? Platform.isWindows;
    if (!windows) {
      runner.runSync('chmod', ['700', directory.path]);
    }
    return directory;
  }
}
