#!/usr/bin/env bash
# harness-tsd-sync-check.sh — 变更检测（ADR-0004）：重算 work/epic 的哈希，与 TSD 冻结时记账的
# work_sha/epic_sha 比对，检测冻结 TSD 是否被 work/epic 后续变更作废。只检测、只告警，不修复、不自动 re-plan。
#
# work 哈希只覆盖 body（跳过 frontmatter）：镜像适配器 harness-status.sh 会写 work frontmatter 的
# tsd:/status，若哈希含 frontmatter，镜像自身写入会被误判成「work 变更」。owner 的决策内容在 body，
# 故只哈希 body。epic 未被镜像写入，仍按整内容哈希。
#
# 用法:
#   harness-tsd-sync-check.sh hash <work-slug>     输出 work body 的 sha256（plan 冻结时记账用，与比对同源）
#   harness-tsd-sync-check.sh tsd-sha <tsd-slug>   输出 TSD body 的 sha256（plan 冻结时记账为 content_sha）
#   harness-tsd-sync-check.sh [slug ...]           校验指定/全部冻结 TSD（缺省全部）
# 退出码: 0=全部一致 / 1=发现 stale（work/epic 已变更） / 2=数据不全或需人工判定（缺 work_sha、冻结 TSD 内容不符）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# 可移植 sha256，**统一只输出十六进制摘要**（单行单字段），故调用方 `awk '{print $1}'` 恒取到摘要。
# 优先真 `sha256sum`（GNU/Linux、Git Bash 常无 `shasum`），再 `shasum -a 256`（BSD/macOS），
# 再 `openssl dgst`（最小容器）。
#
# **不再用同名函数覆盖 `sha256sum`**：旧实现（a）从不优先真 `sha256sum` 二进制，
# （b）openssl 分支输出 `SHA2-256(stdin)= <hex>`，被 `awk '{print $1}'` 取成常量标签
# `SHA2-256(stdin)=`（正好 16 字符）→ 记账与比对**恒相等 = 假绿**：冻结 TSD 被未留痕地
# 就地改写也检不出来（ADR-0012 内容寻址静默失效）。改用具名函数，各分支各自归一成摘要。
# 注意 **`find -exec` 不经 shell**，函数对它无效 —— 故下面把 `-exec sha256sum {} +` 改成 while 循环。
_sha256() {  # <file...> | stdin → 十六进制摘要（单行单字段）
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$@" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 "$@" | awk '{print $NF}'
  else cat "$@" 2>/dev/null | cksum | awk '{print $1}'; fi
}

# shellcheck source=harness-identity.sh
source "$ROOT/ci/bin/harness-identity.sh"
# shellcheck source=harness-env.sh
source "$ROOT/ci/bin/harness-env.sh"

emit() { printf '[tsd-sync] %s\n' "$1" >&2; }

# 计算文件 body 的 sha256：跳过前两条 `---` 之间的 frontmatter，只哈希正文
_body_sha() {  # <file> → sha256
  awk '/^---[[:space:]]*$/ && n < 2 { n++; next } n >= 2 { print }' "$1" 2>/dev/null | _sha256 | awk '{print $1}'
}

# hash 子命令：plan 冻结时记账用，输出与 sync 比对完全一致的 work body sha256
if [ "${1:-}" = hash ]; then
  ws="${2:?用法: harness-tsd-sync-check.sh hash <work-slug>}"
  case "$ws" in *[!A-Za-z0-9._-]*) emit "work-slug 含非法字符: $ws"; exit 2;; esac
  work="$("$HARNESS_PYTHON" "$ROOT/ci/bin/work_unit.py" locate "$ROOT" "$ws" 2>/dev/null || true)"
  [ -n "$work" ] || { emit "找不到 work: *-${ws}.md"; exit 1; }
  _body_sha "$work"
  exit 0
fi

# tsd-sha 子命令：plan 冻结时记账 `content_sha`（ADR-0012 决策 1 的 PhaseArtifact 内容寻址）。
# 与校验同源（同一个 _body_sha），否则记的与比的对不上。body 不含 frontmatter，
# 故 content_sha 写进 frontmatter 不会自指、不会改变哈希。
if [ "${1:-}" = tsd-sha ]; then
  ts="${2:?用法: harness-tsd-sync-check.sh tsd-sha <tsd-slug>}"
  case "$ts" in *[!A-Za-z0-9._-]*) emit "tsd-slug 含非法字符: $ts"; exit 2;; esac
  PID="$(h_id)"
  tf="$ROOT/.harness/tsd/${PID}-${ts}.md"
  [ -f "$tf" ] || { emit "找不到 TSD: ${PID}-${ts}.md"; exit 1; }
  _body_sha "$tf"
  exit 0
