#!/usr/bin/env bash
# 本地端到端预检：在一台连着的设备上把 example 跑起来，逐条打通 patchbay 的
# 命令面，并给出每一步的退出码与断言结果。
#
# 目标可以是 Android 真机/模拟器、iOS Simulator 或 iOS 真机——平台由 example_session.sh
# 按 `flutter devices` 判定。两个平台跑同一份 host/CLI 步骤清单；平台 driver 的设备矩阵只在
# 该版本承诺的平台上运行。未承诺的平台仍由无 driver 检查证明 fail-closed，不能误接另一平台的
# driver 来制造一份没有意义的失败。
#
# 它证明的是「协议 + CLI + host 三方接线在真设备上确实通」。它**不能**替代业务验收：
# 真实控制器语义、设备 SDK 确认、真实 UI 的滚动与遮挡、签名真机上的系统弹窗，都只有
# 接入方能出证据。规则见 AGENTS.md「实现与验证」。
#
# 模式：**debug（JIT）**，不是 profile/AOT。这不是随手选的默认值——`ui.inspect` 与三棵诊断树只在
# debug 构建存在（见 AGENTS.md「联调姿势」），用 profile 跑会让这几步静默消失，"全过"就不再等于
# "全覆盖"。性能数字要另跑一次 profile 会话，那次拿不到 inspect 与诊断树，属于两种用途。
#
# 但"预检只跑 debug"本身也有代价：**只在非 debug 存在的缺陷，本脚本在原理上看不见**。已实证一例
# ——`capture` 在 profile 必然退 3（BUG-20260819-02），它在这里长期全绿。那一面由
# `tool/example_profile_smoke.sh` 覆盖：跑 profile 会话，只验答复形态，不求全覆盖。两者互补，
# 任一方全绿都不代表另一方成立。
#
# CLI 本身相反：先 AOT 编成原生可执行再复用（由 example_session.sh 负责），否则四十余步会各自
# 重新编译一遍。
#
# 用法：
#   tool/example_precheck.sh [device-id]
#
# device-id 取自 `flutter devices`（Android 用 adb serial，iOS Simulator 用 simctl UDID）；
# 省略时取第一台 online 的 adb 设备。
#
# 退出码：0 全过；1 有步骤失败（末尾列出失败清单）。

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tool/example_session.sh
source "$ROOT/tool/example_session.sh"

PASS=0
FAIL=0
FAILED_STEPS=()
OUT="$(mktemp "${TMPDIR:-/tmp}/patchbay-precheck-out.XXXXXX")"
PRECHECK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/patchbay-precheck.XXXXXX")"

cleanup() {
  example_session_stop
  rm -f "$OUT"
  rm -rf "$PRECHECK_TMP"
}
trap cleanup EXIT

# 断言一条 CLI 命令的退出码，并可选地对 --json 输出跑一段 python 表达式。
#
# expect_code 允许非 0：拒绝也是答复，"应当被拒绝"同样是需要证明的行为。
check() {
  local name="$1" expect_code="$2" assertion="$3"
  shift 3
  local actual=0
  example_session_cli "$@" >"$OUT" 2>&1 || actual=$?
  if [ "$actual" != "$expect_code" ]; then
    printf '  ✗ %-42s 退出码 %s（期望 %s）\n' "$name" "$actual" "$expect_code"
    sed -E 's#(ws|http)s?://[^[:space:]]+#<redacted-uri>#g' "$OUT" | tail -3 | sed 's/^/      /'
    FAIL=$((FAIL + 1)); FAILED_STEPS+=("$name"); return 0
  fi
  if [ -n "$assertion" ]; then
    if ! PATCHBAY_OUT="$OUT" python3 -c "
import json, os, sys
raw = open(os.environ['PATCHBAY_OUT'], encoding='utf-8').read()
try:
    doc = json.loads(raw)
except Exception:
    print('输出不是 JSON'); sys.exit(1)
sys.exit(0 if bool($assertion) else 1)
" 2>/dev/null; then
      printf '  ✗ %-42s 断言不成立：%s\n' "$name" "$assertion"
      FAIL=$((FAIL + 1)); FAILED_STEPS+=("$name"); return 0
    fi
  fi
  printf '  ✓ %-42s\n' "$name"
  PASS=$((PASS + 1))
}

# 本地命令：不连 App，也不能带 --ws-uri。
example_session_cli_local() {
  "$PATCHBAY_CLI_BIN" "$@"
}

check_local() {
  local name="$1" expect_code="$2" assertion="$3"
  shift 3
  local actual=0
  example_session_cli_local "$@" >"$OUT" 2>&1 || actual=$?
  if [ "$actual" != "$expect_code" ]; then
    printf '  ✗ %-42s 退出码 %s（期望 %s）\n' "$name" "$actual" "$expect_code"
    FAIL=$((FAIL + 1)); FAILED_STEPS+=("$name"); return 0
  fi
  if [ -n "$assertion" ]; then
    if ! PATCHBAY_OUT="$OUT" python3 -c "
import json, os, sys
raw = open(os.environ['PATCHBAY_OUT'], encoding='utf-8').read()
try:
    doc = json.loads(raw)
except Exception:
    print('输出不是 JSON'); sys.exit(1)
sys.exit(0 if bool($assertion) else 1)
" 2>/dev/null; then
      printf '  ✗ %-42s 断言不成立：%s\n' "$name" "$assertion"
      FAIL=$((FAIL + 1)); FAILED_STEPS+=("$name"); return 0
    fi
  fi
  printf '  ✓ %-42s\n' "$name"
  PASS=$((PASS + 1))
}

