---
categories: security compliance data-integrity observability architecture process governance correctness accessibility
domains: log data harness-own-guard contract requirements
---

# 约束语义模型（约束类型 + canonical 模板）

约束 = harness 沉淀的「不可违反或已验证」的规则，是 gate（执行器）承载的对象。

本文件是**约束语义的单源**：约束类型（category）、约束 canonical 模板、以及约束 ↔ gate ↔ pitfalls ↔ checklist 的关系。后续「分类去重」从这里派生脚本逻辑，改约束只改这里。

> 顶部 frontmatter 的 `categories` 是 category 枚举的**共享单源**（keep-land / closed-loop-audit 从这里读，不硬编码）。新增**跨项目** category = 改这一行 + 在 §1 表加一行说明，脚本自动生效。
> 同一行的 `domains` 是**已知共享域**的单源（keep-scan 的 prompt 提示从这里读）。它**不是闭枚举**——domain 的权威是 `.harness/checklists/{domain}.md` 的**文件名**（项目可有「其他小写域」），故不用于校验，只用于提示。
> **项目本地 category**（项目自己跑出来的、暂不跨项目）加 `.harness/categories.yaml`（格式 `categories: a b c`，空格分隔）。keep-land 读「共享 + 项目本地」并集；跨项目有价值再晋升到本文件，和 checklist 项 `project-local → shared` 同构。

## 1. 约束类型（category）

「**为什么这是铁律**」的领域分类，与 domain（「**在哪**」：log / data / harness-own-guard / contract / requirements）**正交**。一条约束 = 一个 category + 一个 domain。

| category | 含义 | 判据（命中即此类） | 典型执行形态 | 现有示例 |
|---|---|---|---|---|
| `security` | 安全 | 注入 / 越权 / 密钥泄露 / 脱敏 / XSS | pitfall（deterministic） | HOG-001 禁 eval |
| `compliance` | 合规 | 审计留痕 / 数据留存 / 等保法规 | checklist 或 pitfall | — |
| `data-integrity` | 数据完整性 | 金额守恒 / 对账平衡 / 唯一性 / schema 迁移 | pitfall + 运行时契约 | DATA-001 / DATA-002 |
| `observability` | 可观测性 | 埋点 / 结构化日志 / trace / 监控 key | pitfall | LOG-001 / LOG-002 |
| `architecture` | 架构 | 依赖方向 / layer 边界 / 循环依赖 / 模块职责 | judge（arch）或 deterministic | — |
| `process` | 过程纪律 | 需求/决策完整性（3W2H、D/A/I 归属），防范围漂移/决策被代拍 | judge（requirements 节点） | REQ-001 / REQ-002 |
| `governance` | 治理 | 声明↔落盘↔同步可验证，防假检查/契约漂移 | checklist（judge）+ 对账 | CONTRACT-001 / CONTRACT-002 |
| `correctness` | 判定可靠性 | 门禁/判定脚本不假绿、不吞错误、退出码契约被尊重 | judge（review 节点） | HOG-002 / HOG-005 等 |
| `accessibility` | 无障碍 | 键盘可达 / 语义正确 / 辅助技术可感知 / 对比度 | checklist（judge）+ 可选确定性（项目侧 linter） | **（无内置项）** 曾有的 `a11y` 域已退役，见 ADR-0005 退役记录 |

- 枚举是**初始集**：新增 category 改顶部 frontmatter `categories`（机器可读单源）+ 本表加一行说明即可，脚本从 frontmatter 派生，不改任何脚本。
- category 用于报告/审计/晋升优先级（如 `security` 更值得跨项目 shared），**不作为 id 前缀**（id 前缀沿用 domain 惯例：LOG / DATA / HOG）。

## 2. 约束 canonical 模板

一条约束 = **一份 canonical**（存 checklist 项），执行形态**派生**（deterministic → pitfalls 规则；judge → 本条目即 judge 输入）。canonical 与派生靠 `deterministic_rule` 指针关联，不重复存语义。

