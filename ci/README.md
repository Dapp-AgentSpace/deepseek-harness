# Harness 执行层（CI）

确定性权威门禁与 LLM-as-judge 都在这里，不在 agent、不在宿主 hooks。

## 文件

| 文件 | 作用 | 有 AI 吗 |
|---|---|---|
| `LICENSE` | 套件根 `LICENSE` 的逐字副本（MIT）。`upgrade.sh` 把整个 `ci/` 复制进每个项目，副本须自带许可声明；改根 LICENSE 时同步此文件 | 无 |
| `bin/harness-scaffold.sh` | 接入时按栈探测生成确定性基准文件（schema-check/gates）与架构契约声明（contracts/arch.md）；`--stack <label>` 供 greenfield 冷启动显式指定目标栈 | 无 |
| `bin/harness-gate.sh` | 串跑确定性门禁（static/pitfall/schema/dep/compat/audit） | 无 |
| `bin/harness-preflight.sh` | 环境预检（确定性）：读 `identity.yaml` 的 `toolchain.*` 解析工具真实路径，写 `.harness/toolchain.env`（本机缓存，不入库）；缺 required 即退 1（流程不得开始） | 无 |
| `bin/harness-env.sh` | 环境解析库（`source` 用）：读 `.harness/toolchain.env` 缓存，缺失/失效回退即时探测；导出 `HARNESS_PYTHON` / `PYTHONUTF8` / `py_ok` | 无 |
| `bin/harness-tier.sh` | 风险嗅探（确定性）：从 diff 嗅探 full/light，供 harness-run 决定开哪些 judge 节点（on_ramp） | 无 |
| `rules/pitfalls.yaml` | 坑库共享结构规则（Semgrep，rule.id 对齐 checklist id；project-local 层见 `.harness/pitfalls.yaml`） | 无 |
| `dep-policy.yaml` | 依赖安全判定基线单源（漏洞阻断严重级 + 许可证禁止清单 + 例外；project-local 层见 `.harness/dep-policy.yaml`） | 无 |
| `bin/depcheck.py` | 依赖安全判定深模块（解析 trivy JSON + 策略 → blocking findings 与报告；纯标准库，不依赖 PyYAML） | 无 |
| `compat-policy.yaml` | 兼容性判定基线单源（最低支持版本 floors + 例外；project-local 层见 `.harness/compat-policy.yaml`） | 无 |
| `bin/compatcheck.py` | 兼容性判定深模块（读清单声明的「最低支持版本」vs 基线 → blocking findings 与报告；纯标准库，不依赖 PyYAML） | 无 |
| `gates.yaml` | 门禁注册表（身份单源：key/名称/类型/开关/binding/on_ramp） | 无 |
| `constraint-model.md` | 约束语义模型单源（约束类型 category + canonical 模板 + 约束↔gate↔pitfalls↔checklist 派生关系） | 无 |
| `work-unit-schema.md` | work-unit 格式单源（`.harness/work/` 的 frontmatter 字段 + CodeStable 适配映射，ADR-0010） | 无 |
| `runtime-contract-schema.md` | 运行时契约**数据侧**配置单源（`env.data.*` / `runtime-config.yaml` / `runtime-subjects.yaml` 字段 + 变化模型管道表 + 观测缺口） | 无 |
| `tsd-ls-json-schema.md` | TSD 花名册 `--json` 输出格式单源（字段/类型/四态取值 + 「`null` ≠ `0`」纪律；`harness-tsd-ls` 消费方的单一真源） | 无 |
| `agents-routing.md` | 项目根 `AGENTS.md` 的 **harness 受管路由块**单源（研发诉求先经 harness 入口、不得直接走 cs-feat 等跳过；由 `agents_md.py ensure` 播种、`closed-loop-audit` 对账） | 无 |
| `bin/closed-loop-audit.sh` | 对账确定性部分（声明≠落盘的存在性核对） | 无 |
| `bin/audit_checks.py` | 对账子检查深模块（`review-validity` / `metric-sources` / `observation` / `agents-md` / `gate-identity` / `selftest-wiring` / `domain-attribution` / `domain-backfill` …）；消息须可被 `audit_summary` 分类 | 无 |
| `bin/audit_summary.py` | 把 `closed-loop-audit.sh` 的输出行分类落 `.harness/reports/audit-last.json`（`declaration_not_landed` 的来源；按输出行分类，报告说了什么指标就记什么） | 无 |
| `bin/harness-metric.sh` | MetricEvent append-only 写者（`--source` 来源必填 / `--run` 可选 run 归属；一事件一行 JSONL） | 无 |
| `bin/metrics.py` | 指标模型**单一真源**（16 格四要素 + 四态纪律 ok/empty/unavailable/error；`--json`/`--keys`/`--run`） | 无 |
| `bin/harness-measure.sh` | 度量报表（HTML + 文本；`--section` 出 markdown 观测节供 close 内嵌 / `--run` per-run 视图 / 每次 append `measure-history.jsonl` 并渲染趋势） | 无 |
| `bin/harness-gates-ls.sh` | 读门禁注册表输出 TSV（gate/audit 共用） | 无 |
| `bin/harness-runtime-check.sh` | 运行回路执行器（薄包装 → harness-runtime-run.py；读 runtime-config.yaml 逐域跑，不再生成 per-domain _check.sh） | 无 |
| `bin/harness-runtime-run.py` | 运行回路通用执行器深模块（读 env.yaml + runtime-config.yaml + runtime-subjects.yaml，逐域组 env 跑 抓取→预检→判定） | 无 |
| `bin/harness-data-check.sh` | 数据不变量抓取深模块（curl 落报告；判定走 judge data；METHOD/BODY 支持 POST JSON） | 无 |
| `bin/harness-baseline.sh` | baseline 锚的确认/校验/只读检索（ADR-0015 决策 3/4）：客户显式确认 baseline 引用 → pin 不可变 SHA 落盘留痕、漂移检测、`git show` 只读检索 baseline 代码 | 无 |
| `bin/harness-data-redact.py` | 「脱敏但保完整性」深模块（ADR-0015 决策 6）：按策略逐字段脱敏（tokenize/drop/keep）+ 保完整性守卫（脱敏会打断不变量即拒绝产出）；纯标准库 | 无 |
| `bin/harness-data-causal-judge.sh` | 跨业务共享数据的离线因果校验判定深模块（ADR-0015）：读 baseline 代码 + 线上数据（脱敏）+ 日志，重建触发链判「其他业务的改动是否符合预期」 | 有 |
| `bin/harness-keep-scan.sh` | 定期扫 cs-keep lesson → 无头 LLM 提取 → checklist/pitfalls 提案 | 有 |
| `bin/harness-keep-land.sh` | 把 owner 已 approved 的提案落盘（checklist / pitfalls 两层） | 无 |
| `bin/checklist.py` | checklist/pitfall 解析深模块（单一归属：分段+字段提取+pitfall id；candidates/ls/gap/keep-land/audit 共用；`backfill` 子命令列 R3 待回填项） | 无 |
| `bin/depgraph.py` | 大仓依赖图抽取深模块（tree-sitter 精确解析 import/use/require → 模块级依赖边；只出图与结构事实，不下结论；按文件内容 SHA-256 增量缓存，文件未变不重解析，`--no-cache` 强制全量） | 无 |
| `bin/harness-depgraph.sh` | 大仓依赖图薄包装（栈探测 + 默认 module_root + 调 depgraph.py）；喂 judge 当导航（ADR-0006） | 无 |
| `bin/harness-checklist-candidates.sh` | 晋升缝（发现）：扫 `reuse: candidate` 候选清单 | 无 |
| `bin/harness-checklist-promote.sh` | 晋升缝（执行）：按 §2b 校验并**改写**后落入 suite 源；默认 dry-run，`--apply` 才写 | 无 |
| `bin/harness-runcard.sh` | RunCard **唯一生产者**（create/advance/round/premise/finish；ADR-0012）；各阶段 skill 只调它不手写卡 | 无 |
| `bin/runcard.py` | RunCard 解析与**确定性校验**深模块（字段/tsd 冻结/handoff_from 链/无孤儿/环；挂 closed-loop-audit） | 无 |
| `bin/harness-checklist-ls.sh` | 消费缝：loader 把 local+shared 两层适用 judge 项拼成评审上下文 | 无 |
| `bin/harness-tsd-ls.sh` | TSD 花名册派生视图入口（一次列出全部 TSD 状态卡 + 「看详情」深链 + 「引用开工」入口；只读、不落盘、不 spawn agent，ADR-0012 决策 4） | 无 |
| `bin/tsd_board.py` | TSD 花名册派生深模块（读 TSD frontmatter + RunCard phase + work-unit 未解阻塞；纯标准库） | 无 |
| `bin/handoff.py` | Handoff 派生视图聚合深模块（RunCard + work-unit + ReviewRecord + ADR → 一轮交接；不落盘，ADR-0012） | 无 |
| `bin/harness-epic-progress.sh` | TSD close 后「关联 epic 剩余 item」派生视图入口（`<tsd-slug>`；读 TSD `task:` → work-unit `epic:` → epic 子项契约 + 游标 current_item done 标记；四态输出，只读不落盘，ADR-0012 决策 4） | 无 |
| `bin/epic_progress.py` | 关联 epic 剩余 item 派生深模块（TSD `task:` → work-unit `epic:` → epic 永久文档 `## 子项契约` + 游标 `current_item`；完成态 = work-unit 终态 OR 游标 done 标记；纯标准库，不落盘不 spawn） | 无 |
| `bin/identity.py` | `.harness/identity.yaml` 的 Python 读取深模块（project.id 单一归属，镜像 shell 的 `harness-identity.sh` 的 `h_id`） | 无 |
| `bin/agents_md.py` | 项目根 `AGENTS.md` 受管路由块的播种/对账深模块（`ensure` 合并、`check` 对账；源 `agents-routing.md`；scaffold 与 audit 共用） | 无 |
| `bin/harness-checklist-issue.sh` | 反馈缝：shared 项过泛/假阳落 cs-issue + 非零退出通知 | 无 |
| `bin/harness-runtime-gap.sh` | 纵向爬梯：列 `runtime: data|log` 未落 rung 4 的 checklist 项 | 无 |
| `bin/judge-review.sh` | LLM-as-judge 无头调度（评审/对账语义/arch 漂移/数据契约/跨业务因果） | 有 |
| `bin/harness-hook-protect.sh` | 宿主层写时拦截（保护身份与契约文件） | 无 |
| `bin/harness-hook-post-check.sh` | 回合结束快速告警 | 无 |
| `workflows/quality-gates.yml` | GitHub Actions 确定性门禁 | 无 |
| `workflows/llm-judge.yml` | GitHub Actions LLM-as-judge（PR + 手动 arch 漂移） | 有 |