# 从上一条 --json 输出里取一个值，供后续步骤当参数用。
read_json() {
  PATCHBAY_OUT="$OUT" python3 -c "
import json, os
doc = json.load(open(os.environ['PATCHBAY_OUT'], encoding='utf-8'))
print($1)
"
}

# 路由命令的答复只证明导航请求已受理，不证明平台动画已经移除旧 route。
# 读取当前 revision 后等待下一帧；不用 sleep 猜 iOS / Android 的动画时长。
wait_next_frame() {
  local revision
  if ! example_session_cli --json ui wait frame-revision 0 >"$OUT" 2>&1; then
    return 1
  fi
  revision="$(read_json "(doc.get('payload') or doc)['frameRevision']")"
  example_session_cli --json ui wait frame-revision "$revision" \
    --timeout-ms 5000 >"$OUT" 2>&1
}

# `navigation go` 在新 route 入栈后立即答复，旧 route 要到动画结束才释放。
# 同一个 PatchbayKey 不能在旧 Home 尚未释放时交给新 Home；按 catalog 的 mounted
# 状态逐帧等待真实释放，不把逻辑 destination 当成 widget 生命周期证据。
check_catalog_target_unmounted() {
  local name="$1" target_id="$2"
  local attempt=1 max_attempts=30 actual=0 target_state=''
  while [ "$attempt" -le "$max_attempts" ]; do
    actual=0
    example_session_cli --json catalog >"$OUT" 2>&1 || actual=$?
    if [ "$actual" != 0 ]; then
      target_state='catalogFailed'; break
    fi
    target_state="$(read_json "next(('mounted' if t.get('mounted') else 'unmounted' for t in doc['uiTargets'] if t['id'] == '$target_id'), 'notFound')")"
    if [ "$target_state" = unmounted ]; then
      printf '  ✓ %-42s attempts=%s\n' "$name" "$attempt"
      PASS=$((PASS + 1)); return 0
    fi
    if [ "$target_state" != mounted ] || [ "$attempt" = "$max_attempts" ]; then
      break
    fi
    wait_next_frame
    actual=$?
    if [ "$actual" != 0 ]; then
      target_state='uiWaitFrameFailed'; break
    fi
    attempt=$((attempt + 1))
  done
  printf '  ✗ %-42s state=%s（%s 次尝试）\n' \
    "$name" "${target_state:-unknown}" "$attempt"
  FAIL=$((FAIL + 1)); FAILED_STEPS+=("$name"); return 0
}

# capture 自己会跨一帧后二次解析 target。页面恰好处于 route 过渡时，第一次
# catalog 可能读到即将卸载的 generation；bridge 必须 fail-closed，我们则推进
# 一帧、重读 catalog 后有界重试。只放行这三种动态失效，其他拒绝立即失败。
check_capture_target() {
  local name="$1" target_id="$2" output_path="$3"
  local attempt=1 max_attempts=5 actual=0 code='' target_state=''
  while [ "$attempt" -le "$max_attempts" ]; do
    actual=0
    example_session_cli --json catalog >"$OUT" 2>&1 || actual=$?
    if [ "$actual" != 0 ]; then
      code='catalogFailed'; break
    fi
    target_state="$(read_json "next((str(t['generation']) if t.get('mounted') and 'capture' in t.get('operations', []) else 'unmounted' if not t.get('mounted') else 'operationUnavailable' for t in doc['uiTargets'] if t['id'] == '$target_id'), 'notFound')")"
    case "$target_state" in
      notFound) code='uiTargetNotFound'; break ;;
      operationUnavailable) code='uiOperationUnavailable'; break ;;
      unmounted) code='uiTargetUnmounted'; actual=5 ;;
      *)
        actual=0
        example_session_cli --json --output "$output_path" capture target \
          "$target_id" "$target_state" >"$OUT" 2>&1 || actual=$?
        if [ "$actual" = 0 ]; then
          printf '  ✓ %-42s generation=%s attempts=%s\n' \
            "$name" "$target_state" "$attempt"
          PASS=$((PASS + 1)); return 0
        fi
        code="$(read_json "(doc.get('rejection') or {}).get('code', '')" 2>/dev/null || true)"
        case "$code" in
          uiTargetUnmounted|uiGenerationStale|captureTargetChanged) ;;
          *) break ;;
        esac
        ;;
    esac
    if [ "$attempt" = "$max_attempts" ]; then
      break
    fi
    wait_next_frame
    actual=$?
    if [ "$actual" != 0 ]; then
      code='uiWaitFrameFailed'; break
    fi
    attempt=$((attempt + 1))
  done
  printf '  ✗ %-42s 退出码 %s，code=%s（%s 次尝试）\n' \
    "$name" "$actual" "${code:-unknown}" "$attempt"
  FAIL=$((FAIL + 1)); FAILED_STEPS+=("$name"); return 0
}

