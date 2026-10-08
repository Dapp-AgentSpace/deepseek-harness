#!/usr/bin/env bash
# harness-keep-scan.sh — 定期扫描 cs-keep 沉淀的 lesson（.codestable/lessons/），用无头 LLM（subagent）
# 解析提取，生成「checklist vs pitfalls」路由提案，落 .harness/work/proposal-{slug}.md
# （status: proposed）。只提不落：实际落盘由 harness-keep-land.sh 在 owner 批准（status: approved）后执行。
#
# 路由判据（单源见 README §五）：
#   - deterministic（落 pitfalls）：能被确定性工具（Semgrep AST/lint/脚本/类型）可靠判定，无假阳性；
#   - judge（落 checklist）：判定需要理解意图/语义/上下文，确定性工具会假阳性/假阴性。
#
# 用法: harness-keep-scan.sh [--runner claude|traecli|opencode|api]    # 默认 claude -p，可 env HARNESS_KEEP_RUNNER 覆盖
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LESSONS="$ROOT/.codestable/lessons"
WORK="$ROOT/.harness/work"
LLM_SH="${HARNESS_KEEP_LLM_SH:-$ROOT/ci/bin/harness-llm.sh}"
# shellcheck source=harness-identity.sh
source "$ROOT/ci/bin/harness-identity.sh"

emit() { printf '[keep-scan] %s\n' "$*"; }

RUNNER="${HARNESS_KEEP_RUNNER:-claude}"
while [ $# -gt 0 ]; do
  case "$1" in
    --runner) RUNNER="${2:-claude}"; shift;;
    --runner=*) RUNNER="${1#--runner=}";;
  esac
  shift
done

[ -d "$LESSONS" ] || { emit "无 .codestable/lessons/（cs-keep 尚未沉淀 lesson），无需扫描"; exit 0; }

PID="$(h_id)"
[ -n "$PID" ] || PID="unknown"

mkdir -p "$WORK"

# 无头 LLM 调用：复用共享深模块 harness-llm.sh（claude/traecli/opencode/api；这里只要 prompt → 输出，不需要 verdict）
run_keep_llm() {
  local r="$1" p="$2"
  printf '%s' "$p" | "$LLM_SH" "$r"
}

# 枚举提示的单源：从 ci/constraint-model.md frontmatter 读，不在 prompt 里硬编码第二份清单
# （踩过：加 accessibility 到单源后 prompt 仍是旧清单，LLM 永远不会提议新 category）。
# 兜底是内置列表——但只该在 constraint-model.md 缺失时生效。
CAT_ENUM="$(sed -n 's/^categories:[[:space:]]*//p' "$ROOT/ci/constraint-model.md" 2>/dev/null | head -1 | tr -s '[:space:]' '|' | sed 's/|$//')"
DOM_ENUM="$(sed -n 's/^domains:[[:space:]]*//p' "$ROOT/ci/constraint-model.md" 2>/dev/null | head -1 | tr -s '[:space:]' '|' | sed 's/|$//')"
# 兜底仅用于 constraint-model.md 缺失（ci/ 已随项目同步，正常不触发）。改单源时顺手同步这两行——
# 它们是「单源」的唯一例外，不同步等于在兜底路径上重新引入刚修掉的漂移。
[ -n "$CAT_ENUM" ] || CAT_ENUM="security|compliance|data-integrity|observability|architecture|process|governance|correctness|accessibility"
[ -n "$DOM_ENUM" ] || DOM_ENUM="log|data|harness-own-guard|contract|requirements"

# 提案正文指令：LLM 必须按此格式输出（frontmatter 供 land 路由，fenced 块是落盘工件）。
# 用带引号 heredoc 保证字面内容不被 shell 展开（枚举经 __CATEGORIES__/__DOMAINS__ 占位符注入）。
read -r -d '' EXTRACT_INSTR <<'EOF' || true
你是 harness 的 keep 提取 subagent。把下面这条 cs-keep lesson 路由为 checklist 项（judge）或 pitfalls 规则（deterministic），输出一份提案文件。

路由判据（严格二选一）：
- deterministic（落 pitfalls）：能被确定性工具（Semgrep AST / lint / 类型 / 脚本）可靠判定——违例样本命中 + 合法样本放过都验证过，无假阳性。
- judge（落 checklist）：判定需要理解意图/语义/上下文，确定性工具会假阳性/假阴性。

**边界纪律（harness 最忌上下文污染）**：每条 checklist 项必须显式声明 `problem_domain`（问题域——这条规则
解决什么问题空间）与 `domain_knowledge`（相关领域知识——判定/应用它需要知道什么），缺一不可，否则落盘挡回 need-human。
若本 lesson **明确点名**要修正/取代某条既有项（lesson 文本里出现该 item id），在提案 frontmatter 加
`supersedes: <该既有 item id>`；**不要猜测或编造 id** —— 拿不准就删掉此行（漏填只会触发 need-human；
猜错 id 会在落盘时静默改掉一条无关的既有项，正是要防的）。