## 环境解析与预检（本机相关，不入库）

解释器与外部工具的探测**单源**在 `bin/harness-env.sh` + `bin/harness-preflight.sh`，不再散落在各脚本：

- **需求单源**（入库）：`.harness/identity.yaml` 的 `toolchain.{required,optional}` 声明本项目流程需要哪些工具。
- **解析缓存**（不入库，`.gitignore` 排除）：`.harness/toolchain.env`，由 `harness-preflight.sh` 生成，含工具绝对路径与 OS 指纹。
- **前置**：`harness` / `harness-run` / `harness-init` 在流程**之前**跑 `harness-preflight.sh`；缺 required 工具即退 1，流程不得开始。
- **复用**：各脚本 `source bin/harness-env.sh` 读缓存；缓存有效（OS 指纹匹配 + `[ -x ]`）时**不再实跑探测**，缺失/失效回退即时探测。
- **与 `attention.md` 分工**：attention 是项目通用高频事实（入库）；`toolchain.env` 是本机依赖路径（不入库）。见 ADR-0014。

## 门禁退出码契约

- `harness-gate.sh`：`0` 绿 / `1` 红 / `2` 黄(未配置门禁)。
- `closed-loop-audit.sh`：`0` 对账通过 / `1` 声明未落盘。
- `judge-review.sh`：`0` 无 blocking / `1` 有 blocking / `2` 需人工（缺 token、未装 ocr、覆盖不完整）。
  - 审查节点（`ocr`）的 blocking 映射：`severity ∈ {critical, high}` → 退出 1；`medium`/`low` → 不阻断；
    `status=completed_with_errors` → 退出 2（覆盖不完整）；`status=skipped` → 退出 0（无可评审文件）。

