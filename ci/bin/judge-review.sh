#!/usr/bin/env bash
# judge-review.sh — LLM-as-judge 无头调用入口。评审 TSD/测试/代码/依赖 + 对账语义判断 + arch 漂移。
# 评审纪律见 skill `harness-review`。退出码 0=无 blocking / 1=有 blocking / 2=需人工（单源见 ci/README.md 门禁注册表）。
# 三个独立判断节点（review/contract/quality）各自绑定 runner，见 identity.yaml judge.nodes。
set -euo pipefail
export PYTHONUTF8=1  # PEP 540: Windows 强制 UTF-8（避免 GBK 读/写中文出错）

# 环境解析（解释器 / 编码）单源见 ci/bin/harness-env.sh；本机缓存 .harness/toolchain.env 由 harness-preflight.sh 生成。
# 本脚本主体在 python：占位桩下会**静默产出空**，与「真的没问题」不可分（gates-ls 盲区曾使对账变红）。
# shellcheck source=harness-env.sh
source "$(dirname "${BASH_SOURCE[0]}")/harness-env.sh"
py_ok || { echo "[judge] python3 不可用（命令存在但执行失败；Windows 上常见为 Store 占位桩）——拒绝静默无事发生" >&2; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LLM_SH="$ROOT/ci/bin/harness-llm.sh"
# shellcheck source=harness-identity.sh
source "$ROOT/ci/bin/harness-identity.sh"
# judge 收口共享库（judge_verdict 等）：判定标记分类的**单一真源**，主链路与 data/data-causal judge 同源，
# 不在调用点各抄一份 grep（抄多份必然改一处漏一处）。本库只定义函数，source 无副作用。
# shellcheck source=harness-judge-common.sh
source "$ROOT/ci/bin/harness-judge-common.sh"
# 位置参数 + --checklist-domain <domain> 选项（消费缝：把适用 judge checklist 上下文注入 prompt）
# 该选项**可重复**（也可逗号分隔）：一次评审常需多个域（如 TSD 评审要 requirements + contract + data）。
# 此前只收一个值，后一次覆盖前一次 —— 多域调用会**静默只剩最后一个**。
TARGET=""
PROMPT_FILE=""
CHECKLIST_DOMAIN=""
DEPGRAPH=""
LIST_DOMAINS=0
LIST_NODES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --checklist-domain) CHECKLIST_DOMAIN="${CHECKLIST_DOMAIN:+$CHECKLIST_DOMAIN,}${2:-}"; shift 2;;
    --checklist-domain=*) CHECKLIST_DOMAIN="${CHECKLIST_DOMAIN:+$CHECKLIST_DOMAIN,}${1#--checklist-domain=}"; shift;;
    --list-target-domains) LIST_DOMAINS=1; shift;;
    --list-target-nodes) LIST_NODES=1; shift;;
    --depgraph) DEPGRAPH=1; shift;;
    *)  if [ -z "$TARGET" ]; then TARGET="$1"; elif [ -z "$PROMPT_FILE" ]; then PROMPT_FILE="$1"; fi; shift;;
  esac
done

TARGET="${TARGET:-diff}"
# data 目标是独立垂直切面（契约加载→LLM 判定→block 落 issue），委托深模块 harness-data-judge.sh；
# 本脚本只做纯调度，data 不进下面的 node/runner/prompt/verdict 主链路。
if [ "$TARGET" = data ]; then
  exec "$ROOT/ci/bin/harness-data-judge.sh" "$PROMPT_FILE"
fi
# data-causal 是另一条独立垂直切面（跨业务共享数据的离线因果校验，ADR-0015）：委托深模块
# harness-data-causal-judge.sh（读 baseline 代码 + 线上数据 + 日志，重建触发链）。同上，不进主链路。
if [ "$TARGET" = data-causal ]; then
  exec "$ROOT/ci/bin/harness-data-causal-judge.sh" "$PROMPT_FILE"
fi
OCR_OUT="$ROOT/.harness/reports/ocr-${TARGET}.json"

