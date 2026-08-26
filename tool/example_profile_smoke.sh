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
# PB-050-20 的落盘目录指向本次冒烟自己的临时目录：既让「有没有落盘」可断言，也不去
# 动运行者真正的 $HOME/.patchbay/outputs/v1。
PROFILE_OUTPUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/patchbay-profile-out-dir.XXXXXX")"
export PATCHBAY_OUTPUT_DIR="$PROFILE_OUTPUT_DIR"

cleanup() {
  example_session_stop
  rm -f "$OUT" "$SHOT"
  rm -rf "$PROFILE_OUTPUT_DIR"
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

# PB-050-20：这条答复的 `data` 是不是空的，以及它有没有被落盘。
#
# 打印四种之一：`empty-inline`（空且没落盘，正确）、`empty-spilled`（空却落了盘，
# 本步要抓的就是它）、`nonempty-spilled` / `nonempty-inline`（非空，两种都正常）。
funnel_spill_shape() {
  PATCHBAY_OUT="$OUT" python3 -c "
import json, os
try:
    doc = json.load(open(os.environ['PATCHBAY_OUT'], encoding='utf-8'))
except Exception:
    print('unreadable'); raise SystemExit(0)
data = doc.get('data')
empty = data is None or (hasattr(data, '__len__') and len(data) == 0)
spilled = isinstance(doc.get('localArtifact'), dict)
print(('empty' if empty else 'nonempty') + ('-spilled' if spilled else '-inline'))
" 2>/dev/null || echo 'unreadable'
}

# PB-050-21：brief 下空 `data` 与被 elide 的 `data` 是不是可分辨。
#
# 唯一的分辨手段是 `localView.omitted`：elide 时 `$.data` 在列表里，空 data 时不在。
# 打印 `empty-kept`（空且未登记，正确）、`empty-omitted`（空却报成被删，错）、
# `nonempty-omitted`（非空且被删，正确）、`nonempty-kept`（非空却没删，投影没生效）。
funnel_brief_shape() {
  PATCHBAY_OUT="$OUT" python3 -c "
import json, os
try:
    doc = json.load(open(os.environ['PATCHBAY_OUT'], encoding='utf-8'))
except Exception:
    print('unreadable'); raise SystemExit(0)
view = doc.get('localView') or {}
omitted = view.get('omitted') or []
present = 'data' in doc
data = doc.get('data')
empty = data is None or (hasattr(data, '__len__') and len(data) == 0)
listed = '\$.data' in omitted
if not present and not listed:
    print('gone-unreported'); raise SystemExit(0)
print(('empty' if empty and present else 'nonempty') + ('-omitted' if listed else '-kept'))
" 2>/dev/null || echo 'unreadable'
}

# 一棵诊断树的输出漏斗形态。两条不变式：
#   1. **空 data 不落盘**。否则回执会声称一份"已校验的 artifact"，而文件里只有
#      空串或 null——把"这个构建没有这个能力"包装成"已经取到了"，正是本脚本存在
#      的理由那一类的错。
#   2. **brief 下空 data 与被 elide 的 data 可分辨**。`localView.omitted` 是唯一
#      分辨手段，空 data 时它里面不含 `$.data`。
#
# 阈值压到很小，让"没落盘"只可能是因为成员为空，不是因为文档还不够大。brief 那一步
# 反过来用 `--max-inline-bytes 0` 完全关掉落盘，好让 `omitted` 只反映 brief 自己的
# 决定，不与 PB-050-20 的接缝混在一起。
funnel_probe() {
  local name=""
  name="$1"
  shift
  local actual=0
  local spill_shape=""
  local brief_shape=""

  example_session_cli --json --max-inline-bytes 256 "$@" >"$OUT" 2>&1 || actual=$?
  if [ "$actual" != 0 ]; then
    printf '  ✗ %-34s 退出 %s（本步只在退 0 时才有意义）\n' "$name" "$actual"
    FAIL=$((FAIL + 1)); FAILED_STEPS+=("$name"); return 0
  fi
  spill_shape="$(funnel_spill_shape)"

  actual=0
  example_session_cli --json --view brief --max-inline-bytes 0 "$@" \
    >"$OUT" 2>&1 || actual=$?
  if [ "$actual" != 0 ]; then
    printf '  ✗ %-34s --view brief 退出 %s\n' "$name" "$actual"
    FAIL=$((FAIL + 1)); FAILED_STEPS+=("$name"); return 0
  fi
  brief_shape="$(funnel_brief_shape)"

  case "$spill_shape" in
    empty-spilled)
      printf '  ✗ %-34s 空 data 却落了盘——回执在为一份空文件背书\n' "$name"
      FAIL=$((FAIL + 1)); FAILED_STEPS+=("$name"); return 0 ;;
    unreadable)
      printf '  ✗ %-34s 落盘判定读不出答复形态\n' "$name"
      FAIL=$((FAIL + 1)); FAILED_STEPS+=("$name"); return 0 ;;
  esac
  case "$brief_shape" in
    empty-omitted)
      printf '  ✗ %-34s 空 data 被报成 omitted——与被 elide 不可分辨\n' "$name"
      FAIL=$((FAIL + 1)); FAILED_STEPS+=("$name"); return 0 ;;
    nonempty-kept|gone-unreported|unreadable)
      printf '  ✗ %-34s brief 形态异常：%s\n' "$name" "$brief_shape"
      FAIL=$((FAIL + 1)); FAILED_STEPS+=("$name"); return 0 ;;
  esac
  printf '  ✓ %-34s spill=%s brief=%s\n' "$name" "$spill_shape" "$brief_shape"
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
echo "== reveal 答复形态（PB-050-17，不依赖任何 debug-only API）=="
# reveal 的整条路径——语义树观察、occlusion 判定、语义 action 派发——都走
# `debugSemantics`（release 才为 null），与上面已经 required 的 ui tap 同源，
# 因此在 profile 下同样必须可用，不进 degradable 那一组。这里只验答复形态
# （退出码 + 不落进 transport），语义正确性由 example_precheck.sh 在 debug
# 下逐条断言，本脚本不重复求全覆盖。
probe 'navigation go reveal' required --json navigation go example.reveal
probe 'ui reveal' required --json ui reveal example.reveal.row.far \
  --max-steps 60 --timeout-ms 20000
probe 'navigation go home（reveal 收尾）' required --json navigation go example.home

echo
echo "== debug-only 的面（只验类型化降级，不写死期望）=="
probe 'ui inspect on' degradable --json ui inspect on --ttl-ms 60000
probe 'ui widget-tree' degradable --json ui widget-tree
probe 'ui render-tree' degradable --json ui render-tree
probe 'ui focus-tree' degradable --json ui focus-tree

echo
echo "== 输出漏斗在非 debug 下的形态（PB-050-20 / PB-050-21）=="
# 三棵诊断树在 profile 下返回的是退 0 配空 data，不是拒绝——这正是上面 degradable
# 那组观察到的形态。本组把它变成两条可判红的不变式，见 funnel_probe 的注释。
funnel_probe 'ui widget-tree 漏斗形态' ui widget-tree
funnel_probe 'ui render-tree 漏斗形态' ui render-tree
funnel_probe 'ui focus-tree 漏斗形态' ui focus-tree
if [ -n "$(ls -A "$PROFILE_OUTPUT_DIR" 2>/dev/null)" ]; then
  printf '  · %-34s %s\n' '落盘目录非空' \
    '有诊断树的 data 非空并按阈值落了盘——这是正确行为，仅记录'
fi

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