### frontmatter 字段契约

| 字段 | 必填 | 取值 | 说明 |
|---|---|---|---|
| `id` | 是 | `<DOMAIN>-NNN` | 全局唯一，前缀沿用 domain（LOG/DATA/HOG…） |
| `category` | 是 | security / compliance / data-integrity / observability / architecture / process / governance / correctness / accessibility | 约束类型（§1，枚举单源见顶部 frontmatter） |
| `project` | 是 | 项目 id / 维护方 | project-local 填**项目 id**（这条属于哪个项目）；shared 填**维护方**（如 `harness`），**不写客户项目 id** —— 见 §2b 条件三 |
| `status` | 是 | shared / project-local / approved | `shared`=跨项目基线（需 owner 授权）；`project-local`=项目私有；`approved`=**已晋升到 shared、待本机同步**的交接态（见下「晋升交接」） |
| `domain` | 是 | log / data / harness-own-guard / contract / requirements / 其他 | 域（「在哪」） |
| `severity` | 是 | blocking / important | 违例后果 |
| `check_mode` | 是 | deterministic / judge | 执行形态（可机械 / 需判断） |
| `deterministic_rule` | 仅 deterministic | pitfall 规则 id | 指向可执行派生；judge 不写此行 |
| `reuse` | 否 | candidate | 跨项目复用候选（独立于本项目视角也可能适用）；无此行=仅本项目。发现走 `harness-checklist-candidates.sh`，晋升由 owner 手动提交 suite。**准入判据见 §2b —— 打标只需「可能适用」，晋升必须过 §2b 两条硬条件**（打标是提议，晋升是承诺） |
| `applies_to` | 否 | 空格标签（如 `stack:maven` / `has:npm` / `lang:java`） | shared 项的适用前置：与项目 traits 匹配才被 loader 消费；**空=声称通用**。三类标签：`stack:<x>`（单标签，`stack_detect` 按优先级只回一个，polyglot 会漏）、`has:<x>`（`stack_detect_all` 枚举到的每个栈都成立，按栈限定优先用它）、`lang:<x>`（构建栈到语言的归一：maven/gradle→java、npm→js），因为**匹配是「与」（tags ⊆ traits）**，表达不了「maven 或 gradle」。**注意**：loader 只注入 `check_mode: judge` 项，故 `deterministic` 项上的 `applies_to` 是文档、不参与过滤 |
| `runtime` | 否 | data / log / none | 是否可爬 CONTRACT-001 rung 4（运行时契约+定时脚本）：data=数据不变量只读查询 / log=行为不变量日志埋点 / none=静态-only（默认）。none 之外未落 runtime 契约由 `harness-runtime-gap.sh` 列出 |
| `problem_domain` | **新项必填** | 短 slug（如 `structured-logging`） | **问题域**：这条约束解决什么问题空间（比 `domain` 更细）。harness 最忌上下文污染，故新项必须显式声明「问题域 + 相关领域知识」以划清边界。存量 grandfather，由 `audit domain-backfill` 列「待回填」 |
| `domain_knowledge` | **新项必填** | 短文本 | **相关领域知识**：判定/应用它需要的领域知识（如「JVM 日志框架、结构化键值约定」）。与 `problem_domain` 配套，同为划界用。存量 grandfather，同上 |
| `lifecycle` | 否 | active（默认）/ superseded / retired | 生命周期。**不复用 `status`**（`status` 是层级 shared/project-local/approved）。缺省即 `active`；`retired`=不再适用但保留溯源；`superseded`=已被取代（D2 就地替换后旧项**应消失**，残留即 `audit domain-attribution` 红） |
| `supersedes` | 否 | item id | 本项**取代**的旧 item（修正时记 provenance）。落盘走 `harness-keep-land.sh` 的**就地替换**（按此 id 定位旧项、改写，不 append） |
| `superseded_by` | 否 | item id | 本项**被谁取代**。`audit domain-attribution` 校验其指向存在 |

