#!/usr/bin/env bash
# harness-data-trace.sh — 统一只读数据访问接口（data trace）调用器（ADR-0017）。
# 数据校验（数据 UT rung3 / 运行时 rung4）经**同一套命令**读项目数据，不关心实现语言
# （Python / Java / Node）。项目唯一接口位于 .harness/data_trace/（每项目恰一份）。
#
# 子命令：
#   check                         数据校验前存在性检查（接口存在 + manifest 合法 + ping 通 + 方法对账）
#   ping                          探活（接口存在性）
#   list-entities                 列出可读实体
#   query <entity> --where <json> 等值条件查询（[{field,value},...]）→ EntityData 形状到 stdout
#   describe <entity>             schema 内省
#   audit-methods                 实现方法 vs manifest 对账（多出→need-human / 缺→告警 / 写语义→blocking）
#
# 环境变量（不硬编码）：
#   HARNESS_DATA_TRACE_DIR   接口目录（缺省 <root>/.harness/data_trace；测试用临时目录隔离）
#   HARNESS_DATA_TRACE_ENTRY 覆盖统一入口（如 "python3 cli.py" / "node cli.mjs"）；缺省自动探测
#   HARNESS_DATA_TOKEN        UAT 数据源只读 token（走 CI secrets，不进仓库）
#   HARNESS_PYTHON            Python 解释器（suite 单源，见 harness-env.sh）
#
# 退出码：0=正常 / 1=有发现（check 的 need-human / blocking；audit-methods 的差异）/ 2=用法或环境错误
#         （接口缺失 / manifest 缺失 / ping 失败 = 接口不存在，调用方按 ADR-0017 判 rung 3 红）
# 用法: harness-data-trace.sh <subcommand> [args...]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=harness-env.sh
source "$ROOT/ci/bin/harness-env.sh"

CMD="${1:-}"
[ -n "$CMD" ] || { echo "[data-trace] 用法: harness-data-trace.sh <check|ping|list-entities|query|describe|audit-methods> [args...]" >&2; exit 2; }
shift || true

DT_DIR="${HARNESS_DATA_TRACE_DIR:-$ROOT/.harness/data_trace}"

# ── 统一入口解析 ────────────────────────────────────────────────────────────────────
# source.yaml 的 entry 字段（项目自有配置，信任其内容）优先；否则按文件自动探测。
# 探测顺序：cli.py（HARNESS_PYTHON）→ cli.mjs/cli.js（node）→ cli.sh（bash）。
resolve_entry() {
  if [ -n "${HARNESS_DATA_TRACE_ENTRY:-}" ]; then
    printf '%s' "$HARNESS_DATA_TRACE_ENTRY"
    return
  fi
  if [ -f "$DT_DIR/source.yaml" ] && grep -qE '^entry:[[:space:]]*[^#]' "$DT_DIR/source.yaml"; then
    entry="$(sed -nE 's/^entry:[[:space:]]*(.*)$/\1/p' "$DT_DIR/source.yaml" | head -1 | sed -E 's/[[:space:]]+#.*$//; s/^[[:space:]]+|[[:space:]]+$//g')"
    if [ -n "$entry" ]; then printf '%s' "$entry"; return; fi
  fi
  if [ -f "$DT_DIR/cli.py" ]; then printf '%s cli.py' "${HARNESS_PYTHON:-python3}"; return; fi
  if [ -f "$DT_DIR/cli.mjs" ]; then printf 'node cli.mjs'; return; fi
  if [ -f "$DT_DIR/cli.js" ]; then printf 'node cli.js'; return; fi
  if [ -f "$DT_DIR/cli.sh" ]; then printf 'bash cli.sh'; return; fi
  return 1
}

# 跑接口命令：entry <args...>，stdout 接 JSON，stderr 透传。HOG-002：捕获退出码须 set +e。
# 在 $DT_DIR 子 shell 内执行（cli.py/cli.mjs/cli.sh 为相对入口，须相对接口目录解析），父 shell CWD 不受影响。
run_cli() {
  local entry rc
  if ! entry="$(resolve_entry)"; then
    echo "[data-trace] 未找到统一入口（.harness/data_trace/cli.{py,mjs,js,sh} 或 source.yaml entry 缺失）" >&2
    return 2
  fi
  # entry 是项目自有配置（可含参数），按空白分词为数组执行（有意分词，非注入面）
  local -a cli_args=()
  read -r -a cli_args <<< "$entry"
  set +e
  ( cd "$DT_DIR" && "${cli_args[@]}" "$@" ) 2>&1
  rc=$?
  set -e
  return $rc
}

