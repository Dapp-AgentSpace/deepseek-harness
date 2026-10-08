#!/usr/bin/env bash
# harness-checklist-issue.sh — shared checklist 项在本项目被判定为「过泛/假阳/不适用」时，落一条 cs-issue
# （追踪）+ 引导调用方非零退出（通知），供 suite owner 复核后退役/收紧 applies_to。只读：不修 shared 源。
#
# 用法: harness-checklist-issue.sh <project.id> <checklist-id> <原因>
#   证据（judge 结论/命中片段）从 stdin 读入，落入 issue 的「证据」节。
set -euo pipefail

PID="${1:?用法: harness-checklist-issue.sh <project.id> <checklist-id> <原因>}"
CID="${2:?缺少 checklist id}"
REASON="${3:?缺少原因（过泛/假阳/不适用 等）}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=harness-issue-lib.sh
source "$ROOT/ci/bin/harness-issue-lib.sh"

issue_safe_slug "project.id" "$PID"
issue_safe_slug "checklist id" "$CID"
REASON="$(issue_oneline "$REASON")"

WORK="$ROOT/.harness/work"
DATE="$(date +%Y-%m-%d)"
TS="$(date +%Y-%m-%dT%H:%M:%S%z)"
EVIDENCE="$(issue_evidence)"
OUT="$(issue_next_path "$WORK" "${PID}-checklist-${CID}-${DATE}")"
SLUG="$(basename "$OUT" .md)"
cat > "$OUT" <<EOF
---
schema_version: 1
id: ${SLUG}
kind: issue
status: proposed
producer: harness-checklist
created: ${DATE}
updated: ${DATE}
---

# shared checklist 项在本项目疑似过泛/假阳：${CID}

## 目标
复核 shared 约束 ${CID} 是否对本项目「${PID}」过泛/假阳；若确认，suite owner 退役或收紧其
\`applies_to\`，避免污染其它项目。

## 现场
- 项目：${PID}
- checklist 项：${CID}
- 原因：${REASON}
- 发现时间：${TS}

## 边界
- 只读：本 issue 只做复核与 shared 源修订，不在本项目本地改写 shared 项（本地可临时豁免并记录）。

## 证据
${EVIDENCE}

## 验收
- suite owner 确认后：退役 shared 项，或收紧 applies_to，或确认为本项目误判并关闭。

## 状态与未决
- proposed：待 owner 确认后处理。
EOF

echo "[checklist-issue] 已落 work-unit: .harness/work/${SLUG}.md"
echo "[checklist-issue] 通知路径：调用方非零退出 → CI 失败（GitHub Actions / GitLab pipeline）→ 通知 owner"