## judge 节点与 runner

`judge.nodes` 在 `.harness/identity.yaml`：三个独立判断节点，各自绑定 runner，可并行独立执行（非多选一）。

- `review`（审查节点）→ `ocr`：open-code-review（Alibaba）本地 CLI，确定性工程 × agent 混合评审。`ocr review` 审 diff、`ocr scan` 全量扫描；首次 `ocr config provider/model` 配 LLM，或用 `ocr delegate` 免 LLM 配置（闭环.txt 步骤 8 的默认评审执行器）。**只审代码**（`.md` 文档被 `unsupported_ext` 过滤）：`diff` 走 review 节点（ocr）；`arch`/`tsd`/`report` 语义评审需 prompt 型 runner（arch 读 `.harness/contracts/arch.md` 判漂移）。
- `contract`（契约检查节点）→ `claude`：`claude -p`，做声明≠落盘对账与契约语义判断。
- `quality`（质量验证节点）→ `traecli`：TraeCode CLI 2.0 `exec` 非交互模式，**旗舰版专属**（需 `TRAECLI_PERSONAL_ACCESS_TOKEN`；无 token 时自动回退 `claude`）。做元治理——验证门禁真实性（假绿）、checklist 有效性（observed→validated）、运行时契约可执行、闭环完整性；跑在 harness-run 收尾 / harness-close 毕业前。
- 回退/扩展：任一节点可改用 `opencode`（`opencode run`，无旗舰版依赖）或 `api`（直接 LLM API，扩展点）。

### 大仓依赖图（arch 导航，只读不下结论）

arch 深分析需快速检索大仓结构。`harness-depgraph.sh [--fmt mermaid|json|facts] [--collapse N] [--no-cache]` 用
tree-sitter 精确解析 import/use/require，出模块级依赖图（node=目录，edge=import 解析到目录）当导航
（ADR-0006：判断与导航分离，图是地图不是判定）。tree-sitter 为可选依赖（大仓才需要）：
`pip install -r ci/requirements-depgraph.txt`；未装时清晰报错退出 2，不降级出错误图。shell/unknown 无
import 语义，只出目录树。`--fmt facts` 列结构事实（SCC 环/叶子/枢纽），好/坏仍由 judge 判。
增量缓存按文件内容 SHA-256 落 `.harness/reports/depgraph-cache.json`（派生数据，删了下次自动全量）：
文件没变就不重跑 tree-sitter 解析，只重解析变更文件。键控用内容哈希而非 `git diff`——git diff 会漏
未跟踪文件/非 git 仓库/revert 到旧内容，漏判即出陈旧图。

