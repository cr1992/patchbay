import 'dart:convert';

import 'package:patchbay/patchbay.dart';

import 'permission_platform_adapter.dart';

const Map<String, String> patchbayAndroidP0Permissions = <String, String>{
  'camera': 'android.permission.CAMERA',
  'microphone': 'android.permission.RECORD_AUDIO',
  'locationWhenInUse': 'android.permission.ACCESS_FINE_LOCATION',
  'notifications': 'android.permission.POST_NOTIFICATIONS',
};

final class PatchbayAndroidPermissionAdapter
    implements PatchbayPermissionPlatformAdapter {
  PatchbayAndroidPermissionAdapter({
    this.adbExecutable = 'adb',
    this.instrumentationRunner,
    PatchbayPlatformCommandRunner? runCommand,
  }) : _run = runCommand ?? runPatchbayPlatformCommand;

  final String adbExecutable;
  final String? instrumentationRunner;
  final PatchbayPlatformCommandRunner _run;

  @override
  Future<PatchbayPermissionDriverResponse> handle(
    PatchbayPermissionDriverRequest request,
  ) async {
    try {
      final PatchbayPlatformCommandResult version = await _run(
        adbExecutable,
        const <String>['version'],
        permissionAdapterTimeout(request),
      );
      if (version.exitCode != 0) {
        throw const _AdapterFailure('platformDriverUnavailable');
      }
      if (request.operation == PatchbayPermissionOperation.capabilities) {
        return acceptedPermissionDriverResponse(
          request,
          capabilities: await _probeCapabilities(request),
          evidence: <PatchbayPermissionEvidence>[
            PatchbayPermissionEvidence(
              factSource: PatchbayPermissionFactSource.deviceReported,
              kind: 'platformTool',
              details: <String, Object?>{
                'executable': adbExecutable,
                'version': version.stdout.split('\n').first.trim(),
                'uiAutomatorRunnerConfigured':
                    instrumentationRunner?.isNotEmpty == true,
              },
            ),
          ],
        );
      }

      final String permission = _requiredPermission(request);
      final String applicationId = _requiredApplication(request);
      final String device = await _selectDevice(request);
      await _verifyApplication(
        request,
        device,
        applicationId,
        requireRunning: _mutates(request.operation),
      );

      // This flag describes whether the operation is expected to cross the
      // system-UI boundary. adb-only status/normalize/reset operations do not.
      final bool systemUiExpected =
          request.operation == PatchbayPermissionOperation.exercise;

      if (request.operation == PatchbayPermissionOperation.status ||
          request.operation == PatchbayPermissionOperation.fail) {
        return acceptedPermissionDriverResponse(
          request,
          after: await _status(request, device, applicationId, permission),
          evidence: <PatchbayPermissionEvidence>[
            _evidence('androidPackageManager', device),
          ],
        );
      }
      final PatchbayPermissionStatus before = await _status(
        request,
        device,
        applicationId,
        permission,
        systemUiExpected: systemUiExpected,
      );
      if (request.operation == PatchbayPermissionOperation.reset ||
          request.operation == PatchbayPermissionOperation.normalize &&
              request.state == PatchbayPermissionState.notDetermined) {
        await _reset(request, device, applicationId, permission);
      } else if (request.operation == PatchbayPermissionOperation.normalize) {
        await _normalize(request, device, applicationId, permission);
      } else if (request.operation == PatchbayPermissionOperation.exercise) {
        return _exercise(request, device, applicationId, permission, before);
      } else {
        throw const _AdapterFailure('permissionOperationInvalid');
      }
      return acceptedPermissionDriverResponse(
        request,
        before: before,
        after: await _status(
          request,
          device,
          applicationId,
          permission,
          systemUiExpected: systemUiExpected,
        ),
        evidence: <PatchbayPermissionEvidence>[
          _evidence('androidPackageManagerMutation', device),
        ],
      );
    } on _AdapterFailure catch (failure) {
      return rejectedPermissionDriverResponse(
        request,
        failure.code,
        details: failure.details,
        notice: failure.notice,
      );
    }
  }

  /// 探测出来的能力矩阵，而不是「配置了 runner 路径」的推断。
  ///
  /// 此前只要 `instrumentationRunner` 非空，就对四个权限一律宣布 `exercise` 与
  /// allow / deny / allowOnce 三种 decision——给一个设备上并不存在的 runner 字符串也照样
  /// 宣布。声明比事实宽的代价是调用方按声明编排、到执行时才失败，而失败点离原因很远。
  ///
  /// 这里逐项落到可核对的事实上：
  /// - `exercise` 与 decisions 需要 runner **确实注册在这台设备上**（`pm list
  ///   instrumentation`），不是路径非空；
  /// - 读写动作需要目标应用**声明过**该权限——判据是 manifest 合并出的
  ///   `requested permissions:` 小节，不是 `runtime permissions:` 小节：后者只在
  ///   Android 物化过运行时记录后才会出现，声明过但从未被问过的权限不会在其中，
  ///   不能拿它的缺席当"没声明"；
  /// - `allowOnce` 只在系统提供"仅这一次"的权限上给出。Android 的一次性授权覆盖
  ///   相机、麦克风与位置，不覆盖通知。
  Future<PatchbayPermissionCapabilities> _probeCapabilities(
    PatchbayPermissionDriverRequest request,
  ) async {
    final String? applicationId = request.applicationId;
    String? device;
    try {
      device = await _selectDevice(request);
    } on _AdapterFailure {
      device = null;
    }

    var runnerInstalled = false;
    final String? runner = instrumentationRunner;
    if (device != null && runner != null && runner.isNotEmpty) {
      final PatchbayPlatformCommandResult installed = await _adb(
        request,
        device,
        const <String>['shell', 'pm', 'list', 'instrumentation'],
      );
      // `pm list instrumentation` 的行形如 `instrumentation:<pkg>/<runner> (target=...)`。
      // 只认整段 `<pkg>/<runner>` 命中，避免同名前缀误判。
      runnerInstalled =
          installed.exitCode == 0 && installed.stdout.contains(runner);
    }

    Set<String> declared = const <String>{};
    if (device != null && applicationId != null && applicationId.isNotEmpty) {
      final PatchbayPlatformCommandResult dump = await _adb(
        request,
        device,
        <String>['shell', 'dumpsys', 'package', applicationId],
      );
      if (dump.exitCode == 0) {
        // 用 manifest 的「requested permissions:」小节判声明，不用 runtime 条目——
        // 见 `_declaredPlatformPermissions` 的注释：runtime 条目是懒物化的，缺席不
        // 代表没声明。这个 preflight 的结果直接决定 `PatchbayPermissionDriverRunner`
        // 是否放行 normalize/reset（它要求 action 在 capabilities 里），所以这里如果
        // 仍按旧的 runtime-only 判断，声明过但未物化的权限会被判"没声明"，
        // normalize/reset 在 preflight 就被拒绝，根本进不到 `_normalize`/`_status`。
        final Set<String> declaredPlatformPermissions =
            _declaredPlatformPermissions(dump.stdout);
        declared = <String>{
          for (final MapEntry<String, String> entry
              in patchbayAndroidP0Permissions.entries)
            if (declaredPlatformPermissions.contains(entry.value)) entry.key,
        };
      }
    }

    // 拿不到设备或应用身份时不做逐项断言：此时既不能证明支持，也不能证明不支持，
    // 于是只报平台与 driver 身份，动作集留空，由调用方带上身份再问一次。
    final bool identified =
        device != null && applicationId != null && applicationId.isNotEmpty;

    return PatchbayPermissionCapabilities(
      platform: 'android',
      driver: 'android.adb-uiautomator',
      driverVersion: '1',
      permissions: <String, PatchbayPermissionCapability>{
        for (final String permission in patchbayAndroidP0Permissions.keys)
          permission: PatchbayPermissionCapability(
            // 三档，区别是"用什么证据说话"：
            // - 有身份且应用声明过：读写都可做（有 runner 才加 exercise）；
            // - 有身份但应用没声明：只留 `status`。能不能问和答案是什么是两件事——问了会
            //   得到 `state: unsupported` 加原因，而把 `status` 也收掉会让调用方只拿到一个
            //   笼统的拒绝，分不清"平台不支持"还是"这个应用没声明"；
            // - 没有设备或应用身份：报 driver 级动作，不对具体应用下断言。
            actions: !identified
                ? <PatchbayPermissionAction>{
                    PatchbayPermissionAction.status,
                    PatchbayPermissionAction.grant,
                    PatchbayPermissionAction.revoke,
                    PatchbayPermissionAction.reset,
                  }
                : !declared.contains(permission)
                ? const <PatchbayPermissionAction>{
                    PatchbayPermissionAction.status,
                  }
                : <PatchbayPermissionAction>{
                    PatchbayPermissionAction.status,
                    PatchbayPermissionAction.grant,
                    PatchbayPermissionAction.revoke,
                    PatchbayPermissionAction.reset,
                    if (runnerInstalled) PatchbayPermissionAction.exercise,
                  },
            decisions:
                runnerInstalled && identified && declared.contains(permission)
                ? <PatchbayPermissionDecision>{
                    PatchbayPermissionDecision.allow,
                    PatchbayPermissionDecision.deny,
                    if (_supportsOneTime(permission))
                      PatchbayPermissionDecision.allowOnce,
                  }
                : const <PatchbayPermissionDecision>{},
          ),
      },
    );
  }

  /// Android 的「仅这一次」只出现在相机、麦克风与位置的弹窗上，通知没有这一档。
  static bool _supportsOneTime(String permission) => const <String>{
    'camera',
    'microphone',
    'locationWhenInUse',
  }.contains(permission);

  /// 状态答复里的 `supportedActions` 用的固定动作集。
  ///
  /// 它描述的是「driver 对一个**已声明**权限能做什么」，与 `_probeCapabilities` 的逐项
  /// 探测不同：走到这里时权限的运行时条目已经读到了，声明与否已成事实。
  Set<PatchbayPermissionAction> get _statusActions =>
      <PatchbayPermissionAction>{
        PatchbayPermissionAction.status,
        PatchbayPermissionAction.grant,
        PatchbayPermissionAction.revoke,
        PatchbayPermissionAction.reset,
        if (instrumentationRunner?.isNotEmpty == true)
          PatchbayPermissionAction.exercise,
      };

  Future<String> _selectDevice(PatchbayPermissionDriverRequest request) async {
    final PatchbayPlatformCommandResult result = await _run(
      adbExecutable,
      const <String>['devices'],
      permissionAdapterTimeout(request),
    );
    if (result.exitCode != 0) {
      throw const _AdapterFailure('platformDriverUnavailable');
    }
    final List<String> devices = <String>[
      for (final String line in result.stdout.split('\n'))
        if (line.contains('\tdevice')) line.split('\t').first.trim(),
    ];
    if (request.deviceId case final String requested) {
      if (!devices.contains(requested)) {
        throw const _AdapterFailure('platformDeviceUnavailable');
      }
      return requested;
    }
    if (devices.length != 1) {
      throw _AdapterFailure(
        devices.isEmpty
            ? 'platformDeviceUnavailable'
            : 'platformDeviceAmbiguous',
        details: <String, Object?>{'deviceCount': devices.length},
      );
    }
    return devices.single;
  }

  Future<void> _verifyApplication(
    PatchbayPermissionDriverRequest request,
    String device,
    String applicationId, {
    required bool requireRunning,
  }) async {
    final PatchbayPlatformCommandResult installed = await _adb(
      request,
      device,
      <String>['shell', 'pm', 'path', applicationId],
    );
    if (installed.exitCode != 0 ||
        !installed.stdout.trim().startsWith('package:')) {
      throw const _AdapterFailure('platformApplicationMismatch');
    }
    if (!requireRunning) return;
    final PatchbayPlatformCommandResult running = await _adb(
      request,
      device,
      <String>['shell', 'pidof', applicationId],
    );
    if (running.exitCode != 0 ||
        !RegExp(r'^\d+(?:\s+\d+)*$').hasMatch(running.stdout.trim())) {
      throw const _AdapterFailure('platformApplicationMismatch');
    }
  }

  Future<PatchbayPermissionStatus> _status(
    PatchbayPermissionDriverRequest request,
    String device,
    String applicationId,
    String permission, {
    bool systemUiExpected = false,
  }) async {
    final String platformPermission = patchbayAndroidP0Permissions[permission]!;
    final PatchbayPlatformCommandResult result = await _adb(
      request,
      device,
      <String>['shell', 'dumpsys', 'package', applicationId],
    );
    if (result.exitCode != 0) {
      throw const _AdapterFailure('permissionUnsupported');
    }
    final RegExpMatch? match = RegExp(
      '${RegExp.escape(platformPermission)}:\\s+granted=(true|false),\\s*flags=\\[([^\\]]*)\\]',
    ).firstMatch(result.stdout);
    if (match == null) {
      // `runtime permissions:` 小节没有这个权限的条目,原因有两种,处置完全不同,
      // 不能用同一个判断:
      //
      // - App 从没在 manifest 里声明过它:`requested permissions:` 小节里也找不到,
      //   这才是真正的「不支持」,要改 App 的 manifest。
      // - App 声明过,但 Android 还没有为它物化 runtime 记录:`requested
      //   permissions:` 里有,只是从未被请求/授予/拒绝过,因此从未落地到 runtime
      //   小节。这是 Android 对运行时权限的懒物化行为(实测:同一个安装,
      //   `POST_NOTIFICATIONS`/`ACCESS_FINE_LOCATION`/`CAMERA`/`RECORD_AUDIO`
      //   都在 requested 里,却只有被请求过的 `ACCESS_COARSE_LOCATION` 落进了
      //   runtime 小节),不是错误。此前只看 runtime 小节,把这种"声明了但还没人
      //   问过"的形态也报成 notDeclaredByApp,而 grant/reset 本可以物化这条记录。
      if (!_declaredPlatformPermissions(
        result.stdout,
      ).contains(platformPermission)) {
        // 封闭状态词表里 `unsupported` 本来就是可返回状态,所以这里返回状态并在
        // 证据里写清原因。`supportedActions` 同时收敛为空:没声明的权限上没有
        // 任何动作可做。
        return PatchbayPermissionStatus(
          permission: permission,
          platformPermission: platformPermission,
          state: PatchbayPermissionState.unsupported,
          platformState: 'notDeclaredByApp',
          factSource: PatchbayPermissionFactSource.deviceReported,
          driver: 'android.adb-uiautomator',
          driverVersion: '1',
          supportedActions: const <PatchbayPermissionAction>{},
          requiresRestart: false,
          requiresSettings: false,
          systemUiExpected: false,
          notice:
              '应用未在 manifest 里声明 $platformPermission，'
              '设备上不存在该运行时权限的状态。',
        );
      }
      // 声明过、只是还没物化:语义上等价于「从未被决定过」，映射到既有词表的
      // `notDetermined`，不是新状态。`platformState` 用 `noRuntimeRecord`
      // 说明具体原因是「懒物化」而非「拒绝/待定」；`supportedActions` 恢复成
      // 正常声明权限的动作集，因为 grant/reset 都能作用于它——`pm grant` 会
      // 促成 Android 落地这条 runtime 记录（真机验证见 CHANGELOG）。
      return PatchbayPermissionStatus(
        permission: permission,
        platformPermission: platformPermission,
        state: PatchbayPermissionState.notDetermined,
        platformState: 'noRuntimeRecord',
        factSource: PatchbayPermissionFactSource.deviceReported,
        driver: 'android.adb-uiautomator',
        driverVersion: '1',
        supportedActions: _statusActions,
        requiresRestart: false,
        requiresSettings: false,
        systemUiExpected: systemUiExpected,
        notice:
            '应用已在 manifest 里声明 $platformPermission，'
            '但设备尚未物化其运行时权限记录（Android 对运行时权限的懒物化行为）。'
            'grant/reset 会促成物化，之后状态将反映真实的 granted/denied。',
      );
    }
    final bool granted = match.group(1) == 'true';
    final Set<String> flags = match
        .group(2)!
        .split(RegExp(r'[|,\s]+'))
        .where((String value) => value.isNotEmpty)
        .toSet();
    // `ONE_TIME` 是 Android 对"仅这一次"授权打的标记。不认它就会把一次性授权读成普通
    // `granted`，于是 `exercise --decision allowOnce` 之后的复核拿不到区别——一个没有被
    // 证明过的结果会被当成成功。
    final PatchbayPermissionState state = granted
        ? flags.contains('ONE_TIME')
              ? PatchbayPermissionState.allowOnce
              : PatchbayPermissionState.granted
        : flags.contains('USER_FIXED')
        ? PatchbayPermissionState.permanentlyDenied
        : flags.contains('USER_SET')
        ? PatchbayPermissionState.denied
        : PatchbayPermissionState.notDetermined;
    final List<String> sortedFlags = flags.toList(growable: false)..sort();
    return PatchbayPermissionStatus(
      permission: permission,
      platformPermission: platformPermission,
      state: state,
      platformState: granted
          ? 'granted'
          : sortedFlags.isEmpty
          ? 'denied'
          : 'denied:${sortedFlags.join('|')}',
      factSource: PatchbayPermissionFactSource.deviceReported,
      driver: 'android.adb-uiautomator',
      driverVersion: '1',
      supportedActions: _statusActions,
      // Android 会在撤销一个**当前已授予**的运行时权限时终止应用进程。这是确定性的
      // 系统行为，因此不必等运行时撞上：从 `granted` 出发唯一可用的变更（revoke，
      // 以及底层同样走 revoke 的 reset）必然杀进程；从 `notDetermined` / `denied`
      // 出发的 grant 不会。所以这个字段可以由当前状态直接推出。
      //
      // 它不是"多一个好看的字段"。它固定为 false 时，监督循环分不清"瞬时断连"
      // 和"进程已被系统终止、必须重新拉起"——实测后者会让重连窗口空转到超时，
      // 等一个不可能自己回来的连接。它同时决定 exercise 闭环的步骤顺序：如果
      // 前置 reset 会杀进程，那么触发权限请求必须排在重新拉起之后。
      requiresRestart: granted,
      requiresSettings: state == PatchbayPermissionState.permanentlyDenied,
      systemUiExpected: systemUiExpected,
    );
  }

  /// 从 `dumpsys package` 的输出里读出 manifest 合并声明过的平台权限全名集合。
  ///
  /// 判据是 `requested permissions:` 小节,不是 `runtime permissions:` 小节。两者
  /// 的落地时机不同:前者在安装时由 manifest 合并产生,声明了就在;后者是 Android
  /// 对运行时权限的懒物化记录,只有权限被请求过、授予过或拒绝过之后才会出现对应的
  /// 一行。同一个应用上,`CAMERA`/`RECORD_AUDIO`/`ACCESS_FINE_LOCATION`/
  /// `POST_NOTIFICATIONS` 全部声明过,但如果只有 `ACCESS_COARSE_LOCATION`
  /// 被系统请求过,`runtime permissions:` 里就只有它一行——其余四个不物化不代表
  /// 没声明。用 `runtime permissions:` 的缺席判"没声明"会把这种懒物化态误判为
  /// `notDeclaredByApp`。
  ///
  /// 用缩进定界小节,不假定具体缩进宽度:找到 `requested permissions:` 那一行后,
  /// 后续缩进严格大于它的行都算作条目,遇到缩进回落到不大于它的行(下一个小节
  /// 标题，如 `install permissions:`)或到达输出末尾即停止。这样不依赖某个固定的
  /// 空格数，能跨 AOSP / OEM 的 dumpsys 格式差异。
  static Set<String> _declaredPlatformPermissions(String dumpsysOutput) {
    final List<String> lines = dumpsysOutput.split('\n');
    final int headerIndex = lines.indexWhere(
      (String line) => RegExp(r'^\s*requested permissions:\s*$').hasMatch(line),
    );
    if (headerIndex == -1) return const <String>{};
    final int headerIndent = _leadingSpaceCount(lines[headerIndex]);
    final Set<String> declared = <String>{};
    for (int i = headerIndex + 1; i < lines.length; i++) {
      final String line = lines[i];
      if (line.trim().isEmpty) continue;
      if (_leadingSpaceCount(line) <= headerIndent) break;
      // 条目通常是裸权限名一行；防御性地只取 `:` 前的部分，容忍某些 OEM 在这个
      // 小节里也带 `granted=` 后缀的变体。
      declared.add(line.trim().split(':').first.trim());
    }
    return declared;
  }

  static int _leadingSpaceCount(String line) {
    var count = 0;
    while (count < line.length && line[count] == ' ') {
      count++;
    }
    return count;
  }

  Future<void> _normalize(
    PatchbayPermissionDriverRequest request,
    String device,
    String applicationId,
    String permission,
  ) async {
    final String platformPermission = patchbayAndroidP0Permissions[permission]!;
    final List<String> action = switch (request.state) {
      PatchbayPermissionState.granted => <String>[
        'shell',
        'pm',
        'grant',
        applicationId,
        platformPermission,
      ],
      // 撤销只能把权限打回 `notDetermined`（`granted=false` 且不带 `USER_SET`），产生不出
      // 真正的"用户拒绝"——那只有用户在系统弹窗上按下拒绝才会有。此前这里照样 revoke，
      // 然后在复核阶段报状态不符：权限已经被改了、App 也被系统杀了，却什么都没达成。
      // 改为先拒绝、不产生副作用，并指向真正能到达该状态的动作。
      PatchbayPermissionState.denied ||
      PatchbayPermissionState.permanentlyDenied => throw _AdapterFailure(
        'permissionStateUnreachable',
        details: <String, Object?>{
          'requestedState': request.state?.name,
          'reachableVia': 'exercise',
          'decision': PatchbayPermissionDecision.deny.name,
        },
        notice:
            'adb 只能把权限撤到 notDetermined；denied 需要用户在系统弹窗上拒绝，'
            '请改用 exercise --decision deny。',
      ),
      _ => throw const _AdapterFailure('permissionStateUnsupported'),
    };
    final PatchbayPlatformCommandResult result = await _adb(
      request,
      device,
      action,
    );
    if (result.exitCode != 0) {
      throw const _AdapterFailure('permissionUnsupported');
    }
  }

  Future<void> _reset(
    PatchbayPermissionDriverRequest request,
    String device,
    String applicationId,
    String permission,
  ) async {
    final String platformPermission = patchbayAndroidP0Permissions[permission]!;
    await _adb(request, device, <String>[
      'shell',
      'pm',
      'revoke',
      applicationId,
      platformPermission,
    ]);
    for (final String flag in const <String>['user-set', 'user-fixed']) {
      final PatchbayPlatformCommandResult result = await _adb(
        request,
        device,
        <String>[
          'shell',
          'pm',
          'clear-permission-flags',
          applicationId,
          platformPermission,
          flag,
        ],
      );
      if (result.exitCode != 0) {
        throw const _AdapterFailure('permissionUnsupported');
      }
    }
  }

  Future<PatchbayPermissionDriverResponse> _exercise(
    PatchbayPermissionDriverRequest request,
    String device,
    String applicationId,
    String permission,
    PatchbayPermissionStatus before,
  ) async {
    final String? runner = instrumentationRunner;
    final PatchbayPermissionDecision? decision = request.decision;
    if (runner == null || runner.isEmpty || decision == null) {
      throw const _AdapterFailure('permissionDecisionUnsupported');
    }
    final PatchbayPlatformCommandResult result =
        await _adb(request, device, <String>[
          'shell',
          'am',
          'instrument',
          '-w',
          '-r',
          '-e',
          'targetPackage',
          applicationId,
          '-e',
          'permission',
          permission,
          '-e',
          'decision',
          decision.name,
          runner,
        ]);
    final String? marker = result.stdout
        .split('\n')
        .where((String line) => line.startsWith('PATCHBAY_RESULT='))
        .map((String line) => line.substring('PATCHBAY_RESULT='.length))
        .firstOrNull;
    if (result.exitCode != 0 || marker == null) {
      throw const _AdapterFailure('systemUiUnexpected');
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(base64Decode(marker)));
    } on Object {
      throw const _AdapterFailure('systemUiUnexpected');
    }
    if (decoded is! Map<String, dynamic> ||
        decoded['targetPackage'] != applicationId ||
        decoded['permission'] != permission ||
        decoded['decision'] != decision.name ||
        decoded['handled'] != true) {
      throw const _AdapterFailure('systemUiUnexpected');
    }
    return acceptedPermissionDriverResponse(
      request,
      before: before,
      after: await _status(
        request,
        device,
        applicationId,
        permission,
        systemUiExpected: true,
      ),
      evidence: <PatchbayPermissionEvidence>[
        _evidence('androidUiAutomator', device),
      ],
      interruption: PatchbayPermissionInterruption(
        expected: true,
        handled: true,
        permission: permission,
        decision: decision,
      ),
    );
  }

  Future<PatchbayPlatformCommandResult> _adb(
    PatchbayPermissionDriverRequest request,
    String device,
    List<String> arguments,
  ) => _run(adbExecutable, <String>[
    '-s',
    device,
    ...arguments,
  ], permissionAdapterTimeout(request));

  static String _requiredPermission(PatchbayPermissionDriverRequest request) {
    final String? permission = request.permission;
    if (permission == null ||
        !patchbayAndroidP0Permissions.containsKey(permission)) {
      throw const _AdapterFailure('permissionUnsupported');
    }
    return permission;
  }

  static String _requiredApplication(PatchbayPermissionDriverRequest request) {
    final String? applicationId = request.applicationId;
    if (applicationId == null || applicationId.isEmpty) {
      throw const _AdapterFailure('platformApplicationMismatch');
    }
    return applicationId;
  }

  static bool _mutates(PatchbayPermissionOperation operation) =>
      operation == PatchbayPermissionOperation.normalize ||
      operation == PatchbayPermissionOperation.reset ||
      operation == PatchbayPermissionOperation.exercise;

  static PatchbayPermissionEvidence _evidence(String kind, String device) =>
      PatchbayPermissionEvidence(
        factSource: PatchbayPermissionFactSource.deviceReported,
        kind: kind,
        details: <String, Object?>{'deviceId': device},
      );
}

final class _AdapterFailure implements Exception {
  const _AdapterFailure(
    this.code, {
    this.details = const <String, Object?>{},
    this.notice,
  });

  final String code;
  final Map<String, Object?> details;

  /// 给人读的一句话。稳定 code 说的是"哪一类失败"，notice 说的是"下一步该做什么"，
  /// 例如 denied 不可达时指向 `exercise --decision deny`。
  final String? notice;
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
