import 'dart:io';

import 'package:test/test.dart';

/// PB-050-23：稳定拒绝码注册表 ratchet。
///
/// 背景（见 docs/design.md、docs/guide.md 对「稳定 code」的叙述）：Patchbay 的
/// rejection / error 信封是「稳定 `code` + 自由 `details`」同构的两种写法（App
/// 侧 `PatchbayRejection.code`、CLI 侧 `error.code`）。`code` 对外承诺不随意
/// 改名/删除，`details` 则是自由诊断内容，不受此约束。contracts/core_wire.json
/// 把 wire 上的 `code` 字段类型定义为不受限的 `String`（第 179 行），也就是说
/// 协议层面本身不提供一张封闭码表——「这些 code 值是封闭集合」目前只是团队自觉，
/// 没有机器强制。本测试把这份自觉变成机检：全仓扫描 packages/*/lib 里所有会
/// 成为「稳定 code」字面量的写法，断言它们都在下面冻结的注册表内；新增一个
/// 字面量码却忘了登记，测试立刻红。
///
/// ## 判据：什么算「稳定 code」
///
/// 只锁「会流到 rejection/error 信封顶层 `code` 字段」的字面量，具体是下面这些
/// 语法形态（本文件下方 `_scanFile` 实现，逐条列出真实存在于当前代码里的写法，
/// 而不是猜测的通用规则）：
///
/// 1. `code: 'xxx'` —— 具名参数直接量（`PatchbayRejection(code: ...)` 等）。
/// 2. `'code': 'xxx'` —— Map 字面量里的 `'code'` 键（JSON 信封手写场景）。
/// 3. `reasonCode: 'xxx'` / `'reasonCode': 'xxx'` —— CLI 侧事件/清单用的平行
///    字段，语义同 `code`（如 launcher.dart 的 `emit(..., reasonCode: ...)`）。
/// 4. `timeoutCode: 'xxx'` —— manifest_runner.dart 超时专用的具名参数。
/// 5. `.rejected('xxx')` —— 各 `*Resolution.rejected(...)` / `_WaitProbe.rejected`
///    等内部 factory 的第一个位置参数。
/// 6. `XxxException('xxx')` / `XxxFailure('xxx')` / `XxxViolation('xxx')` /
///    `XxxRejected('xxx')` / `XxxRejection('xxx')` —— 以这些后缀结尾的类型的
///    构造调用，第一个位置参数是字面量。
/// 7. `xxxCode ?? 'xxx'` —— 已有 code 缺失时的兜底默认值（如
///    `gates.dart` 的 `code: base.code ?? 'baseGateRejected'`）。
/// 8. `xxxCode = 'xxx'`（顶层 const 或局部变量赋值，标识符以 `Code` 结尾）——
///    如 `patchbayAppUnresponsiveCode`、`lastStaleCode = 'sessionPending'`。
/// 9. `EnumType.member => 'xxx'` 或 switch 通配 `_ => 'xxx'` —— 把内部枚举
///    （如 `PatchbayBlobFailureCode`）转成 wire code 的 switch 表达式分支。
/// 10. 已知的「code 转发 helper」——见下方 `_codeForwardingHelpers`：这些私有/
///     包内函数把 code 作为参数转发给 `PatchbayRejection`/`.rejected(...)`，
///     字面量出现在调用点而不是定义点，语法上和普通函数调用没有区别，
///     无法用通用规则识别，所以按函数名单独处理。
///
/// ## 判据：什么排除在外（不锁）
///
/// - `details:`/`notice:` 内部的自由文本、以及 details Map 的键名——这些是
///   `docs/design.md` 明确说的「自由 details」，不是稳定 code。扫描时会跳过
///   `details:`/`notice:` 之后的内容，以及紧跟在 `[` 之后的 `json['field']`
///   取字段名字面量。
/// - 只在 `details.reason`/内部一致性检查里出现、从未成为顶层 `code` 的字符串。
///   例如 `host_invoker.dart` 的 `_invocationSemanticViolation` 返回的
///   `'emptyRequestId'`/`'acceptedWithRejection'` 等——读源码确认它们只塞进
///   `_invalidInvocationEnvelope` 的 `details.reason`，顶层 `code` 永远是
///   `'providerProtocolViolation'`；这类字符串故意不收录。
/// - 纯内部展示/回退值，不是 code 语义：如 `'unknown'`、`'none'`、
///   `'xcodebuild'`、`'direct'`/`'vmService'`（transport 模式名）——不满足上面
///   任何一种语法形态，天然不会被扫描逻辑命中。
///
/// ## 维护说明
///
/// **新增码先进这张表，否则测试红。** 冻结清单 `_frozenStableCodes` 按字母序
/// 排列；新增一个稳定拒绝码时，先把字符串加进这张表（可以顺手排好序，但排序
/// 只是可读性，不是断言的一部分），再让测试通过。清单不因为「这个码看起来该
/// 删/该改名」而擅自变动——ratchet 只管新增，不做清理判断；确有需要清理时，
/// 走独立的变更并说明理由，不要和功能改动混在一次改动里。
///
/// 本清单是 2026-08（PB-050-23）对 packages/*/lib 的一次性全量核对结果。有
/// 少数条目在核对时判断为「值得保留但不完全确定是协议稳定码」，已在下面用
/// 行内注释标出，不代表它们不该在表里——按本任务的指令，存疑但已存在的散码
/// 一律先如实入表（ratchet 锁现状），去留判断留给后续独立评审。
const Set<String> _frozenStableCodes = <String>{
  'appUnresponsive',
  'artifactMetadataContractViolated',
  'artifactPayloadContractViolated',
  'artifactSourceFailed',
  'baseGateRejected',
  'blobAdmissionFailed',
  'blobBase64Invalid',
  'blobCapacityExceeded',
  'blobChunkContractViolated',
  'blobExpired',
  'blobIntegrityMismatch',
  'blobInvalidChunkLimit',
  'blobInvalidTtl',
  'blobLengthOutOfBounds',
  'blobMetadataContractViolated',
  'blobNotFound',
  'blobOffsetOutOfBounds',
  'blobPayloadContractViolated',
  'blobTooLarge',
  'budgetExceeded',
  'captureByteLimitExceeded',
  'captureDiffArtifactExpired',
  'captureDiffArtifactNotFound',
  'captureDiffArtifactUnavailable',
  'captureDiffArtifactUnsupported',
  'captureDiffByteLimitExceeded',
  'captureDiffDecodeFailed',
  'captureDiffPixelLimitExceeded',
  'captureDiffSpecMismatch',
  'captureEncodingFailed',
  'captureEncodingTimeout',
  'captureFrameTimeout',
  'captureGenerationWithoutTarget',
  'captureLifecycleNotResumed',
  'capturePixelLimitExceeded',
  'captureRootNotMounted',
  'captureTargetChanged',
  'captureTargetGenerationRequired',
  'captureTargetNotPainted',
  'catalogContractViolated',
  'catalogInvocationDrift',
  'catalogRetryPolicyInvalid',
  'catalogUiTargetsContractViolated',
  'childStartFailed',
  'clientClosed',
  'commandNotRegistered',
  'consumerGateRejected',
  'duplicateRequestId',
  'flutterDiagnosticUnavailable',
  'identityMismatch',
  'identityValidationFailed',
  'inspectorUnavailable',
  'invalidArguments',
  'invalidCaptureArguments',
  'invalidInspectArguments',
  'invalidKeepAwakeArguments',
  'invalidNavigationArguments',
  'invalidSnapshotDiffRequest',
  'invalidSnapshotRequest',
  'invalidUiArguments',
  'invalidUiTreeLimits',
  'jobWaitPayloadContractViolated',
  'keepAwakeDelegateFailed',
  'keepAwakeHostDisposed',
  'keepAwakeLifecycleNotResumed',
  'keepAwakeNotWired',
  'keepAwakeTransportUnavailable',
  'launchBudgetInvalid',
  'launchCancelled',
  'launchContextInvalid',
  'launchSessionAmbiguous',
  'localArtifactTooLarge',
  'localArtifactVerifyFailed',
  'localArtifactWriteFailed',
  'logCursorStale',
  'logQueryTimeout',
  'logRecordTooLarge',
  'logRedactionContractViolated',
  'logSourceContractViolated',
  'manifestDestinationUnavailable',
  'manifestFormatUnsupported',
  'manifestInvalid',
  'manifestNamespaceConflict',
  'manifestResourceLimit',
  'manifestRestoreBudgetUnavailable',
  'manifestRestoreFailed',
  'manifestSemanticsContractViolated',
  'manifestSemanticsIdentifierAmbiguous',
  'manifestSemanticsResourceLimit',
  'manifestSemanticsTreeTruncated',
  'manifestSemanticsUnavailable',
  'manifestUnreadable',
  'manifestWalkthroughScreenTimeout',
  'manifestWalkthroughTotalTimeout',
  'navigationCapabilityUnavailable',
  'navigationCatalogContractViolated',
  'navigationCurrentUnregistered',
  'navigationDestinationAmbiguous',
  'navigationDestinationContractViolated',
  'navigationDestinationNotFound',
  'navigationLifecycleNotResumed',
  'navigationObserverFailed',
  'navigationOperationUnavailable',
  'navigationPolicyChanged',
  'navigationRedirected',
  'navigationRequestFailed',
  'navigationRevisionContractViolated',
  'navigationRevisionStale',
  'navigationTimeout',
  'navigationUnavailable',
  'networkProfilingUnavailable',
  'pendingSessionExpired',
  'pendingTtlInvalid',
  'performanceProfileMalformedVmResponse',
  'performanceProfileTimelineRestoreFailed',
  'performanceProfileVmRpcFailed',
  'performanceProfilingUnavailable',
  'permissionCapabilityInvalid',
  'permissionDecisionRequired',
  'permissionDecisionUnsupported',
  'permissionDriverRequestInvalid',
  'permissionDriverResponseInvalid',
  'permissionEvidenceInvalid',
  'permissionInterruptionInvalid',
  'permissionOperationInvalid',
  'permissionReleaseBuildForbidden',
  // 存疑：来自 ios_xcuitest_runner.dart 的 `throw const
  // FormatException('permissionRunnerArgumentsInvalid')`——用的是 Dart 内置
  // FormatException 而不是 Patchbay 自家的 code 承载类型，不确定这条是否真的
  // 会流到某个稳定 `code` 字段还是只作为本地 CLI 参数解析的报错文案。按
  // ratchet 现状收录，去留留给后续评审。
  'permissionRunnerArgumentsInvalid',
  'permissionSessionIdentityMismatch',
  'permissionStateMismatch',
  'permissionStateRequired',
  'permissionStateUnreachable',
  'permissionStateUnsupported',
  'permissionStatusInvalid',
  'permissionTimeoutInvalid',
  'permissionUnsupported',
  'platformApplicationMismatch',
  'platformDeviceUnavailable',
  'platformDriverFailed',
  'platformDriverProtocolError',
  'platformDriverRequestMismatch',
  'platformDriverResponseTooLarge',
  'platformDriverUnavailable',
  'platformDriverVersionMismatch',
  'profilingVmServiceRequired',
  'protocolError',
  'providerProtocolViolation',
  'hostDisposed',
  'invocationCallerDisconnected',
  'invocationCancelled',
  'invocationDeadlineExceeded',
  'requestIdConflict',
  'requestIdMismatch',
  'requestIdValidationFailed',
  'requestLedgerFull',
  'responseTooLarge',
  'schemaVersionMismatch',
  'sensitiveInputRequiresStdin',
  'sessionAmbiguous',
  'sessionDirectoryEmpty',
  'sessionIdInvalid',
  'sessionIdentityMismatch',
  'sessionNotFound',
  'sessionPending',
  'sessionRecordInvalid',
  'sessionRuntimeRestarted',
  'sessionSchemaMismatch',
  // PB-050-14：workspace 亲和性的四个新码。前三个是"当前 checkout 归属"三种
  // 判不出/判否的形态，最后一个是 scoped pin 的资源上限；本稿之外不再新增。
  'sessionSelectionCapacityExceeded',
  'sessionSelectionInvalid',
  'sessionSelectionStale',
  'sessionStaleProcess',
  'sessionStaleTransport',
  'sessionUnreachable',
  'sessionWorkspaceEmpty',
  'sessionWorkspaceMismatch',
  'sessionWorkspaceUnavailable',
  'snapshotDiffClientUnavailable',
  'snapshotDiffLimitExceeded',
  'snapshotPayloadTooLarge',
  'snapshotRevisionUnavailable',
  'snapshotSelectionUnsupportedByHost',
  'snapshotWaitTimeout',
  'stoppedAfterFailure',
  'systemUiUnexpected',
  'terminalEchoControlFailed',
  'terminalEchoRestoreFailed',
  // 存疑：单个全小写单词，没有其他同类码那样的驼峰分词。来自
  // `PatchbayDirectClientException('timeout')`（direct_client.dart），构造形态
  // 和同文件里的 'protocolError'/'transportError' 等一致，按同类收录；是否要
  // 改成更具描述性的名字留给后续评审。
  'timeout',
  'traceActivePointerInvalid',
  'traceAlreadyActive',
  'traceAlreadyFinished',
  'traceArtifactInvalid',
  'traceArtifactMissing',
  'traceArtifactPathInvalid',
  'traceBundleTooLarge',
  'traceEventInvalid',
  'traceEventTooLarge',
  'traceEventTypeUnsupported',
  'traceExportExists',
  'traceHomeUnavailable',
  'traceIdInvalid',
  'traceIntegrityMismatch',
  'traceManifestInvalid',
  'traceNameEmpty',
  'traceNotActive',
  'traceNotFound',
  'traceNoteEmpty',
  'traceRetentionAgeExceeded',
  'traceRetentionBytesExceeded',
  'traceRetentionCountExceeded',
  'traceTruncatedTail',
  'transportError',
  'uiGenerationStale',
  'uiGestureBudgetExceeded',
  'uiGestureDenied',
  'uiGesturePointOutOfBounds',
  'uiGesturePolicyChanged',
  'uiGestureTargetObscured',
  'uiGesturesDisabled',
  'uiLifecycleNotResumed',
  'uiOperationUnavailable',
  // PB-050-17：reveal 的六个准入前稳定码。受理后的 `reason` 词表不在这里——
  // 那一组落在 payload 的自由字段上，由 packages/patchbay_flutter 的
  // `PatchbayRevealReason` 封闭集合与穷尽性测试锁定。
  'uiRevealBudgetExceeded',
  'uiRevealContainerAmbiguous',
  'uiRevealDenied',
  'uiRevealDisabled',
  'uiRevealNoScrollableContainer',
  'uiRevealPolicyChanged',
  'uiSemanticsActionBlocked',
  'uiSemanticsActionDenied',
  'uiSemanticsActionUnavailable',
  'uiSemanticsActionsDisabled',
  'uiSemanticsGenerationStale',
  'uiSemanticsIdentifierAmbiguous',
  'uiSemanticsIdentifierNotFound',
  'uiSemanticsNodeNotFound',
  'uiSemanticsNodeNotObserved',
  'uiSemanticsPolicyChanged',
  'uiSemanticsTargetAmbiguous',
  'uiSemanticsTargetObscured',
  'uiSemanticsTextRequired',
  'uiSemanticsUnavailable',
  'uiSemanticsUnexpectedText',
  'uiSemanticsValueRedacted',
  'uiTargetAmbiguous',
  'uiTargetNotFound',
  'uiTargetUnmounted',
  'uiWaitLifecycleNotResumed',
  'uiWaitTimeout',
  'vmServiceUnavailable',
};