# 独立算一份文件的 SHA-256。回执自报 verified=true 没有证明力，能被外部复核才有。
sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

# PB-050-20：跑一条覆盖清单里的命令，证明超阈值时无界成员真的落到了本地文件。
#
# 三条断言，缺一不可：
#   1. stdout 确实变短——漏斗的全部意义就在这里；基准是同一条命令加
#      `--max-inline-bytes 0`，也就是 0.4.1 的输出形态；
#   2. 回执里的 path 指向一个存在的文件，且长度与回执自报的一致；
#   3. `shasum -a 256` 独立算出的摘要等于回执自报的 sha256。
#
# 阈值用 `--max-inline-bytes` 显式压小，而不是指望这台设备今天的界面恰好大过
# 64 KiB 默认值：要证明的是这条链路成立，不是某次界面有多大。默认阈值本身由
# 单元测试的三点边界用例锁定，不需要真机再赌一次。
#
# 只打印字节数与摘要前缀，不打印路径：那是本机绝对路径，不进任何可留存的输出。
check_spill() {
  local name=""
  name="$1"
  shift
  local actual=0
  local inline_bytes=0
  local spilled_bytes=0
  local artifact_path=""
  local artifact_sha=""
  local artifact_len=""
  local disk_sha=""
  local disk_len=""

  example_session_cli --json --max-inline-bytes 0 "$@" >"$OUT" 2>&1 || actual=$?
  if [ "$actual" != 0 ]; then
    printf '  ✗ %-42s 内联基准退出码 %s\n' "$name" "$actual"
    sed -E 's#(ws|http)s?://[^[:space:]]+#<redacted-uri>#g' "$OUT" | tail -3 | sed 's/^/      /'
    FAIL=$((FAIL + 1)); FAILED_STEPS+=("$name"); return 0
  fi
  inline_bytes="$(wc -c <"$OUT" | tr -d ' ')"

  actual=0
  example_session_cli --json --max-inline-bytes 512 "$@" >"$OUT" 2>&1 || actual=$?
  if [ "$actual" != 0 ]; then
    printf '  ✗ %-42s 落盘退出码 %s\n' "$name" "$actual"
    sed -E 's#(ws|http)s?://[^[:space:]]+#<redacted-uri>#g' "$OUT" | tail -3 | sed 's/^/      /'
    FAIL=$((FAIL + 1)); FAILED_STEPS+=("$name"); return 0
  fi
  spilled_bytes="$(wc -c <"$OUT" | tr -d ' ')"
  artifact_path="$(read_json "doc['localArtifact']['path']" 2>/dev/null || true)"
  artifact_sha="$(read_json "doc['localArtifact']['sha256']" 2>/dev/null || true)"
  artifact_len="$(read_json "doc['localArtifact']['length']" 2>/dev/null || true)"

  if [ -z "$artifact_path" ] || [ ! -f "$artifact_path" ]; then
    printf '  ✗ %-42s 回执没有指向一个存在的文件\n' "$name"
    FAIL=$((FAIL + 1)); FAILED_STEPS+=("$name"); return 0
  fi
  if [ "$spilled_bytes" -ge "$inline_bytes" ]; then
    printf '  ✗ %-42s stdout 没有变短（%s → %s 字节）\n' \
      "$name" "$inline_bytes" "$spilled_bytes"
    FAIL=$((FAIL + 1)); FAILED_STEPS+=("$name"); return 0
  fi
  disk_sha="$(sha256_of "$artifact_path")"
  disk_len="$(wc -c <"$artifact_path" | tr -d ' ')"
  if [ "$disk_sha" != "$artifact_sha" ]; then
    printf '  ✗ %-42s shasum 与回执对不上（磁盘 %s… vs 回执 %s…）\n' \
      "$name" "${disk_sha:0:12}" "${artifact_sha:0:12}"
    FAIL=$((FAIL + 1)); FAILED_STEPS+=("$name"); return 0
  fi
  if [ "$disk_len" != "$artifact_len" ]; then
    printf '  ✗ %-42s 长度与回执对不上（磁盘 %s vs 回执 %s）\n' \
      "$name" "$disk_len" "$artifact_len"
    FAIL=$((FAIL + 1)); FAILED_STEPS+=("$name"); return 0
  fi
  printf '  ✓ %-42s stdout %s→%s 字节，artifact %s 字节 sha=%s…\n' \
    "$name" "$inline_bytes" "$spilled_bytes" "$disk_len" "${disk_sha:0:12}"
  PASS=$((PASS + 1))
}

