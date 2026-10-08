---
project: deepseek-harness
target: subagent-active-status
node: review
round: 1
conclusion: 建议先改再合
tsd_content_sha: c7c8b561b7a6849564612a585cc98096d53b4c165ade21c71d16f38703a1ad9c
date: 2026-10-03
---

# TSD 评审 · subagent-active-status（review 节点，claude runner）

> 评审对象：`.harness/tsd/deepseek-harness-subagent-active-status.md`（frozen，
> content_sha=c7c8b561…，work_sha=38c01a4e…）。LLM-as-judge 对账 + 人工复核。
> 复核说明：本记录由评审执行者落盘，judge 原始判定忠实记录，复核后修正的严重度
> 在对应条目标注「复核降级/复核确认」。

## 评审维度

验收可测性 / CONTRACT-001（断言空跑视为未落盘）/ REQ-002（隐藏真实取舍）/
DATA-003（无数据不变量）/ 反 TSD 模式一致性 / 影响面与实现吻合度。

## 发现清单

### blocking

- **[目标与验收 #7] watchSettlement「陈旧走告警路径」无可失败判据（C-6.2 假绿）** —
  契约脚本 `ci/bin/contract-subagent-active-status.sh:73` 的 C-6.1「超时后复查
  lastActivityAt 新鲜度」只 grep `lastActivityAt` 出现在 `continuation-activation.ts`，
  而该 token 在 waitSettlement 投影（continuation-activation.ts:922）与
  settledProjection（:872）无关出现——删掉 :749-754 的陈旧复查/告警逻辑 grep 仍通过，
  C-6 对该验收子行为不可能判红（CONTRACT-001 rung-3「断言空跑视为未落盘」）。
  同一分支被 v8-ignore（:746-756）排除在单测覆盖外。验收 #7 的「陈旧→告警」子行为
  无任何可失败校验。**复核确认属实**（已读契约脚本 L71-73 与 continuation-activation.ts
  相关行）。

### important

- **[开放决策 / 契约变化] 「无开放决策」声明与 `whenIdle` 公开接口变更的取舍不符** —
  返回类型 void→`'idle'|'timeout'`（runtime-types.ts:198）是真实公开接口变更，TSD 以
  「返回值被忽略→无感知」声明为无开放决策。全仓测试桩存在类型不匹配：
  `packages/api/job-controller/tests/host-harness.ts:36`、`packages/api/remotes/tests/built-lib.e2e.ts:108`、
  `packages/api/session-controller/tests/archived-session-gate.host.spec.ts:41`、
  `packages/api/job-controller/tests/observe.host.spec.ts:241`、
  `packages/deliverables/tool-present/tests/present.spec.ts:46`、
  `packages/core/agent/tests/agent.spec.ts:35`、`packages/core/agent/tests/archive-admission.spec.ts:30`、
  `packages/core/agent-loop/tests/inbox.spec.ts:37` —— 均 `whenIdle: () => Promise.resolve()`
  （返回 `Promise<void>`），且 `host-harness.ts:23-38` 的 `Agent & {disposeScope}` 字面量
  缺新增必填成员 `lastActivityAt`。**复核降级：blocking → important**。judge 原判
  blocking（「双重复合破坏」），复核后确认：这些是 vitest 测试桩，vitest transpile-only
  不查类型，api 包 tsconfig（tsconfig.host.json files 仅 src/*）不含 tests/，生产调用点
  （`packages/bundle/headless/src/index.ts:353,369`、subagent dispose 等）均
  `await agent.whenIdle()` 不 care 返回值 → **无运行时破坏、无生产调用点破坏**。真实
  问题是测试桩类型兼容性隐患 + TSD「无感知」声明过于乐观（REQ-002 未挂 D/A/I）。
- **[影响面] `wait_settlement` 注册方式与 TSD 影响面声明不符** — 影响面列
  `tool-subagent-control/src/index.ts（注册新工具）` 为必须修改，但 index.ts 未改
  （inject=['tools','subagents'] 无 'agents'）；实现采用 list_agents 同族独立模块。
  TSD「inject 与 list_agents 同族」（指向独立模块）与「index.ts 注册」自相矛盾。
  建议 TSD 修订影响面措辞或交代 index.ts 不变更的理由。
- **[反 TSD 模式声明] CONTRACT-001 落盘映射不完整** — 「禁止改 notifySettlement 丢失
  恢复」「禁止动 GUI」无任何落盘校验（契约脚本只覆盖 C-7 三条：setInterval ×2、
  持久化依赖），TSD 也未声明 `enforcement: judge`。实现当前未越界，但按 rung-1 这两条
  强制力仅剩 review。

### nit

- **[反 TSD 模式声明] C-7.1 只拦字面 `setInterval`**，setTimeout 递归轮询不会被抓；
  事件驱动属性由行为测试保证，非阻断。

## 确认无误

- DATA-003「无数据不变量」成立：waiter 集合是实例私有内存 Map，`lastActivityAt` 是
  内存属性非 session 存储字段；结算必释放 waiter 是代码路径保证（dispose），有并发测试。
- REQ-001 五维均落实质内容。
- 验收 #1-6、#8 均有实质断言可失败；反 TSD 五条禁止实现均未越界。

## 结论

建议先改再合。1 个 blocking（C-6 陈旧告警判据假绿）+ 3 个 important + 1 个 nit。
blocking 未解决不得合入：需为验收 #7「陈旧→告警」补可失败判据（契约锚点收紧或行为测试）。

JUDGE_VERDICT: block
JUDGE_METRIC: plan.w2h_completeness=100
