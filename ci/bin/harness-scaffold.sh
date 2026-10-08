#!/usr/bin/env bash
# harness-scaffold.sh — 项目接入时按技术栈探测，自动生成确定性门禁的「基准文件」与架构契约「声明」。
#
# 原则（对齐 ADR-0001 / CONTRACT-001）：
#   - 只生成「真实、可落盘、可失败」的确定性校验，绝不生成 exit 0 的空过假校验；
#   - 架构契约是判断类：scaffold 只落声明草稿 .harness/contracts/arch.md，由 LLM-as-judge 执行；
#   - 无法安全自动生成的 gate 置 false；gates.* 首次全写，之后绝不覆盖 owner 手改的值，
#     只补「ci/gates.yaml 注册表里有、identity.yaml 里缺」的新门禁开关（否则「加门禁只改
#     注册表」不成立——老项目永远拿不到新门禁的开关，closed-loop-audit 会一直报缺开关）。
#
# 用法: ./ci/bin/harness-scaffold.sh [--refresh-base] [--stack <label>] [ROOT]    # 默认仓库根；须先跑 harness-init 确定 project.id
#   --refresh-base  强制重生成确定性基准文件（harness.schema-check）；补注册表新增而 identity
#                   缺的 gates.* 开关；不覆盖已有值、不触碰 contracts（项目自有事实）。供 upgrade.sh 调用。
#   --stack <label> greenfield 冷启动：无代码仓库显式指定目标栈（maven|gradle|go|rust|npm|python|shell），
#                   按该栈模板生成 arch.md（facts 空、标注 greenfield、待首次落地后刷新）；有代码时也可强制覆盖探测标签。
set -euo pipefail
export PYTHONUTF8=1  # PEP 540: Windows 强制 UTF-8（避免 GBK 读/写中文出错）

ROOT=""
REFRESH_BASE=0
STACK_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --refresh-base) REFRESH_BASE=1;;
    --stack) STACK_OVERRIDE="$2"; shift;;
    --stack=*) STACK_OVERRIDE="${1#--stack=}";;
    *) ROOT="$1";;
  esac
  shift
done
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
HARNESS_DIR="$ROOT/.harness"
ID_FILE="$HARNESS_DIR/identity.yaml"
SCAFFOLD_STATE="$HARNESS_DIR/.scaffold-state"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 库与本脚本同目录（套件 ci/bin）；HARNESS_ID_ROOT / HARNESS_STACK_ROOT 指向接入目标 ROOT（可能是外部仓库，非套件自身）。
# shellcheck source=harness-identity.sh
source "$SCRIPTS_DIR/harness-identity.sh"
HARNESS_ID_ROOT="$ROOT"
# shellcheck source=harness-stack.sh
source "$SCRIPTS_DIR/harness-stack.sh"
HARNESS_STACK_ROOT="$ROOT"
# 环境解析（解释器 / 编码）单源见 ci/bin/harness-env.sh；缓存 .harness/toolchain.env 由 harness-preflight.sh 生成。
# shellcheck source=harness-env.sh
source "$SCRIPTS_DIR/harness-env.sh"

emit() { printf '[scaffold] %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# 模块依赖图（可选导航，ADR-0006）：多栈抽取「谁依赖谁」，只列事实不下结论。scaffold 把它当 facts 写进 arch.md。
# tree-sitter 未装 / 无 python3 / 无模块 → 无输出（调用方据此标注「未生成」，绝不假绿、绝不伪造图）。
depgraph_run() {
  local fmt="$1" specs out win_root
  local python="${HARNESS_PYTHON}"
  command -v "$python" >/dev/null 2>&1 || return 1
  specs="$(stack_detect_all 2>/dev/null || true)"
  [ -n "$specs" ] || return 1
  win_root="$(_winpath "$ROOT")"
  specs="$(printf '%s\n' "$specs" | while IFS=$'\t' read -r st p; do [ -n "$p" ] && printf '%s\t%s\n' "$st" "$(_winpath "$p")"; done)"
  out="$(printf '%s\n' "$specs" | "$python" "$SCRIPTS_DIR/depgraph.py" --multi "$win_root" - --fmt "$fmt" --collapse 2 2>/dev/null || true)"
  [ -n "$out" ] && printf '%s\n' "$out"
}

# ---- 技术栈探测：委托共享深模块 harness-stack.sh（探测谓词/优先级单一来源，与 gate 执行共用）----
# 标签：maven|gradle|go|rust|npm|python|shell|unknown。优先 Java（多数 monorepo 的主构建模块），
# 其次 go/rust，再 JS，再 Python，最后纯脚本兜底。

# ---- 各 gate 是否可「真实接线」（返回 0=可 / 1=不可）----
wire_static() {
  case "$stack" in
    maven|gradle) stack_java_runner;;
    go) have go;;
    rust) have cargo;;
    npm) stack_lint_script;;
    shell) return 0;;   # bash -n 兜底恒可用
    *) return 1;;
  esac
}