# ── 目标登记表（**加一个评审目标 = 这里加一行**）──────────────────────────────────
# 列：目标|节点|runner 覆写|描述|默认域|指标 prompt 形态|ocr 子命令
#
# 此前「评审目标」这个概念散在 **7 处 case**：`node_for` / 三段 runner 覆写（tsd·report / arch / doc）/
# `target_desc` / `judge_metric_prompt` / `target_domains` / `--list-target-domains` 的硬编码枚举 /
# `run_headless` 的 ocr case。加一个目标要改 7 处，其中两处还各自维护「有哪些目标」——
# 与另一处是两份事实。
#
# 更值钱的是**已经漂过一次**：`skills/harness-review/SKILL.md` 手抄的那份路由表写成「arch → ocr」，
# 与代码相反，后来由人发现并改正。按本套件自己的标准，**手抄的视图是一句没有执行点的声明**。
# 现在表是唯一真源，skill 只需指向 `--list-target-domains`。
TARGET_TABLE="diff|review||git diff (staged/range)|||review
tsd|review|claude|TSD 全文 + content_sha（body 哈希，经 harness-tsd-sync-check.sh tsd-sha 取值）|requirements contract data|tsd|
report|review|claude|测试/评审报告|contract data||
arch|review|claude|当前代码结构 vs .harness/contracts/arch.md 架构声明|||scan
doc|review|claude|本次改动的 Markdown（3W2H 支撑 / 清晰 / 有证据）|||
audit|contract||声明≠落盘对账|contract||
quality|quality||质量治理闭环的元验证（门禁/checklist/运行时契约是否真实有效）|contract|quality|"

targets() { printf '%s\n' "$TARGET_TABLE" | awk -F'|' 'NF>1 {print $1}'; }
target_field() {  # <target> <列号>；目标不存在 → 空
  printf '%s\n' "$TARGET_TABLE" | awk -F'|' -v t="$1" -v n="$2" '$1 == t {print $n}'
}

# 三个独立判断节点，各自绑定 runner（非多选一）：review→审查 / contract→契约检查 / quality→质量验证
node="$(target_field "$TARGET" 2)"
[ -n "$node" ] || { echo "[judge] 未知目标: $TARGET（已知：$(targets | tr '\n' ' ')）"; exit 2; }
runner="$(h_node "$node")"
[ -n "$runner" ] || runner="$(h_get runner)"   # 兼容旧单值 judge.runner
# runner 覆写：该目标的评审面 ocr 覆盖不到，须走 prompt 型 runner。**为什么每个目标要覆写**记在表里，
# 代码只读表 —— 三个覆写各自的原由（ocr 不消费 prompt / 读不了 arch.md / 过滤全部 .md）见下方注释。
override="$(target_field "$TARGET" 3)"
if [ -n "$override" ]; then
  runner="$override"
  # tsd/report 是文档/语义评审，常需 PROMPT_FILE 提供内容；未给就提示（不阻断）
  if [ "$TARGET" = tsd ] || [ "$TARGET" = report ]; then
    [ -z "$PROMPT_FILE" ] && echo "[judge] 提示：$TARGET 是文档/语义评审，请用第 2 参数传 PROMPT_FILE 提供内容"
  fi
fi
# 三段覆写的原由（表里只记「覆写成什么」，为什么覆写在这里）：
#   tsd/report —— 文档/语义目标，ocr 只审代码，须 prompt 型 runner；
#   arch —— 漂移是判断类，必须读 `.harness/contracts/arch.md` 声明，而 ocr scan 不消费 $prompt（读不了它）；
#           `--depgraph` 只在 prompt 里追加依赖图导航（见下方注入，非必须）。
#   doc —— ocr 按 `unsupported_ext` **过滤掉全部 `.md`**，文档面它一条也看不到。
provider="$(h_get provider)"

target_desc="$(target_field "$TARGET" 4)"

# 质量验证节点的默认判定指令：元治理——验证「质量信号」本身是否真实有效（不评审具体代码/业务）
# 文档评审的判据（owner 定）：**文档以 3W2H 为支撑、清晰、有证据**。
# 3W2H 五维取自 REQ-001（见 checklists/shared/requirements.md），此处落在文档上。
doc_prompt() {
  cat <<'EOF'
你按 skill harness-review 的纪律评审**文档改动**：只读、单轮，对象是本次改动里的 Markdown。
ocr 按 unsupported_ext 过滤全部 .md —— 文档面它覆盖不到，本入口就是补那一半。

判据三条：

1) **3W2H 为支撑**（取自 REQ-001 五维，落在文档上）：
   - What   这份文档要让读者获得或改变什么？
   - Why    不做会怎样 / 解决谁的问题。无 Why 的文档视为不可验证。
   - Who    写给谁（新人 / 维护者 / 决策者）。读者不明 → 内容取舍无依据。
   - How    读者照做能否落地：步骤 / 命令 / 指针可核验。
   - How much 边界与验收：适用与不适用、什么情况下失效。
   五维缺一，**指出缺哪维、缺什么内容**；不给泛化建议（「建议补充更多细节」不算发现）。

2) **清晰**：一句话能说清主旨；无自造黑话或未定义缩写；段落各司其职（规则 / 适用 / 证据 / 示例
   不混写）；同一概念全文一个词，不换着叫。

