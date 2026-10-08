---
project: deepseek-harness
target: subagent-active-status
node: review
round: 1
conclusion: 建议先改再合
tsd_content_sha: c7c8b561b7a6849564612a585cc98096d53b4c165ade21c71d16f38703a1ad9c
date: 2026-10-03
---

# 报告评审 · subagent-active-status（review 节点，claude runner）

> 评审对象：`.harness/reports/deepseek-harness-subagent-active-status-verify.md`
> （verify 阶段产物）。LLM-as-judge 对账 + 人工复核。

## 评审维度

报告证据可信度（数字必须有落盘来源）/ 结论与证据一致 / 归因诚实性 /
CI 权威入口声明可执行性。

## 发现清单

### blocking

- **[blocking] Coverage 数字无落盘证据** — verify.md L52-61 声称「7 文件 include」但表格
  只有 6 行（缺 types.ts），且 `.harness/reports/` 无任何 coverage 日志、`coverage/`
  目录不存在。CONTRACT-001 rung-3「断言空跑视为未落盘」——数字无来源即视为未声明。
  **复核确认属实**：`.harness/reports/` 实测无 coverage 产物；TEMP 里有多次
  `npx vitest run --coverage` 的真实运行日志（cov-full/cov-pass/cov-scoped/cov-sub*.log），
  但报告未引用、未把证据落盘进 `.harness/reports/`。修复方向：将 coverage 日志与
  产物落盘进 `.harness/reports/` 并让报告引用具体路径（`coverage/` include 配置
  与表格行数对齐，补上 types.ts）。
- **[blocking] corpus「364 passed|1 skipped（18 文件）」无任何落盘日志** — verify.md L42
  的核心测试套件结论没有对应的 vitest 运行日志落盘，无法复核通过数、跳过数、文件数。
  **复核确认属实**：`.harness/reports/` 无 corpus 运行日志。修复方向：corpus 跑完后
  把 vitest 输出落盘为 `.harness/reports/corpus-vitest.log` 并让报告引用。
- **[blocking] agent.ts 覆盖率缺口归因不实** — verify.md L81-83 称 agent.ts 覆盖率
  （70.84/60.86/75/72.25）为「同源 win32 预存缺口」，但 SHELL_PREFERENCE_HINT 注入仅
  L763-764 两行，真实主因是窄 include + 本 work-unit 未提交的 STALL 机制使仓库
  per-file 100% 门禁对 agent.ts 实为红，被包装成「预存黄项」。**复核说明**：agent.ts
  的 agent-loop 工作树确混入多份非本 work-unit 改动（action-registry/job-journal/STALL
  机制），归因表述「同源」不准确；判定由 LLM 给出，指向的报告内部一致性问题成立——
  归因至少应拆清「本 work-unit 引入的窄测试面」与「win32 预存差异」两条。

### important

- **[important] 「CI 权威入口」声明无执行点** — verify.md L15 声称 CI 是权威入口，但
  `.github/workflows/ci.yml` 只跑 `pnpm exec vitest run`（L684），未引用
  `ci/bin/contract-subagent-active-status.sh` 契约脚本。**复核确认属实**（grep CI 工作流
  无 contract 脚本引用）。

### nit

- **[nit] tsc 四包 exit 0 无日志** — verify.md §4 的 tsc 结论无命令输出落盘，无法复核。

## 结论

建议先改再合。3 个 blocking + 1 个 important + 1 个 nit。verify 报告的三大核心数字
（coverage / corpus / 归因）均缺落盘证据或归因失真，需回 verify 阶段补证据、对齐
include 配置、修正归因措辞后再合。

JUDGE_VERDICT: block