栈与 module_root 默认由 `harness-stack.sh` **多栈自动推导**：无显式 `--stack`/`--module-root` 且
identity 未配置时，按仓库清单枚举所有模块（每个 pom.xml/build.gradle(.kts) 一个 Java 模块，每个
package.json 一个 JS/TS 模块，go.mod/Cargo.toml 单仓根），逐栈抽图合并成一张图，节点按模块
命名空间化（`<模块相对路径>::`，避免 frontend/components 与 h5/components 撞名）。聚合型清单
（目录下还有更深层同类型清单，如仓库根挂名的 package.json / monorepo 根）自动跳过，只留真正的源码
模块边界。polyglot 仓库（Java 后端 + Vue 前端）一次出齐，无需配置。
仅当自动推导不准时才在 `.harness/identity.yaml` 用 `judge.depgraph_stack` / `judge.depgraph_module_root`
覆盖（后者相对仓库根）；显式配置的 root 必须存在，配错会响亮报错退出 2，不静默出空图（空图会被 judge
当无导航跳过 = 假绿）。`.vue` SFC 只解析其 `<script>` 块（typescript grammar），相对导入剥文件扩展名
落到目录 node。JS/TS 别名（`jsconfig.json`/`tsconfig.json` 的 `compilerOptions.paths`，从 module_root
向上找 config 文件）按最长前缀解析到目录；别名 target 指向 module_root 外或配错（如 `../../` 悬空路径）
则归 external，不臆造。

**消费（闭环）**：`judge-review.sh arch` 恒转 prompt 型 runner `claude`，读 `.harness/contracts/arch.md`
全文判架构漂移（缺 arch.md 直接退出 2：无架构声明无法判定）；`--depgraph` 只在 prompt 里追加依赖图导航
（大仓可选）。依赖图只当导航、好/坏由 judge 判；外部依赖只标注不解析（无法读取外部代码属正常，不算缺陷）。

架构契约 `.harness/contracts/arch.md` 由 `harness-scaffold.sh` 按栈选模板生成（四带：facts / boundaries /
semantics / constraints），模板库见 `ci/contracts/arch/`。栈探测（`stack_detect`）含 `python`
（pyproject.toml/setup.py/requirements.txt，此前 Python 仓库会被判 `unknown`）；`stack_profile()`
从构建清单 grep 框架/ORM 信号（`framework=spring-boot orm=mybatis`、`framework=gin`、`framework=django`
等）进 facts 的「架构画像」行，比单标签更细，仍是确定性事实、只当导航不判好坏。

## 门禁注册表（身份单源）

门禁**身份**（key/名称/类型/退出码/执行器/开关）在 `gates.yaml` 单源定义；`harness-gate.sh`（跑）、
`identity.yaml`（`gates.*` 开关）、`harness-scaffold.sh`（接线）、`closed-loop-audit.sh`（对账）都从它读，
改名/加门禁只改 `gates.yaml`。执行器分两类：确定性（无 AI，CI 脚本，`harness-gate.sh` 内 `g_<key>` 函数）
与判断类（LLM-as-judge，`judge-review.sh`，runner 绑定见下「judge 节点与 runner」）。
**每阶段跑哪几条**由各阶段自己维护（见下），身份表本身不在此重复。

## 依赖安全门禁（dep）

`trivy fs` 扫漏洞 + 许可证，判定归 `bin/depcheck.py`，判据单源 `dep-policy.yaml`（两层：本文件 =
shared 基线随 upgrade 同步；`.harness/dep-policy.yaml` = 项目自有例外，语义层不覆盖，两层取并集、
只增不减）。**依赖的 CVE/许可证只在确定性门禁判，不进 agent**——LLM 无从知晓 CVE 库与包许可证的
真实状态（ADR-0001）。review 节点对新增库只判「引入是否合理」（来源可信度/维护活跃度/是否已有等价库）。

- **全量判定、不看 diff**：命中即红，不区分「新增/存量」。存量既成事实不靠静默豁免，靠 `ignore`
  逐条登记（**必须带 `reason`**，可选 `expires` 到期自动失效重新变红——防例外沉淀成永久豁免）。
  大仓首次接入有一次 triage 成本，`g_dep` 会把每条 blocking 的 `ignore` 骨架写进
  `.harness/reports/dep-last.md`，复制进 `.harness/dep-policy.yaml` 补理由即可。这是有意为之：
  把「已知但接受」变成留痕的决定，而不是无声的绿。