3) **有证据**：关键断言有**可复现锚** —— 规范（WCAG / RFC）、测试、规则 id、ADR 指针、代码指针
   （`文件:行`）。**不接受**事故叙述（「某项目曾因此出过问题」）与口号式断言（「最佳实践」「众所周知」）。
   锚与断言不匹配（引了规范但说的不是规范要求的那件事）同样要指出。

只提会改变读者行为或判断的问题；不挑排版、标点与文风。每条附 `文件:行号`。
EOF
}

quality_prompt() {
  cat <<'EOF'
你按 skill harness-review 的纪律做「质量验证」：只读、单轮，验证本仓库质量治理闭环的可信度，不评审具体代码/业务。
逐项核对并判定（每条给 文件:行号 或说明）：
1. 门禁真实性（假绿）：每条确定性门禁（静态/schema/坑库/对账）的基准文件是否有真实命中路径——能被违反、能失败，而非 exit 0 空过或 grep 不到任何东西。
2. checklist 有效性：沉淀的 checklist 项是否 observed（有真实证据）→ validated（拦过真实问题），而非泛化口号或 git 已表达的事实。
3. 运行时契约有效性：close 配置的定时校验脚本是否真实可执行（真抓日志/查数据），而非只有契约文档没有脚本。
4. 闭环完整性：build→verify→review→close 每步是否有可核验证据（测试输出/gate 退出码/judge 结论），无跳步、无「应该可以」。
5. **半改动（跨轮撞车）**：抽查本轮修复是否只改了「一半」—— 典型形态：改了实例没改模板/同款调用点、
   声明改了而读取者没跟、修了 A 处的缺陷而 B 处同款还在、产出落了盘却没有任何消费方。
   判据是**回看多轮**：把 round N 的修复与 round N+1 判出的新缺陷对照，看后者是不是前者的「配套那半」。
   `.harness/reports/*-review.md` 的 frontmatter 有 `round`，据此定位相邻两轮。
   这是**定性判据、不量化**（事后信号、难自动、易误报，ADR-0012 决策 5 明确如此）：只报你能指出
   具体「缺的那半」在哪的实例，并给两轮各自的 文件:行号；指不出就不要报。
6. **归属域正确性（记忆治理 R4）**：抽查 checklist/pitfall 项的 `domain` / `problem_domain` 是否与该项的
   规则正文与「证据：」行**相符** —— 证据指向 X 域却标成 Y 域 = 归属错误（blocking）；`problem_domain`
   或 `domain_knowledge` 缺失、或与规则内容不相干 = 缺失（important）。归属域错了，规则会在**错误的
   评审上下文**里被注入（或该注入时不被注入）—— 这正是 harness 最忌的上下文/流程污染，故要查。
三档结论：可合 / 有条件可合 / 建议先改再合；发现分级 blocking/important/nit；blocking 未解决不得给通过。
EOF
}

# arch 漂移的 prompt 型判定指令：LLM 对照架构声明 .harness/contracts/arch.md 发现 drift。
# --depgraph 时额外前置注入依赖图导航（见下方注入）；arch.md 是必须读的声明，图只是可选导航。
arch_prompt() {
  cat <<'EOF'
你按 skill harness-review 的纪律做「架构漂移检测」：只读、单轮，判断当前代码结构是否偏离其架构声明 .harness/contracts/arch.md。
逐项核对并判定（每条 finding 附 文件:行号 或模块路径，锚在活源码，不锚文档/快照）：
1. 依赖方向：代码里实际的依赖边是否违反 arch.md 声明的边界（谁能调谁、seam 在哪）；SCC 环是否成问题由你判。
2. 模块职责：出现的新模块/新依赖是否偏离 arch.md 的事实层/边界层/语义层/约束层声明。
3. 检测深度 = 声明深度（ADR-0006）：arch.md 声明到哪层，你就判到哪层；未声明的层不臆造。
arch.md 标注 greenfield（无代码、facts 待落地）时，只按已声明的 boundaries/semantics/constraints 判已出现代码的偏离，不判未落地的 facts。
外部依赖（不解析源码）不视为缺陷，除非 arch.md 明确声明了禁止。
**读 frontmatter 的 `human_reviewed`**：为 `false` 时，结论里必须标注「该声明尚未经 owner 确认」
—— 声明本身未经人复核时，据它判出的 drift 结论强度有限，读者要知道这一点。
三档结论：可合 / 有条件可合 / 建议先改再合；发现分级 blocking/important/nit；blocking 未解决不得给通过。
EOF
}

