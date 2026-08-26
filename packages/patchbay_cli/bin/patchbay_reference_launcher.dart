// 宿主侧会话声明器的参考实现。仓内 example 用它，接入方可以照抄。
//
// 为什么需要它：权限写操作（`normalize` / `exercise` / `fail`）只接受 `--session`，也就是
// 必须存在 launcher 会话库里的一条活动记录；而记录**由被 `patchbay launch` 监督的子进程
// 自己声明**，不是由 CLI 代写。此前仓内 example 用 `--vmservice-out-file` 直接取 URI、
// 从不声明记录，于是权限写路径在仓内没有任何可跑的载体——预检里权限一节只能验证
// 「没装 driver 时 fail-closed」。这不是覆盖疏漏，是结构限制。
//
// 职责边界刻意保持最小：本程序只做「起 App → 取到 URI → 声明会话 → 退出时清理」。
// 重连、生命周期判定、keep-awake 续租都由 `patchbay launch` 的监督循环负责，它读的正是
// 这里写下的记录。真实接入方的 launcher 也应当只承担这一段。
//
// 用法（由 tool/example_session.sh 调用，不必手敲）：
//   patchbay launch -- dart run bin/patchbay_reference_launcher.dart \
//     --device <id> --application-id <id> [--build-mode debug] [--project <dir>]
import 'dart:async';
import 'dart:io';

import 'package:patchbay_cli/patchbay_cli.dart';
import 'package:patchbay_cli/src/platform/process_utils.dart';

