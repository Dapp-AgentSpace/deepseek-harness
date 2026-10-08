# attention — 本仓库每次 harness 任务开工必读

> 高频必读事实，全文 ≤25 条，超限先合并再新增。
> 每条一行：`- 事实（来源路径）`

- 项目标识 project.id 见 `.harness/identity.yaml`，所有 harness 产出必须携带它。（identity.yaml）
- 确定性权威门禁在 CI，不在 agent；门禁脚本入口 `ci/bin/harness-gate.sh`。（ci/README）
- 本仓库是 DeepSeek Harness（dsh）开源源码仓库：packages/ 是 Cordis 插件工作区，改 packages/ 前先读 docs/architecture.md。（AGENTS.md / README.md）
- 共享 checklist 来源 = suite checkout 的 `checklists/shared/`（`identity.yaml` 的 `checklist.shared_store`），loader 实时读、git pull 刷新。（harness-checklist-ls.sh）
- 本机环境解析见 `.harness/toolchain.env`（`ci/bin/harness-preflight.sh` 生成，本机缓存、**不入库**）；需求单源在 `identity.yaml` 的 `toolchain:`。（harness-preflight）
- judge 节点 `runner=claude` 依赖环境变量 `ANTHROPIC_AUTH_TOKEN`（本机设在 Windows 用户环境 `HKCU:\Environment`）；DSH 沙箱子进程会剥离它，故跑 harness 前须先把该变量注入 shell，否则 contract/quality 节点报 `Not logged in`。（identity.yaml judge.nodes / harness-llm.sh）
