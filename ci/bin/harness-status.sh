#!/usr/bin/env bash
# harness-status.sh — work↔TSD 状态 seam 的薄适配器（ADR-0004）。
# 状态单一真相源 = TSD frontmatter 的 `status`（frozen→building→verified→reviewed→closed），work 只是镜像。
# 一处推进：TSD status + work status 镜像（closed→done，其余透传不碰 CodeStable 细粒度状态）
#          + work frontmatter `tsd:` backlink + 记一行阶段证据（落 reports/*.status.log）。
#
# 用法: harness-status.sh advance <slug> <stage>
#   slug  = TSD 的 slug（= 文件名 {project.id}-{slug}.md 的 slug 段）；也接受 work slug（回退按 TSD 的 task 字段定位）。
#   stage = building | verified | reviewed | closed（frozen 由 plan 冻结时写入，不走这里）
# 退出码: 0=已推进 / 1=TSD 不存在或参数非法 / 2=环境缺 project.id 或 slug 含非法字符
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=harness-identity.sh
source "$ROOT/ci/bin/harness-identity.sh"
# shellcheck source=harness-env.sh
source "$ROOT/ci/bin/harness-env.sh"

emit() { printf '[harness-status] %s\n' "$1" >&2; }

CMD="${1:-}"; SLUG="${2:-}"; STAGE="${3:-}"
case "$CMD" in
  advance|reopen) ;;
  *) emit "用法: harness-status.sh advance <slug> <stage> | reopen <slug>"; exit 1;;
esac
[ -n "$SLUG" ] || { emit "缺少 slug"; exit 1; }
case "$SLUG" in *[!A-Za-z0-9._-]*) emit "slug 含非法字符（只允许 [A-Za-z0-9._-]）: $SLUG"; exit 2;; esac
if [ "$CMD" = advance ]; then
  case "$STAGE" in building|verified|reviewed|closed) ;; *) emit "非法 stage: $STAGE（building|verified|reviewed|closed）"; exit 1;; esac
fi

PID="$(h_id)"
[ -n "$PID" ] || { emit "identity.yaml 缺 project.id"; exit 2; }

# 定位 TSD：优先把 slug 当 TSD 文件名段，回退当 work slug（比对 task 字段）
# **也接受「完整文件名段」**（`{pid}-{slug}`）：本脚本的 slug 是**裸 slug**（下面自己拼 `${PID}-`），
# 而 `harness-runcard.sh create` 的参数是**完整文件名段** —— 同一个词两种含义，调用方极易传错，
# 而传错的表现是「找不到 TSD」，看不出是约定不一致（实测：runcard 委托 reopen 时踩到）。
# 多认一种写法，把这个坑填掉。
TSD=""
if [ -f "$ROOT/.harness/tsd/${PID}-${SLUG}.md" ]; then
  TSD="$ROOT/.harness/tsd/${PID}-${SLUG}.md"
elif [ -f "$ROOT/.harness/tsd/${SLUG}.md" ]; then
  TSD="$ROOT/.harness/tsd/${SLUG}.md"