Future<int> main(List<String> arguments) async {
  final Map<String, String> options = _parse(arguments);
  final String? device = options['device'];
  if (device == null || device.isEmpty) {
    stderr.writeln(
      '用法：dart run bin/patchbay_reference_launcher.dart '
      '--device <id> --application-id <id>',
    );
    return 64;
  }
  final String? applicationId = options['application-id'];
  if (applicationId == null || applicationId.isEmpty) {
    stderr.writeln('必须给 --application-id：会话对账按它比对 host 的 identity');
    return 64;
  }
  final String buildMode = options['build-mode'] ?? 'debug';
  final Directory project = Directory(
    options['project'] ?? Directory.current.path,
  );

  // 不在受监督环境里就直接失败，而不是"顺便也能跑"：一条没有 owner 的会话记录会被
  // 后续的 prune 判成孤儿，写它只会制造噪声。
  final PatchbayLaunchContext? context =
      PatchbayLaunchContext.tryFromEnvironment(Platform.environment);
  if (context == null) {
    stderr.writeln(
      '未检测到 patchbay launch 注入的环境；请用 '
      '`patchbay launch -- dart run bin/patchbay_reference_launcher.dart ...` 启动',
    );
    return 64;
  }

  final PatchbaySessionStore store = PatchbaySessionStore(
    context.sessionDirectory,
  );
  final Directory uriDirectory = Directory.systemTemp.createTempSync(
    'patchbay-example-session-',
  );
  final File uriFile = File('${uriDirectory.path}/vmservice.uri');

  final Process app = await Process.start('flutter', <String>[
    'run',
    '-d',
    device,
    '--$buildMode',
    '--no-pub',
    '--vmservice-out-file',
    uriFile.path,
  ], workingDirectory: project.path);
  // App 的 stdio 不接管也不丢：URI 只从文件读，日志原样透出给操作者。
  app.stdout.listen(stdout.add);
  app.stderr.listen(stderr.add);

  final String sessionId =
      'reference-${context.launchId}-${DateTime.now().microsecondsSinceEpoch}';
  var declared = false;

  Future<void> cleanup() async {
    if (declared) store.remove(sessionId);
    try {
      uriDirectory.deleteSync(recursive: true);
    } on FileSystemException {
      // 清理失败不该改变退出码：产物在系统临时目录里，下次开机就没了。
    }
  }

  // 会话记录带认证材料，进程被 Ctrl-C 或被上层杀掉时必须删掉，不能留给下一次运行。
  late final StreamSubscription<ProcessSignal> sigint;
  sigint = ProcessSignal.sigint.watch().listen((_) async {
    await cleanup();
    app.kill();
    await sigint.cancel();
  });

  // 先声明一条 pending 记录，再去等 URI。顺序不能颠倒：`patchbay launch` 有自己的
  // 声明窗口，等 App 起来再声明会让它在子进程还在构建时就判 `sessionNotDeclared` 失败。
  // 显式 pending 状态就是为这段"还没有传输"的时间存在的——不用空 URI 去暗示启动中。
  // workspace 归属由 `patchbay launch` 在启动本进程前算好，经 launch context 注入；
  // 本程序不自己推断，也不用 `--project` 覆盖它——子进程改 cwd 不该改变会话归属。
  // 老 launcher（不注入 workspace）下 context.workspace 为 null，这里照旧写 legacy
  // 记录，不伪造身份。
  final PatchbaySessionRecord pending = PatchbaySessionRecord(
    sessionId: sessionId,
    applicationId: applicationId,
    appInstanceId: null,
    isolateId: null,
    processId: app.pid,
    // 传输未知时必须是 null，不是空字符串：监督循环按 `wsUri == null` 判断"还没有传输"，
    // 空字符串会被当成"有传输但地址为空"，于是探测永远失败、一路 sessionUnreachable。
    wsUri: null,
    buildMode: buildMode,
    createdAt: DateTime.now().toUtc(),
    workspacePath: context.workspace?.canonicalRoot ?? project.path,
    deviceId: device,
    state: PatchbaySessionStatus.pending,
    ownerPid: context.ownerPid,
    launchId: context.launchId,
    observedAtMs: DateTime.now().millisecondsSinceEpoch,
    // 启动身份在记录创建时采集一次；采集不到保持 null（老记录语义，纯 PID 判定）。
    processStartTime: PlatformProcessUtils.processStartTimeSignature(app.pid),
    workspaceIdentityVersion: context.workspace == null
        ? null
        : patchbayWorkspaceIdentityVersion,
    workspaceKind: context.workspace?.kind,
    workspaceId: context.workspace?.workspaceId,
  );
  store.write(pending);
  declared = true;
  stderr.writeln('[reference-launcher] 会话已声明为 pending：$sessionId');

  final DateTime deadline = DateTime.now().add(const Duration(minutes: 5));
  while (DateTime.now().isBefore(deadline)) {
    if (uriFile.existsSync() && uriFile.readAsStringSync().trim().isNotEmpty) {
      break;
    }
    if (await app.exitCode.timeout(
          const Duration(milliseconds: 400),
          onTimeout: () => -1,
        ) !=
        -1) {
      await cleanup();
      stderr.writeln('flutter run 已退出，未取到 VM Service URI');
      return 1;
    }
  }
  final String wsUri = uriFile.existsSync()
      ? uriFile.readAsStringSync().trim()
      : '';
  if (wsUri.isEmpty) {
    await cleanup();
    stderr.writeln('5 分钟内没等到 VM Service URI');
    app.kill();
    return 1;
  }

  // 只补传输，状态仍留 pending：identity 探测通过后由 `patchbay launch` 改成 live。
  // 子进程不自己宣布"活着"——那是它无权断言的事实。
  store.write(
    pending.withTransport(
      wsUri,
      observedAtMs: DateTime.now().millisecondsSinceEpoch,
    ),
  );
  stderr.writeln('[reference-launcher] 传输已补齐（URI 不打印）');

  final int code = await app.exitCode;
  await cleanup();
  await sigint.cancel();
  return code;
}

Map<String, String> _parse(List<String> arguments) {
  final Map<String, String> parsed = <String, String>{};
  for (var index = 0; index < arguments.length; index += 1) {
    final String argument = arguments[index];
    if (!argument.startsWith('--')) continue;
    final String key = argument.substring(2);
    final String? value = index + 1 < arguments.length
        ? arguments[index + 1]
        : null;
    if (value != null && !value.startsWith('--')) {
      parsed[key] = value;
      index += 1;
    } else {
      parsed[key] = '';
    }
  }
  return parsed;
}