/// 已知的「code 转发 helper」函数名单（判据第 10 条）。
///
/// 这些私有/包内函数把稳定 code 作为参数转发给 `PatchbayRejection(code:
/// code, ...)` 或等价构造，字面量出现在**调用点**而不是定义点：
///
/// - `_reject` / `_rejected`：多个 bridge 文件（capture_bridge.dart、
///   inspect_bridge.dart、navigation_bridge.dart、gesture_bridge.dart、
///   keep_awake_bridge.dart、ui_wait_bridge.dart、artifact_service.dart）
///   各自定义的同名私有方法，签名形如 `(requestId, code, {details, notice})`。
/// - `_rejectionEnvelope`：host_snapshot.dart，签名
///   `(code, notice, details)`，三者都是位置参数。
/// - `_externalDuplicateRejection`：host_invoker.dart，
///   签名 `(requestId, code)`。
/// - `rejectedPermissionDriverResponse`：permission_platform_adapter.dart，
///   签名 `(request, code, {details})`。
/// - `localWalkthroughFailure`：manifest_runner.dart，
///   签名 `(code)`。
/// - `_requiredString` / `_optionalString`：permissions.dart 的 JSON 字段
///   解析辅助函数，签名 `(value, code)`——`code` 是字段缺失/类型不对时抛出的
///   `PatchbayPermissionWireException` 的稳定码。
///
/// 这是一份枚举名单，不是通用规则：Dart 语法本身无法区分「这个位置参数将来
/// 会成为稳定 code」和普通字符串参数。以后再新增一个同类 helper（换一个新
/// 名字转发 code），本测试的扫描逻辑不会自动发现它，需要把新名字加进这里，
/// 否则该 helper 转发的新字面量会被扫描逻辑静默漏掉（而不是被冻结清单挡红）。
/// 这是本测试相对完整静态分析的已知局限，写在这里以便下次踩到时能想起来。
const List<String> _codeForwardingHelpers = <String>[
  '_reject',
  '_rejected',
  '_rejectionEnvelope',
  '_externalDuplicateRejection',
  'rejectedPermissionDriverResponse',
  'localWalkthroughFailure',
  '_requiredString',
  '_optionalString',
];

