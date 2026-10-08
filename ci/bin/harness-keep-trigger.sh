#!/usr/bin/env bash
# harness-keep-trigger.sh — 「是否触发 cs-keep 沉淀」的确定性判断原语（优化 #4）。
# 扫 .codestable/lessons/ 的 observed lesson，判断是否有尚未落盘（landed）的待沉淀知识：
#   - lesson 无 proposal-{slug}.md                → 未扫描（需触发 keep-scan）
#   - 有提案但 status ≠ landed（proposed/approved/need-human）→ 待 owner 处理
#   - 有提案且 status = landed                    → 已沉淀（跳过）
# 退出码 0=无待沉淀 / 1=有待沉淀（stdout 列出待处理清单，供 harness-close 触发 keep-scan → 批准 → keep-land）。
# 只读：不改 lesson、不改提案。这是 close 阶段「判断是否需要触发 cs-keep」的执行原语，替代「纪律委托」散文。
# 用法: harness-keep-trigger.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LESSONS="$ROOT/.codestable/lessons"
WORK="$ROOT/.harness/work"

emit() { printf '[keep-trigger] %s\n' "$*"; }

[ -d "$LESSONS" ] || { emit "无 .codestable/lessons/，无待沉淀 lesson"; exit 0; }

unlanded=0
for l in "$LESSONS"/*.md; do
  [ -f "$l" ] || continue
  grep -qE '^status:[[:space:]]*observed' "$l" || continue
  # slug 与 keep-scan.sh 同源（basename + 白名单净化），保证 proposal 文件名对齐
  slug="$(basename "$l" .md | tr -cd 'A-Za-z0-9._-')"
  [ -n "$slug" ] || continue
  prop="$WORK/proposal-${slug}.md"
  if [ -f "$prop" ] && grep -qE '^status:[[:space:]]*landed' "$prop"; then
    :  # 已沉淀
  else
    unlanded=$((unlanded+1))
    if [ -f "$prop" ]; then
      st="$(sed -nE 's/^status:[[:space:]]*([^[:space:]]+).*/\1/p' "$prop" | head -1)"
      emit "待处理 lesson: ${slug}（提案 status=${st:-未知}）"
    else
      emit "未扫描 lesson: ${slug}"
    fi
  fi
done

if [ "$unlanded" -eq 0 ]; then
  emit "无待沉淀 lesson（observed 均已 landed）"
  exit 0
fi
emit "有待沉淀 lesson：${unlanded} 条 → 触发 cs-keep 沉淀流程（keep-scan → 批准 → keep-land）"
exit 1
