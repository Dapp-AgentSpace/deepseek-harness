---
project: deepseek-harness
task: subagent-active-status
status: declared
domain: build
enforcement: deterministic
schema_version: 1
verification: ci/bin/contract-subagent-active-status.sh
generated_at: 2026-10-03
human_reviewed: false
---

# 检查契约 · subagent-active-status（CONTRACT-001 rung 2）

> 本契约把 TSD `deepseek-harness-subagent-active-status` 的「必须 / 禁止」约束落成
> 可执行检查（CONTRACT-001 阶梯 rung 2：只有脚本才算落盘，本文档只是声明）。
> 校验入口：`ci/bin/contract-subagent-active-status.sh`（exit 0 = 通过；每条检查可单独失败、
> 可解释失败原因）。行为证明以 vitest 实际输出为准，结构检查只做快失败锚点。

## 约束清单（C-N 与脚本 check 一一对应）

### C-1 工具 `wait_settlement`（必须）
- C-1.1 独立插件 `packages/subagent/tool-subagent-control/src/wait-settlement.ts`，
  namespace 形态同 `list-agents.ts`：`export const name = 'tool-subagent-wait-settlement'`、
  `export const inject = ['tools','subagents','agents']`、`export function apply(ctx)`；
  无 `default` 导出。
- C-1.2 `defineTool` 注册 name = `wait_settlement`；schema 含 `agent_id`（required）+
  可选 `wait` / `timeout_ms`；output.schema 含 `settled` 与 `agent`。
- C-1.3 execute 需 `exec.agent`（parent），缺失时抛
  `wait_settlement requires a calling agent (exec.agent was undefined)`（同 send_message 纪律）。
- C-1.4 测试锚点：`tests/wait-settlement.spec.ts` 注册/导出形状/超时/结算/并发/非法超时全绿。

### C-2 服务 `waitSettlement`（必须）
- C-2.1 `ctx.subagents.waitSettlement(childId, timeoutMs, signal)` 服务方法存在
  （`packages/subagent/subagent/src/index.ts`，经 `requireContinuations()` 委派）。
- C-2.2 非正/非有限 `timeoutMs` 抛错（镜像 `jobs.wait` 校验：
  `!Number.isFinite(timeoutMs) || timeoutMs <= 0` → throw）。
- C-2.3 超时/中止返回当前投影（**不抛** TOOL_TIMEOUT 类错误）；未结算超时 =
  `{settled:false, agent:<当前投影>}`。
- C-2.4 子代理结算时**全部**等待者被释放（并发多 wait 均 `settled:true`）。

### C-3 `whenIdle` 超时（必须）
- C-3.1 `Agent.whenIdle(opts?: {timeoutMs?: number}): Promise<'idle'|'timeout'>`
  （`packages/core/agent-loop/src/agent.ts` + `runtime-types.ts` 接口声明）。
- C-3.2 不传参行为与现状逐字节等价（无限等待，返回 `'idle'`）。
- C-3.3 非正/非有限 `timeoutMs` 抛错（镜像 `jobs.wait` 校验）。
- C-3.4 超时路径 `log.warn("agent idle wait timed out", agentId, elapsedMs)`。

### C-4 `lastActivityAt`（必须）
- C-4.1 `Agent.lastActivityAt: number`（只读，epoch ms；`runtime-types.ts` 接口 + agent.ts 实现）。
- C-4.2 随 `setPhase`/step 推进更新（单调不减）。

### C-5 waiter 集合（必须）
- C-5.1 `continuation-activation.ts` 实例私有 waiter 集合；释放点挂在
  `finishDisposal` 的 `notifySettlement`（L864）之后；`resident.delete`（L862）在其前，
  waiter 先同步查 `resident` 绝不漏结算。
- C-5.2 日志契约字符串存在（key 级）：
  `subagent wait registered` / `subagent settlement released` / `subagent wait timed out`
  （`subagent` 包）+ `agent idle wait timed out`（agent-loop 包）。

### C-6 `watchSettlement` 有限等待（必须）
- C-6.1 `continuation-activation.ts` `watchSettlement`（L725-779）不再无限 `whenIdle()`：
  L729 处传入 `timeoutMs`，超时后复查 `agent.status` 与 `lastActivityAt` 新鲜度，
  新鲜继续等，陈旧走告警路径（不无限挂起）。

### C-7 反 TSD 模式（禁止）
- C-7.1 无轮询实现：waiter 集合事件驱动（结算时释放），新文件/改动无 `setInterval`
  轮询循环查询 agent 状态。
- C-7.2 无新持久化/schema：waiter 集合与 `lastActivityAt` 是内存运行时态，不落盘。
- C-7.3 无 GUI/前端改动（`packages/client` / `apps/web` 不受本 task 影响）。
- C-7.4 未改 `notifySettlement` 的丢失恢复（父离线/`sendWaking` 失败持久化补发）——
  语义级约束，review 人工核；脚本只锚 C-5.1 释放点位置。

### C-8 回归（必须）
- C-8.1 新增套件全绿：`core/agent-loop/tests/when-idle.spec.ts`、
  `tool-subagent-control/tests/wait-settlement.spec.ts`。
- C-8.2 关键回归无破坏：`core/agent-loop/tests/loop.spec.ts`（whenIdle 调用方）、
  `tool-subagent-control/tests/list-agents.spec.ts`（工具注册范式）。

## 校验脚本说明

`ci/bin/contract-subagent-active-status.sh` 执行：
1. 结构锚点（grep 源文件，快失败、可解释）；
2. 行为证明（vitest 跑 C-8 的四条套件，输出落 `.harness/reports/contract-vitest.log`）。
全部通过 exit 0；任一失败 exit 1 且逐条打印 `[FAIL] <约束>`。
