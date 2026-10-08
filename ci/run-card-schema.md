# RunCard 格式单源

> 设计决策见 **ADR-0012**（执行态与观测模型）。本文只定**字段级**，是 RunCard 落盘/读取脚本的单一真源，
> 同 [`work-unit-schema.md`](work-unit-schema.md) 的定位。字段与 ADR 不一致时，以 ADR 为准并改本文。

RunCard 是「一次执行」的推进态载体。它**不承载目标/范围/约束的正文** —— 那些属于 TSD（规格）；
它只记录：这次执行走到哪、回修了几轮、上一轮是谁。

## 字段

| 字段 | 必填 | 语义 |
|---|---|---|
| `schema_version` | 是 | `1` |
| `id` | 是 | RunCard 唯一标识（= 文件名）：`{project.id}-rc-{tsd}` —— 用**与 `tsd` 字段同一个值**。同一 TSD 复开时后缀 `-2`、`-3` |
| `tsd` | 是 | **单向引用** TSD 的**文件名段**（`{project.id}-{slug}`，如 `harness-order-push`）。TSD 侧**不写** `run_card`/`run_status` 反向字段（ADR-0012 决策 1） |
| `handoff_from` | 是 | 上一条 RunCard 的 `id`；首条为 `none`。**链式回指**（ADR-0012 决策 4：断链 = 有一轮没交接） |
| `phase` | 是 | 当前阶段：`plan` / `build` / `verify` / `review` / `close` / `done` / `aborted` |
| `rounds` | 是 | 回修轮次计数（「红 → 回 build 重跑」算一轮，口径同 `flow.max_fix_rounds`） |
| `started` | 是 | 创建日期 `YYYY-MM-DD` |
| `updated` | 否 | 最近推进日期 |

**「是否完成」不落 RunCard 的独立字段**：`done` 只是 `phase` 的一个取值。**「TSD 是否完成」由 close
判定、完成标识落在 TSD 的 `status: closed`**（owner 2026-09-19 定，**修正 ADR-0012 原文的「由脚本聚合、
不写回 TSD」** —— 实测没有那个聚合脚本，且拿一堆被写的字段去「派生」得到的是第三份事实）。判定方与
落法见 ADR-0012 决策 1 与本文「复开时 TSD 的 `status` 回退」节。

**「每阶段的退出标准是否达成」同样派生于 `phase`，不落独立字段**（ADR-0012 决策 1 列了这项，
此处定它的落法）：`phase` 推进过某阶段 = 该阶段的退出标准已达成 —— 这是决策 1「只留推进态、
不留第二份须同步的事实」的直接推论。若另立一个 `exit_ok: {build: true, …}` 字段，它与 `phase`
就是两份必须同步的事实，且**没有额外信息**（`phase=review` 已蕴含 build 的退出标准过了）。
判据仍在各阶段 skill 的硬门槛里（门禁过才推进），RunCard 只记推进的结果。

## 正文：本轮前提（非派生上下文）

frontmatter 只放标量；RunCard 正文有一段**非派生**的 `context`：

```markdown
## 本轮前提（动别处前必读）

- 前提：<本轮立的假设/决定> —— 耦合位置：<文件 或 实体 id>
- 前提：<……>
```

- **只写「推不出来的」**：能派生的（完成项/遗留项/风险/决策）一律不写，见 ADR-0012 决策 1 ——
  这段专放「本轮立下的前提 + 其耦合位置」，这是几轮跨轮撞车的根因，且没有别的实体可承载。
- 由各阶段 skill **在推进 `phase` 时顺带 append** 自己的前提条目（谁立的前提谁写，不替别人写）。
- **「读」靠流程强制**：每个阶段 skill 开工第 0 步 = 读 `handoff_from` 指向的前任 RunCard 的这段。

## 生产者 / 消费者（ADR-0012 决策 4）

**写者按字段声明**（不是整卡单写者 —— 每卡各阶段都推进，强约束为「每字段只被声明它的那方写」，
改别人的字段 = 违例）：

