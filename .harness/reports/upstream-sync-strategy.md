# 上游同步策略：deepseek-ai/deepseek-harness → 本仓（Dapp-AgentSpace fork）

> 目标：定期同步官方 master 最新能力，同时**保护本仓优化不被覆盖**；每次合并前
> 必须分析上游是否已实现与本仓相同的优化，据此决定「保留本地 / 采用上游 / 重放移植」。

---

## 一、现状诊断（2026-02 实证）

### 1.1 仓库拓扑
| 项 | 值 |
|---|---|
| 本仓 fork | `git@github.com-p:Dapp-AgentSpace/deepseek-harness.git`（origin，person 身份） |
| 上游官方 | `https://github.com/deepseek-ai/deepseek-harness.git`（**当前无 upstream remote**） |
| 分叉点（merge-base） | 上游 `0.2.0-rc.2`（Merge PR #5479，hash 见 git merge-base） |
| 上游当前 master | `0.2.1-alpha.2`（Merge PR #5946） |
| 本仓当前 HEAD | merge-original 分支（与 origin/master 同点） |
| 本仓独有提交 | 7 个（自分叉点起，清单见 1.2） |
| 本仓独有改动规模 | 197 文件，+21959 行 / -108 行 |

### 1.2 本仓 7 个独有提交（hash 省略，`git log --oneline merge-base..HEAD` 可查）
```
deepseek-harness: fix lint            ← 含 typecheck 全仓修复（whenIdle 签名 + lastActivityAt）
deepseek-harness: refine code
deepharness: still fix model ouput dup
deepseek-harness: fix text dep
Merge pull request #2 from Dapp-AgentSpace/refine
deppseek-harness: refine text output mass
deepseek-harness: refine code to process mass messages when output maxToken touched
```

### 1.3 本仓优化核心（需保护的资产）
- **`wait_settlement` 模型可见工具**（`packages/subagent/tool-subagent-control/src/wait-settlement.ts`，+129 行）
  → 解决「task 长时间处理主会话卡死无状态返回」的核心痛点：让模型可主动
  **等待/探测**子代理结算状态（`wait:true` 阻塞至预算 / `wait:false` 仅探活）。
- **`ctx.subagents.waitSettlement()` 服务 API 链**（continuation-activation.ts:912 实现
  → continuation.ts:243 代理 → index.ts:280 暴露），`SubagentWaitOutcome` 类型。
- continuation-activation.ts（+93）、continuation.ts（+11）、types.ts（+18）、
  index.ts（+24）。
- agent-loop/src/agent.ts（+835 行，与上游冲突，见 1.4）。

### 1.4 合并预演结果（git merge-tree --write-tree，纯计算零落地）
上游 master 合入本仓 HEAD 时 **5 个内容冲突**：

| 冲突文件 | 上游改动 | 本仓改动 | 处置建议 |
|---|---|---|---|
| `packages/bundle/headless/tests/headless.spec.ts` | 上游测试演进 | 我方 whenIdle 签名适配 | 保留上游 + 重放我方签名适配 |
| `packages/core/agent-loop/package.json` | 上游依赖变更 | 我方变更 | 逐项合并依赖 |
| `packages/core/agent-loop/src/agent.ts` | 上游 2 提交（refresh provider ctx / restore runtime ctx after compaction） | 我方 +835 行 | **重点人工审查** |
| `packages/core/agent-loop/src/index.ts` | 上游重构 | 我方改动 | 人工审查 |
| `packages/core/agent-loop/tests/loop.spec.ts` | 上游测试重构 | 我方改动 | 人工审查 |

**自动合并成功（无需人工）**：continuation-activation.ts、continuation.ts、
runtime-types.ts、goal-round-driver/src/index.ts、jobs.spec.ts 等——说明本仓优化
与上游改动**大体正交**，git 三路合并可自动处理。

