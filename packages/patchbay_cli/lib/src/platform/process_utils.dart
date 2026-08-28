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
  /// The guard is the `NSpid` row in `<procRoot>/self/status`, not the mere
  /// existence of `<procRoot>/<our own numeric pid>`. Two different
  /// misconfigurations have to be caught:
  ///
  /// * A chroot or sandbox with no procfs at all, or an empty `/proc`
  ///   directory — `<procRoot>` alone would look fine and every PID would
  ///   read as dead.
  /// * A procfs belonging to an ancestor or otherwise different PID
  ///   namespace, bind-mounted in. Numeric PIDs can collide — PID 1 is the
  ///   obvious case — so finding our number there proves nothing. Linux
  ///   exposes `NSpid` from the namespace that mounted this procfs through
  ///   each nested namespace containing the caller. Exactly one value equal
  ///   to Dart's [pid] proves this mount and the process use the same PID
  ///   numbering; multiple values prove they do not.
  ///
  /// Missing `NSpid` (including an old kernel), malformed status, or any I/O
  /// failure is not evidence of death. The tool-based probe takes over.
  static bool? _procfsLiveness(int processId, String procRoot) {
    try {
      if (!_procfsUsesCurrentPidNamespace(procRoot)) return null;
      return Directory('$procRoot/$processId').existsSync();
    } on FileSystemException {
      return null;
    }
  }

  /// Whether numeric PID paths in [procRoot] use this process's namespace.
  static bool _procfsUsesCurrentPidNamespace(String procRoot) {
    try {
      final File status = File('$procRoot/self/status');
      if (!status.existsSync()) return false;
      for (final String line in status.readAsLinesSync()) {
        if (!line.startsWith('NSpid:')) continue;
        final String value = line.substring('NSpid:'.length).trim();
        if (value.isEmpty) return false;
        final List<String> namespacePids = value.split(RegExp(r'\s+'));
        return namespacePids.length == 1 && namespacePids.single == '$pid';
      }
      return false;
    } on FileSystemException {
      return false;
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
  ///    pinned — for macOS and for a Linux host whose procfs namespace was
  ///    proven but whose target stat/boot-id lookup could not answer. An
  ///    unproven Linux procfs cannot use this fallback because GNU `ps` reads
  ///    that same mount.
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
      // GNU `ps` reads the mounted procfs too. If that procfs belongs to an
      // ancestor/foreign PID namespace, falling through to `ps` would ask the
      // same wrong PID-space question through a subprocess. Liveness can
      // safely fall back to the `kill(2)`-backed tool path; Linux launch time
      // has no equivalent independent source, so inability to prove the
      // namespace must remain `null` / identity-unverified.
      if (!_procfsUsesCurrentPidNamespace(procRoot)) return null;
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
      return _encodeSignature(
        windows ? windowsStartTimeScheme : posixStartTimeScheme,
        payload,
      );
    } on ProcessException {
      return null;
    }
  }

  /// The kernel's own answer, or `null` when procfs cannot give it.
  ///
  /// The caller has already established [_procfsUsesCurrentPidNamespace].
  /// Keeping the proof outside this helper also matters for fallback: GNU
  /// `ps` reads the mounted procfs, so an unproven namespace must return
  /// `null` before the code reaches `ps`; other procfs failures may still use
  /// that same-namespace fallback.
  static String? _procfsStartTimeSignature(int processId, String procRoot) {
    try {
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
      //
      // A boot id that is present but not a UUID gets the same treatment, and
      // for a sharper reason: [_parseSignature] would refuse to read it back,
      // so persisting it would hand this host a signature that can only ever
      // compare `unverifiable` -- the PID-reuse guard silently gone for the
      // life of the record. `ps` may still be able to answer.
      return _encodeSignature(linuxStartTimeScheme, '$bootId:$ticks');
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
    return _startTimeTicksPattern.hasMatch(ticks) ? ticks : null;
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
  /// [processStartTimeSignature] — no stricter than what those writers can
  /// emit, and no looser either. Both directions cost something: a legal
  /// signature rejected here silently forfeits the PID-reuse guard for that
  /// record, while a corrupted one accepted here can be read as a different
  /// launch and delete the record of a live session.
  ///
  /// * `v2-linux` — `<boot_id>:<ticks>`, one `:`, a UUID and a run of decimal
  ///   digits. Not "positive": PID 1 legitimately starts at tick 0.
  /// * `v2-posix` — `ps -o lstart=` under the pinned `LC_ALL=C`, after this
  ///   file's own trim-and-collapse: `Www Mmm D HH:MM:SS YYYY`. The shape is
  ///   asserted, and can be, precisely *because* the locale is pinned —
  ///   measured identical on BSD and GNU `ps` under `LC_ALL=C`, the only
  ///   environment this signature is ever taken in. The day is one or two
  ///   digits because BSD pads single-digit days with a second space, which
  ///   the collapse removes.
  /// * `v2-win` — a round-trip (`"o"`) rendering of a UTC `DateTime`, which
  ///   is culture-invariant and therefore fully specified: exactly seven
  ///   fractional digits and a `Z`.
  ///
  /// Anything short of the full shape is a truncated or mangled value, not a
  /// dialect: accepting a prefix of one would let a half-written record
  /// compare unequal to the whole one it was written from.
  static ({String scheme, String payload})? _parseSignature(String signature) {
    final int separator = signature.indexOf(':');
    if (separator <= 0) return null;
    final String scheme = signature.substring(0, separator);
    if (!knownStartTimeSchemes.contains(scheme)) return null;
    final String payload = signature.substring(separator + 1);
    final bool wellFormed = _isStartTimePayloadWellFormed(scheme, payload);
    return wellFormed ? (scheme: scheme, payload: payload) : null;
  }

  /// The only writer for scheme-tagged signatures.
  ///
  /// Keeping this on the same predicate as [_parseSignature] makes it
  /// impossible for this build to persist a value its reader will reject.
  static String? _encodeSignature(String scheme, String payload) =>
      knownStartTimeSchemes.contains(scheme) &&
          _isStartTimePayloadWellFormed(scheme, payload)
      ? '$scheme:$payload'
      : null;

  static bool _isStartTimePayloadWellFormed(String scheme, String payload) =>
      switch (scheme) {
        linuxStartTimeScheme => _isProcfsPayload(payload),
        posixStartTimeScheme => _isPosixLstartPayload(payload),
        windowsStartTimeScheme => _isWindowsInstantPayload(payload),
        // A registered scheme without a payload contract remains unreadable.
        _ => false,
      };

  /// `<boot_id>:<ticks>` as [_procfsStartTimeSignature] assembles it.
  static bool _isProcfsPayload(String payload) {
    final int separator = payload.indexOf(':');
    if (separator < 0) return false;
    return _bootIdPattern.hasMatch(payload.substring(0, separator)) &&
        _startTimeTicksPattern.hasMatch(payload.substring(separator + 1));
  }

  /// `ps -o lstart=` as [_stableFormattingEnvironment] makes it render, after
  /// the trim-and-collapse in [processStartTimeSignature]:
  /// `Www Mmm D HH:MM:SS YYYY`.
  ///
  /// The locale is pinned to C, so weekday and month are closed vocabularies.
  static final RegExp _lstartPattern = RegExp(
    r'^(Sun|Mon|Tue|Wed|Thu|Fri|Sat) '
    r'(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) '
    r'(\d{1,2}) (\d{2}):(\d{2}):(\d{2}) (\d{4})$',
  );

  static const List<String> _posixWeekdays = <String>[
    'Mon',
    'Tue',
    'Wed',
    'Thu',
    'Fri',
    'Sat',
    'Sun',
  ];

  static const List<String> _posixMonths = <String>[
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  static bool _isPosixLstartPayload(String payload) {
    final RegExpMatch? match = _lstartPattern.firstMatch(payload);
    if (match == null) return false;
    final int month = _posixMonths.indexOf(match.group(2)!) + 1;
    final int day = int.parse(match.group(3)!);
    final int hour = int.parse(match.group(4)!);
    final int minute = int.parse(match.group(5)!);
    final int second = int.parse(match.group(6)!);
    final int year = int.parse(match.group(7)!);
    if (!_isCalendarDate(year, month, day) ||
        hour > 23 ||
        minute > 59 ||
        second > 60) {
      return false;
    }
    final DateTime date = DateTime.utc(year, month, day);
    return match.group(1) == _posixWeekdays[date.weekday - 1];
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
  ///
  /// Seven fractional digits, exactly. `"o"` is a fixed-width round-trip
  /// format, not a shortest-form one, so a value carrying three of them (or
  /// none) was truncated after it was written; allowing it would let the
  /// truncated copy compare `different` against the intact one.
  static final RegExp _windowsInstantPattern = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})\.(\d{7})Z$',
  );

  static bool _isWindowsInstantPayload(String payload) {
    final RegExpMatch? match = _windowsInstantPattern.firstMatch(payload);
    if (match == null) return false;
    final int year = int.parse(match.group(1)!);
    final int month = int.parse(match.group(2)!);
    final int day = int.parse(match.group(3)!);
    final int hour = int.parse(match.group(4)!);
    final int minute = int.parse(match.group(5)!);
    final int second = int.parse(match.group(6)!);
    return year >= 1 &&
        _isCalendarDate(year, month, day) &&
        hour <= 23 &&
        minute <= 59 &&
        second <= 59;
  }

  static bool _isCalendarDate(int year, int month, int day) {
    if (month < 1 || month > 12 || day < 1 || day > 31) return false;
    final DateTime candidate = DateTime.utc(year, month, day);
    return candidate.year == year &&
        candidate.month == month &&
        candidate.day == day;
  }

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