| 字段 | 写者 | 何时写 |
|---|---|---|
| `tsd` / `id` / `started` / `handoff_from` | `harness-plan` | 创建时，之后不可改 |
| （TSD 的）`status` 与 work 镜像 | `harness-status.sh`（**唯一写者**） | `advance` 推进；`reopen` 复开时回退。`harness-runcard.sh create` 只**触发** `reopen`，不自己写 |
| `phase` | 正在**完成**该阶段的 skill | 该阶段门禁过 → 写下一阶段 |
| `rounds` | 触发回修的那次判定（review/verify） | 红 → +1 |
| `updated` | 任一推进方 | 每次推进 |
| 正文「本轮前提」 | 各阶段 skill | 推进 phase 时 append 自己的条目 |
| 终态 `done`/`aborted` | `harness-close` | 毕业或中止 |

| 角色 | 谁 | 动作 |
|---|---|---|
| **消费者 ①** | `harness-run`（编排器） | 读 `phase` 决定从哪续跑 |
| **消费者 ②** | 下一条 RunCard | 经 `handoff_from` 承接；开工读其「本轮前提」 |
| **消费者 ③（检测）** | `closed-loop-audit` | 三条核对（见下） |

## 审计核对（三条，挂进 closed-loop-audit）

1. **`tsd` 存在且冻结**：指向的 TSD 文件在、`tsd_frozen: true`。缺 → 红。
2. **`handoff_from` 链不断**：每条非首条 RunCard 的 `handoff_from` 都指向一条存在的前任 RunCard。
   断链 → 红（有一轮没交接）。
3. **无孤儿**：每条非终态（`phase != done/aborted`）的 RunCard，要么是链上最新一条，要么有后继
   `handoff_from` 指向它。非最新又无后继 = 产出未被消费 → 报「RunCard 未被消费」。

## 生命周期

```
harness-plan     创建（phase=plan, handoff_from=<前任或 none>, rounds=0）
harness-build    推进 build →（红则 rounds+1，回 build）
harness-verify   → verify
harness-review   → review（红则回 build，rounds+1）
harness-close    → close → done
复开              新 RunCard（handoff_from=前任 id，id 后缀 -2）
```

## 与 Handoff 的关系

RunCard **不**写「遗留项/风险/决策/下一步」——那些由 **Handoff 派生视图**在交接时从
RunCard + work-unit（`blocked_by` 未解析的）+ ReviewRecord（blocking 发现）+ ADR 聚合（ADR-0012 决策 1）。
RunCard 只提供链式回指，让「下一轮真的读了上一轮」可被对账。

## 复开时 TSD 的 `status` 回退（owner 拍板，2026-09-19）

`status: closed` 是**完成标识**（ADR-0004 的 spec 级进度），而**创建执行卡 = 声明「该规格又进入执行」**
—— 两者不能同时成立。故**复开时 `status` 回退到 `frozen`**。

- 只在**真的需要回退**时动：首卡时 `harness-plan` 刚写 `frozen`，此时什么都不做、不打印。
- **`create` 只触发，不自己写**：委托 `ci/bin/harness-status.sh reopen <slug>`。TSD `status` 与
  work 镜像是一对，写者必须**唯一**（镜像规则只该有一处）—— 自己写就会让「谁维护镜像」出现第二个答案。
- **`reopen` 的 work 映射是 `building`，不是 `frozen`**：work 的 `frozen` 是 harness 专有值，
  CodeStable 侧只认 `planned/in_progress/done`（映射 `in_progress`→`building`）—— 写 `frozen` 会让
  cs 侧读到不认识的取值。`building` 是**双方都认**的非终态值，且 `harness-run` 复开后第一步就推进到它。
- **约定不一致的坑（已填）**：`harness-status.sh` 的 slug 是**裸 slug**（它自己拼 `${PID}-`），
  而 `harness-runcard.sh create` 的参数是**完整文件名段** —— 同一个词两种含义。`harness-status.sh`
  的定位已**同时接受两种写法**，否则传错的表现是「找不到 TSD」，看不出是约定不一致。

## 已定（owner 拍板，2026-09-18）

1. **`id` 加后缀**：`{project.id}-rc-{tsd-slug}`，复开时 `-2`、`-3`（方便区分历史）。
2. **复开 = 新建 RunCard**，不在旧卡上写 `reopened`；旧卡停在 `done`/`aborted`。
3. **阶段 skill 写自己的 `phase` 推进**（强约束、无遗漏：每一步推进由实际执行方落卡，
   不靠编排器替写）——写者按字段声明，见上表。
4. **RunCard 正文带「本轮前提」（非派生 context）**：专放推不出来的前提 + 耦合位置，
   能派生的内容一律不写（避免第二事实源）。