### 1.5 重复优化检测结论（实证）
| 检测项 | 结果 |
|---|---|
| 上游 master 是否含 `waitSettlement` API | **否**（git grep 空） |
| 上游 master 是否含 `wait_settlement` 工具 | **否**（git grep 空） |
| 上游 subagent 自身 settlement 机制 | **有**：manager.ts（+1475 行）、`SettlementState`、`waitForChildren()`、`whenIdle()` 等待、删 run-settlement.ts |
| 判定 | 上游 settlement 是**内部服务层机制**；我方是**模型可见工具层 + 服务 API**。**非重复，我方为独有能力，必须保留** |

> ⚠️ 依赖风险：我方 wait-settlement.ts 调用 `ctx.subagents.waitSettlement()`（我方自建 API）。
> 上游重构 subagent（manager.ts / lifecycle.ts / structured.ts）后，我方 API 挂载点
> （continuation-activation 等）可能被上游重构覆盖 → 合并时需验证 API 链在新基线上仍成立。

---

## 二、同步策略设计

### 2.1 建立 upstream 跟踪（一次性）
```bash
git remote add upstream https://github.com/deepseek-ai/deepseek-harness.git
git fetch upstream            # 只更新 remote-tracking，不动工作区/分支
git remote -v                # origin(本仓) + upstream(官方)
```
> 可选：本仓若需 push 上游（PR），可用 work 身份：
> `git remote add upstream git@github.com-work:deepseek-ai/deepseek-harness.git`

### 2.2 分支模型（保护本仓改动的核心）
```
upstream/master   ← 纯上游跟踪，永远 fast-forward，绝不直接改动（只读镜像）
      │
      │ 定期 git merge upstream/master
      ▼
master（本仓产品线）  ← 本仓优化 + 上游能力，冲突在此解决
      │
      └── feature 分支（如 refine）：大优化先落 feature，PR 合入 master
```
- **用 merge 不用 rebase**：本仓已 push origin（多人/多会话协作），rebase 改写历史
  有风险；merge 保留双方历史，冲突一次性解决。
- 上游只进 `upstream/master`，本仓优化永不直接落在 upstream 跟踪分支上 → **保证不被覆盖**。

### 2.3 定期同步流程（每次合并的标准动作）
```bash
# 1) 更新上游镜像
git fetch upstream

# 2) 预演合并（只读，零落地）——先知道冲突面
git merge-tree --write-tree --messages HEAD upstream/master

# 3) 重复优化检测（见 2.5）——先判断「上游是否已做相同优化」

# 4) 确保工作区干净后执行合并
git merge upstream/master        # 冲突按 2.4 处理

# 5) 合并后全量门禁
npm run typecheck && npm run lint    # 或走 harness 门禁体系

# 6) 提交合并结果（本仓提交，不影响 upstream/master）
```

### 2.4 冲突解决框架（按冲突性质分类）
| 冲突类型 | 判定方法 | 处置原则 |
|---|---|---|
| A. 上游功能演进 | 上游改功能/结构，我方未碰该语义 | **以上游为准**，我方适配层在其上重放 |
| B. 我方独有优化 + 上游无关改动 | 两侧改同文件不同区域 | 手动合并，双方都保留 |
| C. 上游已实现等价能力 | 2.5 检测命中 | **放弃本地版，采用上游版**，删本地重复实现 |
| D. 我方优化依赖的挂载点被上游重构 | 我方 API 调用处在上游重构范围内 | 在上游新结构上**移植/重接**我方能力 |

操作要点：
- `git merge` 冲突时用 `git status` 列冲突文件，逐个 `git diff` 三路比对
  （ours/theirs/base）。
- 纯本仓侧文件冲突：`git checkout --ours <file>`；纯上游侧：`--theirs`；
  两侧都改：手动编辑 + `git add`。
- **不要用 `git merge -X theirs` 一类全局策略**——会静默丢弃本仓优化。