# 指标标记的判定指令（ADR-0012 决策 5）：judge 判定类四格的**唯一来源**。
# 只对能判的目标请求 —— 请求了才可能拿到；拿不到时该格显示「无来源」（可见，不塌成 0）。
# 措辞按四要素写（定义/坏信号/口径），否则 LLM 给的数没有意义：光一个比例分不出「哪维敷衍」，
# 故值一律配「正文里点名缺什么」或「分母」。
judge_metric_prompt() {
  # 分派键取自目标登记表（第 6 列）—— 不再自己 case 一遍目标名
  case "$(target_field "$1" 6)" in
    tsd) cat <<'EOF'

报告 frontmatter 必须带 `tsd_content_sha`（被评审 TSD 的 body 哈希），取值方式：跑
`ci/bin/harness-tsd-sync-check.sh tsd-sha <tsd-slug>`，**原样写入，不要自己算** ——
该值要与 TSD 的 `content_sha` 校验同源（同一个 `_body_sha`），自己算的定义不一致就没法比对，
「这份评审针对哪个规格版本」也就无从判定。写散文里的「版本冻结：SHA-256 …」不算数（没有覆盖范围定义）。

另外单独一行输出一条指标标记（格式 `JUDGE_METRIC: <key>=<value>`）：
- `JUDGE_METRIC: plan.w2h_completeness=<0-100>` —— REQ-001 五维（What 目标行为 / Why 价值 /
  Who 干系人 / How 契约变化 / How much 验收）中**落实质内容**的维度占比（0=五维全空过，100=五维俱全）。
  只写维度名不留内容 = 该维未覆盖。**缺哪维、缺什么，在结论正文里点名**。
EOF
      ;;
    quality) cat <<'EOF'

另外单独输出指标标记（每行一条，格式 `JUDGE_METRIC: <key>=<value>`）：
- `JUDGE_METRIC: verify.false_green=<整数>` —— 你查出的**假绿**门禁条数（断言空跑、路径未触达、
  退出码恒 0、grep 不到任何东西）。0 = 你逐条查过且没发现假绿。
- `JUDGE_METRIC: review.false_positive_rate=<n>/<m>` —— 你抽查的 blocking 发现中，被 verify 阶段
  **证伪**的条数 n / 抽查总数 m。**必须给分母**：0/1 与 0/50 的含义完全不同。无可查时报 `0/0`。
- `JUDGE_METRIC: close.routing_accuracy=<n>/<m>` —— 两段式分流（确定性 vs 语义）抽查中判对的 n /
  总数 m。**必须给分母**，同上。无可查时报 `0/0`。
EOF
      ;;
    *) : ;;
  esac
}

# ── 目标 → 默认 checklist 域（消费缝的**流程保证**）──────────────────────────────
# 此前 `--checklist-domain` 只有人工调用才传，**没有任何流程自动带** —— 于是「shared judge 项
# 从未被消费」这条检测测的其实是「有没有人记得传」，而不是「规则有没有用」。本表把它变成默认行为。
#
# 只列**真实存在且为 judge 类**的域；域不存在时 loader 会退 2 并说明，不静默。
# 刻意**不含** `log` 域：`checklists/shared/log.md` 的 LOG-001/002 是 `check_mode: deterministic`
# （Semgrep 规则，走确定性门禁），loader 只收 judge 项 —— 列它只会每次都打一行「无适用 judge 项」的噪音。
# **代码评审关切**的域（无障碍这类）也不该列：代码评审走 ocr，**ocr 不消费 prompt**，
# 注入对它结构上无效（见下方 ocr 分支与 skill 的文档化限制）。列它等于假装覆盖了 ——
# 内置的 `a11y` 域就因此退役（ADR-0005 退役记录）。
target_domains() {  # 默认域取自目标登记表（第 5 列）
  target_field "$1" 5
}

# 查询模式：打印「目标 → 默认域」映射（`<target>\t<domain> <domain>`，一行一个目标），退出 0。
# 给**执行点可达性对账**用（closed-loop-audit）：它要判「某个共享域有没有任何命名路径请求到」，
# 而命名路径之一就是本表。做成查询模式而不是让调用方 sed 抽函数文本 —— 抽文本会随函数改名/换行
# 静默失配，而失配的表现是「查不到任何默认域」= 把所有域都误报成不可达。
# 位置必须在 `target_domains()` 定义**之后**：shell 函数要先定义再调用。
if [ "$LIST_DOMAINS" -eq 1 ]; then
  # 目标枚举**从表派生**（此前这里硬编码 `tsd report audit quality`，与 target_domains 的 case
  # 是两份事实）。只列有默认域的目标 —— 没有默认域的（diff/arch/doc）本就不需要 checklist 注入。
  for _t in $(targets); do
    _d="$(target_domains "$_t")"
    [ -n "$_d" ] && printf '%s\t%s\n' "$_t" "$_d"
  done
  exit 0
fi