else
  for f in "$ROOT"/.harness/tsd/*.md; do
    [ -f "$f" ] || continue
    [ "$(h_fld "$f" task)" = "$SLUG" ] && { TSD="$f"; break; }
  done
fi
[ -n "$TSD" ] || { emit "找不到 TSD（slug=$SLUG，pid=$PID）"; exit 1; }

TASK="$(h_fld "$TSD" task)"
[ -n "$TASK" ] || emit "TSD 缺 task 字段，无法定位 work（只推进 TSD）: $(basename "$TSD")"

# 1) 推进 / 回退 TSD status（status 字段由 plan 冻结时写入，此处必须已存在）
grep -qE '^[[:space:]]*status:[[:space:]]*' "$TSD" || { emit "TSD 缺 status 字段（应由 plan 冻结时写入）: $(basename "$TSD")"; exit 1; }
if [ "$CMD" = reopen ]; then
  h_set "$TSD" status frozen
else
  h_set "$TSD" status "$STAGE"
fi

# 2) work 镜像 + backlink
WORK=""
if [ -n "$TASK" ]; then
  WORK="$("$HARNESS_PYTHON" "$ROOT/ci/bin/work_unit.py" locate "$ROOT" "$TASK" 2>/dev/null || true)"
fi
if [ -n "$WORK" ]; then
  tsd_rel=".harness/tsd/$(basename "$TSD")"
  # 2a) tsd: backlink（幂等：存在则更新；缺则插到**标识行**后）
  # 锚点 = `id:` —— work-unit schema（ci/work-unit-schema.md:16）的唯一标识字段；harness 自产文件
  # （`.harness/work/*.md`）均只有 `id:`、**没有 `slug:`**。兼容旧写法 `slug:`：`work_unit.py locate`
  # 仍会回退到 `.codestable/work/*-{slug}.md`（CodeStable 适配前的文件用 `slug:`）。
  # 此前只锚 `slug:` → awk 永不匹配 → 回链**静默不写**（locate 找得到文件、插入锚点却找不到），
  # 于是 `harness-handoff.sh` 的「遗留项 / 未解 blocking」两节恒报「判不了」。
  if grep -qE '^[[:space:]]*tsd:[[:space:]]*' "$WORK"; then
    h_set "$WORK" tsd "$tsd_rel"
  else
    awk -v line="tsd: ${tsd_rel}" '!done && /^[[:space:]]*(id|slug):/ { print; print line; done=1; next } { print }' \
      "$WORK" > "$WORK.tmp" && mv "$WORK.tmp" "$WORK"
    # 兜底可见化：万一锚点都没有（work 文件缺 id/slug，schema 违规），**不静默放过** —— 报出来。
    grep -qE '^[[:space:]]*tsd:[[:space:]]*' "$WORK" \
      || emit "work 缺 id:/slug: 标识行，tsd: 回链未写入: $(basename "$WORK")"
  fi
  # 2b) 状态映射（显式列，不猜）：advance closed → work `done`；**reopen → work `building`**；其余透传。
  # reopen 映射到 `building` 而不是 `frozen`：work 的 `frozen` 是 harness 专有值，CodeStable 侧只认
  # `planned/in_progress/done`（映射 `in_progress`→`building`）—— 写 `frozen` 会让 cs 侧读到不认识
  # 的取值。`building` 是**双方都认**的非终态值，且 harness-run 复开后第一步就推进到它。
  if [ "$CMD" = reopen ]; then
    h_set "$WORK" status building
  elif [ "$STAGE" = closed ]; then
    h_set "$WORK" status done
  fi
else
  emit "未找到对应 work（*-${TASK}.md），已推进 TSD、未镜像 work"
fi

# 3) 阶段证据（不就地改冻结 TSD 正文，落独立状态日志）
# 文件名用 TSD 的**规范 slug**（basename 去 .md、去 {pid}- 前缀），**不是**调用方传入的 SLUG 原样：
# `harness-runcard.sh create` 委托 reopen 时传的是**完整文件名段**（`fx-alpha`），直接拼 SLUG 会写出
# `{pid}-{pid}-{slug}` 双前缀孤儿（ADR-0019 审计 G2 形态，实测 `fx-fx-alpha.status.log`）。
# 裸 slug 与完整段两种写法解析到同一份 TSD，证据文件名必须归一成 {pid}-{slug}。
TSDSLUG="$(basename "$TSD" .md)"
TSDSLUG="${TSDSLUG#"$PID"-}"
LOG="$ROOT/.harness/reports/${PID}-${TSDSLUG}.status.log"
mkdir -p "$(dirname "$LOG")"
printf '%s\t%s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "${STAGE:-$CMD}" >> "$LOG"

emit "已推进 ${SLUG} → ${STAGE:-$CMD}（work=${TASK:-无}）"