wire_schema() {
  [ "$stack" = maven ] || [ "$stack" = gradle ]   # Java 持久化模型才有 @Document
}

wire_pitfall() {
  have semgrep   # 坑库 = 共享 Semgrep 规则 ci/rules/pitfalls.yaml（需 semgrep CLI）
}

# 依赖安全需三样齐备：策略单源 + 有依赖可查 + trivy。缺 trivy 时置 false（不是黄：
# 本仓确实没有可执行校验，报黄会每次跑都刷一条噪声；置 false 由 owner 在装好 trivy 后手动开）。
wire_dep() {
  [ -f "$ROOT/ci/dep-policy.yaml" ] || { emit "dep 不接线：缺 ci/dep-policy.yaml"; return 1; }
  # 不用 `stack_dep_files | grep -q .`：本脚本 set -o pipefail，grep -q 首个匹配即退出会让上游
  # sort 收到 SIGPIPE → 整条管道非零 → 明明有清单却报「无清单」（ocr round-3 #5）。捕获变量不走管道。
  local _depf; _depf="$(stack_dep_files)"
  [ -n "$_depf" ] || { emit "dep 不接线：本仓无依赖清单/锁文件"; return 1; }
  # 缺工具时 emit：此前这里**全程无提示**，owner 只看到 gates.dep=false，无从得知为何没接上。
  # （对比 wire_compat 每条不接线都有 emit —— 同一份文件里两套标准。）
  have trivy || { emit "dep 不接线：未装 trivy（装好后手改 gates.dep 置 true 并重跑 scaffold）"; return 1; }
  # g_dep 还多一个前提：**能跑的解释器**（py_ok，判定归 depcheck.py）。命令在但执行失败
  # （Windows 上常见为 Store 占位桩）时 g_dep 会红；只查 trivy 会把它接成 true → 装出个每次跑都红
  # 的门禁（ocr round-3 #9）。
  py_ok \
    || { emit "dep 不接线：python3 不可用（命令存在但执行失败）——g_dep 的判定依赖 depcheck.py"; return 1; }
  return 0
}

# 兼容性需三样齐备：策略单源 + 有清单可读 + **至少一条可判定的「最低支持版本」声明**。
# 缺声明时置 false（不是黄：本仓确实没有可校验的声明，报黄会每次跑都刷一条噪声；置 false 由 owner
# 把基线声明出来后再手动开）——同 wire_dep 对 trivy 的取舍。探针实跑 compatcheck.py 的 collect()
# 而非只 `command -v`：Windows 上 python3 常是 Store 占位桩，命令在但执行即失败，只查命令会把
# 「不可接线」误判成可接线，装出一个每次跑都黄的门禁；判据也不在 shell 里重复实现。
wire_compat() {
  [ -f "$ROOT/ci/compat-policy.yaml" ] || { emit "compat 不接线：缺 ci/compat-policy.yaml"; return 1; }
  local m; m="$(stack_compat_manifests)"
  [ -n "$m" ] || { emit "compat 不接线：本仓无可判定清单（package.json/go.mod/Cargo.toml/pom.xml/pyproject.toml）"; return 1; }
  # stdin 不会被 MSYS 自动转 Windows 路径（只有参数会），逐行过 _winpath 归一，同 g_compat。
  local rc=0
  printf '%s\n' "$m" \
    | while IFS= read -r p; do [ -n "$p" ] && printf '%s\n' "$(_winpath "$p")"; done \
    | "${HARNESS_PYTHON}" "$SCRIPTS_DIR/compatcheck.py" --probe >/dev/null 2>&1 || rc=$?
  # rc=1 是探针唯一「干净地说不」的码（本仓确无声明）。其余非零码无法与「解释器跑不起来」区分，
  # 一律按「接线失败」报出来——静默置 false 会让人以为门禁正常，实际它从未接过线（Windows 上
  # python3 常见为 Store 占位桩，命令在但执行即失败，正是这个盲区）。
  case "$rc" in
    0) return 0;;
    1) emit "compat 不接线：本仓清单未声明任何最低支持版本（engines/requires-python/rust-version/go 指令/Java 编译级别）——声明好基线后手改 gates.compat 置 true"; return 1;;
    *) emit "compat 不接线：探针执行异常 rc=$rc（${HARNESS_PYTHON} 不可用或 compatcheck.py 报错）——修好后重跑 scaffold，或手改 gates.compat"; return 1;;
  esac
}