# 查询模式：打印「目标 → 判定节点」映射（`<target>\t<node>`，一行一个目标），退出 0。
# 给**「发指标⇒有报告」对账**用（closed-loop-audit 的 review-landing 检查）：MetricEvent 的 `source`
# 记 `judge-review.sh:<target>`，评审报告 frontmatter 记 `node` —— 两处要按本表映射才能对上
# （如 audit 目标 → contract 节点）。同 --list-target-domains：做成查询模式，不 sed 抽函数文本。
if [ "$LIST_NODES" -eq 1 ]; then
  for _t in $(targets); do
    _n="$(target_field "$_t" 2)"
    [ -n "$_n" ] && printf '%s\t%s\n' "$_t" "$_n"
  done
  exit 0
fi

prompt="你按 skill harness-review 评审目标【$TARGET】($target_desc)。只读、单轮，返回三档结论(可合/有条件可合/建议先改再合)与分级发现(blocking/important/nit)。blocking 未解决不得给通过。"
[ "$TARGET" = "quality" ] && prompt="$(quality_prompt)"
[ "$TARGET" = "arch" ] && prompt="$(arch_prompt)"
[ "$TARGET" = "doc" ] && prompt="$(doc_prompt)"
if [ -n "$PROMPT_FILE" ] && [ -f "$PROMPT_FILE" ]; then
  prompt="$(cat "$PROMPT_FILE")"
fi
# 消费缝：把适用 judge checklist 上下文前置注入。仅 prompt 型 runner 生效
# （ocr 的 diff 走 ocr CLI 不消费 $prompt，此注入对其无效，见 harness-review skill 的文档化限制）。
# 域集合 = **目标默认域 ∪ 显式传入的域**（并集去重）：默认保证流程会注入，显式传入用于追加/覆盖场景。
CK_LS="$ROOT/ci/bin/harness-checklist-ls.sh"
CK_DOMAINS="$(target_domains "$TARGET")"
if [ -n "$CHECKLIST_DOMAIN" ]; then
  CK_DOMAINS="$(printf '%s %s' "$CK_DOMAINS" "$(printf '%s' "$CHECKLIST_DOMAIN" | tr ',' ' ')")"
fi
if [ -n "${CK_DOMAINS// /}" ] && [ -x "$CK_LS" ]; then
  CK_CTX=""
  _sep=$'\n\n'
  for _d in $CK_DOMAINS; do
    # 每个域单独调 loader（它是 per-domain 的），逐个累加。域不存在 / 无适用项时 loader 退 2 或
    # 打一行 stderr 说明 —— 这里 `|| true` 不吞错：空输出只是「该域没项」，不影响其它域。
    _out="$(bash "$CK_LS" "$_d" 2>/dev/null || true)"
    [ -n "$_out" ] && CK_CTX="${CK_CTX}${CK_CTX:+$_sep}${_out}"
  done
  if [ -n "$CK_CTX" ]; then
    prompt="以下为适用于本目标域的 judge checklist 上下文，逐条判定，命中即 blocking 并注明命中的 checklist id："$'\n\n'"${CK_CTX}"$'\n\n'"${prompt}"
  fi
fi
# arch.md 声明注入（ADR-0006）：arch 漂移判断必须对照架构声明。把 arch.md 全文注入 prompt（不只给路径，
# 避免 LLM 漏读/读不全）。arch.md 缺失 = 无架构声明，直接退出 2（不静默退化成纯代码扫描，避免名不副实）。
if [ "$TARGET" = arch ]; then
  ARCH_MD="$ROOT/.harness/contracts/arch.md"
  [ -f "$ARCH_MD" ] || { echo "[judge] 缺少 $ARCH_MD（架构声明），无法判定架构漂移；请先跑 harness-init 生成 arch.md"; exit 2; }
  prompt="以下为架构契约声明（.harness/contracts/arch.md 全文，逐条对照判定 drift）："$'\n\n'"$(cat "$ARCH_MD")"$'\n\n'"${prompt}"