# PB-050-21：brief 只是少打印几个键。同一会话内 brief 的 nodeCount / treeRevision
# 必须与 full 逐字相同，nodes 必须不在文档里、且被登记在 localView.omitted。
#
# 树会随界面变化，所以用 treeRevision 判断两次读取是否可比：不可比就再读一次，
# 有界重试。不用 sleep 猜时序，也不把"界面动了"读成"brief 撒谎"。
check_brief_semantics_parity() {
  local name=""
  name="$1"
  local attempt=1
  local max_attempts=3
  local actual=0
  local full_revision=""
  local full_count=""
  local brief_revision=""
  local verdict=""

  while [ "$attempt" -le "$max_attempts" ]; do
    actual=0
    example_session_cli --json ui semantics tree >"$OUT" 2>&1 || actual=$?
    if [ "$actual" != 0 ]; then verdict='fullFailed'; break; fi
    full_revision="$(read_json "(doc.get('payload') or doc)['treeRevision']")"
    full_count="$(read_json "(doc.get('payload') or doc)['nodeCount']")"

    actual=0
    example_session_cli --json --view brief ui semantics tree >"$OUT" 2>&1 || actual=$?
    if [ "$actual" != 0 ]; then verdict='briefFailed'; break; fi
    brief_revision="$(read_json "doc['payload']['treeRevision']")"
    if [ "$brief_revision" != "$full_revision" ]; then
      # 两次读取之间界面变了，这一轮不可比。
      attempt=$((attempt + 1)); continue
    fi
    verdict="$(read_json "'ok' if (
        doc['payload']['nodeCount'] == $full_count
        and 'nodes' not in doc['payload']
        and '\$.payload.nodes' in doc['localView']['omitted']
        and doc['localView']['view'] == 'brief'
        and doc['localView']['projection'] == 'ui.semantics.tree'
    ) else 'mismatch'" 2>/dev/null || echo 'unreadable')"
    if [ "$verdict" = ok ]; then
      printf '  ✓ %-42s treeRevision=%s nodeCount=%s\n' \
        "$name" "$full_revision" "$full_count"
      PASS=$((PASS + 1)); return 0
    fi
    break
  done
  printf '  ✗ %-42s %s（%s 次尝试）\n' \
    "$name" "${verdict:-treeRevisionUnstable}" "$attempt"
  FAIL=$((FAIL + 1)); FAILED_STEPS+=("$name"); return 0
}

echo "== 启动 example =="
if ! example_session_start "${1:-}"; then
  echo "预检未开始：会话启动失败（原因见上方 [session] 行）" >&2
  exit 1
fi

echo
echo "== 预检环境 =="
echo "  CLI 源 revision：${PATCHBAY_CLI_STAMP:-unknown}"
echo "  目标平台：${PATCHBAY_SESSION_PLATFORM:-unknown}"
echo "  被调 App 构建模式：debug（JIT）"

echo
echo "== 身份与目录 =="
check 'identity' 0 "doc['applicationId'] == 'dev.patchbay.example'" --json identity
check 'catalog' 0 "len(doc['commands']) >= 26" --json catalog

example_session_cli --json catalog >"$OUT" 2>&1
NOTE_GENERATION="$(read_json "[t['generation'] for t in doc['uiTargets'] if t['id'] == 'example.note'][0]")"
echo "  targets generation：note=$NOTE_GENERATION"

echo
echo "== 状态读取 =="
check 'snapshot' 0 "doc['counter'] >= 0" --json snapshot
check 'snapshot --path' 0 "doc['selection']['found'] is True" \
  --json snapshot --path device.value
check 'snapshot --path 不存在的字段' 0 "doc['selection']['found'] is False" \
  --json snapshot --path nope.missing
check 'snapshot wait exists' 0 "'outcome' in doc['wait']" \
  --json snapshot wait counter --until exists
example_session_cli --json snapshot >"$OUT" 2>&1
SNAPSHOT_REVISION="$(read_json "doc.get('revision') or 1")"
check 'snapshot diff --from <revision>' 0 "'revision' in json.dumps(doc)" \
  --json snapshot diff --from "$SNAPSHOT_REVISION"

echo
echo "== 域命令与执行证据 =="
check 'exec increment' 0 "doc['payload']['counter'] >= 1" \
  --json exec example.counter.increment
# deviceConfirmed 是唯一算成功的一类。notSent 与 sentUnconfirmed 必须退 6（类型化失败）
# ——它们是「没送出去」和「送了但设备没回报」，把任何一条读成 0 就是误报成功。
check 'exec device.write deviceConfirmed' 0 \
  "doc['payload']['execution']['classification'] == 'deviceConfirmed'" \
  --json exec example.device.write \
  --args '{"value":101,"outcome":"deviceConfirmed"}'
for outcome in sentUnconfirmed notSent; do
  check "exec device.write $outcome 不误报成功" 6 "" \
    --json exec example.device.write \
    --args "{\"value\":$((RANDOM % 900 + 100)),\"outcome\":\"$outcome\"}"
done
# 先写一个值让它确认，再用同值请求 unchanged：同值证据只有真的同值时才诚实。
check 'exec device.write 前置确认' 0 "" --json exec example.device.write \
  --args '{"value":7,"outcome":"deviceConfirmed"}'
check 'exec device.write unchanged' 0 \
  "doc['payload']['execution']['classification'] == 'unchanged'" \
  --json exec example.device.write --args '{"value":7,"outcome":"unchanged"}'
check 'describe device.write' 0 "'responseSchema' in json.dumps(doc)" \
  --json describe example.device.write

