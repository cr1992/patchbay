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
CARD_CAPTURE_GEN="$(read_json "[t['generation'] for t in doc['uiTargets'] if t['id'] == 'example.card.capture'][0]")"
echo "  targets generation：note=$NOTE_GENERATION card=$CARD_CAPTURE_GEN"

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
check 'ui wait tree-revision' 0 "" --json ui wait tree-revision 1
check 'ui widget-tree' 0 "" --json ui widget-tree
check 'ui render-tree' 0 "" --json ui render-tree
check 'ui focus-tree' 0 "" --json ui focus-tree

echo
echo "== 锚定手势 =="
# 三棵 debug 诊断树会短暂触发 inspector/semantics 刷新；真机上紧接着抓树时，
# scrollable 的独立 Semantics 节点可能正处在重建窗口。用正式的有界条件等待固定
# 两个目标已经 mounted，再读取 generation；不能用 sleep 猜时序，也不能缺节点时跳过。
check 'ui wait gesture surface mounted' 0 "" \
  --json ui wait semantics-mounted example.gesture.surface --timeout-ms 10000
check 'ui wait gesture list mounted' 0 "" \
  --json ui wait semantics-mounted example.gesture.list --timeout-ms 10000
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
print(gens.get('example.gesture.surface', ''), gens.get('example.gesture.list', ''))
")"
SURFACE_GEN="${GEN%% *}"
LIST_GEN="${GEN##* }"
if [ -n "$SURFACE_GEN" ] && [ -n "$LIST_GEN" ]; then
  echo "  gesture generation：surface=$SURFACE_GEN list=$LIST_GEN"
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
  check 'gesture fling 在列表面被接受' 0 "doc['payload']['outcome'] == 'dispatched'" \
    --json ui gesture fling \
    example.gesture.list "$LIST_GEN" --start '{"x":0.5,"y":0.8}' \
    --velocity '{"x":0,"y":-6}'
else
  printf '  ✗ %-42s %s\n' 'gesture surface generation' \
    '未从 semantics 树解析到 example.gesture.surface / example.gesture.list 的 generation'
  echo '      手势是 P0 能力，取不到目标按失败计——跳过会让"全过"不等于"全覆盖"。'
  FAIL=$((FAIL + 1)); FAILED_STEPS+=('gesture surface generation')
fi

# setText 可能让系统键盘占据视口；若放在手势前，较矮设备上的两个手势节点存在被裁出
# Semantics 树的风险。手势证据固定后再测文本输入，后续 navigation 会离开当前页，
# 不再依赖这两个节点。
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
if [ -n "$CARD_CAPTURE_GEN" ]; then
  check 'capture target' 0 "" --output "$PRECHECK_TMP/capture-target.png" \
    capture target example.card.capture "$CARD_CAPTURE_GEN"
fi
example_session_cli --output "$PRECHECK_TMP/cap1.png" capture root >"$OUT" 2>&1
BLOB1="$(read_json "doc['payload']['blob']['blobId']")"
example_session_cli --json exec example.counter.increment >/dev/null 2>&1
example_session_cli --output "$PRECHECK_TMP/cap2.png" capture root >"$OUT" 2>&1
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