### 2.5 重复优化检测流程（每次合并必做，回答「上游是否已做相同优化」）
```bash
# a) 功能符号扫描（最快）
git grep -n '<我方功能符号>' upstream/master -- '<我方包路径>'
#    例：git grep -n 'waitSettlement' upstream/master -- packages/subagent/

# b) 关键词提交扫描
git log upstream/master --oneline --grep='settle\|wait\|continuation' | head -30

# c) 上游重构史：新增/删除文件
git log --diff-filter=A upstream/master -- <路径>   # 新增（上游新机制）
git log --diff-filter=D upstream/master -- <路径>   # 删除（上游重构掉）

# d) 内容级对比：上游实现 vs 我方实现
git show upstream/master:<path> 与本地实现比对语义

# e) 判定决策矩阵
#    上游有等价能力 → 采用上游，本地版废弃（C 类冲突，删本地）
#    上游无此能力   → 我方优化保留，检查挂载点是否被重构（D 类）
```

### 2.6 本仓优化资产清单（防覆盖登记表）
每次同步前核对以下资产仍在：
| 资产 | 文件 | 上游是否已有 |
|---|---|---|
| wait_settlement 工具 | `packages/subagent/tool-subagent-control/src/wait-settlement.ts` | 无 |
| waitSettlement 服务 API | continuation-activation.ts / continuation.ts / index.ts | 无 |
| SubagentWaitOutcome 类型 | subagent/src/types.ts | 无 |
| agent-loop 增强 | agent-loop/src/agent.ts（+835） | 部分（上游 2 提交） |

---

## 三、自动化建议（可选演进）

1. **同步脚本** `scripts/sync-upstream.sh`：fetch → merge-tree 预演 → 冲突报告
   → 重复优化扫描（grep 资产清单）→ 输出同步就绪摘要。合并动作仍人工触发。
2. **定时提醒**：每周一检查 `git rev-parse upstream/master` 与上次同步点差异；
   上游有更新才提醒合并（避免无谓合并）。
3. **合并后门禁**：合并即跑 `npm run typecheck`（防上游新签名破坏我方类型适配，
   如本轮 whenIdle/lastActivityAt 修复需在合并后重验）。
4. **资产清单回归**：合并后跑一遍 2.6 登记表 grep，防我方能力被上游重构静默抹掉。

---

## 四、立即建议动作（待 owner 确认）
1. `git remote add upstream`（写 .git/config，一次性）。
2. 完整预演 + 逐冲突文件三路比对（agent-loop/src/agent.ts +835 为重点）。
3. 按 2.4 处置 5 个冲突 + 验证 waitSettlement API 链在新基线上成立。
4. 合并后跑全量 typecheck/lint/test。

> 本次仅完成只读预演（merge-tree），未执行任何 merge/写入。

---

## 五、重复优化孰优孰劣：评估框架（「上游也做了同样优化，谁的更好？」）

> 前置原则：**先判定是否真的重复，再比较孰优孰劣。** 同文件 ≠ 同功能。

### 5.1 第一步：按「功能语义」判定重复，不按文件
| 错误做法 | 正确做法 |
|---|---|
| 上游改了 `agent.ts`，我们也改了 `agent.ts` → 重复？ | 看**改的是什么功能**：上游 2 提交改「上下文/请求准入」（refresh/restore provider context）；我们 +835 行改「防卡死/进度/重复防护」（STALL_HARD_LIMIT_MS、PROGRESS_INTERVAL_MS、REPETITION_GUARD）。**功能正交，非重复**。 |

判定方法：
- `git diff <base> HEAD -- <file>` 提取我方功能符号（常量/函数/类名）→ 列功能清单
- `git log <base>..upstream/master -- <file>` + `git show <上游提交>` 提取上游功能清单
- 功能清单**交集为空 → 非重复**，正常合并即可；交集非空 → 进入 5.2 比较。

