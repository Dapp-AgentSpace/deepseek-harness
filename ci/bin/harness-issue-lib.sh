#!/usr/bin/env bash
# harness-issue-lib.sh — 写「issue work-unit」的共享骨架（harness-runtime-issue / harness-checklist-issue 共用）。
# 承载安全净化（白名单防路径穿越、单行化防结构注入、证据截断防撑爆）与落盘路径原语（slug 唯一化），
# 消除这两处曾经各抄一份的安全逻辑。调用方只传语义参数、保留自己的 frontmatter 与 body。
# source 后使用（本文件是库，勿直接执行）。

# issue_safe_slug <label> <value>：非 [A-Za-z0-9._-] 即 exit 2（路径穿越/文件名注入防护）
issue_safe_slug() {
  case "$2" in *[!A-Za-z0-9._-]*) echo "[issue] $1 含非法字符（只允许 [A-Za-z0-9._-]）: $2" >&2; exit 2;; esac
}

# issue_oneline <value>：自由文本单行化（防 markdown 结构注入）
issue_oneline() { printf '%s' "$1" | tr '\n' ' '; }

# issue_evidence：从 stdin 读证据 → 50KB 截断 + 4 空格缩进（防超长撑爆 + ``` 结构注入）
issue_evidence() {
  local e
  e="$(cat)"; e="${e:0:51200}"
  printf '%s\n' "$e" | sed 's/^/    /'
}

# issue_next_path <work_dir> <base>：返回未占用的 <work_dir>/<base>[-n].md，并 mkdir -p
issue_next_path() {
  local work="$1" base="$2" slug="$base" n=0
  while [ -f "$work/$slug.md" ]; do n=$((n + 1)); slug="${base}-${n}"; done
  mkdir -p "$work"
  printf '%s/%s.md' "$work" "$slug"
}
