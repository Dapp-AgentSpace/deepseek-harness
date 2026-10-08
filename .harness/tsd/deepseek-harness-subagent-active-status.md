---
project: deepseek-harness
type: tsd
slug: subagent-active-status
task: subagent-active-status
schema_version: 1
tsd_frozen: true
status: frozen
work_sha: 38c01a4ef11709f8190fa7926761a0dac9543174eb07ffea5e3b14501373bf1a
content_sha: c7c8b561b7a6849564612a585cc98096d53b4c165ade21c71d16f38703a1ad9c
created: 2026-10-03
---

<!-- markdownlint-disable -->

# TSD · 子任务主动状态查询与有限等待（subagent-active-status）

## 需求分析（3W2H，REQ-001）

- **What 目标行为**：让主会话对任意 subagent（含 continuable）可**主动查询状态**与**带超时地
  等待结果**，等待不无限挂起。具体两块：
  ① 新增 `wait_settlement` 工具 + 服务层 `ctx.subagents.waitSettlement()`，复刻
  `job_output {wait:true, timeout_ms}` 的语义（超时返回当前状态而非报错）；
  ② `Agent.whenIdle()` 增加可选 `timeoutMs`（缺省行为不变），并新增 `lastActivityAt`，
  `watchSettlement` 改用有限等待。
- **Why 价值**：当前 continuable subagent 无任何等待/查询工具，结算靠 `notifySettlement`
  事件推送，主 agent 只能被动等；父侧 `whenIdle()`（agent.ts L650-655）是无限循环，
  子代理失联/死循环时父代理**永久挂起**——这是「主会话卡死 / 一直 loading 无状态返回」
  的直接根因路径之一。不做则主会话对子任务永远无主动观测与超时兜底。
- **Who 干系人**：受益 = 主会话 agent（可主动查询/等待子任务，超时兜底防挂起）+ 用户
  （GUI 不再无限 loading，见 P2 后续 work-unit）；受影响 = `core/agent-loop` 的
  `Agent` 接口使用者（`whenIdle` 签名扩展，缺省兼容）、`subagent` 服务消费者
  （新增方法，不改既有）；A 方（对 schema/data 有否决权）= 无（本 task 无数据 schema 变更）。
- **How 实现路径**：**契约新增 + 向后兼容扩展**。服务层
  `packages/subagent/subagent/src/index.ts` 新增 `waitSettlement`；结算落地点
  `continuation-activation.ts` `notifySettlement`（L871-888）旁维护 waiter 集合并释放；
  新工具 `packages/subagent/tool-subagent-control/src/wait-settlement.ts` 注册
  `wait_settlement`；`agent.ts` `whenIdle`（L650-655）加超时 + `lastActivityAt` 属性；
  `watchSettlement`（L725-779）L729 处改用有限等待。
- **How much 范围与验收**：范围 = 上述两块；非目标 = settlement 丢失持久化恢复（P1）、
  list_agents 细化/agent_status（P1）、GUI 进度事件（P2）、systemPrompt 文案（P2）。
  验收 = 见「目标与验收」。

## 目标与验收

- [ ] `wait_settlement` 工具已注册（inject `['tools','subagents','agents']`），
      schema 含 `agent_id` + 可选 `timeout_ms`/`wait`，返回 `{settled, agent}`。
- [ ] `ctx.subagents.waitSettlement(childId, timeoutMs, signal)` 服务方法存在：
      超时/中止返回当前投影（**不抛** TOOL_TIMEOUT 类错误，复刻 `jobs.wait` 语义）。
- [ ] 子代理结算时**全部**等待者被释放（并发多 wait 均 resolve，settled=true）。
- [ ] 未结算且超时时返回 `{settled:false, agent:<当前状态投影>}`。
- [ ] `Agent.whenIdle({timeoutMs})`：超时返回 `'timeout'`；idle 先到返回 `'idle'`；
      **不传参行为与现状完全一致**（无限等待，回归保证）。
- [ ] `Agent.lastActivityAt` 属性存在，随 `setPhase`/step 推进更新（epoch ms）。
- [ ] `watchSettlement` L729 改用有限等待：超时后复查 `agent.status` 与 `lastActivityAt`
      新鲜度，新鲜继续等，陈旧走告警路径（不无限挂起）。
