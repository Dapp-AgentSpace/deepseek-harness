---
project: deepseek-harness
target: subagent-active-status
node: quality
round: 1
conclusion: 建议先改再合
tsd_content_sha: c7c8b561b7a6849564612a585cc98096d53b4c165ade21c71d16f38703a1ad9c
date: 2026-10-03
---

# 质量验证 · subagent-active-status（quality 节点，claude runner）

> 元治理评审：本 TSD 的质量治理闭环（门禁/checklist/运行时契约/评审落盘）是否真实
> 有效、可信度几何。LLM-as-judge 对账 + 人工复核。

## 评审维度

评审结论落盘闭环 / verify 报告证据可信 / CI 门禁执行点 / 运行时契约与声明一致性 /
checklist 消费缝 / 元治理指标（false_green、false_positive_rate、routing_accuracy）。

## 发现清单

### blocking

- **[B1] review 节点判定未落盘为 ReviewRecord** — 评审结论（tsd/report/audit/quality
  四目标）此前只存在于 TEMP 输出，`.harness/reports/` 无任何 `*-review.md`。
  `audit_checks.py:142`（review_landing）对「从未落盘」不可见，`review_record.py:196`
  收集不到 → close 会在 review 实际红时毕业（假闭环）。**本记录即为修复动作**：本次
  落盘 tsd/report/quality 三份（audit 待节点完成后补），B1 对本 TSD 已闭环；但作为
  发现本身成立——judge 输出与 ReviewRecord 落盘之间无机制强制，靠执行者事后落盘。
- **[B2] verify 报告两大绿柱无落盘证据 + agent.ts 归因失真** — 同 report 节点
  blocking ①②③（corpus 364/coverage 数字无日志落盘、agent.ts 归因「同源 win32 缺口」
  与真实主因不符，agent.ts 工作树 diff +551/-20 混入多份非本 work-unit 改动）。
  复核同 report，不重复。

### important

- **[I1] `ci/workflows/quality-gates.yml:26,29` 不被 GitHub Actions 发现** — 该工作流位于
  `ci/workflows/`，GitHub Actions 只认 `.github/workflows/`，故文件无执行点。
  `attention.md:7`「权威门禁在 CI」声明无实际接线。复核：CI 里只有
  `.github/workflows/ci.yml` 跑 vitest（L684），确认无执行点。
- **[I2] runtime-check.yml schedule 移除后仅手动 dispatch** — `harness-runtime-check.sh:30-34`
  无域时 exit 0（诚实非假绿），但运行时契约检查不再定时触发。TSD 声明 P1/P2 期接入 →
  属声明内延期，需在 close/attention 显式记录。
- **[I3] checklists/build.md DSH-BUILD-001..004 均 `check_mode: script` 无消费方** —
  `harness-checklist-ls.sh:78` 只注入 `check_mode: judge` 项，script 类清单项无人消费。
  属 quality 阶段已知缺口（I3），不影响本 TSD 验收但属治理债务。
- **[I4] 13:49 四次 judge 因模型不可用全无产出** — 根因 `identity.yaml` judge.model 为空
  走 settings.json 坏默认模型；已修复为 `claude-sonnet-4-5-20250929`（identity.yaml:43）
  后重跑成功。修复已验证，属已解决的运行事件，记录留痕。

### nit

- **[N1] verify.md:23「C-1 9/9」实为 10 项** — `contract-subagent-active-status.sh:45`
  的 forbid「无 default 导出」是第 10 项，报告计数 9/9 不实；pass=32 自洽（forbid 通过
  计 1）。复核确认：C-1 段确含 10 条 req（L36-45）。报告计数需修正为 10/10 或注明
  forbid 口径。
- **[N2] tsc 无日志** — 同 report 节点 nit。

## 半改动实例

- 实例 A（跨轮证据缺半）：verify 声称绿但无证据落盘 → report-review 判出「缺的那半」
  → 该判定本身也未落盘（B1）。三层证据链均未闭环，本次落盘后补最后一环。
- 实例 C（声明无接线）：attention.md:7「CI 权威门禁」声明 vs CI 实际只跑 vitest 无契约
  脚本接线（I1）。

## 归属域正确性

R4 全部通过：发现的归属域（report→report 节点、quality→quality 节点）与目标登记表
一致，无跨域错放。

## 指标

- verify.false_green=2（corpus/coverage 无据）
- review.false_positive_rate=0/2（抽查的 2 条 blocking 均未被证伪）
- close.routing_accuracy=2/2

## 结论

建议先改再合。2 个 blocking（B1 落盘闭环、B2 证据）+ 4 important + 2 nit。
B1 已由本次落盘闭环；B2 需回 verify 补证据。quality 节点自证：其结论此前只在 TEMP，
正是 B1 的实例。

JUDGE_VERDICT: block
JUDGE_METRIC: verify.false_green=2
JUDGE_METRIC: review.false_positive_rate=0/2
JUDGE_METRIC: close.routing_accuracy=2/2
