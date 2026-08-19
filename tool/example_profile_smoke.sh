#!/usr/bin/env bash
# profile 冒烟：把 example 以 **profile 构建**跑起来，验证非 debug 会话下的答复形态。
#
# 与 `example_precheck.sh` 的分工：预检在 debug 下逐条打通全部命令面，本脚本只跑一小组
# 步骤，但跑在 debug **看不见的那一半**上。两者不可互相替代。
#
# 它守的不变式只有一条：
#
#   profile 下每条命令要么正常工作，要么给出**类型化拒绝**；绝不能退出 3（transport）。
#
# 退出 3 意味着异常在 host 侧逃出了命令边界，被包成 RPCError 交回来——调用方既拿不到
# `error.code`，也无从判断是能力不存在还是实现炸了。已实证一例：绘制就绪判据读 debug-only
# 的 `RenderObject.debugNeedsPaint`，profile 剥掉赋值它的断言后读取即抛，于是 `capture`
# 在 profile 必然退 3。仓内每一条会话都是 debug，该缺陷因此在预检全绿的情况下活了一整个
# 版本周期，最终由接入方在 iOS 真机上撞出来（iOS 联调只能用 profile）。
#
# 因此本脚本刻意**不**逐条硬编码"这一步应该返回什么"：debug-only 的面在 profile 下如何
# 降级本身就是待观测的事实，写死期望只会把今天的实现固化成契约。脚本给出实测矩阵，并只对
# 两件事失败：出现退出 3，或标了「必须可用」的能力没跑通。
#
# 另标一种**不判失败但要看见**的形态：退 0 却交回空 `data`。首轮实测里三棵诊断树都是这样
# ——`ui widget-tree` 只回一行 `WidgetsFlutterBinding - PROFILE MODE`，render / focus 直接
# 是空串。它比类型化拒绝更难处置：调用方分不清"profile 下没有这个能力"和"界面本身就是空的"。
# 该改成拒绝还是补 capability 属设计裁决，脚本只负责把它摆到台面上。
#
# 用法：
#   tool/example_profile_smoke.sh [device-id]
#
# 退出码：0 全过；1 有步骤失败（末尾列出失败清单）。

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# 会话的构建模式由这里决定；source 之前设置，让 example_session.sh 直接按 profile 构建。
export PATCHBAY_EXAMPLE_MODE=profile
# shellcheck source=tool/example_session.sh
source "$ROOT/tool/example_session.sh"

PASS=0
FAIL=0
WARN=0
FAILED_STEPS=()
WARNED_STEPS=()
OUT="$(mktemp "${TMPDIR:-/tmp}/patchbay-profile-out.XXXXXX")"
SHOT="$(mktemp "${TMPDIR:-/tmp}/patchbay-profile-shot.XXXXXX").png"

cleanup() {
  example_session_stop
  rm -f "$OUT" "$SHOT"
}
trap cleanup EXIT

# 读出一条 `--json` 答复里的拒绝码，纯展示用；不是 JSON 或没有拒绝码时给个占位。
rejection_code() {
  PATCHBAY_OUT="$OUT" python3 -c "
import json, os
try:
    doc = json.load(open(os.environ['PATCHBAY_OUT'], encoding='utf-8'))
except Exception:
    print('-'); raise SystemExit(0)
rejection = doc.get('rejection') or {}
error = doc.get('error') or {}
print(rejection.get('code') or error.get('code') or '-')
" 2>/dev/null || echo '-'
}

# 该答复是不是「成功码配空载荷」。
#
# 这是本脚本要盯的第二种坏形态。类型化拒绝至少让调用方知道"这里没有能力"；退 0 却交回空
# 数据则把两件不同的事压成同一个答复——"profile 下拿不到"和"界面本身就是空的"从此不可区分，
# 而两者的处置完全相反。
empty_payload() {
  PATCHBAY_OUT="$OUT" python3 -c "
import json, os
try:
    doc = json.load(open(os.environ['PATCHBAY_OUT'], encoding='utf-8'))
except Exception:
    raise SystemExit(1)
payload = doc.get('payload')
if not isinstance(payload, dict):
    raise SystemExit(1)
data = payload.get('data')
if not isinstance(data, str):
    raise SystemExit(1)
# 只剩绑定名/模式名这类一行样板，也算空。
raise SystemExit(0 if len(data.strip().splitlines()) <= 1 else 1)
" 2>/dev/null
}

