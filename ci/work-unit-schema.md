# work-unit schema（单源）

work-unit 是 harness 闭环的**最小工作单元**：拆解产物（feat/issue）与 harness 自产追踪件（runtime/checklist/keep 提案）统一用这一个 schema。方向见 ADR-0010（定义 harness 自有输入格式、把 `.codestable/*` 文件格式耦合收进 `work_unit.py` 适配器一处；**CodeStable 仍是拆解/沉淀的必需提供者**，install 的 `CS_REQUIRED` 保持阻断 —— 目标是「清 seam」不是「去 cs」）。

## 命名空间与文件约定

- 目录：`.harness/work/{id}.md`，`id` 唯一，文件名 = `id`（小写字母数字连字符）。
- 与 TSD 的关系：work-unit 是「输入单元」，TSD 是「冻结规格」；TSD frontmatter 的 `task` 字段回链 work-unit `id`（取代「回链 `.codestable/work/*-{task}.md`」）。
- 变更检测哈希 **body**（不含 frontmatter，同 ADR-0004 的 `work_sha` 语义）。

## Frontmatter 字段

| 字段 | 必填 | 语义 |
|---|---|---|
| `schema_version` | 是 | `1` |
| `id` | 是 | 唯一标识（= 文件名） |
| `kind` | 是 | `feat`（功能）/ `issue`（缺陷·追踪）/ `proposal`（keep 沉淀提案） |
| `status` | 是 | 生命周期，镜像 TSD（见下）；无 TSD 时为 `incoming` |
| `producer` | 是 | 生产者（provenance）：`cs-feat` / `cs-issue` / `cs-epic`（CodeStable 拆解适配）· `harness-runtime` / `harness-checklist` / `harness-keep`（harness 自产）· `manual` |
| `tsd` | 否 | 回链 TSD slug（`{project.id}-{id}`），有 TSD 时由 `harness-status` 回写 |
| `blocked_by` | 否 | **阻塞边**（ADR-0012 决策 1）：本单元被哪些 work-unit `id` 阻塞。见下 |
| `created` | 是 | 创建日期（`YYYY-MM-DD`） |
| `updated` | 否 | 最近变更日期 |

## `blocked_by`（阻塞边：遗留项的结构载体）

**格式**：`blocked_by: <id>[, <id>…]`（逗号分隔的 work-unit `id`）。空 / `[]` / `none` / `-` = 无阻塞。
解析归 `ci/bin/work_unit.py` 的 `parse_blocked_by`（单一归属，读侧不各自重写）。

**语义**：一条边 = 「本单元在 `<id>` 完成前不能开始」。这是**遗留项的机器可读载体**——ADR-0012 决策 1
把「round N 的遗留」定义为「`blocked_by` 未解析的 work-unit」，把「round N+1 的输入」定义为
「该字段的并集」。比一份交接文档可靠：可 grep、可 git diff、跨轮存活、不靠人记得写。

**「已解析」的判据**（`work_unit.py` 的 `blockers_resolved`）：指向的 work-unit 存在**且**其 `status`
是终态 —— `feat`/`issue` 为 `done`，`proposal` 为 `landed`。其余一律算未解析，**含「指向的 id 不存在」**
（悬空边本身是缺陷，不能当已解析放过）。

**谁写**：创建该 work-unit 的那一方。`harness-plan` 承接拆解单元时按依赖顺序落（它已有「写清依赖顺序」
这一步）；`harness-close` 把本轮遗留拆成新 work-unit 时落（新单元的阻塞边指向未完成的前置）。
**谁读**：`harness-handoff.sh` 聚合 Handoff 派生视图时（未解析的即本轮的遗留项）；下一轮的 `harness-plan`
把它当输入。

## status（生命周期状态，语义随 kind/source 不同）

- `feat`/`issue`（build 工作单元，走 build→close 循环）：镜像 TSD（ADR-0004 决策 1）——
  `incoming`（无 TSD）→ `frozen` → `building` → `verified` → `reviewed` → `done`（TSD `closed` → work `done`，其余透传）。
- `issue`（tracking，source=`harness-runtime`/`harness-checklist`）：`proposed`，配合
  `disposition: open|confirmed|false-alarm` 记终局（供 harness-measure 度量 precision/TTF）。
- `proposal`（keep，source=`harness-keep`）：`proposed` → `approved` → `landed`。

## 适配映射（`.codestable/work/*.md` → harness schema）

| CodeStable 字段 | harness 字段 | 映射 |
|---|---|---|
| `slug` | `id` | 直通 |
| `type` | `kind` | `feat`→`feat`、`issue`→`issue` |
| `status`（`planned`/`in_progress`/`done`） | `status` | `planned`→`incoming`、`in_progress`→`building`、`done`→`done`（有 TSD 后以 TSD 镜像为准） |
| `entry`（`cs-feat`/`cs-issue`/`cs-epic`） | `producer` | 直通 |
| `created` | `created` | 直通 |
| （无） | `tsd` | 由 `harness-status` 回写 |
| （无） | `blocked_by` | 由 `harness-plan` 承接拆解时按依赖序落（cs 侧无对应字段，不猜） |

## 迁移示例

```markdown
---
schema_version: 1
id: demo-supply-sign-initiate
kind: issue
status: done
producer: cs-issue
tsd: demo-module-sign-initiate
blocked_by: demo-module-order-push-ndms-align
created: 2026-08-05
updated: 2026-09-16
---

# 签收发起：补 signItems 载荷与 accepted/needReview 解析
…（正文：目标/现场/边界/证据/验收，原样迁移）
```

## Body 约定（随 `kind`）

- `feat` / `issue`：目标 / 现场 / 边界 / 证据 / 验收（或含需求分析 3W2H 与开放决策 D/A/I，见 REQ-001/REQ-002）。
- `proposal`（harness-keep）：`check_mode` / `domain` / `severity` / checklist 块 / semgrep 块（沿用 harness-keep-land 现有约定，`status: proposed → approved → landed`）。

正文格式不强统一；但哈希与「只读消费」都基于 body。