### 空模板

```markdown
---
id: <DOMAIN>-NNN
category: <security|compliance|data-integrity|observability|architecture|process|governance|correctness|accessibility>
project: <溯源项目>
status: <shared|project-local|approved>
domain: <log|data|harness-own-guard|contract|requirements|其他>
severity: <blocking|important>
check_mode: <deterministic|judge>
deterministic_rule: <仅 deterministic 填，judge 删此行>
reuse: <candidate|删此行>
applies_to: <空格标签，空=通用|删此行>
runtime: <data|log|none>
problem_domain: <问题域 slug，如 structured-logging>
domain_knowledge: <相关领域知识，一句话>
lifecycle: <active|superseded|retired，缺省 active 可删此行>
supersedes: <item id|删此行>
superseded_by: <item id|删此行>
---

## <ID> <标题>

规则：（一条可判定「违反与否」的陈述）
适用：（边界内）
不适用：（边界外 / 停止应用信号）
证据：（来源 lesson / ADR / issue 指针，最多 3 条）
派生：deterministic → ci/rules/pitfalls.yaml 或 .harness/pitfalls.yaml 一条规则（<deterministic_rule>）；judge → 本条目即 judge 输入
```

## 2a. 变化模型原语（时间维，ADR-0007）

数据不变量除静态断言（结构/关系，抓「永远错」）外，声明时间维的变化模型（抓「突然变」）：该 metric
随时间的变化预期。运行时由 `harness-data-delta.sh` 做确定性 delta 预检（标「存疑」），`judge data` 做
语义判定（正当变化 vs 回归）。变化模型存于运行时契约 `.harness/contracts/{pid}-runtime-{domain}.md`
的「变化模型」管道表（列契约 `metric | json_path | primitive | params`；`json_path` 点路径，数组用 `[*]` 摊平）：

| primitive | 语义 | params | 确定性预检 |
|---|---|---|---|
| `monotonic-nondecreasing` | 累计量只增不减 | — | 最新快照 min 下移 → 存疑 |
| `monotonic-nonincreasing` | 只减不增 | — | 最新快照 max 上移 → 存疑 |
| `constant` | 落定后不变 | — | 值集变化 → 存疑 |
| `bounded-rate` | 环比变化有界 | `x%` | 总和相对变化 > x% → 存疑 |
| `within-sigma` | 落在滚动窗口 Nσ 内 | `N`（默认 3） | 最新值偏离均值 > Nσ → 存疑 |
| `reconcile-zero` | 跨源对账 delta 收敛到 0 | — | 不预检（跨字段，交 LLM） |
| `unbounded` | 无先验，LLM 自由判断 | — | 不预检（默认） |

`params` 列可带 `except: <逗号分隔情形>` = 该 metric 的合法变化情形（如退款/拒签）。仅供 LLM judge 判
存疑项「正当变化 vs 回归」时参照；确定性预检不因 `except` 抑制，照常标存疑（语义判断归 LLM）。

确定性预检只做粗粒度信号（max/min/总和/σ），逐记录语义判断仍归 LLM。

## 2b. 晋升判据（project-local → shared 的准入条件）

只有**项目无关**的约束才能进 `checklists/shared/`。这不是「看起来通用」的主观印象，而是两条可自检的硬条件。
**判据是单源，本处为准**（README §五与 `harness-keep` / `harness-close` skill 引用本节，不另写一套）。

**条件一 · 规则换项目仍成立，且适用范围说得清**

- 自检：把本项目名、本项目的领域词汇全部抹掉，这条规则对别的项目还成立吗？
- **适用范围有两种轴，别用错**：

  | 轴 | 什么时候用 | 怎么表达 | 例 |
  |---|---|---|---|
  | **项目类别** | 规则只对某类**仓库**成立 | 填 `applies_to`（`has:<x>` / `lang:<x>` / 自定义 trait） | `log` → `lang:java`（非 JVM 仓库收它没有意义） |
  | **改动类别** | 规则对任何仓库都能成立，但只在该类**改动出现时**才有话可说 | 写进正文 `适用：` / `不适用：`，由**评审时的 judge** 判定 | DATA-002「所有 schema / 迁移改动」、CONTRACT-002「所有公开 interface 改动」 |