- **退出码**：无策略 / 本仓无依赖清单锁文件 / 未装 `trivy` = **2（黄，不假绿）**；
  trivy 自身跑失败（如漏洞库拉不下来）= **1（红，不吞错误**，同 `g_pitfall` 的 HOG-005 防护）；
  **`python3` 跑不起来 = 1（红）**——判据评估不了不等于「未配置」，记黄就成了「检查没跑也不算红」。
  `have python3` 只查 `command -v`，而 Windows 上 `python3` 常是 Microsoft Store 占位桩（命令在、
  任何调用非零退出），故 `g_dep` 用 `py_ok` 实跑一次解释器再往下走；有 blocking = 1。
  `gates.dep` 由 scaffold 的 `wire_dep` 按「策略在 + 有依赖清单 + 有 trivy」三样
  齐备才置 true。identity.yaml 里已有该行则**不覆盖**（owner 手改优先）——所以装好 trivy 后要把
  `gates.dep` 手动改成 `true` 并重跑，scaffold 不会替你开。缺该行时 scaffold 会自动补上（值按
  wire_dep 计算），保持「加门禁只改 ci/gates.yaml」成立。
- **禁止清单选型**：传染型 copyleft（GPL/AGPL）+ 源码可用但限制商用（SSPL/BUSL/Elastic/CC-NC）+
  Semgrep Registry 规则集。有意放行 MIT/Apache-2.0/BSD/ISC/MPL-2.0/LGPL（后者以独立 CLI 调用不传染）；
  项目若静态链接 LGPL 库须自行加禁止。清单与理由见 `dep-policy.yaml` 头部注释。
- **匹配规则（`license_match`）**：精确相等，或 reported = 清单项 + `-only` / `-or-later`（尾 `+` 等价）。
  **`-with-<exception>` 一律不匹配**——它是额外授予而非同族变体。踩过：早先用 `startswith(deny + "-")`
  一律前缀匹配，把 `GPL-2.0-with-classpath-exception`（`jakarta.annotation-api`、`jaxb-api` 等标准 Java
  依赖的许可，明确允许链接进闭源大作品）判成 GPL-2.0，真实 Java 项目上 460 条 findings 里凭空多出 2 条假红。
  假红的门禁必然被无视，比漏报更糟。要拦某个例外形态就把完整 id 另立一条（精确匹配命中）。
  `ignore` 与 `deny` 共用同一匹配规则，例外范围与禁止范围必须对称。
- **默认漏洞库地址在国内网络不可达**：trivy 默认走 `mirror.gcr.io`，该域常被墙（表现为
  `failed to download vulnerability DB: dial tcp ... timeout`，`g_dep` 随即红）。改走上游
  `ghcr.io` 即可：`export TRIVY_DB_REPOSITORY=ghcr.io/aquasecurity/trivy-db`、
  `TRIVY_JAVA_DB_REPOSITORY=ghcr.io/aquasecurity/trivy-java-db`（Java 项目需要后者）。
- **漏洞库拉取失败有三层，改镜像只是其中一层**（2026-09-20 实测：Windows 11 + Docker Desktop +
  trivy 0.74.0）。`g_dep` 报「trivy 执行失败」时先分辨是哪一层，别直接归因「网络不可达、改镜像即可」：
  - **① 凭据助手（最先撞到）**：`~/.docker/config.json` 的 `"credsStore": "desktop"` 会让 trivy
    （经 go-containerregistry）去 exec `docker-credential-desktop`，失败即**硬错误**
    `error getting credentials - err: exec: "docker-credential-desktop": executable file not found in %PATH%`。
    **反直觉点**：该 exe 确实在 `C:\Program Files\Docker\Docker\resources\bin\`、`command -v` 找得到，
    但 trivy 的子进程 exec 仍报找不到 —— 故「PATH 里有没有它」不足以判断这一层。
    绕过：`DOCKER_CONFIG=<dir>`，该 dir 的 `config.json` 只写 `{"auths":{}}`（无 `credsStore`）。
  - **② 制品下载超时（不是墙）**：绕过后错误变为 `oci download error: copy error: context deadline exceeded`。
    直测 `curl -m8 https://ghcr.io/v2/` 返 **401**（正常鉴权挑战）→ **该域可达**，超时来自 trivy-db
    制品大（数百 MB）+ 链路慢。故「改 `TRIVY_DB_REPOSITORY`」在这一层**不一定有帮助**
    （实测 `1ms.run` / `docker.m.daocloud.io` / `dockerpull.org` 三个镜像均未在超时内产出）。
  - **③ 兜底：用本地已缓存的库**：`trivy --version` 会打印本地库时间戳（如
    `Vulnerability DB: Version 2, UpdatedAt …`）。有缓存时 `TRIVY_SKIP_DB_UPDATE=true` 可直接跑通。
    代价：库随时间变旧，需定期联网更新一次。
  - **处置顺序**：`DOCKER_CONFIG` 去 `credsStore` → 再看镜像/网络 → 最后 `TRIVY_SKIP_DB_UPDATE`。
    **不要**把 `TRIVY_SKIP_DB_UPDATE` 内建进门禁（拿旧库冒充「已检查」= 假绿）；它是**操作者的**手段。
    本仓实测：加上 ①②③ 的处置后 `g_dep` 从「工具执行失败」恢复为**真实判定**
    （460 findings / 103 blocking）。