# 读 manifest.yaml 的实体名（entities: 下的顶层子键，即首个缩进层级），去注释/空行。
# 注意：gsub 改 $1 会重建 $0，若 R2 无 next 会落到 R3 把 in_e 清零（多实体只解析出第一个）；
# 且 R2 必须只匹配「实体级缩进」，否则 reviewed_by/reviewed_at 字段会被当成实体名。
manifest_entities() {
  [ -f "$DT_DIR/manifest.yaml" ] || return 0
  awk '
    /^entities:/ { in_e=1; next }
    in_e && /^[[:space:]]+[A-Za-z0-9_.-]+:/ {
      if (indent == "") { match($0, /^[[:space:]]+/); indent = RLENGTH }
      match($0, /^[[:space:]]+/)
      if (RLENGTH == indent) { sub(/^[[:space:]]*/, ""); sub(/:.*/, ""); print }
      next
    }
    in_e && /^[^[:space:]#]/ && !/^entities:/ { in_e=0 }
  ' "$DT_DIR/manifest.yaml"
}

# 读 manifest 里某实体的 reviewed 字段（reviewed_by/reviewed_at，可能缺 = 未审核）。
# 关键：R2 只在「下一个实体级键」（与目标实体同缩进）时退出；字段行（更深缩进）不得退出，
# 否则 reviewed_by 在前、reviewed_at 在后时第二个字段永远读不到。
manifest_reviewed() {  # manifest_reviewed <entity> <field>
  local ent="$1" fld="$2"
  [ -f "$DT_DIR/manifest.yaml" ] || return 0
  awk -v ent="$ent" -v fld="$fld" '
    $0 ~ "^[[:space:]]*" ent ":" { match($0, /^[[:space:]]+/); indent = RLENGTH; in_e=1; next }
    in_e && /^[[:space:]]+[A-Za-z0-9_.-]+:/ {
      match($0, /^[[:space:]]+/)
      if (RLENGTH == indent) { in_e=0; next }
    }
    in_e && $0 ~ "^[[:space:]]+" fld ":" { sub(/^[[:space:]]*[A-Za-z0-9_.-]+:[[:space:]]*/, ""); gsub(/[[:space:]]+$/, ""); print; exit }
  ' "$DT_DIR/manifest.yaml"
}

# 只读性守卫：实现源码含写语义命令串 → blocking。启发式（HOG 同类）：查带引号的命令 token，
# 排除注释行；scaffold 只生成读命令，出现写命令串即实现越界。
# 模式用 [-i + 词边界]：既命中 "delete" 裸 token，也命中 "delete from orders" / UPDATE ... 等真实写语句
# （SQL 动词常大写），且不误伤 "deleting"/字段名等子串。
WRITE_VERBS='create|update|delete|write|insert|drop|truncate|patch'
readonly_guard() {
  local f rc=0
  for f in "$DT_DIR"/*.py "$DT_DIR"/*.mjs "$DT_DIR"/*.js "$DT_DIR"/*.java "$DT_DIR"/*.sh; do
    [ -f "$f" ] || continue
    if grep -inE "[\"']($WRITE_VERBS)\b" "$f" | grep -vE '^\s*[0-9]+:\s*#' >/dev/null 2>&1; then
      echo "[data-trace][blocking] 只读守卫：$f 含写语义命令 token（$(basename "$f")）——data trace 接口只允许读操作" >&2
      rc=1
    fi
  done
  return $rc
}

# 方法对账：list-entities（实现）vs manifest（已批准）。多出→need-human；缺→告警。
# 输出行前缀 [data-trace][need-human] / [data-trace][warn]，供 closed-loop-audit 分类。
audit_methods() {
  local missing=0 rc=0 ent out
  if ! out="$(run_cli list-entities)"; then
    echo "[data-trace][warn] list-entities 不可执行（rc=$?）——方法对账降级为仅 manifest（接口可能未实现）" >&2
    return 0
  fi
  # 解析 {"entities":[...]}
  local impl_list=""
  impl_list="$(printf '%s' "$out" | sed -nE 's/.*"entities"[[:space:]]*:[[:space:]]*\[([^]]*)\].*/\1/p')"
  for ent in $(printf '%s' "$impl_list" | tr ',' '\n' | sed -nE 's/.*"([^"]+)".*/\1/p' | sort -u); do
    if ! manifest_entities | grep -qx "$ent"; then
      echo "[data-trace][need-human] 新增数据获取方法未审核：实现暴露 query/$ent，manifest 未批准（owner 审核只读性+用途后追加 manifest）"
      rc=1
    fi
  done
  # manifest 有、实现缺 = 能力缩水告警（存储形态可能变化）
  while IFS= read -r ent; do
    [ -n "$ent" ] || continue
    if ! printf '%s\n' "$impl_list" | tr ',' '\n' | sed -nE 's/.*"([^"]+)".*/\1/p' | sort -u | grep -qx "$ent"; then
      echo "[data-trace][warn] 实现缺 manifest 已批准实体 $ent（能力缩水，可能是存储形态变化，需 owner 确认）"
    fi
  done < <(manifest_entities)
  readonly_guard || rc=1
  return $rc
}

case "$CMD" in
  check)
    # ① 接口存在
    if [ ! -d "$DT_DIR" ]; then
      echo "[data-trace] 缺少 .harness/data_trace/（ADR-0017：数据校验前须有项目唯一只读接口；缺失时用 harness-data-trace-init.sh 按栈生成）" >&2
      exit 2
    fi
    # ② manifest 存在且合法（entities 块 + 每实体 reviewed）
    if [ ! -f "$DT_DIR/manifest.yaml" ]; then
      echo "[data-trace] 缺少 manifest.yaml（已批准方法集锚，人工审核凭据）" >&2
      exit 2
    fi
    bad=0
    while IFS= read -r ent; do
      [ -n "$ent" ] || continue
      rb="$(manifest_reviewed "$ent" reviewed_by)"
      ra="$(manifest_reviewed "$ent" reviewed_at)"
      if [ -z "$rb" ] || [ -z "$ra" ]; then
        echo "[data-trace][need-human] manifest 实体 $ent 缺 reviewed_by/reviewed_at（方法未经人工审核，须 owner 补审）"
        bad=1
      fi
    done < <(manifest_entities)
    # ③ ping 可执行（接口存在性 = 能跑 + ok）
    pout=""
    prc=0
    pout="$(run_cli ping 2>&1)" || prc=$?
    if [ "$prc" -ne 0 ] || ! printf '%s' "$pout" | grep -q '"ok"[[:space:]]*:[[:space:]]*true'; then
      echo "[data-trace] ping 失败（rc=$prc, out=$pout）——接口存在但不可执行（连接未配置时 query 须显式 exit 2，不假绿）" >&2
      exit 2
    fi
    # ④ 方法对账（多出→need-human；写语义→blocking；缺→warn）
    arc=0
    audit_methods || arc=$?
    if [ "$bad" -ne 0 ] || [ "$arc" -ne 0 ]; then exit 1; fi
    echo "[data-trace] check 通过：$DT_DIR（接口存在、manifest 合法、ping ok、方法集一致）"
    exit 0
    ;;
  ping|list-entities)
    run_cli "$CMD"
    ;;
  query)
    entity="${1:-}"
    [ -n "$entity" ] || { echo "[data-trace] query 缺 entity" >&2; exit 2; }
    case "$entity" in *[!A-Za-z0-9._-]*) echo "[data-trace] entity 含非法字符（只允许 [A-Za-z0-9._-]）: $entity" >&2; exit 2;; esac
    shift || true
    run_cli query "$entity" "$@"
    ;;
  describe)
    entity="${1:-}"
    [ -n "$entity" ] || { echo "[data-trace] describe 缺 entity" >&2; exit 2; }
    shift || true
    run_cli describe "$entity" "$@"
    ;;
  audit-methods)
    audit_methods
    ;;
  *)
    echo "[data-trace] 未知子命令: $CMD（check|ping|list-entities|query|describe|audit-methods）" >&2
    exit 2
    ;;
esac
