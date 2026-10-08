# 项目 checklist · build（构建与测试门禁域）

> 本 work-unit（subagent-active-status，P0 wait_settlement 闭环）沉淀的确定性门禁纪律。
> project-local；晋升 shared 需 owner 显式授权。

---
id: DSH-BUILD-001
category: process
project: deepseek-harness
status: project-local
domain: build
severity: blocking
check_mode: judge
---

## DSH-BUILD-001 vitest coverage 门禁跑法：精确 include + 精确文件列表

规则：仓库 `vitest.config.ts` 的 coverage include 是全仓库（`packages/*/*/src/**/*.{ts,tsx}`）且
per-file 阈值 100%。跑覆盖率时：
1. 任一测试失败会**吞掉整个 coverage 表**（v8 抑制），先保证 corpus 全绿；
2. `--exclude` 对 positional 目录无效（被 positional 覆盖），必须用
   `--coverage.include=packages/<scope>/...` 逐文件限定目标；
3. corpus 用**精确通过的 spec 文件列表**（而非目录），避免引入已知失败/无关文件拖低阈值。

适用：本仓库任何带 coverage 门禁的 work-unit。
不适用：无 coverage 门禁的纯 lint 检查。
证据：subagent-active-status verify（`.harness/reports/deepseek-harness-subagent-active-status-verify.md`）——
初跑三因（失败吞表/全仓库 include/--exclude 无效）逐一定性后，18 文件 364 passed 时 4 个
work-unit 文件 coverage 全 100%。

---
id: DSH-BUILD-002
category: correctness
project: deepseek-harness
status: project-local
domain: build
severity: important
check_mode: judge
---

## DSH-BUILD-002 v8 ignore 分支边界：ignore 起点要覆盖 `if` 行本身

规则：`/* v8 ignore start */` 若放在 `if (...) {` 的**体内**，只忽略语句，不忽略 `if` 分支本身——
v8 仍会报该 if 的未覆盖分支。要让整个分支（含条件行）豁免，必须把 ignore 起点**上移到 if 之前**，
并在注释里写清不可达原因。

适用：为"单测不可达"的守卫分支（如 60s 定时器臂）补 v8 ignore 时。
不适用：可达分支——可达分支必须用确定性测试覆盖，不能用 ignore 掩盖。
证据：`packages/subagent/subagent/src/continuation-activation.ts` watchSettlement 超时臂
（60s 预算单测不可达）——初版 ignore 在体内，branch 98.11% 报 L746；上移后 100%。

---
id: DSH-BUILD-003
category: correctness
project: deepseek-harness
status: project-local
domain: build
severity: important
check_mode: judge
---

## DSH-BUILD-003 tools 注册表抛错语义：execute 抛异常 → isError 结果，非 rejects

规则：`tools` 注册表（`packages/core/tools/src/index.ts`）会把 execute 抛出的异常捕获为
`toolErrorResult`：返回 `{ content:[{type:'text',text:'Error: ...'}], isError:true, error:{...} }`，
**不会 reject**。agent-less 工具测试断言用 `result.isError === true` + text 含错误信息，
不要 `await expect(...).rejects`。

适用：本仓库工具插件（`tool-subagent-control` 等）的 agent-less 错误路径测试。
不适用：非工具（服务层）直接抛错仍正常 rejects。
证据：`packages/subagent/tool-subagent-control/tests/wait-settlement.spec.ts`（agent-less caller
isError 测试）；`packages/core/tools/src/index.ts` `toolErrorResult(error)`。

---
id: DSH-BUILD-004
category: correctness
project: deepseek-harness
status: project-local
domain: build
severity: blocking
check_mode: judge
---

## DSH-BUILD-004 结算等待的确定性测试：孙代理等待态 + 外部 abort

规则：测"子代理结算等待"的确定性状态，两种模板：
1. **孙等待态（inactive 投影）**：`ctx.subagents.startContinuable(startSpec(child))` 建孙代理
   （GatedAdapter 持住孙），子 turn 完成后 `ownedChildren.size > 0` → 子 idle+resident 且
   settlementState 'wait'（持久，kick 自动唤醒只对 pending inbox 生效，不打扰孙等待态）→
   `waitSettlement(childId, shortTimeout)` 返回 `{settled:false, agent.status:'inactive'}`。
2. **外部 abort（非超时）**：`const pending = ctx.subagents.waitSettlement(childId, ms, controller.signal)`
   后立即 `controller.abort()`（executor 同步注册 waiter，命中 onAbort）→ 返回投影且
   不写 'subagent wait timed out' 日志。

适用：subagent 结算/等待相关测试。
不适用：无需结算时序的纯工具 schema 测试。
证据：`packages/subagent/tool-subagent-control/tests/wait-settlement.spec.ts`（孙等待态 inactive 投影、
外部 abort 两测试，覆盖 continuation-activation.ts L921/L940 分支）；模板源自
`packages/subagent/subagent/tests/continuation.spec.ts`（'wakes a waiting Activation'）。