# ---- 证据采集（供 arch 草稿自动生成）----
base_package() {
  local f pkg
  f="$(find "$ROOT" -type f -path '*/src/main/java/*' \( -path '*/controller/*' -o -path '*/service/*' \) -name '*.java' 2>/dev/null | head -1 || true)"
  [ -n "$f" ] || return 1
  pkg="$(grep -m1 '^package ' "$f" 2>/dev/null | sed -E 's/^package[[:space:]]+([a-zA-Z0-9_.]+);.*/\1/' || true)"
  [ -n "$pkg" ] || return 1
  echo "$pkg" | sed -E 's/\.(controller|service)(\..*)?$//'
}

modules_list() {
  # 只列「子模块」目录（深度 2：ROOT/<module>/<manifest>）；根 manifest 属单模块仓库，不算子模块
  find "$ROOT" -mindepth 2 -maxdepth 2 -type f \( -name pom.xml -o -name build.gradle -o -name build.gradle.kts -o -name go.mod -o -name Cargo.toml -o -name package.json -o -name composer.json \) \
    -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null \
    | sed 's|/[^/]*$||' | sed "s|^$ROOT/||" | sort -u | tr '\n' ' '
}

layer_dirs() {
  find "$ROOT" -type d -path '*/src/main/java/*' 2>/dev/null \
    | grep -oE '(controller|service|model|repository|repo|dao|mapper|util|config|dto|vo|entity|domain|web|job|filter|exception|annotation|constant|property)' \
    | sort | uniq -c | awk '{printf "%s(%s) ", $2, $1}'
}

# ---- 生成物 ----

# （已退役）原 pitfalls_for 生成 .harness/pitfalls.txt 字面坑库 → 改为共享 Semgrep 规则
# ci/rules/pitfalls.yaml（rule.id 对齐 checklist id），由 harness-gate.sh 的 g_pitfall 执行。

