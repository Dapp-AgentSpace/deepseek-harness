#!/usr/bin/env bash
# harness-runtime-check.sh — 运行回路编排器（方向 B）：harness-runtime-run.py 只做纯解析（吐 JSON 计划），
# 本脚本用 jq 读计划、逐域 export env 并直接调 抓取(harness-data-check.sh)→预检(harness-data-delta.sh)→
# 判定(judge-review.sh data)。bash 直接调 .sh，不再由 Python 跨进程 subprocess 调 bash（避开 Windows 脆弱性）。
# HARNESS_DATA_TOKEN（机密）来源：CI 由 yml 注入；本地（非 CI）从 .harness/env.local（gitignored）装载。
# 退出码 0=全绿或零域跳过（零域＝「无域可查」，显式说明，非假绿）/ 1=至少一域红 / 2=缺 jq 或配置错。
set -euo pipefail
export PYTHONUTF8=1  # PEP 540: Windows 强制 UTF-8（避免 GBK 读/写中文出错）
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 与执行器 harness-runtime-run.py 同源：显式传 ROOT 就用它，否则按本文件位置推导（部署后位于 <project>/ci/bin）
if [ -n "${1:-}" ]; then ROOT="$(cd "$1" && pwd)"; else ROOT="$(cd "$DIR/../.." && pwd)"; fi
# 环境解析（解释器 / 编码）单源见 ci/bin/harness-env.sh；本机缓存 .harness/toolchain.env 由 harness-preflight.sh 生成。
# shellcheck source=harness-env.sh
source "$ROOT/ci/bin/harness-env.sh"
# 本地运行（CI 未注入 token）时装载本地机密；CI 已注入则跳过（不覆盖 CI 值）。
if [ -z "${HARNESS_DATA_TOKEN:-}" ] && [ -f "$ROOT/.harness/env.local" ]; then
  # shellcheck disable=SC1090
  . "$ROOT/.harness/env.local"
  export HARNESS_DATA_TOKEN
fi
command -v jq >/dev/null 2>&1 || { echo "[runtime] 缺少 jq（运行回路编排依赖：pip/包管理器安装 jq）" >&2; exit 2; }

# 纯解析：python 读 yaml → 吐 JSON 计划；配置错/依赖数据缺失 → python 非零退出，这里直接中止。
PLAN="$("$HARNESS_PYTHON" "$DIR/harness-runtime-run.py" "$ROOT")" || exit $?
# 零域（无 runtime-config.yaml）＝「无域可查」，不是「无偏差」：必须显式说明，**绝不**打印
# 「未发现业务不变量偏差」—— 那是在声称「查了、没问题」，而实际一个域都没查（假绿）。
# 与 harness-selftest.sh「本仓无 tests/ → 跳过，非失败」同款纪律：「没跑」≠「跑了没问题」。
# 注意：生产者零域时吐的是 `{"pid":…,"domains":[]}`（**非空** JSON），故不能靠 `[ -n "$PLAN" ]` 判空
# （旧守卫因此**不可达**，正是本缺陷的根因）。
NDOM="$(printf '%s' "$PLAN" | jq -r '(.domains // []) | length' 2>/dev/null || echo 0)"
if [ -z "$PLAN" ] || [ "${NDOM:-0}" -eq 0 ]; then
  echo "[runtime] 无域可查（未配置 .harness/runtime-config.yaml）——跳过，非失败"
  exit 0
fi

PID="$(printf '%s' "$PLAN" | jq -r '.pid')"
failed=0
while IFS= read -r dom; do
  domain="$(printf '%s' "$dom" | jq -r '.domain')"
  echo "== $domain =="
  export HARNESS_DATA_ENDPOINT="$(printf '%s' "$dom" | jq -r '.env.HARNESS_DATA_ENDPOINT')"
  export HARNESS_DATA_HEADER="$(printf '%s' "$dom" | jq -r '.env.HARNESS_DATA_HEADER')"
  export HARNESS_DATA_AUTH_SCHEME="$(printf '%s' "$dom" | jq -r '.env.HARNESS_DATA_AUTH_SCHEME')"
  export HARNESS_DATA_EXTRA_HEADERS="$(printf '%s' "$dom" | jq -r '.env.HARNESS_DATA_EXTRA_HEADERS | join("\n")')"
  export HARNESS_DATA_METHOD="$(printf '%s' "$dom" | jq -r '.env.HARNESS_DATA_METHOD')"
  export HARNESS_DATA_BODY="$(printf '%s' "$dom" | jq -r '.env.HARNESS_DATA_BODY')"
  "$DIR/harness-data-check.sh" "$PID" "$domain" || { failed=1; continue; }
  "$DIR/harness-data-delta.sh" "$domain" || { failed=1; continue; }
  "$DIR/judge-review.sh" data "$domain" || { failed=1; continue; }
done < <(printf '%s' "$PLAN" | jq -c '.domains[]')

if [ "$failed" -ne 0 ]; then
  echo "[runtime] 检测到业务不变量偏差或配置/依赖缺失（证据见上方；已落 cs-issue 的即阻塞）"
  exit 1
fi
echo "[runtime] 未发现业务不变量偏差"