# PB-050-06：timeoutMs 同时是 CLI 声明等待预算与 host monotonic deadline。
# handler 在 cancellation callback 中完成停止证明；随后一条普通命令成功，证明
# execution slot 已释放，而不是仅仅让调用方停止等待。
check 'invocation deadline 可确认停止' 5 \
  "doc['rejection']['code'] == 'invocationDeadlineExceeded'" \
  --json exec example.invocation.cooperativeWait --args '{"timeoutMs":30}'
check '确认停止后 execution slot 已释放' 0 \
  "doc['payload']['counter'] >= 1" --json exec example.counter.increment

echo
echo "== job =="
check 'exec job.run' 0 "'jobId' in json.dumps(doc)" \
  --json exec example.job.run --args '{"steps":2}'
example_session_cli --json exec example.job.run --args '{"steps":2}' >"$OUT" 2>&1
JOB_ID="$(read_json "doc.get('jobId') or doc['payload']['jobId']")"
check 'job get' 0 "'events' in json.dumps(doc)" --json job get "$JOB_ID"
example_session_cli --json exec example.job.run --args '{"steps":10}' >"$OUT" 2>&1
LONG_JOB_ID="$(read_json "doc.get('jobId') or doc['payload']['jobId']")"
check 'job cancel' 0 "" --json job cancel "$LONG_JOB_ID"

echo
echo "== UI 观察与操作 =="
check 'ui semantics tree' 0 "'nodes' in json.dumps(doc)" --json ui semantics tree
check 'ui tap increment' 0 "" --json ui tap example.counter.increment
ACTION_GEN="$(example_session_cli --json ui semantics tree 2>/dev/null | python3 -c "
import json, sys
doc = json.load(sys.stdin)
payload = doc.get('payload') if isinstance(doc.get('payload'), dict) else doc
print(next((n.get('generation') for n in payload.get('nodes', [])
            if n.get('identifier') == 'example.identifier.action'), ''))
")"
if [ -n "$ACTION_GEN" ]; then
  check 'ui action focus' 0 "doc['payload']['outcome'] == 'dispatched'" \
    --json ui action example.identifier.action "$ACTION_GEN" focus
  check 'ui action scrollDown' 0 "doc['payload']['outcome'] == 'dispatched'" \
    --json ui action example.identifier.action "$ACTION_GEN" scrollDown
  check 'ui action setText' 0 \
    "doc['payload']['outcome'] == 'dispatched' and doc['payload']['length'] == 8" \
    --json ui action example.identifier.action "$ACTION_GEN" setText precheck
else
  printf '  ✗ %-42s %s\n' 'identifier action generation' \
    '未从 semantics 树解析到 example.identifier.action 的 generation'
  FAIL=$((FAIL + 1)); FAILED_STEPS+=('identifier action generation')
fi
check 'ui wait tree-revision' 0 "" --json ui wait tree-revision 1
check 'ui widget-tree' 0 "" --json ui widget-tree
check 'ui render-tree' 0 "" --json ui render-tree
check 'ui focus-tree' 0 "" --json ui focus-tree

echo
echo "== 锚定手势 =="
# 三棵 debug 诊断树会短暂触发 inspector/semantics 刷新；真机上紧接着抓树时，
# scrollable 的独立 Semantics 节点可能正处在重建窗口。用正式的有界条件等待固定
# 三个目标已经 mounted，再读取 generation；不能用 sleep 猜时序，也不能缺节点时跳过。
check 'ui wait gesture surface mounted' 0 "" \
  --json ui wait semantics-mounted example.gesture.surface --timeout-ms 10000
check 'ui wait gesture list mounted' 0 "" \
  --json ui wait semantics-mounted example.gesture.list --timeout-ms 10000
check 'ui wait nested gesture list mounted' 0 "" \
  --json ui wait semantics-mounted example.gesture.nested --timeout-ms 10000
# `ui semantics tree` 的 --json 输出是**信封**：树在 `payload.nodes`，而 `payload.nodes` 是一个
# **扁平**列表——`children` 装的是 nodeId 整数，不是嵌套的子节点对象。按顶层 `doc['nodes']` 取、
# 或按嵌套 children 递归，都只会得到空结果。
#
# 空结果曾被当成"跳过"，于是 P0 的锚定手势在预检里零覆盖，而预检仍然报"全过"。这正是
# AGENTS.md 警告的那种失效：预检"全过"不再等于"全覆盖"。所以这里既修提取，也把取不到
# generation 变成失败。python 的错误不再吞掉——吞掉正是当初让这个洞看不见的原因。
GEN="$(example_session_cli --json ui semantics tree 2>/dev/null | python3 -c "
import json, sys
doc = json.load(sys.stdin)
payload = doc.get('payload') if isinstance(doc.get('payload'), dict) else doc
gens = {n.get('identifier'): n.get('generation') for n in payload.get('nodes', [])
        if n.get('identifier') and n.get('generation') is not None}
