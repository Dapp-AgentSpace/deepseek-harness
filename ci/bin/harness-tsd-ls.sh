#!/usr/bin/env bash
# harness-tsd-ls.sh — TSD 花名册派生视图入口（ADR-0012 决策 4）。聚合逻辑在 ci/bin/tsd_board.py。
#
# **派生视图，不落盘**：只往 stdout 打，不写任何文件；**不 spawn agent**（agent 入口是 harness skill，
# 视图只产出 slug）。单 TSD 详情复用 `harness-handoff.sh <slug>`，本视图不重造详情渲染。
#
# 用法: harness-tsd-ls.sh [--json]
# 退出码: 0=已输出（含「空目录 / 缺目录」的显式说明）/ 2=python3 不可用 或 参数错误
set -euo pipefail
export PYTHONUTF8=1  # PEP 540: Windows 强制 UTF-8（避免 GBK 读/写中文出错）

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# 环境解析（解释器 / 编码）单源见 ci/bin/harness-env.sh；本脚本主体在 python：占位桩下会**静默产出空**，
# 与「真的没问题」不可分，故先实跑一次解释器守卫（不假绿）。**不能只信 py_ok**：harness-env.sh 的
# toolchain.env 缓存分支只做 `[ -x ]` 存在性检查、并不实跑，故陈旧缓存指向「可执行但跑不起来」的解释器时
# py_ok 仍为真 —— 这里补一次真实运行，把「不假绿」保证落到缓存分支上。
# shellcheck source=harness-env.sh
source "$(dirname "${BASH_SOURCE[0]}")/harness-env.sh"
py_ok && "$HARNESS_PYTHON" -c 'pass' >/dev/null 2>&1 || { echo "[tsd-ls] python3 不可用（命令存在但执行失败；Windows 上常见为 Store 占位桩）——拒绝静默无事发生" >&2; exit 2; }

# 参数校验：只认 --json（其余即用法错误，退 2，不静默忽略）
for a in "$@"; do
  case "$a" in
    --json) ;;
    *) echo "[tsd-ls] 未知参数: $a（用法: harness-tsd-ls.sh [--json]）" >&2; exit 2;;
  esac
done

exec "$HARNESS_PYTHON" "$ROOT/ci/bin/tsd_board.py" "$ROOT" "$@"