fi
# 文档内容注入：doc 的评审对象是「本次改动的 .md」，须把 diff 喂进去（否则只有判据没有对象）。
# DOC_RANGE 可指定范围（如 `DOC_RANGE=a203217..HEAD`）；默认 HEAD = 工作区+暂存相对 HEAD 的全部改动。
# 非 git 仓库 / 无 .md 改动 → 显式说明，不静默跑一份无对象的评审（那会产出「看起来通过」的假绿）。
if [ "$TARGET" = doc ]; then
  # 范围：**默认逐级回退**。只取 HEAD 会在最常见的流程（改动已提交 / CI checkout 合并提交）上得到
  # 空 diff，doc 就永远退 2 —— 等于在最需要它的时候不工作（ocr round-3 #1）。回退顺序同 code-review
  # 的 low 变体（`git diff @{upstream}...HEAD` 兜底）。
  if [ -n "${DOC_RANGE:-}" ]; then
    _ranges=("$DOC_RANGE")
  else
    _ranges=("HEAD")
    (cd "$ROOT" && git rev-parse --verify --quiet '@{upstream}' >/dev/null 2>&1) \
      && _ranges+=("@{upstream}...HEAD")
    for _b in main master; do
      (cd "$ROOT" && git rev-parse --verify --quiet "$_b" >/dev/null 2>&1) && _ranges+=("$_b...HEAD")
    done
  fi
  DOC_DIFF=""; _used=""
  for _r in "${_ranges[@]}"; do
    # 范围非法与「无改动」是两回事：`2>/dev/null || true` 会把前者也说成后者，误导操作者
    # （ocr round-3 #2）。git diff 对非法范围非零退且 stderr 有话说。
    # stderr 走临时文件，不折进 _d：git 对**合法**范围也会往 stderr 写 warning，折进来会让
    # _d 不再是 diff 内容（ocr round-4 #7）。core.quotepath=false 同 ls-files —— 否则非 ASCII
    # 路径在 diff 里被引号转义（ocr round-4 #9）。
    _errf="$(mktemp)"
    if ! _d="$(cd "$ROOT" && git -c core.quotepath=false diff "$_r" -- '*.md' 2>"$_errf")"; then
      echo "[judge] doc：范围 '$_r' 不是有效范围（$(head -1 "$_errf")）—— 与「无 .md 改动」是两回事" >&2
      rm -f "$_errf"; exit 2
    fi
    rm -f "$_errf"
    if [ -n "$_d" ]; then DOC_DIFF="$_d"; _used="$_r"; break; fi
  done
  # 未跟踪文件**只在范围=工作区时**才属于「本次改动」；给了历史范围（A..B）还把当前所有未跟踪 .md
  # 算进来是错的（ocr round-3 #3）。core.quotepath=false：默认会把非 ASCII 路径引号转义，
  # 中文文件名（本生态常见）会让下面的 cat 找不到文件（ocr round-3 #8）。
  # 按**实际选中**的范围判，不按请求的 DOC_RANGE：未指定时上面的回退可能落到历史范围，
  # 那就不能把当前全仓未跟踪 .md 算进「本次改动」（ocr round-4 #6）。
  if [ -z "${_used:-}" ] || [ "${_used}" = "HEAD" ]; then
    _untracked="$(cd "$ROOT" && git -c core.quotepath=false ls-files --others --exclude-standard -- '*.md' 2>/dev/null || true)"
    while IFS= read -r _f; do
      [ -n "$_f" ] || continue
      DOC_DIFF="${DOC_DIFF}"$'\n\n'"### 新文件（未跟踪）${_f}"$'\n\n'"$(cat "$ROOT/$_f")"
      _used="${_used:-工作区}"
    done <<< "$_untracked"
  fi
  [ -n "$DOC_DIFF" ] && echo "[judge] doc：范围 = ${_used}" >&2
  if [ -n "$DOC_DIFF" ]; then
    # ① 截断上界 —— 同 harness-issue-lib.sh 的「证据截断防撑爆」（那里 50KB）。无界注入会让一个大 .md
    #    把 prompt 撑爆；且截断必须**显式标注**，否则被截掉的部分看起来像「评过了」。
    _max="${DOC_MAX_BYTES:-51200}"
    if [ "${#DOC_DIFF}" -gt "$_max" ]; then
      _orig="${#DOC_DIFF}"
      DOC_DIFF="${DOC_DIFF:0:$_max}"$'\n\n'"…（已截断：原文 ${_orig} 字符，上限 ${_max}；超出部分**未评**，需人工看）"
    fi
    # ② 围栏长度取「内容里最长连续反引号 + 1」—— 文档正文本来就含 ``` 代码块，固定三反引号会被提前
    #    闭合，后面的内容就跑到围栏外成了 prompt 结构注入（同 issue-lib 的「``` 结构注入」防护）。
    _maxbt="$(printf '%s' "$DOC_DIFF" | awk '{s=$0; while (match(s, /`+/)) { if (RLENGTH>m) m=RLENGTH; s=substr(s,RSTART+RLENGTH) } } END { print m+0 }')"
    _flen=$(( _maxbt + 1 )); [ "$_flen" -ge 3 ] || _flen=3    # 下限 3：纯文本时退化成 1 个反引号写法太怪
    _fo="$(printf '%*s' "$_flen" '' | tr ' ' '`')"
    _fc="$_fo"
    prompt="以下为本次改动的 Markdown diff（评审对象，逐份评）："$'\n\n'"${_fo}diff"$'\n'"${DOC_DIFF}"$'\n'"${_fc}"$'\n\n'"${prompt}"
  else
    echo "[judge] doc：试过的范围（${_ranges[*]}）内都没有 .md 改动 —— 无评审对象，退出 2（不产出空结论）" >&2
    exit 2
  fi
