# 上游同步执行报告：0.2.1-alpha.2（2026-10-11）

> 范围：`deepseek-ai/deepseek-harness` master（release-0.2.1-alpha.2，Merge PR #5946）
> → 本仓（Dapp-AgentSpace fork）工作分支 `sync-upstream-0.2.1`。
> 合并方式：`git merge --no-commit --no-ff upstream/master`（**未 commit、未 push**，等待 owner）。

---

## 一、合并概况

| 项 | 值 |
|---|---|
| 工作分支 | `sync-upstream-0.2.1`（当前 **MERGING**：All conflicts fixed but you are still merging） |
| merge-base | 上游 0.2.0-rc.2 分叉点（`git merge-base HEAD upstream/master` 可查） |
| 上游版本 | release-0.2.1-alpha.2（Merge PR #5946） |
| 合并规模 | 6262 文件，+165246 / -59980 |
| 冲突 | 全部解决，无未解决冲突 |
| 提交状态 | **未 commit**（遵守授权边界，等待 owner 指示） |

---

## 二、已完成工作

1. **merge 落地**：`git merge --no-commit --no-ff upstream/master` 到 `sync-upstream-0.2.1`，冲突全部解决。
2. **type-equivalence 修复**：`verify-type-equiv` 从 DRIFT 479 处 → **479/479 通过**（`core.md` 补 `lastActivityAt` + `whenIdle` JSDoc，与 fork 定制签名一致）。
3. **build 根因修复（13 残留目录）**：tsdown workspace glob 匹配到 13 个**无 package.json 的残留目录**（upstream 已删除的包的旧 node_modules / lib 占位，git 完全不跟踪）→ 它们继承根 tsdown.config.ts（workspace + entry `lib/types/{index,startup}.js`）→ readPackageJson 向上找到根 package.json → nameLabel=`@deepseek-ai/dsh-root` → 在残留目录 cwd 下匹配不到 entry → 报 `Cannot find entry: ["lib/types/{index,startup}.js"]`。**删除 13 个残留目录后 build:lib:host PASS**（upstream CI 无此问题：干净 checkout 无残留目录）。
   - 残留目录清单（旧包名，位置均在 `packages/*/` 下）：schedule-bundle、hook-protocol、hooks-claude-code、hooks-codex、invariants、tool-session-query、skill-badge、session-title-all-prompts-llm、subagent-in-process-driver、tool-terminal、webhook、webhook-github、tool-ralph。
4. **build gate TS6053 修复（tsbuildinfo 污染）**：check:all 中 build gate 失败 `TS6053: File '.../ui-trajectory/tests/oxlint-contract-<uuid>.client.ts' not found`——lint gate 生成 oxlint-contract 临时契约文件后删除，但 **tsc -b 增量缓存（tsbuildinfo）记录了该临时文件路径**，后续 build 的 tsc 增量编译引用已删文件 → 失败。**删除 3 个被污染的 tsbuildinfo**（根 `tsconfig.host.tsbuildinfo`、`ui-trajectory/lib/tsconfig.tsbuildinfo`、`ui-primitives/lib/tsconfig.tsbuildinfo`）→ **`pnpm run build` 重跑 PASS（exit 0）**。单独跑 build:lib:host 一直 PASS 的原因：无 lint gate 并发产生临时文件。
5. **资产回归确认**：`scripts/verify-upstream-assets.sh` **9 项定制资产全部在场**（wait_settlement 工具、waitSettlement 服务 API、SubagentWaitOutcome 类型、agent-loop 防卡死 STALL/STREAMING 上限、进度通知、重复防护、whenIdle/lastActivityAt 签名修正）。
6. **其余通过项（check:all 内）**：optional dependency imports、plugin record callers、build:web、duplication、constraints、default product isolation、documentation build、doc graphs、markdown links、type equivalence、cordis catalog、Cordis inspect catalog、workflow guest source、verify-mermaid、client catalog、export jsdoc、tool catalog、config catalog、skill plugin package list、npm dependency catalog、persistence catalog、released persistence history、Session format catalog、public repository links、repository references、doc refs、subsystem pages、package paths、tsconfig paths、config source ownership、package README 系列、agent note 系列、skill invocation metadata、translation prompt、upgrade guides、documentation standard tests、documentation site checks、module graph、runtime closure、test（部分）、Weighted approval policy、Issue management policy、product package classification、Official bundle catalog、package dependencies、application entrypoints、DSH package licenses、client packages、client UI i18n、client route resolution、proxy-aware dispatchers 等。

---

## 三、check:all 完整分诊（12 个 FAILED）

> `npx tsx scripts/run-gates.ts check-all` 完整跑通，12 个 FAILED 逐一分诊如下。