- [ ] 新增测试全绿：`tool-subagent-control/tests/wait-settlement.spec.ts`、
      `core/agent-loop/tests/when-idle.spec.ts`；既有测试无回归。

## 契约变化或不变

**新增（向后兼容，不触发 CONTRACT-002）**：
- 工具 `wait_settlement`（`tool-subagent-control`，inject 与 `list_agents` 同族）。
- 服务方法 `ctx.subagents.waitSettlement(childSessionId, timeoutMs?, signal?)`。
- `Agent.whenIdle(opts?: {timeoutMs?: number}): Promise<'idle'|'timeout'>` ——
  **签名扩展**：缺省参数时行为与旧 `Promise<void>` 语义一致（无限等待），
  返回类型变化对现有调用点（`dispose` L809、`watchSettlement` L729 等）在
  **不传参路径**下无感知（返回值被忽略）。传参路径是新能力。
- `Agent.lastActivityAt: number`（只读属性，epoch ms）。
- `continuation-activation.ts` 新增 waiter 集合（实例私有字段）与释放逻辑，
  挂在 `notifySettlement`（L864）结算落地点之后。

**不变**：`AgentStatus` 枚举、`agent/status` 事件、`list_agents` schema（P1 再扩）、
`subagent` 服务既有方法签名、会话/作业存储格式。

## 反 TSD 模式声明

本 task 明确禁止：
- **禁止改 `notifySettlement` 的丢失恢复**（父离线/`sendWaking` 失败 → 持久化补发）
  ——那是 P1 work-unit 的边界，本 task 只加「可等待」通道，不碰事件送达可靠性。
- **禁止把 `wait_settlement` 实现为轮询**：必须走 waiter 集合 + 结算时释放的
  事件驱动通道（同 `jobs.wait` 的 `event.awaited` 语义）；轮询是 P2 兜底，非本 task。
- **禁止改变 `whenIdle()` 缺省语义**：不传 `timeoutMs` 必须与现状逐字节等价。
- **禁止新增持久化/数据 schema**：waiter 集合是内存态，不落盘。
- **禁止动 GUI/前端**（P2 边界）。

## 可观测性 / 日志契约

核心业务路径 = 等待-结算通道。声明埋点（统一 `log.info("msg", key, value)`，
`ctx.logger` 结构化）：
- **等待注册点**（`waitSettlement` 入口）：`log.info("subagent wait registered", childId, timeoutMs)`
- **结算释放点**（waiter 释放）：`log.info("subagent settlement released", childId, waiters)`
- **超时返回点**：`log.info("subagent wait timed out", childId, elapsedMs)` —
  waiters=0 或超时路径，供运行时契约脚本按 key 解析（P1/P2 期接）。
- **`whenIdle` 超时路径**（agent 层）：`log.warn("agent idle wait timed out", agentId, elapsedMs)`。

## 数据不变量

本 task 无业务数据链（不读写业务数据、无 source→sink）。waiter 集合与 `lastActivityAt`
是**内存运行时态**，非持久化数据；其生命周期约束（结算必释放全部 waiter）是
**决策约束**（代码路径保证），非数据不变量。故**无数据不变量**。

## 数据 UT

无（本 task 无数据不变量，见上节）。本节无落点。

## 影响面

- **必须修改**：
  - `packages/core/agent-loop/src/agent.ts`（`whenIdle` L650-655 加超时；
    `setPhase` L558-565 旁维护 `lastActivityAt`）
  - `packages/subagent/subagent/src/continuation-activation.ts`
    （waiter 集合 + `notifySettlement` L864 后释放；`watchSettlement` L729 有限等待）
  - `packages/subagent/subagent/src/index.ts`（服务方法 `waitSettlement`，L279-393 区）
  - `packages/subagent/tool-subagent-control/src/wait-settlement.ts`（**新增**工具）
  - `packages/subagent/tool-subagent-control/src/index.ts`（注册新工具，L28-111 区）
  - `packages/subagent/subagent/src/types.ts`（`WaitSettlementOutcome`/返回类型，若需）
- **需要验证**：`core/agent-loop/tests/loop.spec.ts`（whenIdle 回归）、
  `tool-subagent-control/tests/list-agents.spec.ts`（工具注册回归）、
  `subagent/tool-subagent` 相关 host 测试。
- **仍待调查**：无。

## 开放决策

无（本 task 的取舍均在既有范式内向后兼容扩展，无待 owner 拍板项）。