# probe <名称> <required|degradable> -- <cli 参数...>
#
# required：该能力在 profile 下必须可用（退出 0）。
# degradable：debug-only 的面，如何降级是待观测事实。退 3 一律失败；退 0 但载荷为空只记
#             ⚠ 观察，不判失败——这类形态该改成类型化拒绝还是补 capability 是设计裁决，
#             不由一个冒烟脚本单方面定，也不该让 main 上长期挂一盏已知红灯。
probe() {
  local name="$1" kind="$2"
  shift 2
  local actual=0
  example_session_cli "$@" >"$OUT" 2>&1 || actual=$?
  local code
  code="$(rejection_code)"

  if [ "$actual" = 3 ]; then
    printf '  ✗ %-34s 退出 3（transport）——异常逃出了命令边界\n' "$name"
    sed -E 's#(ws|http)s?://[^[:space:]]+#<redacted-uri>#g' "$OUT" | tail -3 | sed 's/^/      /'
    FAIL=$((FAIL + 1)); FAILED_STEPS+=("$name"); return 0
  fi
  if [ "$kind" = required ] && [ "$actual" != 0 ]; then
    printf '  ✗ %-34s 退出 %s（该能力在 profile 下应当可用）code=%s\n' "$name" "$actual" "$code"
    sed -E 's#(ws|http)s?://[^[:space:]]+#<redacted-uri>#g' "$OUT" | tail -3 | sed 's/^/      /'
    FAIL=$((FAIL + 1)); FAILED_STEPS+=("$name"); return 0
  fi
  if [ "$actual" = 0 ] && empty_payload; then
    printf '  ⚠ %-34s 退出 0，但载荷 data 为空——成功码掩盖了"没有能力"\n' "$name"
    WARN=$((WARN + 1)); WARNED_STEPS+=("$name"); return 0
  fi
  printf '  ✓ %-34s 退出 %s  code=%s\n' "$name" "$actual" "$code"
  PASS=$((PASS + 1))
}

echo "== 启动 example（profile）=="
if ! example_session_start "${1:-}"; then
  echo "冒烟未开始：会话启动失败（原因见上方 [session] 行）" >&2
  exit 1
fi

echo
echo "== 环境 =="
echo "  CLI 源 revision：${PATCHBAY_CLI_STAMP:-unknown}"
echo "  目标平台：${PATCHBAY_SESSION_PLATFORM:-unknown}"
echo "  被调 App 构建模式：${PATCHBAY_EXAMPLE_MODE}"

echo
echo "== 非 debug 下必须可用的面 =="
# capture 是本脚本存在的直接理由：它此前在 profile 必然退 3。
probe 'capture root' required --json --output "$SHOT" capture root
probe 'identity' required --json identity
probe 'catalog' required --json catalog
probe 'snapshot' required --json snapshot
probe 'ui semantics tree' required --json ui semantics tree
probe 'ui tap' required --json ui tap example.counter.increment

echo
echo "== debug-only 的面（只验类型化降级，不写死期望）=="
probe 'ui inspect on' degradable --json ui inspect on --ttl-ms 60000
probe 'ui widget-tree' degradable --json ui widget-tree
probe 'ui render-tree' degradable --json ui render-tree
probe 'ui focus-tree' degradable --json ui focus-tree

echo
if [ -s "$SHOT" ]; then
  echo "  截图产物：$(wc -c <"$SHOT" | tr -d ' ') 字节"
fi
echo "== 小结 =="
echo "  通过 ${PASS}，观察 ${WARN}，失败 ${FAIL}"
if [ "$WARN" != 0 ]; then
  printf '  ⚠ 成功码配空载荷：%s\n' "${WARNED_STEPS[*]}"
  echo "    这不判失败，但值得裁决：非 debug 下该改成类型化拒绝，还是发布 capability 让调用方预先分流。"
fi
if [ "$FAIL" != 0 ]; then
  printf '  失败步骤：%s\n' "${FAILED_STEPS[*]}"
  exit 1
fi
exit 0
