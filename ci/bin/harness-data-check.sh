#!/usr/bin/env bash
# harness-data-check.sh — 数据不变量校验的「抓取」深模块（只读查询接口，只抓数据不判定）。
# 判定交给 LLM-as-judge：抓到的数据落 .harness/reports/data-{domain}.json，
# 由 ci/bin/judge-review.sh data <domain> 读「运行时数据契约 + 抓取数据」做语义判定。
# 本脚本只负责 curl 抓取 → 落报告：抓取成功 exit 0（不判定数据是否违例）；抓取失败
# （接口不可达/返回 4xx/5xx）本身是运行时问题，落 cs-issue + exit 1（通知走 CI 失败）。
#
# 读环境变量（不硬编码）：HARNESS_DATA_ENDPOINT / HARNESS_DATA_TOKEN，以及可选
# HARNESS_DATA_HEADER（认证头名，默认 Authorization）/ HARNESS_DATA_AUTH_SCHEME（头值前缀，默认 Bearer）/
# HARNESS_DATA_EXTRA_HEADERS（额外头，每行一条 "Name: Value"）/ HARNESS_DATA_METHOD（默认 GET，非 GET 加 -X）/
# HARNESS_DATA_BODY（可选请求体；非空按 JSON 加 -d + Content-Type: application/json）。
# 用法: harness-data-check.sh <project.id> <domain> [affected-path]
set -euo pipefail

PID="${1:?用法: harness-data-check.sh <project.id> <domain> [affected-path]}"
DOMAIN="${2:?缺少 domain（运行时契约域）}"
AFFECTED="${3:-未标注}"

# DOMAIN 进报告文件名，白名单防路径穿越
case "$DOMAIN" in *[!A-Za-z0-9._-]*) echo "[data-check] domain 含非法字符（只允许 [A-Za-z0-9._-]）: $DOMAIN" >&2; exit 2;; esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ISSUE_SCRIPT="$ROOT/ci/bin/harness-runtime-issue.sh"
REPORTS="$ROOT/.harness/reports"

# 只读查询接口配置（:? 守卫——缺配置即显式失败，不假绿）
ENDPOINT="${HARNESS_DATA_ENDPOINT:?缺少 HARNESS_DATA_ENDPOINT（只读查询接口 URL）}"
TOKEN="${HARNESS_DATA_TOKEN:?缺少 HARNESS_DATA_TOKEN（只读 token，走 CI secrets）}"
# 认证头名可配（不同 API 默认头未必是 Authorization，如 X-API-Key / x-access-token）；
# 头值前缀可配，默认 "Bearer <token>"；显式置空 HARNESS_DATA_AUTH_SCHEME 则只传裸 token。
HEADER="${HARNESS_DATA_HEADER:-Authorization}"
AUTH_SCHEME="${HARNESS_DATA_AUTH_SCHEME-Bearer}"
if [ -n "$AUTH_SCHEME" ]; then AUTH_VALUE="$AUTH_SCHEME $TOKEN"; else AUTH_VALUE="$TOKEN"; fi

# 额外头（可选）：HARNESS_DATA_EXTRA_HEADERS 每行一条 "Name: Value"，空行/`#` 注释忽略，逐条追加为 -H
extra_hdr=()
if [ -n "${HARNESS_DATA_EXTRA_HEADERS:-}" ]; then
  while IFS= read -r line; do
    line="$(printf '%s' "$line" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')"
    [ -n "$line" ] || continue
    case "$line" in \#*) continue;; esac
    extra_hdr+=(-H "$line")
  done <<< "${HARNESS_DATA_EXTRA_HEADERS}" || true
fi

# 可选请求方法与 body（data-trace 数据开放接口多为 POST JSON body，由执行器 harness-runtime-run.py 组 env）。
# 方法大小写不敏感（归一化大写）；GET 缺省不带 -X/-d（行为同旧版）；非 GET 加 -X；有 body 时按 JSON
# 加 -d + Content-Type: application/json。
req_args=()
METHOD="$(printf '%s' "${HARNESS_DATA_METHOD:-GET}" | tr '[:lower:]' '[:upper:]')"
BODY="${HARNESS_DATA_BODY:-}"
if [ "$METHOD" != "GET" ]; then req_args+=(-X "$METHOD"); fi
if [ -n "$BODY" ]; then req_args+=(-d "$BODY" -H "Content-Type: application/json"); fi

# HOG-002：捕获退出码禁用 set -e 下的 `|| rc=$?`，须 set +e 显式取 $?
# --fail-with-body 已含 --fail 语义（4xx/5xx exit 22 且保留响应体供 issue 证据），与 -f 互斥（同用报
# "badly used here"/"must select either"），故此处不叠加 -f；须 curl ≥ 7.76。
set +e
body="$(curl -sS --fail-with-body "${req_args[@]}" "$ENDPOINT" -H "$HEADER: $AUTH_VALUE" "${extra_hdr[@]}" 2>&1)"
curl_rc=$?
set -e

# 抓取失败（接口不可达/返回 4xx/5xx）本身是运行时问题：落 cs-issue + exit 1，不进入判定
if [ "$curl_rc" -ne 0 ]; then
  INVARIANT="只读查询接口可访问（$DOMAIN）"
  if [ -x "$ISSUE_SCRIPT" ]; then
    printf '%s\n' "$body" | "$ISSUE_SCRIPT" "$PID" "$DOMAIN" "$INVARIANT" "$AFFECTED" || true
  else
    echo "[data-check] $DOMAIN 抓取失败，且 harness-runtime-issue.sh 缺失，未落 issue" >&2
  fi
  echo "[data-check] $DOMAIN 抓取失败（接口不可达/返回错误）：$body" >&2
  exit 1
fi

# 抓取成功：落最新快照 + 追加时间序列（ADR-0007：判定需时间轴才能判「突然变」）。
mkdir -p "$REPORTS"
REPORT="$REPORTS/data-${DOMAIN}.json"
HISTORY="$REPORTS/data-${DOMAIN}.jsonl"
printf '%s\n' "$body" > "$REPORT"
# 时间序列 append（FIFO 保留最近 30 条），每条带时间戳供 delta 预检算环比/σ/单调。JSONL 单行。
if [ -n "$body" ]; then
  # 仅当 body 含非空白字符才落 JSONL（纯空白/空体不写无效行，防 delta 静默丢弃）
  case "$body" in
    *[![:space:]]*)
      ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf '{"ts":"%s","data":%s}\n' "$ts" "$(printf '%s' "$body" | tr -d '\n')" >> "$HISTORY"
      tmp="$HISTORY.tmp.$$"
      tail -n 30 "$HISTORY" > "$tmp" && mv "$tmp" "$HISTORY" || rm -f "$tmp"
      ;;
  esac
fi
echo "[data-check] $DOMAIN 数据已抓取 → $REPORT（判定走 judge-review.sh data；时间序列见 $HISTORY）"
exit 0
