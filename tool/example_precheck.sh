#!/usr/bin/env bash
# 本地端到端预检：在一台连着的 Android 设备上把 example 跑起来，逐条打通 patchbay 的
# 命令面，并给出每一步的退出码与断言结果。
#
# 它证明的是「协议 + CLI + host 三方接线在真设备上确实通」。它**不能**替代业务验收：
# 真实控制器语义、设备 SDK 确认、真实 UI 的滚动与遮挡、签名真机上的系统弹窗，都只有
# 接入方能出证据。规则见 AGENTS.md「实现与验证」。
#
# 模式：**debug（JIT）**，不是 profile/AOT。这不是随手选的默认值——`ui.inspect` 与三棵诊断树只在
# debug 构建存在（见 AGENTS.md「联调姿势」），用 profile 跑会让这几步静默消失，"全过"就不再等于
# "全覆盖"。性能数字要另跑一次 profile 会话，那次拿不到 inspect 与诊断树，属于两种用途。
#
# CLI 本身相反：先 AOT 编成原生可执行再复用（由 example_session.sh 负责），否则四十余步会各自
# 重新编译一遍。
#
# 用法：
#   tool/example_precheck.sh [adb-serial]
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

cleanup() {
  example_session_stop
  rm -f "$OUT"
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
echo "  被调 App 构建模式：debug（JIT）"

echo
echo "== 身份与目录 =="
check 'identity' 0 "doc['applicationId'] == 'dev.patchbay.example'" --json identity
check 'catalog' 0 "len(doc['commands']) >= 26" --json catalog

example_session_cli --json catalog >"$OUT" 2>&1
NOTE_GENERATION="$(read_json "[t['generation'] for t in doc['uiTargets'] if t['id'] == 'example.note'][0]")"
echo "  note target generation=$NOTE_GENERATION"

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

echo
echo "== UI 观察与操作 =="
check 'ui semantics tree' 0 "'nodes' in json.dumps(doc)" --json ui semantics tree
check 'ui tap increment' 0 "" --json ui tap example.counter.increment
check 'ui text set' 0 "" \
  --json ui text set example.note "$NOTE_GENERATION" 'precheck note'
check 'ui wait tree-revision' 0 "" --json ui wait tree-revision 1
check 'ui widget-tree' 0 "" --json ui widget-tree
check 'ui render-tree' 0 "" --json ui render-tree
check 'ui focus-tree' 0 "" --json ui focus-tree

echo
echo "== 锚定手势 =="
GEN="$(example_session_cli --json ui semantics tree 2>/dev/null | PATCHBAY_OUT=/dev/stdin python3 -c "
import json,sys
doc = json.load(sys.stdin)
def walk(node):
    yield node
    for child in node.get('children', []):
        yield from walk(child)
gens = [n.get('generation') for r in doc.get('nodes', []) for n in walk(r)
        if n.get('identifier') == 'example.gesture.surface' and n.get('generation') is not None]
print(gens[0] if gens else '')
" 2>/dev/null || true)"
if [ -n "$GEN" ]; then
  check 'gesture press-hold' 0 "" --json ui gesture press-hold \
    example.gesture.surface "$GEN" --start '{"x":0.5,"y":0.5}' --duration-ms 600
  check 'gesture drag' 0 "" --json ui gesture drag \
    example.gesture.surface "$GEN" --start '{"x":0.5,"y":0.8}' \
    --gesture-path '[{"x":0.5,"y":0.2}]' --duration-ms 400
  check 'gesture fling 在按压面被拒' 5 "" --json ui gesture fling \
    example.gesture.surface "$GEN" --start '{"x":0.5,"y":0.8}' \
    --velocity '{"x":0,"y":-1200}'
else
  echo "  ! 未从 semantics 树取到 gesture surface 的 generation，跳过手势三项"
fi

echo
echo "== 导航 =="
check 'navigation catalog' 0 "'destinations' in json.dumps(doc)" \
  --json navigation catalog
check 'navigation current' 0 "" --json navigation current
check 'navigation push details' 0 "" --json navigation push example.details
check 'ui wait destination' 0 "" --json ui wait destination example.details
check 'navigation back' 0 "" --json navigation back

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
check 'capture root' 0 "" --output "$(mktemp "${TMPDIR:-/tmp}/patchbay-shot.XXXXXX").png" capture root

echo
echo "== logs =="
check 'logs query' 0 "'records' in json.dumps(doc)" --json logs query

echo
echo "== manifest =="
check 'ui targets --emit-manifest' 0 "'coverage' in json.dumps(doc)" \
  --json ui targets --emit-manifest

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
printf '预检结果：%s 通过，%s 失败\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '失败步骤：%s\n' "${FAILED_STEPS[*]}"
  exit 1
fi