### 5.2 第二步：多维评分（对真重复的功能逐项打分 1-5）
| 维度 | 看什么 | 权重 |
|---|---|---|
| 功能覆盖度 | 谁覆盖更多场景/边界（超时、取消、并发、空输入、恢复） | 高 |
| 正确性/健壮性 | 错误处理、资源释放、竞态、信号传播 | 高 |
| 性能 | 延迟、内存、CPU、无谓轮询/阻塞 | 中 |
| 设计契合度 | 是否符合官方既有范式（包边界、依赖方向、命名约定） | 中 |
| API 表面 | 易用性、可发现性、类型安全（TS 严格度）、向后兼容 | 中 |
| 测试质量 | 覆盖比例、断言强度、是否测边界失败路径 | 中 |
| 可维护性 | 复杂度（圈复杂度）、注释、死代码、魔法数字 | 低 |
| **演进风险** | **官方会持续迭代**：选官方=跟随上游免维护；选本地=每次同步都要重放补丁，漂移成本逐次累积 | **高** |

> 演进风险是**决定性权重**：除非本地显著更优（≥2 个高分维度且差距明显），
> 否则倾向采纳官方实现——本地补丁是"负债"，会随每次上游同步复利增长。

### 5.3 第三步：决策矩阵
| 比较结果 | 决策 | 操作 |
|---|---|---|
| 官方显著更好（覆盖+健壮+设计） | **弃本地，采用官方** | 删本地实现，迁移我方测试资产到官方 API |
| 本地显著更好（≥2 维度明显领先） | **保留本地**，同时**向上游提 PR 贡献** | 本地实现 upstream-化后提交官方；官方合并后本地自然消亡（最优终局） |
| 各有优势（互补） | **融合** | 官方骨架/基础 + 移植本地增量能力（例：官方做服务层 API，我们做模型可见工具层适配） |
| 难分伯仲 | **证据说话，不靠感觉** | 5.4 获取客观证据后裁决 |

### 5.4 第四步：获取客观证据的方法（不靠主观判断）
1. **微基准/压力测试**：同一负载分别跑双方实现，比延迟/内存/失败率（例：10min 流式硬限 vs 官方类似机制，压 100 并发子代理）。
2. **边界用例矩阵**：构造超时/取消/并发/空输入/进程崩溃用例，分别跑，比谁处理更稳。
3. **静态分析**：圈复杂度、依赖方向、TS 严格模式通过率。
4. **第三方盲评**：LLM-as-judge（本仓 harness-review 机制）或同事对双方实现**匿名**评审——避免"自己的代码更好"偏见。
5. **双轨运行（金丝雀）**：生产环境两版并行跑一段时间，比对真实行为数据（最有力，成本最高）。

### 5.5 本仓真实案例演示（agent-loop/src/agent.ts）
| | 本仓 | 上游 |
|---|---|---|
| 改动量 | +835 行 | +18/+19 行（2 提交） |
| 功能 | 防卡死：STALL_HARD_LIMIT_MS(15min)/STREAMING_HARD_LIMIT_MS(10min)/STALLED_OUTPUT；进度通知：PROGRESS_FIRST_MS(30s)/PROGRESS_INTERVAL_MS(60s)；重复防护：REPETITION_GUARD/TODO_GUARD；WHEN_IDLE_TIMEOUT | 上下文准入：refresh provider context / restore runtime context after compaction |
| 判定 | **功能正交，非重复**——正常合并，不需要"比谁更好" | |
| 合并注意 | 同文件大改 + 上游小改：三路合并后需人工验证两套机制共存（防卡死逻辑不受上下文准入影响，反之亦然） | |

> 一旦上游未来真做了「防卡死/进度通知」等价机制（进入 5.2 比较），按演进风险权重，
> 除非我们的实现有明确压倒性优势，否则应弃本地采用官方，把我们的边界用例迁移过去。