- **按改动类别限定的项，`applies_to` 就该留空** —— 它不是「声称全世界适用」，而是「本项不按项目过滤」。
  给它硬塞一个项目级 trait 是**用错了轴**：既表达不了「改动出现时才管」，又引入探测器漏检的风险。
  反例警示：`持久化/schema` 类规则曾被认为该按项目过滤，于是想加「本项目有持久化状态」的 trait；
  实为按改动过滤，judge 看到 schema 改动才判 —— 加 trait 是错的。
- **`applies_to` 留空且规则确实只对某类项目成立** → 那才是债（该填没填）。

**条件二 · 证据是可复现锚，不是事故叙述**

- **可复现锚**（四类）：
  1. **外部规范**：WCAG 条文 / RFC / 语言规范 —— 别人能自己查证。
  2. **仓内测试**：`tests/<x>/run.sh` 之类，跑一遍就知道规则是否被执行。
  3. **规则 id**：`ci/rules/pitfalls.yaml` 的 Semgrep 规则，或 `harness.schema-check` 这类已知可执行。
  4. **判据执行点**：这条规则在套件里**由谁执行** —— skill（`skills/harness-plan` 步骤1）、
     评审节点（`judge-review.sh tsd|audit`）、对账脚本（`closed-loop-audit.sh`）。
     **它证明的是「规则确实被执行」，不是「规则为何存在」** —— 对「怎么用这套件」类的工作流规则
     （CONTRACT / REQ）这已经够；对领域规则（LOG / DATA）应优先用前三类。
- **事故叙述**：「某项目曾因此出过问题」—— 不可复现，且必然带项目特征。
- 事故可以是被发现的**起因**，但落 shared 时必须**换成锚**。换不出锚，说明这条规则的依据还停留在
  一次观察；按 §生命周期 应留在 project-local，直到它在**另一个项目上被独立第二次验证**。

**条件三 · 整项不体现具体项目**

- **`project` 字段**：**不写客户项目 id**。shared 项记录的是「这条基线归谁维护」，不是「从哪个客户项目来的」
  —— 填维护方（如 `harness`），或按需留空。project-local 层才填项目 id（那是它的溯源）。
- **证据**：不引项目名、内部类名、内部接口路径（由条件二换成锚）。
- **规则正文**：不出现项目特有名词（「我们平台」「本项目」这类）。
- **自检**：把这一项**原样贴给一个外部团队**，他们能看懂并直接应用吗？
  里面有任何一个词需要你在旁边解释「这是我们内部的 XXX」，就不合格。

**为什么卡这三条**：晋升动作是**文本搬运**（见 README §五），源项目的 `project` 字段、证据正文、规则措辞会
**原样带过去**，没有任何一步会问「换一个团队，这东西还成立吗」。不卡这三条，shared 会沉淀成
「一堆带项目名与内部术语的、没人能复核的轶事」—— 而 shared 是要随套件对外分发的。

**三层来源的区别**（别混）：
- `project-local`：这项属于**本项目**，填项目 id，证据可以是内部事故记录。
- `shared`：这项属于**组织基线**，不体现任何具体项目，证据必须是可复现锚（条件二）。
- 套件随包分发的就是后者 —— 分发前若还需要脱敏，说明晋升那一步没按本判据卡住。

**判据缺位的下游症状**（审查时按此反查）：shared 项证据里出现项目名/内部类名/事故描述；
`applies_to` 为空但规则正文已限定了技术栈或领域。

## 2c. 晋升交接（project-local → shared 的状态流转）

晋升是**移动**，但跨机同步不是瞬时的 —— 所以中间存在一个必须显式表达的交接态。

