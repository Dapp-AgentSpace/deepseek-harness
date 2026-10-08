#!/usr/bin/env bash
# harness-preflight.sh — 环境预检（确定性，无 AI）。在 harness 流程**之前**跑一次：
#   读 .harness/identity.yaml 的 toolchain.*（committed 需求单源）→ 解析每个工具的真实路径
#   → 写 .harness/toolchain.env（本机解析缓存，gitignored）。缺 required 工具即退出 1（流程不得开始）。
#
# 为什么前置：缺工具若在流程**中途**才炸，前面白干（正是「减少失败与重试」要治的）。就绪后再复用
# 缓存，各脚本经 ci/bin/harness-env.sh 廉价读取，**不再每次实跑探测**。
#
# 与 attention.md 的分工：本脚本产出的 toolchain.env 是**本机相关**的依赖路径，不入库；
# attention.md 是**项目通用**的高频事实，入库。二者不可混。
#
# 用法: harness-preflight.sh [--quiet]
# 退出码: 0=环境就绪 / 1=缺 required 工具（环境未准备，流程不得开始）/ 2=前置错误（缺 identity.yaml）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ID="$ROOT/.harness/identity.yaml"
OUT="$ROOT/.harness/toolchain.env"
QUIET=0
if [ "${1:-}" = "--quiet" ]; then QUIET=1; fi

say() { if [ "$QUIET" = 1 ]; then :; else printf '%s\n' "$*"; fi; }
warn() { printf '[preflight] %s\n' "$*" >&2; }

[ -f "$ID" ] || { warn "缺 $ID，先跑 harness-init"; exit 2; }

# 读 flow 列表：`required: [a, b]` / `optional: [c]`（单行 flow 列表，见 identity.yaml 的 toolchain 块）
_list() {
  sed -n "s/^[[:space:]]*$1:[[:space:]]*\[\(.*\)\].*/\1/p" "$ID" | head -n1 \
    | tr ',' '\n' | sed -E 's/[[:space:]]*#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//' | grep -v '^$' || true
}
REQ="$(_list required)"
OPT="$(_list optional)"

# 解析解释器（实跑守卫；回退链同 harness-env.sh）
_resolve_python() {
  local c
  for c in "${HARNESS_PYTHON:-}" "${HARNESS_TEST_PYTHON:-}" python3 python; do
    [ -n "$c" ] || continue
    if command -v "$c" >/dev/null 2>&1 && "$c" -c 'pass' >/dev/null 2>&1; then command -v "$c"; return 0; fi
  done
  return 0
}
# 解析任意工具：python3/python 走解释器解析（实跑守卫），其余 command -v
_resolve_tool() {
  case "$1" in
    python3|python) _resolve_python;;
    *) command -v "$1" 2>/dev/null || true;;
  esac
}

FP="$(uname -s 2>/dev/null || echo unknown)-$(uname -m 2>/dev/null || echo unknown)"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"

tmp="$(mktemp)"
{
  echo "# 由 ci/bin/harness-preflight.sh 生成 —— 本机环境解析缓存，请勿提交（.gitignore 已排除）。"
  echo "# 生成时间: $TS"
  printf 'HARNESS_ENV_OS=%q\n' "$FP"
} > "$tmp"

# 解析 required + optional，逐个落盘
missing=""
for t in $REQ $OPT; do
  p="$(_resolve_tool "$t")"
  printf 'HARNESS_TOOL_%s=%q\n' "$t" "$p" >> "$tmp"
  if [ "$t" = python3 ] && [ -n "$p" ]; then
    printf 'HARNESS_PYTHON=%q\n' "$p" >> "$tmp"
  fi
done

# required 缺失汇总（决定退出码）
for t in $REQ; do
  p="$(_resolve_tool "$t")"
  if [ -z "$p" ]; then missing="$missing $t"; fi
done

mv "$tmp" "$OUT"

if [ -n "$missing" ]; then
  warn "环境未就绪：缺 required 工具 ——$missing"
  warn "装好后重跑：bash ci/bin/harness-preflight.sh"
  exit 1
fi

say "[preflight] 环境就绪，已写 $OUT"

# gate 关联提示（缺失只告警，**不改门禁的黄语义** —— 可选门禁缺工具仍是「未配置」黄，不阻断）
if ! command -v semgrep >/dev/null 2>&1 && grep -qE '^[[:space:]]*pitfall:[[:space:]]*true' "$ID" 2>/dev/null; then
  warn "提示：gates.pitfall=true 但缺 semgrep —— 该门禁将记黄（未配置）"
fi
if ! command -v trivy >/dev/null 2>&1 && grep -qE '^[[:space:]]*dep:[[:space:]]*true' "$ID" 2>/dev/null; then
  warn "提示：gates.dep=true 但缺 trivy —— 该门禁将记黄（未配置）"
fi
exit 0
