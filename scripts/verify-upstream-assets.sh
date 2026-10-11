#!/usr/bin/env bash
# verify-upstream-assets.sh — 定制优化资产清单门禁（upstream 同步专用）。
#
# 硬约束 1「定制功能不丢」的可执行载体：逐项 grep 本 fork 的定制优化资产，
# 任一资产缺失即退出码 1（门禁红）。合并 upstream 前跑一遍（基线），
# 合并后跑一遍（回归）——两次都全绿才算合并正确性成立。
#
# 用法：
#   bash scripts/verify-upstream-assets.sh            # 检查工作树
#   bash scripts/verify-upstream-assets.sh <ref>      # 检查指定 ref（如 HEAD 或合并结果）
#
# 资产登记：新增定制功能时在此追加一行（名称 | 证明存在性的 grep 模式 | 路径），
# 与 .agents/skills/dsh-upstream-sync/SKILL.md §1 的清单保持一致。
set -u

REF="${1:-HEAD}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

# 每行格式：name | pattern | path（pattern 为 ERE，path 为 git grep 的路径限定）
ASSETS=(
  "wait_settlement 工具 | wait-settlement | packages/subagent/tool-subagent-control/src/wait-settlement.ts"
  "waitSettlement 服务 API | waitSettlement | packages/subagent/subagent/src"
  "SubagentWaitOutcome 类型 | SubagentWaitOutcome | packages/subagent/subagent/src"
  "agent-loop 防卡死（STALL 上限） | STALL_HARD_LIMIT_MS | packages/core/agent-loop/src/agent.ts"
  "agent-loop 防卡死（STREAMING 上限） | STREAMING_HARD_LIMIT_MS | packages/core/agent-loop/src/agent.ts"
  "agent-loop 进度通知 | PROGRESS_INTERVAL_MS | packages/core/agent-loop/src/agent.ts"
  "agent-loop 重复防护 | REPETITION_GUARD | packages/core/agent-loop/src/agent.ts"
  "runtime-types 签名修正（whenIdle） | whenIdle | packages/core/agent/src/runtime-types.ts"
  "runtime-types 签名修正（lastActivityAt） | lastActivityAt | packages/core/agent/src/runtime-types.ts"
)

red=0
echo "[verify-upstream-assets] 检查 ref: $REF"
for entry in "${ASSETS[@]}"; do
  name="${entry%%|*}"
  rest="${entry#*| }"
  pat="${rest%%|*}"
  path="${rest#*| }"
  # 去掉可能残留的首尾空白
  name="$(printf '%s' "$name" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  pat="$(printf '%s' "$pat" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  path="$(printf '%s' "$path" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  if git grep -q -E "$pat" "$REF" -- "$path" 2>/dev/null; then
    echo "  OK   $name"
  else
    echo "  MISS $name  (grep '$pat' in '$path' @ $REF)"
    red=1
  fi
done

if [ "$red" -eq 1 ]; then
  echo "[verify-upstream-assets] ✗ 存在缺失的定制资产 —— 合并正确性不成立，停止并恢复后再继续。"
  exit 1
fi
echo "[verify-upstream-assets] ✓ 全部定制资产在场（$REF）。"
exit 0