| # | Gate | 耗时 | 分诊结论 | 类型 |
|---|---|---|---|---|
| 1 | **build** | 272.6s | tsbuildinfo 污染（lint 临时文件残留引用）→ **已修复并重跑 PASS** | ✅ 已修复 |
| 2 | **Cordis config** | 9.3s | `apps/cli/tests/profiles/acp/cordis.yml` 是 git symlink（mode 120000），Windows `core.symlinks=false` checkout 成 59 字节文本 → 校验"root must be a Loader entry array"。upstream CI（Linux）symlink 正常 | 🖥️ Windows 环境基线 |
| 3 | **CLI help reference** | 34.6s | `dsh <profile> --help` 加载整个 profile 树后退出。Windows 冷 tsx 缓存下大 profile（acp 18.5–31.6s、web 42.9s、sdk 28.6s）超 30s 超时被 SIGKILL；预热后 web 降至 17.5s。PROFILE_TEMPLATES 与 merge 前一致（acp/web/headless/sdk），**非 merge 回归**，纯 Windows 性能 | 🖥️ Windows 环境基线 |
| 4 | **client domain graph** | 7.4s | upstream 自带（ui-settings-account 等 assets 导入） | ⬆️ upstream 自带 |
| 5 | **vendor rescope** | 212.6s | upstream 自带 | ⬆️ upstream 自带 |
| 6 | **no new unknown casts** | 56.0s | 6 处：agent.ts:382、job-journal.spec.ts:264/271/332、server.spec.ts:427、wait-settlement.spec.ts:24 | 👤 owner 决策项 |
| 7 | **markdown wrap** | 86.1s | AGENTS.md:188/193/195 fork 定制中文段落硬换行，不合 upstream verify-md-wrap 规范 | 📄 fork 文档债基线 |
| 8 | **translation pairing** | 311.2s | fork 文档债基线 | 📄 fork 文档债基线 |
| 9 | **concrete terms** | 79.6s | `ci/constraint-model.md:57`、`ci/work-unit-schema.md:19` provenance 措辞不合规 | 📄 fork 文档债基线 |
| 10 | **doc budgets** | 0.6s | AGENTS.md 2023 词超 1960 上限（fork 定制内容） | 📄 fork 文档债基线 |
| 11 | **persistence type history** | 35.7s | `verify-persistence-changes` 报 **4 处 unacknowledged persistence type changes**（均与 `agent-loop-progress` source union 相关，含 `event:session/title-llm-request.data.messages[]`）。merge 引入的真实类型变化，需兼容性审查后新增 acknowledge 记录 | 👤 owner 决策项 |
| 12 | **Session format references** | 18.5s | `verify-persistence-formats` 报 historical-formats README×3 过期（merge 类型变化的连带产物），需 `--write` 重新生成（会改 tracked 文档） | 👤 owner 决策项 |

---

## 四、纠错经过（诚实记录）

1. **tsdown resolveWorkspace 理解纠正**：最初误判"根 lib/types 必须存在"方向，实际根因是残留目录继承根 config。已读 tsdown build 产物 `resolveWorkspace` 精确代码确认：**auto 模式** = glob 所有 package.json 后 `resolve(rootCwd, file, "..")`（父目录）；**显式 include 模式** = `glob(packages, {onlyDirectories, absolute})` 直接 `resolve(file)`（**无 ".." 映射**）→ **workspace 成员 = 包目录本身**。13 个残留目录（无 package.json）被 glob 匹配 → 继承根 config → entry 找不到。
2. **cordis-config 早期方向**：最初怀疑是 merge 回归，实测确认是 Windows `core.symlinks=false` 下 git symlink checkout 成普通文本的环境基线，非代码问题。
3. **cli-help 早期方向**：最初怀疑 acp app `--help` 处理逻辑缺失，读 `parseCmdline`（dsh-cmdline）确认 help 会 `exit(0)` 触发 shutdown；实测隔离环境 + 预热后正常退出（17.5s）——纯性能问题。

---

## 五、owner 决策项

| # | 事项 | 说明 | 建议 |
|---|---|---|---|
| 1 | **persistence 4 处类型变化 acknowledge** | merge 后 `agent-loop-progress` source union 变化（含 title-llm-request messages[]）。需审查兼容性后新增 `docs/persistence-changes/` acknowledge 记录 | 若接受 upstream 类型变化 → 写记录；若不接受 → 保持 fork 类型 |
| 2 | **Session format references --write** | 重新生成 historical-formats README×3（tracked 文档，会改文件） | 与 #1 联动决策 |
| 3 | **no new unknown casts 6 处** | 已知项（wait-settlement 等 fork 代码） | 更新 baseline 或修代码 |
| 4 | **experimental/hooks-claude-code whenIdle mock** | upstream 为 `Promise<void>`，fork 适配（`'idle' \| 'timeout'`）丢失，待评估重放 | 若 fork 依赖该适配则重放 |
| 5 | **invariants 子系统移除** | upstream 删除 runtime-diagnostics/invariants 包（本地残留已清），fork 是否依赖 | 确认无依赖则接受 |
| 6 | **根 tsdown invariant entry 丢失** | 根 tsdown.config.ts entry `lib/types/{index,startup}.js` 随 invariants 删除后无产出，是否保留该 entry | 若不再需要则移除或改 |
| 7 | **fork 文档债** | markdown wrap / translation pairing / concrete terms / doc budgets（AGENTS.md 超限 + 中文段落硬换行 + ci/*.md 措辞） | 择期还债或 baseline |
| 8 | **Windows 环境基线** | cordis-config（symlink）、CLI help reference（性能）在本机必然失败 | 若需本地门禁全绿，考虑 Windows 专属豁免/超时调整（改 upstream 脚本需谨慎） |

---

## 六、边界与下一步

- **未做**：`git commit`、`git push`（授权边界，等待 owner 指示）。
- **merge 保持 `--no-commit --no-ff`**：HEAD 未移动，工作树即合并结果，随时可 review / commit / 丢弃。
- **下一步（owner 决策后）**：
  1. 决策项 #1/#2（persistence acknowledge + 文档重生成）
  2. 决策项 #3–#6 逐个确认
  3. 决策后重跑 check:all 到全绿（或确认基线清单）
  4. 确认后 commit（由 owner 决定时机与分支策略）
