#!/usr/bin/env bash
# harness-epic-progress.sh — TSD close 后「关联 epic 剩余 item」派生视图入口（ADR-0012 决策 4）。
# 聚合逻辑在 ci/bin/epic_progress.py。
#
# **派生视图，不落盘**：只往 stdout 打，不写任何文件；**不 spawn agent**。
# 消费方：harness-close 步骤 4 汇总报告的 `## 关联 epic 剩余 item` 节 + harness-run 步骤 7 close 摘要行；
# `closed-loop-audit.sh` 的 `close-epic-remaining` 检查据此判红（缺节 = 该产出没有流程内消费者）。
#
# 用法: harness-epic-progress.sh <tsd-slug>
# 退出码: 0=已输出（含「无 epic 关联 / 判不了 / 无剩余 / 有剩余」的显式说明）/ 2=python3 不可用 或 参数错误
set -euo pipefail
export PYTHONUTF8=1  # PEP 540: Windows 强制 UTF-8（避免 GBK 读/写中文出错）

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# 环境解析（解释器 / 编码）单源见 ci/bin/harness-env.sh；先实跑一次解释器守卫（不假绿，同 harness-tsd-ls.sh）。
# shellcheck source=harness-env.sh
source "$(dirname "${BASH_SOURCE[0]}")/harness-env.sh"
py_ok && "$HARNESS_PYTHON" -c 'pass' >/dev/null 2>&1 || { echo "[epic-progress] python3 不可用（命令存在但执行失败）——拒绝静默无事发生" >&2; exit 2; }

# 参数校验：只认 <tsd-slug> 一个位置参数（缺 / 多 → 用法错误，退 2，不静默忽略）
if [ "$#" -ne 1 ]; then
  echo "[epic-progress] 用法: harness-epic-progress.sh <tsd-slug>" >&2
  exit 2
fi

exec "$HARNESS_PYTHON" "$ROOT/ci/bin/epic_progress.py" "$ROOT" "$1"