只输出下面这份提案文件，不要任何额外解释或代码围栏包裹整份文件。

---
schema_version: 1
id: <lesson slug>
kind: proposal
status: proposed
producer: harness-keep
source: <lesson 路径，如 .codestable/lessons/2026-09-09-xxx.md>
project: __PID__
check_mode: judge|deterministic
domain: <__DOMAINS__|其他小写域>
category: <__CATEGORIES__>
severity: blocking|important
supersedes: <既有 item id（仅当 lesson 文本明确点名该 id 时填；拿不准删此行）|否则删此行>
---

# 提案：lesson「<slug>」→ <checklist|pitfalls>

## 路由理由
<一句话：为什么 judge / 为什么 deterministic>

## checklist 项（落 .harness/checklists/{domain}.md；用 markdown 围栏包住，内含自己的 frontmatter）
```markdown
---
id: <域大写-序号，如 HOG-009，避免与已有 id 冲突>
category: <__CATEGORIES__>
project: __PID__
status: project-local
domain: <domain>
severity: <severity>
check_mode: <judge|deterministic>
deterministic_rule: <仅 deterministic 填；judge 不写此行>
problem_domain: <问题域 slug，如 structured-logging>
domain_knowledge: <相关领域知识，一句话>
---

## <id> <规则标题>

## 规则
<一句话可执行规则>

## 适用 / 不适用
<边界与停止信号>

## 证据
<最多 3 条代表性路径/测试/diff 指针，来自 lesson>

## 判据 / 豁免
<judge 才需要：判据=什么算违例，豁免=什么算例外；deterministic 写「见下方 Semgrep 规则」>
```

## Semgrep 规则（仅 deterministic 才需要，落 .harness/pitfalls.yaml；judge 则整段省略）
```yaml
- id: <与上方 deterministic_rule 一致的规则 id>
  languages: [<lang>]
  message: "<id 前缀>: <一句话>"
  severity: ERROR
  pattern: <pattern>
```

=== lesson 内容 ===
EOF

found=0; proposed=0; skipped=0