print(gens.get('example.gesture.surface', ''), gens.get('example.gesture.list', ''), gens.get('example.gesture.nested', ''))
")"
SURFACE_GEN="$(echo "$GEN" | awk '{print $1}')"
LIST_GEN="$(echo "$GEN" | awk '{print $2}')"
NESTED_GEN="$(echo "$GEN" | awk '{print $3}')"
if [ -n "$SURFACE_GEN" ] && [ -n "$LIST_GEN" ] && [ -n "$NESTED_GEN" ]; then
  echo "  gesture generation：surface=$SURFACE_GEN list=$LIST_GEN nested=$NESTED_GEN"
  check 'gesture press-hold' 0 "doc['payload']['outcome'] == 'dispatched'" \
    --json ui gesture press-hold \
    example.gesture.surface "$SURFACE_GEN" --start '{"x":0.5,"y":0.5}' --duration-ms 600
  # drag 的 path 必须至少两点：契约要求分段路径，单点会按 uiGestureBudgetExceeded 拒绝。
  check 'gesture drag 分段路径' 0 "doc['payload']['outcome'] == 'dispatched'" \
    --json ui gesture drag \
    example.gesture.surface "$SURFACE_GEN" --start '{"x":0.5,"y":0.8}' \
    --gesture-path '[{"x":0.5,"y":0.5},{"x":0.5,"y":0.2}]' --duration-ms 400
  # velocity 的单位是「目标宽/高每秒」，向量长度上限 20（见 anchored-gestures Proposal），
  # 不是设备像素每秒。用 -1200 这类像素速度会先撞全局预算，于是这一步会**因为错误的原因**
  # 变绿：看着是"按压面拒绝 fling"，实际是速度越界。断言 code 才能区分这两件事。
  check 'gesture fling 在按压面按策略被拒' 5 \
    "doc['rejection']['code'] == 'uiGestureDenied'" \
    --json ui gesture fling \
    example.gesture.surface "$SURFACE_GEN" --start '{"x":0.5,"y":0.8}' \
    --velocity '{"x":0,"y":-6}'
  # dispatched 只证明指针注入完成，不证明嵌套列表真的滚动。前后各抓一帧并比较，
  # 把“命令退 0 但 UI 没动”的假绿挡在业务验收之前。
  example_session_cli --json --output "$PRECHECK_TMP/nested-before.png" \
    capture root >"$OUT" 2>&1
  NESTED_BEFORE_BLOB="$(read_json "doc['payload']['blob']['blobId']")"
  check 'gesture drag 嵌套水平列表' 0 "doc['payload']['outcome'] == 'dispatched'" \
    --json ui gesture drag \
    example.gesture.nested "$NESTED_GEN" --start '{"x":0.8,"y":0.5}' \
    --gesture-path '[{"x":0.5,"y":0.5},{"x":0.2,"y":0.5}]' --duration-ms 300
  example_session_cli --json --output "$PRECHECK_TMP/nested-after.png" \
    capture root >"$OUT" 2>&1
  NESTED_AFTER_BLOB="$(read_json "doc['payload']['blob']['blobId']")"
  check 'gesture drag 嵌套列表产生视觉变化' 0 \
    "doc['payload']['differenceRatio'] > 0" \
    --json capture diff "$NESTED_BEFORE_BLOB" "$NESTED_AFTER_BLOB"
  # 外层 fling 放在嵌套拖动之后；先 fling 可能把 index 2 的嵌套目标滚出视口，
  # 让后续手势因遮挡被拒而不是验证嵌套归属。
  check 'gesture fling 在列表面被接受' 0 "doc['payload']['outcome'] == 'dispatched'" \
    --json ui gesture fling \
    example.gesture.list "$LIST_GEN" --start '{"x":0.5,"y":0.8}' \
    --velocity '{"x":0,"y":-6}'
else
  printf '  ✗ %-42s %s\n' 'gesture target generation' \
    '未从 semantics 树解析到 surface / list / nested 三个目标的 generation'
  echo '      手势是 P0 能力，取不到目标按失败计——跳过会让"全过"不等于"全覆盖"。'
  FAIL=$((FAIL + 1)); FAILED_STEPS+=('gesture target generation')
fi

# setText 可能让系统键盘占据视口；若放在手势前，较矮设备上的两个手势节点存在被裁出
# Semantics 树的风险。手势证据固定后再测文本输入，后续 navigation 会离开当前页，
# 不再依赖这三个节点。
check 'ui text set' 0 "" \
  --json ui text set example.note "$NOTE_GENERATION" 'precheck note'
check 'ui text enter' 0 "" \
  --json ui text enter example.note "$NOTE_GENERATION" ' entered'

echo
echo "== 导航 =="
check 'navigation catalog' 0 "'destinations' in json.dumps(doc)" \
  --json navigation catalog
check 'navigation current' 0 "" --json navigation current
check 'navigation push details' 0 "" --json navigation push example.details
check 'ui wait destination' 0 "" --json ui wait destination example.details
check 'navigation back' 0 "" --json navigation back
check 'navigation go details' 0 "" --json navigation go example.details
check 'ui wait destination details' 0 "" --json ui wait destination example.details
check_catalog_target_unmounted 'catalog capture target released' \
  example.card.capture
check 'navigation go home' 0 "" --json navigation go example.home
check 'ui wait destination home' 0 "" --json ui wait destination example.home

