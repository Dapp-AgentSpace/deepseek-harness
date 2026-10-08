#!/usr/bin/env bash
# harness-runtime-issue.sh — 运行回路发现业务不变量偏差时，落一条 cs-issue（追踪）+ 引导调用方非零退出（通知）。
#
# 只读：不修线上代码、不改数据，只写 .harness/work/{id}.md。
# 通知路径：调用方以非零退出 → CI 失败（GitHub Actions / GitLab pipeline 默认邮件）→ 通知 owner；
# 同时 open 的 proposed issue 会被 cs-issue / cs-pipeline issue 管道消费。
#
# disposition 终局（供 harness-measure.sh 度量运行回路 precision/TTF）：issue 落盘默认 disposition: open，
# owner 定位后手标 disposition: confirmed（真回归）或 false-alarm（误报）。只改 frontmatter，不改结构。
#
# 用法: harness-runtime-issue.sh <project.id> <domain> <invariant> [affected-path]
#   证据（违规日志/数据）从 stdin 读入，落入 issue 的「证据」节。
set -euo pipefail

PID="${1:?用法: harness-runtime-issue.sh <project.id> <domain> <invariant> [affected-path]}"
DOMAIN="${2:?缺少 domain（运行时契约域，如 mode-gating）}"
INVARIANT="${3:?缺少 violated invariant（被违反的业务不变量）}"
AFFECTED="${4:-未标注}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=harness-issue-lib.sh
source "$ROOT/ci/bin/harness-issue-lib.sh"

# PID/DOMAIN 进文件名，白名单防路径穿越；INVARIANT/AFFECTED 只进 markdown，单行化防结构注入
issue_safe_slug "project.id" "$PID"
issue_safe_slug "domain" "$DOMAIN"
INVARIANT="$(issue_oneline "$INVARIANT")"
AFFECTED="$(issue_oneline "$AFFECTED")"

WORK="$ROOT/.harness/work"
DATE="$(date +%Y-%m-%d)"
TS="$(date +%Y-%m-%dT%H:%M:%S%z)"
EVIDENCE="$(issue_evidence)"
OUT="$(issue_next_path "$WORK" "${PID}-runtime-${DOMAIN}-${DATE}")"
SLUG="$(basename "$OUT" .md)"
cat > "$OUT" <<EOF
---
schema_version: 1
id: ${SLUG}
kind: issue
status: proposed
disposition: open
producer: harness-runtime
created: ${DATE}
updated: ${DATE}
---

# 运行回路发现业务不变量偏差：${INVARIANT}

## 目标
恢复业务不变量「${INVARIANT}」在线上成立；根因定位与修复走 owner 复核。

## 现场
- 运行时契约域：${DOMAIN}
- 发现时间：${TS}
- 影响业务路径：${AFFECTED}
- 违反的不变量：${INVARIANT}

## 边界
- 运行回路只读：本 issue 只做根因定位 + 修复，不直接改线上代码或数据。

## 证据
${EVIDENCE}

## 验收
- 修复后，\`ci/bin/harness-runtime-check.sh\` 复跑不再命中本不变量偏差。

## 状态与未决
- proposed：待 owner 确认后定位根因并修复。
EOF

echo "[runtime-issue] 已落 work-unit: .harness/work/${SLUG}.md"
echo "[runtime-issue] 通知路径：调用方非零退出 → CI 失败（GitHub Actions / GitLab pipeline）→ 通知 owner"