/// 判据第 1-9 条对应的通用扫描正则。每条都标了产生这类写法的真实判例。
final List<_ScanPattern> _generalPatterns = <_ScanPattern>[
  // 1) code: 'xxx'  —— 排除 `'code':` 这种 map 字面量键（由第 2 条单独处理），
  //    用负向前瞻跳过前面已经出现单引号的情况。
  _ScanPattern(
    'named_code',
    RegExp(r"(?<![\w'])code:\s*'([a-zA-Z][a-zA-Z0-9_]*)'"),
  ),
  // 2) 'code': 'xxx'
  _ScanPattern(
    'quoted_key_code',
    RegExp(r"'code':\s*'([a-zA-Z][a-zA-Z0-9_]*)'"),
  ),
  // 3) reasonCode: 'xxx' / 'reasonCode': 'xxx'
  _ScanPattern(
    'named_reasonCode',
    RegExp(r"reasonCode:\s*'([a-zA-Z][a-zA-Z0-9_]*)'"),
  ),
  _ScanPattern(
    'quoted_reasonCode',
    RegExp(r"'reasonCode':\s*'([a-zA-Z][a-zA-Z0-9_]*)'"),
  ),
  // 4) timeoutCode: 'xxx'
  _ScanPattern(
    'named_timeoutCode',
    RegExp(r"timeoutCode:\s*'([a-zA-Z][a-zA-Z0-9_]*)'"),
  ),
  // 5) .rejected('xxx')
  _ScanPattern(
    'rejected_factory',
    RegExp(r"\.rejected\(\s*'([a-zA-Z][a-zA-Z0-9_]*)'"),
  ),
  // 6) XxxException('xxx') / XxxFailure(...) / XxxViolation(...) /
  //    XxxRejected(...) / XxxRejection('xxx')
  _ScanPattern(
    'exc_ctor_literal',
    RegExp(
      r"(?:Exception|Failure|Violation|Rejected|Rejection)\(\s*(?:const\s+)?'([a-zA-Z][a-zA-Z0-9_]*)'",
    ),
  ),
  // 7) xxxCode ?? 'xxx'
  _ScanPattern(
    'code_suffix_fallback',
    RegExp(r"\w*[Cc]ode\s*\?\?\s*'([a-zA-Z][a-zA-Z0-9_]*)'"),
  ),
  // 8) xxxCode = 'xxx'（顶层 const 或局部变量）
  _ScanPattern(
    'code_suffix_assign',
    RegExp(r"\b\w*Code\s*=\s*'([a-zA-Z][a-zA-Z0-9_]*)'"),
  ),
  // 9) EnumType.member => 'xxx' 或 switch 通配 _ => 'xxx'
  _ScanPattern(
    'switch_arrow_code',
    RegExp(r"(?:\w+\.\w+|_)\s*=>\s*'([a-zA-Z][a-zA-Z0-9_]*)'"),
  ),
];

