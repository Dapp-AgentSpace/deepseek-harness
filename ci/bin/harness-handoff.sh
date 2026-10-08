#!/usr/bin/env bash
# harness-handoff.sh — Handoff 派生视图入口（ADR-0012 决策 1/4）。聚合逻辑在 ci/bin/handoff.py。
#
# **派生视图，不落盘**：只往 stdout 打，不写任何文件。ADR-0012 决策 4 把「答不上『谁消费它、
# 怎么检测从未被消费』的产出」一律降级为派生视图 —— 于是「产出即闲置」在结构上不可能。
#
# 用法: harness-handoff.sh <runcard-id|tsd-slug>
# 退出码: 0=已输出 / 1=找不到 RunCard / 2=python3 不可用
set -euo pipefail
export PYTHONUTF8=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# 环境解析（解释器 / 编码）单源见 ci/bin/harness-env.sh；本机缓存 .harness/toolchain.env 由 harness-preflight.sh 生成。
# 本脚本主体在 python：占位桩下会**静默什么都不输出**，与「没有内容」不可分。
# shellcheck source=harness-env.sh
source "$(dirname "${BASH_SOURCE[0]}")/harness-env.sh"
py_ok || { echo "[handoff] python3 不可用（命令存在但执行失败；Windows 上常见为 Store 占位桩）——拒绝静默无事发生" >&2; exit 2; }

[ $# -ge 1 ] || { echo "用法: harness-handoff.sh <runcard-id|tsd-slug>" >&2; exit 2; }

exec "$HARNESS_PYTHON" "$ROOT/ci/bin/handoff.py" "$ROOT" "$1"
