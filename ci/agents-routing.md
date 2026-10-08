<!-- harness:begin -->
> 本节由 harness-suite **管理**，请勿手改；改 suite 源 `ci/agents-routing.md` 后重跑 `./upgrade.sh` 同步。

## 研发入口路由（harness）

本仓是 **harness 闭环项目**（`.harness/identity.yaml`，`project.id` 见该文件）。一切**研发诉求**——
实现新功能 / 修 bug / 重构 / 需求分析 / 跑测试 / 评审 / 收尾 / 自动接力——先经 **`harness` 入口**，
由它读项目标识择 owning 子 skill（`harness-plan` / `harness-build` / `harness-verify` /
`harness-review` / `harness-close` / `harness-run`）同轮直转。

- **不得**把研发诉求直接落到 `cs-feat` / `cs-issue` / `cs-epic` 跳过 harness。在本仓它们只作为
  harness 的**上游拆解/诊断**（由 harness 交入），不作为前门。
- 例外：用户显式点名某个 skill、只想咨询（该用哪个 / 流程怎么走）、或想了解体系时，按用户点名或
  `cs` / `harness` 的入口规则处理，不强改。

## 收尾硬门槛

- 未经 owner 授权，**不得 commit / 发布**（见 `skills/harness-close`）。
<!-- harness:end -->
