# TSD 花名册 `--json` 输出格式单源

> 定位同 [`run-card-schema.md`](run-card-schema.md) / [`work-unit-schema.md`](work-unit-schema.md)：本文只定
> **字段级**，是 `harness-tsd-ls --json` 消费方（未来 GUI / 脚本）的单一真源。设计背景见 **ADR-0012 决策 4**
> （派生视图，不落盘）。字段与 ADR 不一致时，以 ADR 为准并改本文。

`harness-tsd-ls --json` 是 `ci/bin/tsd_board.py` 的机器可读面。它**只读、不落盘、不 spawn agent**：
从 `.harness/tsd/*.md` frontmatter + RunCard（`phase`）+ work-unit（`blocked_by` 解析）**派生**，用时生成。

## 顶层字段

| 字段 | 类型 | 语义 |
|---|---|---|
| `schema_version` | int | `1`。**破坏性变更**（删字段 / 改语义 / 改类型）须 +1 |
| `state` | string | 四态之一，见下。**判不了不塌成空/缺**（同 `metrics.py` 四态纪律） |
| `count` | int | `tsds` 长度（可解析的 TSD 数） |
| `errors` | string[] | `state=error` 时非空：**解析不了**的 TSD 文件名（无 frontmatter 块）。花名册不完整时点名 |
| `tsds` | object[] | 每张 TSD 一张卡片，按 `slug` 升序 |

### `state` 四态（**互斥、可区分**）

| 取值 | 含义 | 触发 |
|---|---|---|
| `ok` | 全部 TSD 可解析 | `.harness/tsd/` 存在且有 ≥1 张可解析卡片 |
| `empty` | 目录存在但无 TSD | `.harness/tsd/` 为空（0 份） |
| `missing` | 目录不存在 | `.harness/tsd/` 缺失（未跑过 plan/init） |
| `error` | 有 TSD 解析不了 | 至少一张无 frontmatter 块 → `errors` 点名，`count` 只计可解析者 |

`empty`/`missing`/`error` **都不等于** `ok`：消费方必须按 `state` 分流，**不得**把非 `ok` 当成「无卡片但正常」。

## `tsds[]` 卡片字段

| 字段 | 类型 | 语义 | 取不到时 |
|---|---|---|---|
| `slug` | string | TSD slug（frontmatter `slug`，否则文件名 `{pid}-{slug}.md` 剥前缀） | — |
| `status` | string | TSD frontmatter `status`（**真相源**，ADR-0004） | 缺字段 → `"?"` |
| `task` | string | TSD frontmatter `task`（work-unit 回链锚） | 缺字段 → `"?"` |
| `frozen` | bool | frontmatter `tsd_frozen: true` | 非 true → `false` |
| `runcard_phase` | string \| null | 同 TSD **最新** RunCard 的 `phase`（经 `handoff.find_runcard` 定位） | **无 RunCard → `null`** |
| `unresolved_blockers` | int \| null | `tsd` 回链指向本 TSD 的 work-unit 中，`blocked_by` **未解析**者数 | **判不了 → `null`**（无 work-unit / 无回链）；`0` 仅当真有 work-unit 且全解析 |
| `handoff` | string | 「看详情」深链命令：`./ci/bin/harness-handoff.sh <slug>` | — |
| `harness_call` | string | 「引用开工」建议：`harness-run <slug>` | — |

**`null` ≠ `0`（本 schema 的关键纪律）**：`unresolved_blockers` 的 `null`（视图看不到阻塞）与 `0`（真无阻塞）
含义相反，塌成同一个 `0` 会把「判不了」读成「本项无事」—— 恰是本视图存在唯一要防的「漏看状态」。
`runcard_phase` 同款：取不到用 `null`，不臆造空串。消费方**必须**区分 `null` 与 `0`/`""`。

## 兼容承诺

- **只增不改**：新增字段是向后兼容；删字段 / 改字段语义 / 改字段类型 = 破坏性变更 → `schema_version` +1。
- 消费方应**忽略未知字段**，据 `schema_version` 决定是否理解。