| 阶段 | local 侧 | **loader 解析到的共享层** | loader 取哪份 |
|---|---|---|---|
| 晋升前 | `status: project-local` + `reuse: candidate` | 无 | local |
| 已晋升、**尚未提交进套件源** | `status: approved` + `promoted_to:` | **套件源 `checklists/shared/` 里还没有** | **local**（仍生效） |
| 已提交进套件源 | `status: approved`（残留，可清理） | 有 | **shared**（以 shared 为准） |

> **「共享侧」指哪一层，别想当然**：`promote` 写的是 `{checklist.shared_store}/{domain}.md`
> （`harness-checklist-promote.sh`），而 **loader 解析共享层**是「本仓有
> `checklists/shared/{domain}.md` 就取它，否则取 `shared_store/{domain}.md`」（`harness-checklist-ls.sh`）。
> 两种配置下过渡点不同：
> · **目标项目**（loader 读 `shared_store`）→ promote 一跑即到位，交接**当即完成**；
> · **套件仓**（loader 读 `checklists/shared/`）→ **必须把该项提交进套件源**才到位 ——
>   `install.sh --refresh-shared` 的方向是「套件源 → 装载副本」，**不会**把晋升项写进套件源。

- **`promote --apply` 只标不删**：把源项标成 `approved` 并记 `promoted_to:`。删了就断档 ——
  本机同步 suite shared 之前，那份是唯一生效的副本。
- **loader 按「以 shared 为准」消歧**：同 id 两层都有时取 shared、跳过 local，避免同一规则注入两次。
- **审计区分两种跨层同 id**：local 侧是 `approved` → `[audit][info]`（预期交接态，提示跑
  `install.sh --refresh-shared`）；**其他状态 → blocking**（真冲突，同一规则会被注入两次）。
- **过渡动作按配置分两种**：loader 读 `shared_store` 的项目 → `./install.sh --refresh-shared`
  （见 README §二）；loader 读套件源的（如套件仓自身）→ **把该项提交进套件源**。
  到位后 local 那份可留可删，loader 不再取它。

## 3. 约束 ↔ gate ↔ pitfalls ↔ checklist

三者不重复，各司其职（为「分类去重」铺路）：

- **约束（canonical，一份）**：上表模板，含 id / category / 语义 / 判据 / 证据 / check_mode。
- **pitfalls.yaml**：`deterministic` 约束的**可执行派生**（Semgrep 规则体），由 `deterministic_rule` 指向。
- **dep-policy.yaml**：依赖域的确定性判据（漏洞阻断严重级 + 许可证禁止清单 + 例外），执行器 `gate: dep`
  → `depcheck.py`。它**不是** Semgrep 规则（AST 匹配表达不了「这个包有没有已知 CVE / 什么许可」），
  与 `g_schema` 的 `harness.schema-check` 同属「已知可执行」而非 pitfalls 派生——所以依赖类约束不会
  在 pitfalls.yaml 里出现，不必去找。
- **checklist**：`judge` 约束的**存储 + judge 输入**（LLM 对照自然语言规则）；deterministic 约束的 checklist 项只存语义 + 指针，不重复判据。
- **gate**：**执行器**，按 `check_mode` 跑派生形态（`binding:true` 铁律永远跑 / judge 按 `on_ramp`），不存约束。

关系：一条约束 → 一份 canonical（checklist 项）→ 按 check_mode 派生 → gate 执行。lesson（cs-keep）是**候选约束**，验证够了晋升为 canonical；铁律（binding gate）是**已固化约束**。

## 4. 与门禁注册表的关系

- `ci/gates.yaml` 是**门禁（执行器）身份单源**（deterministic / judge + binding / on_ramp）。
- 本文件是**约束（被门禁承载的规则）语义单源**（category + 模板 + 派生关系）。
- 两者分属两层，不互相存储：门禁不知道「有哪些约束」，约束不定义「怎么执行」。