class _ScanPattern {
  _ScanPattern(this.name, this.regExp);
  final String name;
  final RegExp regExp;
}

class _CodeHit {
  _CodeHit(this.code, this.file, this.line, this.pattern);
  final String code;
  final String file;
  final int line;
  final String pattern;

  @override
  String toString() => '$code  ($file:$line, $pattern)';
}

void main() {
  final String? root = _repoRoot();

  test(
    'packages/*/lib 中出现的稳定拒绝码字面量都在冻结注册表内 (PB-050-23)',
    () {
      final List<_CodeHit> hits = _scanStableCodes(root!);

      final Map<String, _CodeHit> unregistered = <String, _CodeHit>{};
      final Set<String> discovered = <String>{};
      for (final _CodeHit hit in hits) {
        discovered.add(hit.code);
        if (!_frozenStableCodes.contains(hit.code)) {
          unregistered.putIfAbsent(hit.code, () => hit);
        }
      }

      // 扫描逻辑本身必须真的在工作：仓内已知至少有 200+ 个稳定码字面量，
      // 如果扫出来的数量骤降，大概率是扫描坏了而不是代码变少了。
      expect(
        discovered.length,
        greaterThan(150),
        reason:
            '只扫到 ${discovered.length} 个稳定码字面量，'
            '远低于 PB-050-23 核对时的 ${_frozenStableCodes.length} 个，'
            '扫描逻辑可能已经失效（例如 lib 目录定位错了）',
      );

      final List<String> sortedUnregistered = unregistered.keys.toList()
        ..sort();
      final String detail = sortedUnregistered
          .map((String code) => '  - ${unregistered[code]}')
          .join('\n');

      expect(
        unregistered,
        isEmpty,
        reason:
            '发现 ${unregistered.length} 个未注册的稳定拒绝码，'
            '请先加入 packages/patchbay/test/error_code_registry_ratchet_test.dart '
            '的 _frozenStableCodes：\n$detail',
      );
    },
    skip: root == null ? '不在仓库工作树内，跳过全仓扫描' : null,
  );
}