fi
# 大仓依赖图导航注入（ADR-0006）：--depgraph 时把模块依赖图前置注入。仅 prompt 型 runner 生效
# （ocr 的 diff 走 ocr CLI 不消费 $prompt，此注入对其无效）。tree-sitter 未装/图为空 → 静默跳过（不假绿）。
if [ -n "$DEPGRAPH" ]; then
  DG_SH="$ROOT/ci/bin/harness-depgraph.sh"
  if [ -x "$DG_SH" ]; then
    DG_CTX="$(bash "$DG_SH" --fmt mermaid 2>/dev/null || true)"
    if [ -n "$DG_CTX" ]; then
      prompt="以下为本仓库模块依赖图（导航，非判定；依赖方向/环是否成问题由你判）："$'\n\n'"${DG_CTX}"$'\n\n'"${prompt}"
    fi
  fi
fi
# 非 ocr runner 的 blocking 判定依赖 JUDGE_VERDICT 标记；无论 prompt 来源都强制追加，避免自定义 prompt 丢失该指令导致假绿
prompt="${prompt}$(judge_metric_prompt "$TARGET")"
prompt="${prompt}"$'\n\n'"最后一行只输出 JUDGE_VERDICT: block 或 JUDGE_VERDICT: pass。"

echo "[judge] node=$node runner=${runner:-?} provider=${provider:-<default>} target=$TARGET"

run_headless() {
  case "$runner" in
    ocr)
      # open-code-review (Alibaba)：本地 CLI `ocr`，确定性工程 × agent 混合评审。
      # 只审代码（.md 等文档被 unsupported_ext 过滤）；tsd/report/audit 是文档/语义评审，退给 prompt agent。
      if ! command -v ocr >/dev/null 2>&1; then
        echo "[judge] 未安装 ocr：npm i -g @alibaba-group/open-code-review"
        return 2
      fi
      rm -f "$OCR_OUT"                       # 防止上一轮残留结果被误读
      mkdir -p "$(dirname "$OCR_OUT")"
      pflag=(); [ -n "$provider" ] && pflag=(--provider "$provider")
      # ocr 子命令取自目标登记表（第 7 列）—— 哪个目标走 review、哪个走 scan 只在一处
      case "$(target_field "$TARGET" 7)" in
        review) ocr review "${pflag[@]}" --format json --audience agent --output "$OCR_OUT";;
        scan)   ocr scan   "${pflag[@]}" --format json --output "$OCR_OUT";;
        *)      echo "[judge] 审查节点(ocr)只审代码，不支持 $TARGET（.md/语义目标）；改用契约检查/质量验证节点(claude/traecli)或 --prompt-file"; return 2;;
      esac
      cat "$OCR_OUT"
      ;;
    *)
      # traecli/opencode/claude/api 是 prompt 型 runner，走共享深模块 harness-llm.sh
      # （回退链、未知 runner 判定、api 未实现均在其内，本脚本不再各自 case）。
      # 第 2 参 = judge.model（identity.yaml judge 段）：显式指定评审模型，覆盖
      # ~/.claude/settings.json 的默认模型 —— 后者可能是某个代理上不存在的名字，
      # 裸 `claude -p` 会因此失败（模型错误）；judge 专用模型避免踩这个坑。
      if [ -x "$LLM_SH" ]; then
        printf '%s' "$prompt" | "$LLM_SH" "$runner" "$(h_get model)"
      else
        echo "[judge] 缺少 $LLM_SH（无头 LLM 深模块）" >&2
        return 2
      fi
      ;;
  esac
}

set +e
out="$(run_headless 2>&1)"
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
  echo "$out"
  echo "[judge] runner 执行失败，需人工处理"
  exit 2
fi