- **不引入 PyYAML**：`depcheck.py` 用最小正则解析策略（同 `ci/bin/checklist.py`），确定性门禁不得
  依赖可选 pip 包。策略文件因此只允许「顶层 key + 二级 `- ` 列表项」两级结构。
- **可复现证据**：判定逻辑的回归用例在 `tests/depcheck/`（`./tests/depcheck/run.sh`），覆盖命中/放过、
  例外生效/过期/无效、两层并集、不可解析输入不假绿。改 `depcheck.py` 或策略语义后跑它。

## 兼容性门禁（compat）

判「仓库**声明的**最低支持版本」是否低于基线（设计决策见 **ADR-0011**：只判声明式、机制照 dep 同构、
API 级 breaking change 明确排除）。判据单源 `compat-policy.yaml`（两层：本文件 = shared
基线随 upgrade 同步；`.harness/compat-policy.yaml` = 项目自有例外，语义层不覆盖，两层取并集、
只增不减），判定归 `bin/compatcheck.py`，清单发现归 `harness-stack.sh` 的 `stack_compat_manifests`
（探测谓词不在两处漂移）。

- **只判声明，不判实现**：声明来源为 `package.json` engines.node/npm · `go.mod` 的 `go` 指令 ·
  `Cargo.toml` rust-version（MSRV）· `pom.xml` 的 maven.compiler.release|source|target / java.version ·
  `build.gradle` 的 sourceCompatibility · `pyproject.toml` requires-python / `setup.py|setup.cfg` python_requires。
  取约束串里**首个数值版本 token** 作声明的下界（`>=16`→16 · `^18.0.0`→18.0.0 · `>=3.9,<4`→3.9 ·
  `18.x`→18 · Java `1.8`→1.8）。同引擎同文件多条声明**取最低**——取高的会把真实下界藏起来，
  且声明自相矛盾本身就该被看见。
- **未声明不违例，但作为覆盖缺口列出**：不承诺即不违反。跑完零声明时门禁报绿并在报告里列「未声明引擎」，
  让「这一维没约束可判」可见——跑完的负结论是结论，不是假绿。整仓一条声明都没有时 `wire_compat`
  判「不可真实接线」，scaffold 把 `gates.compat` 置 false（同 `wire_dep` 对 trivy 的取舍：
  不刷每次跑都来的黄噪声），由 owner 声明好基线后手动开。
- **范围边界**：只管「运行时/生态最低支持版本」这一类声明。API 级 breaking change（japicmp /
  api-extractor / cargo-semver-checks 那类）需要**基线产物**（上一版 jar / .api.md / 上一 tag），
  是另一种输入模型，不在本门禁范围内。具体依赖库的版本兼容（peer 冲突、传递依赖）是 dep 门禁的域。
- **退出码**：无策略 / 本仓无可判定清单 / `floors` 为空 = **2（黄，不假绿）**；有 blocking = 1；
  python3 跑不起来 = 1（判据评估不了 ≠ 未配置，同 `g_dep` 的 `py_ok` 防护）。
- **例外**：与 dep 同款纪律——`ignore` 每条必须带 `reason`（缺则不采纳并告警），`expires` 到期
  自动失效重新变红，防例外沉淀成永久豁免。
- **stdin 路径须过 `_winpath`**：清单路径走 stdin 而非位置参数（monorepo 清单条数无上限），
  而 **MSYS 只自动转参数、不转 stdin**——不归一的话原生 python 收到 `/d/...` 找不到文件。
  同 `depgraph` 的 stdin specs 处理。
- **不引入 PyYAML**：同 `depcheck.py`，最小正则解析策略。
- **可复现证据**：判定逻辑的回归用例在 `tests/compatcheck/`（`./tests/compatcheck/run.sh`），
  覆盖命中/放过、版本形态、同引擎多条声明取最低、例外生效/过期/无效、两层并集、不可解析输入不假绿、
  探针、报告落盘。改 `compatcheck.py` 或策略语义后跑它。

## 套件自测（`tests/`）

判定逻辑的回归用例在 `tests/<name>/run.sh`（compatcheck / depcheck / metrics / adr0012 /
reviewrecord / data-causal / runtime-check / tsd-ls / epic-remaining-items），是 CONTRACT-001「门禁必须能失败」的**可复现证据**，HOG 规则也把它们当「可复现锚」引用。

**唯一入口**：`./ci/bin/harness-selftest.sh`（不给参数就跑全部；给名字只跑那几个）。
`tests/` **不分发**（`upgrade.sh` 只拷 `ci/`），项目里没有它 —— 故那是**套件自己的**自测。

**执行点**：`.githooks/pre-commit`（改了 `ci/` 或 `tests/` 时自动跑）。一次性激活：

```bash
git config core.hooksPath .githooks
```

**不激活 = `tests/` 又回到「靠人记得跑」** —— 本仓没有 remote、也没有 CI，git hook 是这里
唯一会自己触发的执行点。`closed-loop-audit.sh` 有一条对账会报「有 `tests/` 却没有入口/执行点」，
别把它绕过去。