echo
echo "== inspect / keep-awake =="
check 'ui inspect on' 0 "" --json ui inspect on --ttl-ms 60000
check 'ui inspect status' 0 "" --json ui inspect status
check 'ui inspect off' 0 "" --json ui inspect off
check 'ui keep-awake on' 0 "" --json ui keep-awake on --lease-ms 60000
check 'ui keep-awake status' 0 "" --json ui keep-awake status
check 'ui keep-awake off' 0 "" --json ui keep-awake off

echo
echo "== capture / blob =="
check 'capture root' 0 "" --output "$PRECHECK_TMP/capture.png" capture root
# 导航往返会重新挂载页面并递增 target generation。capture target 不保证有
# 独立 semantics 节点，因此由 helper 在每次有界尝试前重读 catalog。
check 'catalog capture target available' 0 \
  "any(t['id'] == 'example.card.capture' for t in doc['uiTargets'])" \
  --json catalog
check_capture_target 'capture target' example.card.capture \
  "$PRECHECK_TMP/capture-target.png"
example_session_cli --json --output "$PRECHECK_TMP/cap1.png" capture root >"$OUT" 2>&1
BLOB1="$(read_json "doc['payload']['blob']['blobId']")"
example_session_cli --json exec example.counter.increment >/dev/null 2>&1
example_session_cli --json --output "$PRECHECK_TMP/cap2.png" capture root >"$OUT" 2>&1
BLOB2="$(read_json "doc['payload']['blob']['blobId']")"
check 'capture diff' 0 "'differenceRatio' in json.dumps(doc)" \
  --json capture diff "$BLOB1" "$BLOB2"

echo
echo "== 调试轨迹 =="
TRACE_ROOT="$PRECHECK_TMP/traces"
check_local 'trace start（active）' 0 "doc['active'] is True" \
  --trace-dir "$TRACE_ROOT" --json trace start --name example-precheck --activate
TRACE_ID="$(read_json "doc['trace']['traceId']")"
check 'trace 记录 session / identity' 0 "" \
  --trace-dir "$TRACE_ROOT" --json identity
check 'trace 记录 job admission' 0 "'jobId' in json.dumps(doc)" \
  --trace-dir "$TRACE_ROOT" --json exec example.job.run --args '{"steps":2}'
TRACE_JOB_ID="$(read_json "doc.get('jobId') or doc['payload']['jobId']")"
check 'trace 记录 job event' 0 "'events' in json.dumps(doc)" \
  --trace-dir "$TRACE_ROOT" --json job get "$TRACE_JOB_ID"
check 'trace 记录 artifact' 0 "" \
  --trace-dir "$TRACE_ROOT" --output "$PRECHECK_TMP/trace-capture.png" capture root
check_local 'trace mark' 0 "doc['marked'] is True" \
  --trace-dir "$TRACE_ROOT" --json trace mark '设备预检完成'
check_local 'trace stop' 0 "doc['stopped'] is True" \
  --trace-dir "$TRACE_ROOT" --json trace stop
check_local 'trace show 含 session/job/artifact' 0 \
  "'session.observed' in json.dumps(doc) and 'job.event' in json.dumps(doc) and 'artifact.attached' in json.dumps(doc)" \
  --trace-dir "$TRACE_ROOT" --json trace show "$TRACE_ID"
check_local 'trace export（重新脱敏）' 0 "doc['traceId'] == '$TRACE_ID'" \
  --trace-dir "$TRACE_ROOT" --json --include-artifacts \
  trace export "$TRACE_ID" --output "$PRECHECK_TMP/trace-export"

check_local 'trace comparison baseline start' 0 "doc['active'] is True" \
  --trace-dir "$TRACE_ROOT" --json trace start --name example-baseline --activate
BASELINE_TRACE_ID="$(read_json "doc['trace']['traceId']")"
check 'trace baseline 记录 identity' 0 "" \
  --trace-dir "$TRACE_ROOT" --json identity
check_local 'trace comparison baseline stop' 0 "doc['stopped'] is True" \
  --trace-dir "$TRACE_ROOT" --json trace stop
check_local 'trace diff 可比较另一条轨迹' 0 \
  "sum(len(doc[key]) for key in ('added', 'removed', 'changed')) > 0" \
  --trace-dir "$TRACE_ROOT" --json trace diff "$TRACE_ID" "$BASELINE_TRACE_ID"

echo
echo "== logs =="
check 'logs query' 0 "'records' in json.dumps(doc)" --json logs query
check 'logs export' 0 "" --output "$PRECHECK_TMP/logs.ndjson" logs export

