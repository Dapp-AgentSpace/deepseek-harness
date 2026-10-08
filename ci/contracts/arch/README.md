# 架构契约（arch.md）模板库

per-stack 架构最佳实践基线。`harness-scaffold.sh` 按探测到的栈选本目录模板，注入机器采集的 facts，
生成 `.harness/contracts/arch.md`（架构契约声明，judge 执行）。

## schema（四带）

arch.md 四带（ADR-0006 三带 + human experience 人工约束）：

| 带 | 来源 | 含义 |
|---|---|---|
| facts | 机器采集（scaffold，确定性） | 栈 / base package / 子模块 / 分层目录 / 架构画像（框架/ORM）；不承载判断 |
| boundaries | 本目录模板（基线）+ owner 增删 | 依赖方向 / seam / 模块职责 |
| semantics | owner 人工 | 为什么这么分、什么变化归哪个模块 |
| constraints | owner 人工（human experience） | 每条须回指执行点（CONTRACT-001） |

## 栈 → 模板映射

| stack_detect | 模板 |
|---|---|
| maven / gradle | java.md |
| go | go.md |
| rust | rust.md |
| npm | npm.md |
| python | python.md |
| shell | shell.md |
| unknown | unknown.md（greenfield 冷启动前） |

> `架构画像`（facts 行）由 `harness-stack.sh` 的 `stack_profile()` 从构建清单 grep 框架/ORM 信号得出
> （确定性事实，只当导航、不判好坏），如 `framework=spring-boot orm=mybatis`、`framework=gin`、
> `framework=django`。无信号即空，写「（未识别框架/ORM）」。它比 stack_detect 的单标签更细，但仍不是判断。

## 扩展

- 新增栈：加一个 `<lang>.md`；同语言不同构建工具（maven/gradle）映射到同一 `<lang>.md`。
- 部署：本目录随 `ci/` 整体同步（upgrade.sh 的 `cp -r ci/`），目标项目运行 scaffold 时从
  `ci/contracts/arch/` 读取；不依赖 suite 根 `templates/`（那只是 harness-init 播种 identity/attention 的参照）。