> 代价：全套在 Windows/MSYS 上约 3 分钟（CPU 时间只有几秒，全是进程创建开销），Linux 上快得多。
> 故 hook 按**改动的路径**决定跑不跑，纯文档改动不触发。

## 每阶段门禁组成（各阶段各自维护）

| 阶段（skill） | 确定性门禁 | 判断节点 |
|---|---|---|
| build（harness-build） | 无（落契约脚本） | 无 |
| verify（harness-verify） | static / schema / pitfall / dep / compat / audit | 无（arch 漂移归 review） |
| review（harness-review） | 无 | review（diff / arch） |
| contract（harness-run 步骤 4） | 无 | contract（audit 语义） |
| quality（harness-run 步骤 5 / close） | 无 | quality（元治理） |
| close（harness-close） | 运行时契约脚本周期跑（CI schedule） | quality（毕业前） |

## 铁律与按需（binding / on_ramp）

门禁分两类：企业铁律强制、流程按需，两轴分开（取代原 light/full 分档套餐）。

- **铁律（binding=true）**：确定性门禁 static/schema/pitfall/dep/audit，永远强制跑，任何风险档/降级都关不掉，
  由 `harness-gate.sh` 串跑（verify 阶段）。
- **流程（binding=false，judge 节点）**：按 `on_ramp` 分派——
  - `on_ramp: light`（轻风险也开）：审查节点 review（ocr），默认审查；
  - `on_ramp: full`（仅重风险开）：contract（契约对账）、quality（元治理）。

`harness-run` 在 verify 前跑 `harness-tier.sh`（确定性、无 AI）从 diff **嗅探风险档** full（重风险）还是
light（轻风险），**开发者不手动选**（手动选是可绕过的开关）。嗅探可审计：`--why` 打印触发 full 的规则与
文件，供 quality 节点回头验证「风险档判定对不对」。铁律门禁与风险档无关、永远跑。