# ── JUDGE_METRIC 标记 → MetricEvent（ADR-0012 决策 5）────────────────────────────
# judge 判定类四格（w2h_completeness / false_green / false_positive_rate / routing_accuracy）的
# **唯一来源**：判定结论就在 $out 里，不在这里解析出来就没有落点（此前这四格是「无来源」）。
#
# **口径=观测**：本段任何失败（标记缺失、格式非法、key 不在注册表）都**不改本脚本的退出码**。
# 指标一旦升格成门禁即招 Goodhart（按指标优化而非按问题优化）—— 故这里只记不挡。
# 这与 JUDGE_VERDICT 相反：那个缺失要退 2（防假绿，它是门禁）；这个缺失只是「该格无来源」。
#
# 已知 key 取自 metrics.py 的注册表（单一真源），**不在此抄一份** —— 抄一份就会漂，
# 而漂的表现是「judge 写了但没人认」，且静默。值只收整数或 `n/m`（比例类必须带分母，
# 否则单看比例无从判断可信度）：写进去的必须可信，宁缺勿滥。
emit_judge_metrics() {
  local known key val stage metric py
  # 本函数会被 tests/metrics 用 sed 抽出、在**没有 env 库**的 shell 里单独跑：
  # 故自带回退（HARNESS_PYTHON 未设 → python3，由测试的 PATH 垫片解析到真解释器）。
  py="${HARNESS_PYTHON:-python3}"
  known="$("$py" "$ROOT/ci/bin/metrics.py" --keys 2>/dev/null || true)"
  if [ -z "$known" ]; then
    echo "[judge][warn] 取不到指标注册表（metrics.py --keys 失败）——本次不记指标" >&2
    return 0
  fi
  while IFS= read -r kv; do
    [ -n "$kv" ] || continue
    key="${kv%%=*}"; val="${kv#*=}"
    if ! printf '%s\n' "$known" | grep -qxF "$key"; then
      echo "[judge][warn] 未知指标 key：$key（不在 metrics.py 注册表内），不记" >&2
      continue
    fi
    if ! printf '%s' "$val" | grep -qE '^[0-9]+(/[0-9]+)?$'; then
      echo "[judge][warn] 指标值格式非法：$key=$val（须为整数或 n/m），不记" >&2
      continue
    fi
    stage="${key%%.*}"; metric="${key#*.}"
    # `--run`（ADR-0016 决策 2）：harness-run 注入 HARNESS_RUNCARD 时把指标归到该 run；取不到不带。
    "$ROOT/ci/bin/harness-metric.sh" "$stage" "$metric" "$val" --source "judge-review.sh:$TARGET" \
      --run "${HARNESS_RUNCARD:-}" \
      >/dev/null 2>&1 || true
    echo "[judge] 指标 $key=$val"
  done < <(printf '%s\n' "$out" \
    | sed -nE 's/.*JUDGE_METRIC:[[:space:]]*([A-Za-z0-9_.]+)=([^[:space:]]+).*/\1=\2/p')
}
emit_judge_metrics

# 判定 blocking
if [ "$runner" = "ocr" ]; then
  [ -s "$OCR_OUT" ] || { echo "$out"; echo "[judge] OCR 未产出结果，需人工"; exit 2; }
  verdict="$("$HARNESS_PYTHON" - "$OCR_OUT" <<'PY'
import json, sys
try:
    # 显式 utf-8：下面 except Exception 会把解码失败一并吞成 need-human——GBK locale 下
    # 这不是「需人工」而是「读不了」，静默降级比崩溃更糟。
    d = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    print("need-human"); sys.exit(0)
st = d.get("status", "")
# `complete` 是 ocr 的成功态（实测 status="complete"）；早前白名单漏了它，成功评审被误判
# need-human → review 节点 exit 2。补齐成功态白名单 —— 即 work-unit `harness-ocr-status-mismatch`
# 的收口（非本 task 引入的既有 infra 缺口，本 task review 节点依赖它才可用）。
if st not in ("success", "complete", "completed_with_warnings", "completed_with_errors", "skipped"):
    print("need-human"); sys.exit(0)
if st == "completed_with_errors":
    print("need-human"); sys.exit(0)
if st == "skipped":
    print("pass"); sys.exit(0)
if any(c.get("severity", "").lower() in ("critical", "high") for c in d.get("comments", [])):
    print("block")
else:
    print("pass")
PY
)"
  case "$verdict" in
    block)      echo "$out"; echo "[judge] 发现 blocking（critical/high）"; exit 1;;
    need-human) echo "$out"; echo "[judge] OCR 覆盖不完整或结果解析失败，需人工"; exit 2;;
  esac
  echo "$out"
  echo "[judge] 无 blocking"
  exit 0
fi

# 非 ocr runner：按结构化判定标记。分类走 harness-judge-common.sh 的 judge_verdict（单一真源，与
# data/data-causal judge 同源）；缺 JUDGE_VERDICT 标记 = 需人工（覆盖不完整/runner 异常），防假绿。
case "$(judge_verdict "$out")" in
  block)      echo "$out"; echo "[judge] 发现 blocking"; exit 1;;
  need-human) echo "$out"; echo "[judge] 未输出 JUDGE_VERDICT 标记，需人工"; exit 2;;
  pass)       echo "$out"; echo "[judge] 无 blocking"; exit 0;;
esac