String? _repoRoot() {
  Directory dir = Directory.current.absolute;
  for (int i = 0; i < 6; i++) {
    final bool looksLikeRoot =
        Directory('${dir.path}/packages/patchbay/lib').existsSync() &&
        Directory('${dir.path}/packages/patchbay_cli/lib').existsSync() &&
        Directory('${dir.path}/packages/patchbay_flutter/lib').existsSync() &&
        Directory('${dir.path}/packages/patchbay_transport/lib').existsSync();
    if (looksLikeRoot) return dir.path;
    final Directory parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

List<_CodeHit> _scanStableCodes(String repoRoot) {
  final List<_CodeHit> hits = <_CodeHit>[];
  for (final String package in <String>[
    'patchbay',
    'patchbay_cli',
    'patchbay_flutter',
    'patchbay_transport',
  ]) {
    final Directory libDir = Directory('$repoRoot/packages/$package/lib');
    if (!libDir.existsSync()) continue;
    for (final FileSystemEntity entity in libDir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final String text = entity.readAsStringSync();
      final String relPath = entity.path.substring(repoRoot.length + 1);
      hits.addAll(_scanFile(text, relPath));
    }
  }
  return hits;
}

List<_CodeHit> _scanFile(String text, String relPath) {
  final List<_CodeHit> hits = <_CodeHit>[];

  for (final _ScanPattern pattern in _generalPatterns) {
    for (final RegExpMatch match in pattern.regExp.allMatches(text)) {
      final String code = match.group(1)!;
      final int line = _lineOf(text, match.start);
      hits.add(_CodeHit(code, relPath, line, pattern.name));
    }
  }

  for (final String helper in _codeForwardingHelpers) {
    hits.addAll(_scanHelperCalls(text, relPath, helper));
  }

  return hits;
}

int _lineOf(String text, int offset) =>
    '\n'.allMatches(text.substring(0, offset)).length + 1;

/// 扫描判据第 10 条：对 [helper] 的每次调用，取到括号配平的参数子串，
/// 在「details:/notice: 具名参数开始」或「不是紧跟在 switch (...) 后面的
/// 集合/Map 字面量 `{`」之前截断，只在这段位置参数前缀里找裸字面量——
/// 这样既能吃到 `switch (x) { ...; _ => 'code' }` 这种把 switch 表达式整个
/// 当位置参数的写法，又不会把 `details: <String, Object?>{'gateId': ...}`
/// 里的 Map 键名当成 code。
List<_CodeHit> _scanHelperCalls(String text, String relPath, String helper) {
  final List<_CodeHit> hits = <_CodeHit>[];
  final RegExp callSite = RegExp(RegExp.escape(helper) + r'\(');
  for (final RegExpMatch match in callSite.allMatches(text)) {
    // 确保匹配的是完整标识符调用（前一个字符不是标识符字符），避免
    // `_reject` 命中 `_rejectFoo` 之类的前缀撞名。
    final int nameStart = match.start;
    if (nameStart > 0 && RegExp(r'\w').hasMatch(text[nameStart - 1])) {
      continue;
    }
    final int openParen = match.end - 1;
    final int closeParen = _matchingParen(text, openParen);
    if (closeParen == -1) continue;
    final String args = text.substring(openParen + 1, closeParen);
    final String prefix = args.substring(0, _argPrefixCut(args));
    for (final RegExpMatch lit in RegExp(
      r"(?<!\[)'([a-zA-Z][a-zA-Z0-9_]*)'",
    ).allMatches(prefix)) {
      final int line = _lineOf(text, match.start);
      hits.add(_CodeHit(lit.group(1)!, relPath, line, 'helper:$helper'));
    }
  }
  return hits;
}

int _matchingParen(String text, int openIdx) {
  int depth = 0;
  for (int i = openIdx; i < text.length; i++) {
    if (text[i] == '(') depth++;
    if (text[i] == ')') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}

/// 位置参数前缀的截断点：在 `details:`/`notice:` 关键字或者「不是紧跟在
/// `)` 后面的 `{`」两者中取最靠前的一个；没有则整段参数都算位置参数区。
int _argPrefixCut(String args) {
  int cut = args.length;
  for (final String keyword in <String>['details:', 'notice:']) {
    final int idx = args.indexOf(keyword);
    if (idx != -1 && idx < cut) cut = idx;
  }
  int searchFrom = 0;
  while (true) {
    final int braceIdx = args.indexOf('{', searchFrom);
    if (braceIdx == -1) break;
    int j = braceIdx - 1;
    while (j >= 0 && (args[j] == ' ' || args[j] == '\t' || args[j] == '\n')) {
      j--;
    }
    final bool precededByCloseParen = j >= 0 && args[j] == ')';
    if (!precededByCloseParen) {
      if (braceIdx < cut) cut = braceIdx;
      break;
    }
    searchFrom = braceIdx + 1;
  }
  return cut;
}