fi

PID="$(h_id)"
[ -n "$PID" ] || { emit "identity.yaml 缺 project.id"; exit 2; }

# 收集目标 TSD：显式给 slug 就逐个定位；否则扫全部冻结 TSD
tsds=()
if [ $# -gt 0 ]; then
  for s in "$@"; do
    case "$s" in *[!A-Za-z0-9._-]*) emit "slug 含非法字符: $s"; exit 2;; esac
    if [ -f "$ROOT/.harness/tsd/${PID}-${s}.md" ]; then
      tsds+=("$ROOT/.harness/tsd/${PID}-${s}.md")
    else
      emit "跳过（不存在）: ${PID}-${s}.md"
    fi
  done
else
  files="$(find "$ROOT/.harness/tsd" -maxdepth 1 -type f -name "${PID}-*.md" 2>/dev/null | sort || true)"
  while IFS= read -r f; do [ -n "$f" ] && tsds+=("$f"); done <<< "$files"
fi

stale=0; incomplete=0; checked=0
for t in "${tsds[@]}"; do
  [ -f "$t" ] || continue
  grep -qE '^[[:space:]]*tsd_frozen:[[:space:]]*true' "$t" || { emit "跳过（未冻结）: $(basename "$t")"; continue; }
  checked=$((checked+1))
  name="$(basename "$t")"
  task="$(h_fld "$t" task)"; work_sha="$(h_fld "$t" work_sha)"

  # ── 冻结 TSD 自身的「不可**未留痕**地就地改写」检测（ADR-0012 决策 1 的 content-hash）──
  # 此前 `tsd_frozen: true` 只是个布尔：**冻结但不可内容寻址**，于是 harness-plan 硬门槛
  # 「TSD 一经冻结即不可就地改写」是一句没有任何执行点的声明（CONTRACT-001 rung 1 不满足）。
  #
  # 口径（owner 2026-09-18 定）：边界重确认 = **re-plan 就地改同一份 TSD**（同名文件，故
  # build/run 的按 task-slug 定位、按 task-slug 命名的契约、work-unit 反链**全不动**），
  # 但改 body 的**同时必须重记 content_sha + `tsd_version` +1 + `reconfirmed` 理由**。
  # 「留痕」就是这个重记动作本身；旧版本在 git 历史里，不需要第二个文件。
  #
  # **不一致判红（stale），无例外。** 曾一度判 2（需人工），理由是分不清「违规改写」与「走了
  # 重确认」—— 现在分得清：走了程序的一定重记了哈希，没重记的就不是走了程序。
  #
  # 已知代价（诚实记下）：**纯格式改动**（如 markdownlint 批跑）也算 body 变更，会把冻结 TSD 判红。
  # 实测本仓消费项目就发生过：一次「fix markdownlint errors」提交改了冻结 TSD 的正文，当时无
  # content_sha，无人察觉，且让评审报告里记的 SHA-256 永久失配。判红是**刻意**的 —— 格式批跑要么
  # 别扫 `.harness/tsd/`（项目已在 TSD 内用 `<!-- markdownlint-disable -->` 局部豁免），
  # 要么重记哈希。做「归一化后哈希」去豁免格式差异，会连带隐藏真改动，不做。
  tsd_sha="$(h_fld "$t" content_sha)"
  if [ -n "$tsd_sha" ]; then
    cur_tsd="$(_body_sha "$t")"
    if [ "$cur_tsd" != "$tsd_sha" ]; then
      emit "内容不符 $name：冻结 TSD 正文与 content_sha 不一致（${tsd_sha:0:8}… → ${cur_tsd:0:8}…）—— 冻结 TSD 不可未留痕地改写；要改走 harness-plan 的 re-plan（改后重记 content_sha + tsd_version+1 + reconfirmed）"
      stale=1
    fi
  else
    # 缺 content_sha（ADR-0019 决策 5）：冻结但不可内容寻址 = 「冻结」是空声明。
    # 此前 `if [ -n "$tsd_sha" ]` 才比内容 → 冻结 TSD **没记账也不判**，content-hash 的强制力
    # 只对「记了账的」生效，新建/untracked 冻结 TSD（git ls-files 之外）可绕过记账 ——
    # 审计盲区 5 实锤（消费仓 gitlab 系列 epic TSD 即此形态）。判 incomplete（exit 2，需人工
    # re-plan 记账）：与「缺 work_sha/task」同语义 —— body 自洽，缺的是手续，不是规格被改。
    emit "缺 content_sha $name：冻结 TSD 未记账 content_sha —— 冻结但不可内容寻址 = 冻结是空声明；要改走 harness-plan 的 re-plan（记 content_sha + tsd_version+1 + reconfirmed）"
    incomplete=1
  fi

  # `tsd_version ≥ 2` 必须有 `reconfirmed`（谁批准 + 改了什么）：哈希只证「留了痕」，不证「为什么改」。
  # 两者一起才构成 re-plan 的完整留痕，故这条与上面的 content_sha 检查配对。
  # 判 incomplete（需人工）而不是红：body 是自洽的，缺的是理由 —— 是手续没补齐，不是规格被偷偷改。
  ver="$(h_fld "$t" tsd_version)"; reconf="$(h_fld "$t" reconfirmed)"
  case "$ver" in
    ''|1) ;;
    *) if [ -z "$reconf" ]; then
         emit "缺 reconfirmed $name：tsd_version=${ver}（经 re-plan 修订）但未记「谁批准 + 改了什么」——哈希只证留了痕，不证为什么改"; incomplete=1
       fi;;
  esac

  # work 级检测
  if [ -z "$task" ]; then
    emit "缺 task（旧 TSD 未记账），跳过 work 检测: $name"; incomplete=1
  else
    work="$("$HARNESS_PYTHON" "$ROOT/ci/bin/work_unit.py" locate "$ROOT" "$task" 2>/dev/null || true)"
    if [ -z "$work" ]; then
      emit "STALE $name：work ${task} 不存在（已删/改名）"; stale=1
    elif [ -z "$work_sha" ]; then
      emit "缺 work_sha（旧 TSD 未记账），需 re-plan 记账: $name"; incomplete=1
    else
      cur="$(_body_sha "$work")"
      if [ "$cur" != "$work_sha" ]; then
        emit "STALE $name：work ${task} 已变更（${work_sha:0:8}… → ${cur:0:8}…）"; stale=1
      else
        emit "ok $name（work 未变）"
      fi
    fi
  fi

  # epic 级检测（可选：仅当 plan 记账了 epic/epic_sha 才启用，否则退化为仅 work 级）
  epic="$(h_fld "$t" epic)"; epic_sha="$(h_fld "$t" epic_sha)"
  if [ -n "$epic" ] || [ -n "$epic_sha" ]; then
    if [ -z "$epic" ] || [ -z "$epic_sha" ]; then
      emit "epic/epic_sha 不完整: $name"; incomplete=1
    else
      epic_path="$ROOT/$epic"
      if [ -d "$epic_path" ]; then
        cur_epic="$( (cd "$epic_path" && find . -type f | sort | while IFS= read -r _f; do _sha256 "$_f"; done) | _sha256 | awk '{print $1}')"
      elif [ -f "$epic_path" ]; then
        cur_epic="$(_sha256 "$epic_path" | awk '{print $1}')"
      else
        cur_epic=""
      fi
      if [ -z "$cur_epic" ]; then
        emit "STALE $name：epic ${epic} 不存在"; stale=1
      elif [ "$cur_epic" != "$epic_sha" ]; then
        emit "STALE $name：epic ${epic} 已变更"; stale=1
      fi
    fi
  fi
done

[ "$checked" -eq 0 ] && { emit "无冻结 TSD"; exit 0; }

if [ "$stale" -ne 0 ]; then
  "$ROOT/ci/bin/harness-notify.sh" "Harness · TSD 过期" "检测到 ${stale} 个冻结 TSD 的 work/epic 已变更，建议 re-plan" 2>/dev/null || true
  emit "发现 ${stale} 个 stale，需 owner re-plan（单 work 或批量 --all）"
  exit 1
fi
if [ "$incomplete" -ne 0 ]; then
  emit "部分 TSD 缺 work_sha/task（旧 TSD 未记账），需 re-plan 记账"
  exit 2
fi
emit "全部一致（${checked} 个冻结 TSD）"
exit 0