for l in "$LESSONS"/*.md; do
  [ -f "$l" ] || continue
  slug="$(basename "$l" .md)"
  # 白名单净化：slug 进文件名，剥离 / .. 等防路径穿越（lesson 名视为不可信输入）
  slug="$(printf '%s' "$slug" | tr -cd 'A-Za-z0-9._-')"
  [ -n "$slug" ] || continue
  # 只扫 observed（待路由）；retired 不再路由，validated 已稳定不再重复提案
  grep -qE '^status:[[:space:]]*observed' "$l" || continue
  found=$((found+1))
  [ -f "$WORK/proposal-${slug}.md" ] && { skipped=$((skipped+1)); continue; }

  lesson_body="$(cat "$l")"
  prompt="${EXTRACT_INSTR//__PID__/${PID}}"
  prompt="${prompt//__CATEGORIES__/${CAT_ENUM}}"
  prompt="${prompt//__DOMAINS__/${DOM_ENUM}}"$'\n\n'"${lesson_body}"

  emit "提取 lesson: $slug (runner=$RUNNER)"
  # HOG-002：set +e 取退出码，不吞错误；out 捕获 stdout+stderr 便于诊断
  set +e
  out="$(run_keep_llm "$RUNNER" "$prompt" 2>&1)"
  rc=$?
  set -e

  prop="$WORK/proposal-${slug}.md"
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    emit "LLM 提取失败（rc=$rc），落 need-human 提案"
    cat > "$prop" <<PROP
---
schema_version: 1
id: ${slug}
kind: proposal
status: need-human
producer: harness-keep
source: .codestable/lessons/$(basename "$l")
project: ${PID}
created: $(date +%Y-%m-%d)
---

# 提案：lesson「${slug}」提取失败，需人工处理

LLM 调用失败（runner=${RUNNER}，rc=${rc}）。原始 lesson 见 source，LLM 输出：

${out:-（无输出）}
PROP
    continue
  fi

  # 写 LLM 输出，并把 status 固定为 proposed（LLM 若给错状态也不影响门控）
  printf '%s\n' "$out" > "$prop"
  if grep -qE '^status:[[:space:]]*' "$prop"; then
    sed -E 's/^status:[[:space:]]*.*/status: proposed/' "$prop" > "$prop.tmp" && mv "$prop.tmp" "$prop"
  fi

  # 校验路由字段完整，缺则转 need-human（避免 land 落错文件）。**范围与 land 的读取严格对齐**：
  # - check_mode/domain/severity：land 用 fm(text,...) 只读**外层 frontmatter**，故这里也只在该段 grep
  #   （整文件 grep 会被**内层 checklist 块**同名行假满足 —— 缺外层字段的提案蒙混过关、land 再挡回）。
  # - category/problem_domain/domain_knowledge：land 从**内层围栏块**取，故只在块内 grep。
  # 外层 frontmatter 提取：只取首个 `---` 到**第二个** `---`，且遇 ``` 围栏即停（防未闭合时吞进内层块）。
  outer_fm="$(awk '/^---[ \t]*$/{n++; if(n==1){f=1;next} if(n==2){exit}} /^```/{exit} f' "$prop")"
  # 闭合检测（#3）：第二个 `---` 必须存在且早于首个 ``` 围栏，否则外层 frontmatter 未闭合 → need-human。
  _fence_ln="$(awk '/^```/{print NR; exit}' "$prop")"
  _close_ln="$(awk '/^---[ \t]*$/{n++; if(n==2){print NR; exit}}' "$prop")"
  if [ -z "$_close_ln" ] || { [ -n "$_fence_ln" ] && [ "$_close_ln" -ge "$_fence_ln" ]; }; then
    emit "提案外层 frontmatter 未闭合（缺第二个 ---），转 need-human: $prop"
    sed -E 's/^status:[[:space:]]*.*/status: need-human/' "$prop" > "$prop.tmp" && mv "$prop.tmp" "$prop"
    continue
  fi
  if ! printf '%s\n' "$outer_fm" | grep -qE '^check_mode:[[:space:]]*(judge|deterministic)' \
    || ! printf '%s\n' "$outer_fm" | grep -qE '^domain:[[:space:]]*[a-z0-9-]+' \
    || ! printf '%s\n' "$outer_fm" | grep -qE '^severity:[[:space:]]*(blocking|important)'; then
    emit "提案外层 frontmatter 缺路由字段，转 need-human: $prop"
    sed -E 's/^status:[[:space:]]*.*/status: need-human/' "$prop" > "$prop.tmp" && mv "$prop.tmp" "$prop"
    continue
  fi
  ck_md="$(awk '/^```markdown[ \t]*$/{f=1;next} f&&/^```[ \t]*$/{exit} f' "$prop")"
  if ! printf '%s\n' "$ck_md" | grep -qE '^category:[[:space:]]*[a-z0-9-]+' \
    || ! printf '%s\n' "$ck_md" | grep -qE '^problem_domain:[[:space:]]*[^<[:space:]]' \
    || ! printf '%s\n' "$ck_md" | grep -qE '^domain_knowledge:[[:space:]]*[^<[:space:]]'; then
    emit "提案 checklist 块缺 category/problem_domain/domain_knowledge，转 need-human: $prop"
    sed -E 's/^status:[[:space:]]*.*/status: need-human/' "$prop" > "$prop.tmp" && mv "$prop.tmp" "$prop"
    continue
  fi
  # 内外一致性（#4）：land 按**外层** check_mode/domain/severity 路由。内层块同名行若与外层矛盾
  # （如外层 judge、内层 deterministic 带 yaml），会按外层落盘、内层 yaml 被静默忽略 → 两库不一致。
  _o_cm="$(printf '%s\n' "$outer_fm" | awk -F': *' '/^check_mode:/{print $2; exit}')"
  _i_cm="$(printf '%s\n' "$ck_md" | awk -F': *' '/^check_mode:/{print $2; exit}')"
  _o_dom="$(printf '%s\n' "$outer_fm" | awk -F': *' '/^domain:/{print $2; exit}')"
  _i_dom="$(printf '%s\n' "$ck_md" | awk -F': *' '/^domain:/{print $2; exit}')"
  _o_sev="$(printf '%s\n' "$outer_fm" | awk -F': *' '/^severity:/{print $2; exit}')"
  _i_sev="$(printf '%s\n' "$ck_md" | awk -F': *' '/^severity:/{print $2; exit}')"
  if { [ -n "$_o_cm" ] && [ -n "$_i_cm" ] && [ "$_o_cm" != "$_i_cm" ]; } \
    || { [ -n "$_o_dom" ] && [ -n "$_i_dom" ] && [ "$_o_dom" != "$_i_dom" ]; } \
    || { [ -n "$_o_sev" ] && [ -n "$_i_sev" ] && [ "$_o_sev" != "$_i_sev" ]; }; then
    emit "提案外层与内层块路由字段不一致（check_mode/domain/severity），转 need-human: $prop"
    sed -E 's/^status:[[:space:]]*.*/status: need-human/' "$prop" > "$prop.tmp" && mv "$prop.tmp" "$prop"
    continue
  fi
  # deterministic 必须带 Semgrep yaml 块（否则 land 落成指向不存在规则的 checklist 项）。按**外层**判。
  if printf '%s\n' "$outer_fm" | grep -qE '^check_mode:[[:space:]]*deterministic' && ! grep -q '```yaml' "$prop"; then
    emit "deterministic 提案缺 Semgrep 块，转 need-human: $prop"
    sed -E 's/^status:[[:space:]]*.*/status: need-human/' "$prop" > "$prop.tmp" && mv "$prop.tmp" "$prop"
    continue
  fi
  emit "已提案: $prop"
  proposed=$((proposed+1))
done

emit "完成：发现 $found 条 observed lesson，新提案 $proposed 条，跳过已提案 $skipped 条"