# Java 持久化模型校验：DATA-001「持久化模型必须有 @Document」（有 @Id 但缺 @Document 即违例，value 不约束）
write_schema_check() {
  local out="$ROOT/harness.schema-check"
  cat > "$out" <<'EOF'
#!/usr/bin/env bash
# harness.schema-check — 数据模型域确定性校验（harness-scaffold 按栈生成，可手改）。
# 当前规则：DATA-001「持久化模型必须有 @Document 注解」，@Document 上的 collection value 不约束。
# 判据：顶层 model 包（非 service.<域>.model 这类 DTO）里，有 @Id（Mongo 主键）但没有 @Document、
#       也没 extends BaseModel 的类 = 违例。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
found=0
while IFS= read -r f; do
  case "$f" in */service/*) continue;; esac
  if grep -q '@Id' "$f" && ! grep -q '@Document' "$f" && ! grep -qE 'extends[[:space:]]+BaseModel' "$f"; then
    echo "${f#$ROOT/}"
    found=1
  fi
done < <(find "$ROOT" -path '*/model/*' -name '*.java' -not -path '*/target/*' -not -path '*/node_modules/*' 2>/dev/null)
if [ "$found" -eq 1 ]; then
  echo "[schema] DATA-001 违例：持久化模型（有 @Id）缺少 @Document 注解"
  exit 1
fi
echo "[schema] DATA-001 通过"
exit 0
EOF
  chmod +x "$out"
}

# 架构契约声明（判断类，非确定性门禁）：按栈选模板 + 机器采集 facts，落 .harness/contracts/arch.md。
# 四带 schema（ADR-0006 三带 + human experience）：facts(机器) / boundaries(模板基线) / semantics(人工)
# / constraints(人工约束)。facts 首次生成后不再被 scaffold 自动覆盖（含 --refresh-base），owner 确认即冻结。
write_arch_contract() {
  local out="$HARNESS_DIR/contracts/arch.md"
  local scripts_dir tpl tpl_file
  scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  case "$stack" in
    maven|gradle) tpl=java;;
    go|rust|npm|python|shell|unknown) tpl="$stack";;
    *) tpl=unknown;;
  esac
  tpl_file="$scripts_dir/../contracts/arch/$tpl.md"
  [ -f "$tpl_file" ] || tpl_file="$scripts_dir/../contracts/arch/unknown.md"

  local base modules layers profile pid generated
  base="$(base_package 2>/dev/null || true)"
  modules="$(modules_list)"
  layers="$(layer_dirs || true)"
  profile="$(stack_profile)"
  pid="$(h_id)"
  generated="$(date +%Y-%m-%dT%H:%M:%S)"
  [ -n "$modules" ] || modules="（未识别到子模块）"
  [ -n "$layers" ]  || layers="（未识别分层目录）"
  # 模块依赖图（可选）：tree-sitter 未装则留空，facts 区标注「未生成」。
  local dg_facts="" dg_mermaid=""
  if [ "$GREENFIELD" != 1 ]; then
    dg_facts="$(depgraph_run facts || true)"
    dg_mermaid="$(depgraph_run mermaid || true)"
  fi

  {
    cat <<EOF
---
project: ${pid}
status: declared
domain: arch
enforcement: judge
schema_version: 2
stack: ${stack}
generated_at: ${generated}
human_reviewed: false
---

# 架构契约（声明）

> 本文是**声明**，不是确定性脚本。enforcement 走 LLM-as-judge：\`ci/bin/judge-review.sh arch\`（\`--depgraph\` 可选）。
> 检测深度 = 声明深度（ADR-0006）：facts（机器事实）→ boundaries（边界）→ semantics（语义）
> → constraints（human experience 人工约束）。声明越深，judge 能锚定的 drift 越深。

## 一、facts（机器采集的事实，一次生成即冻结，不承载判断）
- 技术栈：${stack}
EOF
    [ "$GREENFIELD" = 1 ] && echo "- 仓库状态：greenfield（无代码，facts 待首次落地后刷新）"
    if [ "$stack" = maven ] || [ "$stack" = gradle ]; then
      echo "- base package：${base:-（未探测到 Java 源码）}"
    fi
    cat <<EOF
- 子模块：${modules}
- 分层目录（关键词计数）：${layers}
- 架构画像：${profile:-（未识别框架/ORM）}
EOF
    # 模块依赖图（可选导航，只列事实不下结论）：tree-sitter 未装则标注未生成。
    if [ -n "$dg_mermaid" ] || [ -n "$dg_facts" ]; then
      printf '\n### 模块依赖图（tree-sitter 抽取，只读导航，不承载判断）\n\n'
    fi
    if [ -n "$dg_mermaid" ]; then
      printf '%s\n' "$dg_facts"
      printf '\n```mermaid\n%s\n```\n' "$dg_mermaid"
    elif [ -n "$dg_facts" ]; then
      printf '%s\n' "$dg_facts"
    else
      printf '\n- 模块依赖图：未生成（tree-sitter 未装，安装：pip install -r ci/requirements-depgraph.txt）\n'
    fi
    cat <<'EOF'

<!-- facts 区由 harness-scaffold.sh 首次生成；owner 确认后本文件不再被 scaffold 自动覆盖（含 --refresh-base） -->

## 二、boundaries（边界：依赖方向 / seam / 模块职责）

EOF
    cat "$tpl_file"
    cat <<'EOF'

## 三、semantics（语义：为什么这么分、什么变化归哪个模块——owner 人工填，机器不生成）
<!-- 例：跨域只经 service 接口的原因、某个 seam 为什么放这里、拆分/合并模块的判据 -->

## 四、constraints（human experience：owner 施加的人工约束）
<!-- 每条约束须能回指一个执行点（judge / deterministic 门禁 / 运行时契约），否则 CONTRACT-001 视为未声明。
     例：C1：DTO 字段与外部系统 camelCase 对齐 —— 执行点：judge-review.sh diff 评审 -->

## 五、执行点
- 每次 PR：`judge-review.sh diff` —— 审的是**代码**（归属/命名/接缝/边界），走 ocr；
  **ocr 不消费 prompt，读不到本文，故 `diff` 判不了「是否反架构声明」**。
  架构声明面靠 `judge-review.sh arch`（手动，见下）。
- arch 漂移（手动）：`judge-review.sh arch`（claude 读本文全文判 drift；`--depgraph` 追加 tree-sitter 依赖图导航）。
  **注意**：`install.sh` 不部署 workflows，本仓若无 `.github/workflows/` 落点，则以直跑命令为准。
- 确定性对账：`closed-loop-audit.sh` 核对 identity.yaml 的 gates 接线与任务产物命名/前缀（不解析本文架构规则）。
- 架构规则「声明↔执行点」是否真实：由 quality 节点（元治理，`judge-review.sh quality`）判断。
- 文档面：`judge-review.sh doc`（判据：3W2H 支撑 / 清晰 / 有证据；`DOC_RANGE` 指定范围）。
  ocr 按 `unsupported_ext` 过滤全部 `.md`，文档面必须走此入口。

## 六、状态
- [ ] **owner 逐条复核**上述 facts / boundaries / semantics / constraints；确认后把 frontmatter 的
      `human_reviewed` 置 `true`。**该字段是声明的权威状态**（`arch_prompt` 会读它，为 false 时
      judge 须在结论中标注「声明未经人确认」）；本 checkbox 只是同一状态的人读提示。
EOF
  } > "$out"
}

# gates.* 单项读写
has_gate_key() { grep -qE "^[[:space:]]*${1}:[[:space:]]*(true|false)[[:space:]]*$" "$ID_FILE"; }
gate_value()   { grep -oE "^[[:space:]]*${1}:[[:space:]]*[a-z]+" "$ID_FILE" | grep -oE "[a-z]+$" | head -1; }

# 写回 identity.yaml 的 gates.* 单项：已有则改值，缺行则追加到 gates: 块末尾。
# 追加时保持「连续 `key: true|false` 行」不变式——closed-loop-audit.sh 的门禁身份对账按连续行解析
# gates.*，把新 key 插到块中间或注释之后都会被截断，误报「注册表门禁缺开关」。
set_gate() {
  local key="$1" val="$2"
  if has_gate_key "$key"; then
    sed -E "s|^([[:space:]]*)${key}:[[:space:]]*.*|\1${key}: ${val}|" "$ID_FILE" > "$ID_FILE.tmp" && mv "$ID_FILE.tmp" "$ID_FILE"
  else
    awk -v k="$key" -v v="$val" '
      { L[NR] = $0 }
      $0 ~ /^gates:[[:space:]]*$/ { g = NR }
      $0 ~ /^[[:space:]]+[A-Za-z_][A-Za-z0-9_]*:[[:space:]]*(true|false)[[:space:]]*$/ { if (g && NR > g) last = NR }
      END {
        ins = (last ? last : g)
        if (!ins) { print "identity.yaml 缺 gates: 块，未追加 gates." k > "/dev/stderr"; exit 1 }
        for (i = 1; i <= NR; i++) { print L[i]; if (i == ins) print "  " k ": " v }
      }' "$ID_FILE" > "$ID_FILE.tmp" \
      && mv "$ID_FILE.tmp" "$ID_FILE" \
      || emit "注意：identity.yaml 追加 gates.$key 失败（请手补）"
  fi
}

# ---- 主流程 ----
stack="$(stack_detect)"
GREENFIELD=0
[ "$stack" = unknown ] && GREENFIELD=1
[ -n "$STACK_OVERRIDE" ] && stack="$STACK_OVERRIDE"
emit "技术栈: $stack"

[ -f "$ID_FILE" ] || { emit "缺少 $ID_FILE，请先跑 harness-init 确定 project.id"; exit 2; }

mkdir -p "$HARNESS_DIR/contracts" "$HARNESS_DIR/tsd" "$HARNESS_DIR/checklists" "$HARNESS_DIR/reports"

# 0) AGENTS.md 受管路由块：把 suite 的路由声明（ci/agents-routing.md）播种/合并进项目根 —— 缺则新建，
#    已有标记则更新，无标记则**追加**（保留项目自有内容）。幂等。这样 agent 选 skill 前读到的
#    AGENTS.md 会引导研发诉求先经 harness 入口、不得直接走 cs-feat 等跳过（owner 2026-09-26 定）。
#    合并/比对逻辑归 ci/bin/agents_md.py（与 audit 的 check 单一来源）；此处在 init 与 upgrade 两个入口生效。
if [ -f "$SCRIPTS_DIR/agents_md.py" ]; then
  _am_out="$("${HARNESS_PYTHON:-python3}" "$SCRIPTS_DIR/agents_md.py" ensure "$ROOT" 2>&1)"; _am_rc=$?
  if [ "$_am_rc" -ne 0 ]; then
    emit "⚠ AGENTS.md 路由块播种未完成（agents_md.py 退出 $_am_rc）: $_am_out"
  else
    emit "AGENTS.md 路由块: $_am_out"
  fi
fi

# 1) schema-check 生成副作用（Java 持久化模型）：wire_schema 为真且未生成/刷新时写基准文件。
#    gates.schema 接线值由下方「注册表循环」统一计算。
if wire_schema; then
  if [ "$REFRESH_BASE" -eq 1 ] || [ ! -f "$ROOT/harness.schema-check" ]; then
    write_schema_check
    if [ "$REFRESH_BASE" -eq 1 ]; then emit "刷新 harness.schema-check（DATA-001）"; else emit "生成 harness.schema-check（DATA-001）"; fi
  fi
fi

# 2) 架构契约（判断类，非确定性门禁）：按栈选模板 + 机器采集 facts，落 .harness/contracts/arch.md，
#    由 LLM-as-judge 执行。所有栈都生成基础声明（非 Java 也有），空仓库/未知栈落 unknown 模板骨架。
[ -f "$HARNESS_DIR/contracts/arch.md" ] || { write_arch_contract; emit "生成 .harness/contracts/arch.md（架构契约声明，judge 执行）"; }

# 3) 确定性门禁接线：key 来自注册表 ci/gates.yaml；接线值由 wire_<key>（栈探测代码）计算，
#    无 wire_<key> 的（如 audit，closed-loop-audit.sh 随套件提供）恒可用。仅首次 scaffold 写 identity.yaml。
REG_LS="$ROOT/ci/bin/harness-gates-ls.sh"
emit "—— 门禁接线结果 ——"
if [ -x "$REG_LS" ]; then
  # 先取再判退出码：`done < <("$REG_LS")` 把「读取失败」与「注册表为空」混为一谈 ——
  # python3 不可用（Windows Store 占位桩）时 gates-ls 非零退出、输出为空，循环直接不迭代，
  # **全部门禁静默不接线**，而升级输出里看不出任何异常（已实测：三个项目升级后对账报
  # 「注册表门禁 compat/dep 缺开关」）。harness-gate.sh 早有这样的检查，本脚本漏了。
  reg_tsv="$("$REG_LS")" || { emit "✗ 门禁注册表读取失败（$REG_LS 退出非零，常见原因：python3 不可用），未写 gates.* —— 不静默跳过"; exit 1; }
  [ -n "$reg_tsv" ] || { emit "✗ 门禁注册表为空（$REG_LS 无输出），未写 gates.* —— 不静默跳过"; exit 1; }
  while IFS=$'\t' read -r key name typ extra; do
    [ "$typ" = "deterministic" ] || continue
    val=false
    if declare -F "wire_$key" >/dev/null 2>&1; then "wire_$key" && val=true; else val=true; fi
    # 首次全写；之后只补「注册表有而 identity 缺」的新门禁（保证「加门禁只改 gates.yaml」成立），
    # 已存在的值绝不覆盖——owner 手改优先。
    if [ ! -f "$SCAFFOLD_STATE" ] || ! has_gate_key "$key"; then
      set_gate "$key" "$val"
      emit "$name($key) = $val（已写入）"
    else
      emit "$name($key) = $(gate_value "$key")（已有，不动；本仓可接线值 $val）"
    fi
  done <<< "$reg_tsv"
else
  emit "缺少 $REG_LS（门禁注册表读取器），未写 gates.*"
fi
if [ -f "$SCAFFOLD_STATE" ]; then
  emit "已 scaffold 过（$SCAFFOLD_STATE），不改已有 gates.*，仅补新增门禁开关与缺失基准文件"
else
  printf 'stack=%s\nat=%s\n' "$stack" "$(date +%Y-%m-%dT%H:%M:%S)" > "$SCAFFOLD_STATE"
  emit "gates.* 已按 $stack 写入 identity.yaml"
fi

emit "架构契约 → .harness/contracts/arch.md（judge-review.sh arch / ocr scan 执行，非确定性门禁）"