- **契约信号**（命中任一即 full/重风险）：`.harness/` 契约/治理文件、依赖清单（pom.xml/package.json/go.mod 等）、
  对外接口层（controller/web/api/dto + *Controller/*Response/*Request/*DTO 等）、数据模型/schema/迁移
  （model/entity/migration + *Migration/schema*）。
- **不确定 / 空 diff / 无 git → 默认 full**：宁可多查，不可漏检（漏检才是危险失败模式）。

## keep 沉淀管道（cs-keep lesson → checklist/pitfalls）

确定性脚本（扫描/落盘）与无头 LLM（subagent 提取）分工，落盘前需 owner 人工批准：

1. `harness-keep-scan.sh`（有 AI）——定期扫 `.codestable/lessons/*.md` 的 `observed` lesson，用无头 LLM
   （runner 由 `HARNESS_KEEP_RUNNER` 指定，默认 `claude`）解析提取，按 README §五判据路由为
   checklist（`check_mode: judge`）或 pitfalls（`check_mode: deterministic`），写
   `.harness/work/proposal-{slug}.md`（`status: proposed`，ADR-0010）。**只提不落。**
2. **人工批准**（skill `harness-keep`）——owner 逐条审阅提案（路由/规则/判据/证据 + 确定性规则的
   Semgrep 模式），批准改 `status: approved`，返工改 `need-human`，拒绝改 `rejected` 或删除。
3. `harness-keep-land.sh`（无 AI，由 skill `harness-keep` 调用）——只落 `status: approved`，绝不落 `proposed`：
   - `judge` → 追加 checklist 项到 `.harness/checklists/{domain}.md`；
   - `deterministic` → 追加 checklist 项 + Semgrep 规则到 `.harness/pitfalls.yaml`。
   落盘前做 id 冲突检查，冲突转 `need-human`。落盘成功标记 `status: landed`。

坑库两层：`ci/rules/pitfalls.yaml`（shared，suite 源随 upgrade 同步）+ `.harness/pitfalls.yaml`
（project-local，语义层，upgrade 不覆盖）；`g_pitfall` 两个都读。入口见 `workflows/keep-scan.yml`（当前仅手动，定时暂未注册）。

**记忆治理（R2–R4）**：沉淀会过时，故须能**修正**且**划清归属域**：
- R3 域声明：新落盘的 checklist 项必须声明 `problem_domain`（问题域）+ `domain_knowledge`（相关领域知识），
  缺一 `harness-keep-land.sh` 转 `need-human`（harness 最忌上下文/流程污染，不写清适用边界即不可消费）；
  存量 grandfather，`checklist.py backfill <root>` 列待回填，`audit domain-backfill` 只告警不判红。
- R2 过时修正：提案 frontmatter 带 `supersedes: <既有 item id>` → 落盘**就地替换**该旧项（旧版靠 git 历史，
  不 append、不留 duplicate id）；生命周期用独立字段 `lifecycle`（active/superseded/retired），**不复用 `status`**。
- R4 归属域校验：确定性面 `audit domain-attribution`（非法 lifecycle / 残留 superseded / `superseded_by` 悬空 → 红）
  + `domain-backfill`（缺域字段 → 告警）；judge 面由 `harness-review` 的 `quality` 节点 rubric 判（证据指向 X 却标 Y = blocking）。

## 跨项目复用 + 静态→运行时 两缝

**复用 seam（横向）**：project-local 的 checklist/pitfall 项经「标识 + 手动晋升」进入 suite 规范源
（`checklists/shared/` + `ci/rules/pitfalls.yaml`），项目侧经 loader 消费。四条缝：

1. **晋升**：owner 在 `harness-keep` 批准时给可能跨项目复用的项加 `reuse: candidate`
   （`harness-keep-land.sh` 校验该枚举，防拼错致候选静默消失）；`harness-checklist-candidates.sh`
   扫出候选；`harness-checklist-promote.sh <id> --applies-to ...` 按
   [`constraint-model.md` §2b](constraint-model.md) 三条硬条件校验并**改写**后落入 suite 源
   （默认 dry-run，`--apply` 才写）。**晋升是改写不是搬运**：`project` 改维护方、证据换锚、去项目特有名词。
2. **分发**：`checklist.shared_store`（identity.yaml）指向 suite checkout 的 `checklists/shared/`，本地实时读，
   `git pull` 刷新；`applies_to:` 标签按 `project.traits`（缺省回退 `harness-stack.sh` 探测 stack）过滤。
3. **消费**：`harness-checklist-ls.sh <domain>` 双源读 local+shared 的 `check_mode: judge` 项拼上下文；
   `judge-review.sh --checklist-domain <domain>` 自动前置注入（仅 prompt 型 runner；ocr 不消费）。
   消费侧向 `.harness/reports/checklist-consumed.log` 记 `{pid}\t{cid}`；shared_store 缺失降级 local-only 告警。
4. **反馈**：shared 项被判定过泛/假阳 → `harness-checklist-issue.sh <project.id> <checklist-id> <原因>` 落
   cs-issue + 非零退出通知 owner 退役/收紧 `applies_to`。

**爬梯（纵向）**：checklist 项标 `runtime: data|log` = 有线上可观测形态、应爬 CONTRACT-001 rung 4。
`harness-runtime-gap.sh` 列出未落 `.harness/contracts/{pid}-runtime-{domain}.md` + `.harness/runtime-config.yaml`
对应项的 checklist 项；`harness-close` 步骤 1 据此提为运行时契约（复用 `harness-data-check.sh` 抓取 +
`judge-review.sh data` 判定）。执行配置三源：`env.yaml`（env.data.* 单源）/ `runtime-config.yaml`（每域查询规格：collection_name + conditions 等值数组）/
`runtime-subjects.yaml`（依赖数据值），由 `harness-runtime-check.sh`（→ `harness-runtime-run.py`，需
`pip install -r ci/requirements-runtime.txt`）统一读配执行，项目里不再生成 per-domain `_check.sh`。
两缝缺口在 `closed-loop-audit.sh` 只 warning 不 blocking（观察一段）。

## 跨业务共享数据的离线因果校验（ADR-0015）

与时间轴（变化模型）、单写值断言**正交**的第三条轴：判的不是「本次改动是否符合自己的数据契约」，
而是「**其他业务对这份共享数据的改动是否符合预期**」。入口 `judge-review.sh data-causal <domain>`
（委托 `harness-data-causal-judge.sh`），三类输入缺一不可：

- **baseline 代码**：产出当前线上数据的那个状态的只读快照（`git show`，决策 4）。baseline 锚**必须由
  客户显式确认、不得默认**（决策 3）—— 经 `harness-baseline.sh confirm <ref> --by <who>`（skill 流程用
  `AskUserQuestion` 取值）落盘 `.harness/baseline.yaml`（pin 不可变 SHA + 确认人 + 时间）；未确认 / 漂移
  即 fail-fast，不开始推演。
- **线上当前相关数据**：抓取报告，**先经 `harness-data-redact.py` 脱敏（保完整性）**再进 prompt（决策 6）。
- **日志**：触发证据；缺日志 = 事件不完整 → need-human（决策 8：缺事件不给因果结论）。

judge 从「快照 vs 不变量」改为**重建触发链**（决策 5）：baseline 代码声明合法写点 → 日志实际触发 →
线上数据随之变成什么样。触发链断裂（值变而无对应触发）或与 baseline 语义矛盾（出现未声明的写点）即
报违反（block）。配置 schema 见 [`runtime-contract-schema.md` §8](runtime-contract-schema.md)。回归用例
`tests/data-causal/run.sh`（baseline 确认/漂移、脱敏保完整性守卫、causal judge 输入守卫）。



`bin/*.sh` 是平台无关的。GitLab CI / Jenkins 只需在对应 stage 调
`ci/bin/harness-gate.sh`（确定性）与 `ci/bin/judge-review.sh <target>`（LLM-judge），
把 `TRAECLI_PERSONAL_ACCESS_TOKEN`（或对应 runner 凭据）注入环境即可。
