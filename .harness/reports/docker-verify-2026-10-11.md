# Docker 源码构建验证报告：Linux 干净环境（2026-10-11）

> 目的：用 Docker 从源码构建并启动 dsh，实际验证 upstream sync（release-0.2.1-alpha.2
> merge 结果，工作分支 `sync-upstream-0.2.1`，**MERGING 未 commit**）在 **Linux 干净环境**
> 可构建、可启动；并证明 Windows 环境基线 gate（cordis-config symlink、cli-help 性能）
> 在 Linux 上正常 = **非 merge 回归**。

---

## 一、结论速览

| 项 | 结果 |
|---|---|
| docker build（pnpm install + build:lib） | ✅ 成功（build6，镜像 `dsh-source-verify:2026-10-11`，5.57GB） |
| 容器内 6 步验证 | ✅ **7 断言 / 0 失败** |
| cordis-config（Windows 失败项） | ✅ **Linux PASS**（symlink 恢复生效） |
| cli-help（Windows 超时项） | ✅ **Linux PASS**（30s 内完成） |
| xlsx 依赖（cdn.sheetjs.com 黑洞） | ✅ 绕过（分段下载 + 本地服务器 + URL 替换） |

**结论**：merge 结果在 Linux 干净环境可完整构建并启动；cordis-config 与 cli-help
在 Linux 全绿，证实此前 Windows 上的失败均为**环境基线**（symlink checkout 文本化 /
tsx 冷缓存性能），**非 merge 回归**。

---

## 二、构建过程（含踩坑修复）

| 尝试 | 结果 | 根因 / 修复 |
|---|---|---|
| build1 | ❌ `ERR_PNPM_FETCH_TIMEOUT` xlsx tarball | cdn.sheetjs.com 超时（判临时抖动，重跑） |
| build2 | ❌ 同 xlsx 超时（336.7s） | 非临时 → 尝试强制 IPv4（/etc/hosts） |
| build3 | ❌ `/etc/hosts: Read-only file system` | buildkit 阶段 /etc/hosts 只读 → 改 `NODE_OPTIONS=--dns-result-order=ipv4first` |
| build4 | ❌ xlsx 854s 超时（kill） | ipv4first 后 registry 正常，但 xlsx 仍卡 → **证明非 IPv6/DNS 问题** |
| build5 | ❌ `git rev-parse HEAD` | apps/desktop 构建注入 commit hash，容器无 .git → `ENV DSH_CLIENT_COMMIT_HASH=0000000` 绕过 |
| **build6** | ✅ **成功** | 上述修复全部生效 |

### xlsx 下载黑洞（cdn.sheetjs.com）根因与绕过

- **现象**：HEAD 请求 200 快速返回；GET 数据流被限速（无 Range ~7.4KB/s、Range 段 457B/s）；
  Node.js https/http2 客户端请求被黑洞（TLS 指纹非白名单）；npmjs / npmmirror / GitHub
  releases 均无 xlsx 0.20.3。
- **绕过方案**：本机 **串行 Range 分段下载**（500KB/段，每段独立重试，5 段全成功），
  拼接后 **sha512 与 lockfile integrity 完全一致**（`oLDq3jw…3AJA==`，2,409,319 字节）
  → 本机起 Node 静态服务器（127.0.0.1:8123）→ staging 的 package.json 与 pnpm-lock.yaml
  中 xlsx URL 4 处替换为 `http://host.docker.internal:8123/xlsx-0.20.3.tgz`
  （**保留原 integrity**，内容不变仅换下载通道）→ 容器内 pnpm 拉取成功。
- **验证**：ui-sidebar-documentpreview（唯一 xlsx 消费者）构建通过
  （`client.excel.js 7.06MB` 产出），证明 xlsx 正常打包。

### 其他关键修复

- **git symlink 恢复**：Windows checkout（`core.symlinks=false`）把 14 个 git symlink
  （mode 120000）写成普通文本；`scripts/docker-restore-symlinks.sh` 在容器内按 git
  记录的目标重建真实 symlink（cordis.yml、snapshots/*、AGENTS.md 等）。

---

## 三、容器内 6 步验证明细（docker-verify.sh）

| # | 验证项 | 断言 | 结果 |
|---|---|---|---|
| 1 | `pnpm dsh --help`（timeout 60） | 输出 Usage | ✅ |
| 2 | `pnpm dsh --profile acp --help`（timeout 60） | 正常退出 | ✅ |
| 3 | `pnpm run verify-cordis-config`（timeout 120） | PASS | ✅ **symlink 恢复生效** |
| 4 | `pnpm run verify-cli-help`（timeout 600） | PASS（Linux 30s 内） | ✅ **无性能问题** |
| 5 | `pnpm run build:web` + `pnpm start:web`（timeout 300+60） | build 成功 + 启动输出就绪信息 | ✅ |
| 6 | lib 产物存在性 | apps/cli/lib、agent-loop/lib 存在 | ✅ |

**合计：7 通过 / 0 失败**（exit 0）。

---

## 四、对 Windows 基线定论的印证

| Windows 失败项（upstream-sync 报告 §三） | Linux 容器结果 | 结论 |
|---|---|---|
| cordis-config：`apps/cli/tests/profiles/acp/cordis.yml` symlink checkout 成文本 → "root must be a Loader entry array" | ✅ PASS（symlink 重建后正常） | **环境基线确认**：Linux 干净 checkout 无此问题 |
| cli-help：Windows 冷 tsx 缓存下大 profile 超 30s SIGKILL（acp 18.5–31.6s、web 42.9s） | ✅ PASS（30s 内完成） | **环境基线确认**：Linux 无 tsx 冷缓存性能问题 |

两条 gate 在 Linux 全绿 → **非 merge 回归**，均为 Windows 环境固有基线。

---

## 五、环境与产物

- **Docker**：Docker Desktop 4.86.0 (236216)，Client/Server 29.7.2，linux/amd64
- **镜像**：`dsh-source-verify:2026-10-11`（node:24-bookworm + corepack pnpm 11.28.5）
- **构建时间**：build6 全程约 30 分钟（install 重下 1396 包 ~3min + build:lib 251s + 导出 137s）
- **staging**：`D:\code\dsh\dsh-docker-staging`（robocopy，181MB，无 .git/node_modules/lib/dist）
- **日志**：`D:\code\dsh\dsh-docker-build6.log`（成功）、`dsh-docker-verify.log`（6 步验证）

---

## 六、遗留说明（不阻塞）

1. staging 的 `package.json` / `pnpm-lock.yaml` 中 xlsx URL 被替换为
   `http://host.docker.internal:8123/...`（**仅 staging 副本**，主仓文件未动）；
   后续如再构建需先起本地服务器，或换回官方 URL 后重试（CDN 黑洞仍存在）。
2. `ENV DSH_CLIENT_COMMIT_HASH=0000000` 使 desktop 构建绕过 git（容器无 .git），
   仅影响桌面端版本号注入，不影响 CLI/web 功能验证。
3. 本验证**未 commit、未 push**，工作分支保持 MERGING 状态，等待 owner 指示。