echo
echo "== 输出漏斗（PB-050-20 落盘 / PB-050-21 brief）=="
# 落盘产物进预检自己的临时目录：既让本步骤可以断言"文件确实在那儿"，也不去动
# 运行者真正的 $HOME/.patchbay/outputs/v1。cleanup 会连它一起删。
export PATCHBAY_OUTPUT_DIR="$PRECHECK_TMP/outputs"
mkdir -p "$PATCHBAY_OUTPUT_DIR"
# 一棵 semantics 树 + 一棵 SDK 诊断树：两种无界成员形态各一条（JSON 数组与
# 透传 data），也是两条不同的事实来源（host 应答与 VM Service 透传）。
check_spill 'ui semantics tree 落盘并可复核' ui semantics tree
check_spill 'ui widget-tree 落盘并可复核' ui widget-tree
check_brief_semantics_parity 'ui semantics tree --view brief 与 full 对账'
# catalog 的 brief 必须仍然可读：summary 是 describe 之前判断"这条命令是干什么的"
# 的唯一线索，2026-08-25 的裁决把它留在了投影表之外。
check 'catalog --view brief 保留 summary' 0 \
  "(doc['localView']['view'] == 'brief'
    and doc['localView']['projection'] == 'catalog'
    and all(c.get('summary') for c in doc['commands'])
    and '\$.commands[].summary' not in doc['localView']['omitted']
    and any(p in doc['localView']['omitted'] for p in (
      '\$.commands[].parameters', '\$.commands[].responseSchema',
      '\$.commands[].executionContract', '\$.commands[].retryPolicy')))" \
  --json --view brief catalog

echo
echo "== manifest =="
check 'ui targets --emit-manifest' 0 "'coverage' in json.dumps(doc)" \
  --json ui targets --emit-manifest
example_session_cli --json ui targets --emit-manifest 2>/dev/null | python3 -c "
import json, sys
raw = json.load(sys.stdin)
payload = raw.get('payload') if isinstance(raw.get('payload'), dict) else raw
with open('$PRECHECK_TMP/manifest.json', 'w', encoding='utf-8') as f:
    json.dump(payload, f)
"
check 'ui verify-manifest' 0 "" \
  --json ui verify-manifest "$PRECHECK_TMP/manifest.json"

echo
echo "== 画像 =="
check 'perf profile' 0 "" --json perf profile --duration-ms 1500
check 'net profile 按裁决稳定拒绝' 4 "" --json net profile

echo
echo "== 本地面（不经 App）=="
check 'doctor' 0 "" --json doctor
# 没装外部 companion driver 时，能力矩阵是类型化失败（6），不是 0——这正是 fail-closed。
check_local 'permission capabilities 无 driver 时 fail-closed' 6 "" \
  --json permission capabilities

echo
echo "== 权限真实路径 =="
if [ "${PATCHBAY_SESSION_PLATFORM:-}" = android ]; then
  PERMISSION_DRIVER="${TMPDIR:-/tmp}/patchbay-precheck-permission-android"
  if (cd "$PATCHBAY_CLI_DIR" && dart compile exe bin/patchbay_permission_android.dart \
    -o "$PERMISSION_DRIVER" >/dev/null 2>&1); then
    check 'doctor permission' 0 "" \
      --json --permission-driver "$PERMISSION_DRIVER" doctor permission

    check 'permission capabilities（有 driver）' 0 \
      "len(doc['capabilities']['permissions']) == 4 and all(
          v['decisions'] == [] for v in doc['capabilities']['permissions'].values())" \
      --json --permission-driver "$PERMISSION_DRIVER" permission capabilities

    for permission in camera microphone locationWhenInUse notifications; do
      check "permission status $permission" 0 \
        "doc['after']['factSource'] == 'deviceReported' and doc['after']['platformState']" \
        --json --permission-driver "$PERMISSION_DRIVER" permission status "$permission"
    done

    check 'permission normalize granted' 0 \
      "doc['after']['state'] == 'granted' and doc['after']['requiresRestart'] is True" \
      --json --permission-driver "$PERMISSION_DRIVER" \
      permission normalize camera --state granted
    check 'permission normalize 幂等重放' 0 \
      "doc['before']['state'] == 'granted' and doc['after']['state'] == 'granted'" \
      --json --permission-driver "$PERMISSION_DRIVER" \
      permission normalize camera --state granted
    check 'permission normalize denied 不可达即拒绝' 5 \
      "doc['rejection']['code'] == 'permissionStateUnreachable'" \
      --json --permission-driver "$PERMISSION_DRIVER" \
      permission normalize camera --state denied
    check 'permission fail 策略对比' 5 \
      "doc['rejection']['code'] == 'permissionStateMismatch'" \
      --json --permission-driver "$PERMISSION_DRIVER" \
      permission fail camera --state denied
    # reset revokes a granted permission and Android terminates the process, so
    # it remains the final device-mutating precheck step.
    check 'permission reset' 0 \
      "doc['before']['state'] == 'granted' and doc['after']['state'] == 'notDetermined'" \
      --json --permission-driver "$PERMISSION_DRIVER" permission reset camera
  else
    printf '  ✗ %-42s %s\n' 'permission driver 编译' '无法编出 Android 权限 driver'
    FAIL=$((FAIL + 1)); FAILED_STEPS+=('permission driver 编译')
  fi
else
  printf '  · %-42s %s\n' 'permission platform matrix' \
    "${PATCHBAY_SESSION_PLATFORM:-unknown} 不在 0.4.0 平台 driver 承诺内；已由 fail-closed 步骤覆盖"
fi

echo
printf '预检结果：%s 通过，%s 失败\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '失败步骤：%s\n' "${FAILED_STEPS[*]}"
  exit 1
fi
