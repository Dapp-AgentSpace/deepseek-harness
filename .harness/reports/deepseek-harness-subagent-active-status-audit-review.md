---
project: deepseek-harness
target: subagent-active-status
node: contract
round: 1
conclusion: 建议先改再合
tsd_content_sha: c7c8b561b7a6849564612a585cc98096d53b4c165ade21c71d16f38703a1ad9c
date: 2026-10-03
---

# 契约对账 · subagent-active-status（contract 节点，claude runner）

> 声明≠落盘对账：TSD → 契约 → 校验脚本 → 代码 → 测试 → CI 接线全链路。
> 冻结范围：当前工作区变更（`.harness/` 与 `ci/` 均在列）。LLM-as-judge 对账 + 人工复核。

## 评审维度

CONTRACT-001（enforcement/verification 落盘方向）/ CONTRACT-002（公开接口改动三处同步）/
反 TSD 模式落盘 / 对账门禁约定（`${base}_check.sh` 或测试引用）/ CI 接线。

## 发现清单

### blocking

- **[B1] CONTRACT-001（rung 2 集成断裂）——校验脚本不被确定性对账门禁消费** —
  契约 frontmatter（`.harness/contracts/deepseek-harness-subagent-active-status.md:7-8`）
  声明 `enforcement: deterministic` + `verification: ci/bin/contract-subagent-active-status.sh`。
  但确定性对账门禁 `closed-loop-audit.sh:89-97` 只认两种落盘：ROOT 下
  `deepseek-harness-subagent-active-status_check.sh`（不存在）或 `src/test/tests` 测试引用
  （本仓无此目录）。当前脚本位于 `ci/bin/` 且命名不符约定 → 门禁必走 else 分支报
  「声明未落盘」fail=1。脚本本身存在且 pass=32/exit 0（verify 报告 + contract-vitest.log
  实证），但它是手动跑的，不是对账门禁发现的——「已落盘」这一声明在其唯一权威消费方
  面前不成立。**复核确认属实**（已读 closed-loop-audit.sh:76-98 与契约 frontmatter）。
  修复方向：脚本改名至 `${base}_check.sh` 约定（或让对账门禁消费 `verification:` 字段）。
- **[B2] CONTRACT-002（命中）——公开接口签名已改，canonical 文档未同步** —
  `Agent.whenIdle` 签名由 `whenIdle(): Promise<void>` 改为
  `whenIdle(options?: {timeoutMs?: number}): Promise<'idle'|'timeout'>`
  （runtime-types.ts:198、agent.ts:661）。TSD 自述「签名扩展」（TSD L65-68）——属公开
  interface 签名改动。TSD 与契约测试（C-3.1）已同步，但 canonical 文档
  `docs/subsystems/core.md:90` 仍写 `whenIdle(): Promise<void>`，且语义描述
  「resolves after quiescence」在超时返回 `'timeout'` 时已失真。TSD 声称「新增（向后
  兼容，不触发 CONTRACT-002）」不成立：规则要求 TSD、契约测试与 canonical 文档三者
  指向同一版本，此处未同步。**复核确认属实**（core.md:90 为 `whenIdle(): Promise<void>`，
  core.zh.md:94 同理）。修复方向：canonical 文档补新签名与 `'timeout'` 语义。

### important

- **[I1] CONTRACT-001（rung 1）——C-7.3「无 GUI/前端改动」无落盘路径** — 契约
  `.harness/contracts/...md:70` 的 C-7.3 在契约脚本中无任何校验（脚本 C-7 段仅 3 条：
  setInterval×2 + 持久化×1），契约文本也未声明 judge 侧执行点。事实层面 diff 满足
  （git status 无 packages/client、apps/web 改动），但「禁止」声明按 deterministic 方向
  无可执行校验。
- **[I2] CONTRACT-001（rung 1 标注不一致）——C-7.4「未改 notifySettlement 丢失恢复」**
  声明人工核、frontmatter 却标 deterministic — 契约 L72 写明「语义级约束，review 人工
  核；脚本只锚 C-5.1」，但 L7 `enforcement: deterministic`。落盘方向标注与内容不符。
  已人工核实约束语义上成立（continuation-activation.ts:962-979 notifySettlement 对
  sendWaking 失败仍仅 warn，未加持久化补发），问题在标注一致性。
- **[I3] CONTRACT-001（rung 4 未到期）——契约无定时运行回路** —
  `ci/workflows/runtime-check.yml` 注释明示「定时暂未注册：schedule 已移除，待之后再挂
  cron」，且契约脚本未进任何 CI job（全仓 CI 文件零引用）。本 work-unit 未 close，
  rung 4 按阶段未到期，但 close 前须接线。

### nit

- **[N1] TSD 影响面计划漂移** — TSD 影响面预测 `tool-subagent-control/src/index.ts`
  注册新工具，实际改为独立插件 `tool-subagent-wait-settlement`（wait-settlement.ts:18-19），
  index.ts 未改。功能满足（同 list-agents 范式、测试覆盖注册），属计划预测与实现结构漂移。
- **[N2] 契约/TSD 行号引用漂移** — C-6.1 写「watchSettlement L729 处传 timeoutMs」，
  现位于 continuation-activation.ts:744；TSD 多处行号同理。grep 锚点未依赖行号故不受
  影响，仅文档描述陈旧。

## 对账摘要

8 条目标与验收 + 5 条反 TSD 禁止 + 4 条日志契约，其中轮询禁止、缺省语义、lastActivityAt、
日志 key、行为证明（C-8，vitest 33 passed 实证）等全部真实落盘且锚点命中活代码，无假绿；
断裂集中在契约脚本命名/位置未对齐对账门禁约定（B1）、canonical 文档未随接口改动同步
（B2）、C-7.3/C-7.4 落盘方向缺口（I1/I2）、定时回路未接线（I3）。

## 结论

建议先改再合。2 个 blocking + 3 个 important + 2 个 nit。功能性实现（工具/服务/whenIdle/
waiter 集合）与测试本身扎实（33 个新增测试全绿、grep 锚点全部真实命中活代码、无假绿），
断裂点在「声明→落盘」的集成与同步。

JUDGE_VERDICT: block
