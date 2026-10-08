#!/usr/bin/env bash
# harness-selftest.sh — **套件自测的唯一入口**：跑 `tests/*/run.sh`（判定逻辑的回归用例）。
#
# ## 为什么要有这个入口
#
# `tests/` 是**套件自己的**回归套件（不分发：`upgrade.sh` 只拷 `ci/`，项目里没有 `tests/`）。
# 它此前**没有任何执行点** —— `ci/workflows/*.yml` 与 `ci/gitlab/*.yml` 里 0 处提到它，
# `install.sh` / `upgrade.sh` 也不带它；它只被三处**散文**引用（README 的目录树、
# `ci/README.md` 的「改 X 后跑它」、以及 HOG 规则把它当「可复现证据」）。
# 按本套件自己的标准（「没有执行点的声明等于没声明」），这是一句没有落点的声明 ——
# 而 `closed-loop-audit.sh` 恰恰是为抓这类东西存在的，它自己却漏了。
#
# 故本脚本是那个落点，并由 `.githooks/pre-commit` 在套件仓库里自动跑（见该文件）。
#
# ## 用法
#
#   ./ci/bin/harness-selftest.sh              # 跑全部 tests/*/run.sh
#   ./ci/bin/harness-selftest.sh depcheck …   # 只跑指定的几个
#
# 退出码: 0=全部通过 / 1=有失败 / 2=环境不可用（解释器跑不起来）
# 环境变量: HARNESS_TEST_PYTHON=<真解释器>（Windows 上 python3 是 Store 桩时用）
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TDIR="$ROOT/tests"

# 项目里没有 tests/（不分发）→ **不是失败**，是「本仓无套件自测」。**必须显式说明**，
# 不能静默 exit 0 —— 「没跑」与「跑了没问题」长得一样是本套件反复抓到的缺陷类。
if [ ! -d "$TDIR" ]; then
  echo "[selftest] 本仓无 tests/（套件自测不分发到项目）——跳过，非失败" >&2
  exit 0
fi

# 解释器守卫：占位桩下每个套件都会「静默跑出 0 条断言」，而 0 条断言看起来像「没问题」
PY="${HARNESS_TEST_PYTHON:-python3}"
if ! "$PY" -c 'pass' >/dev/null 2>&1; then
  echo "[selftest] $PY 不可用（命令存在但执行失败；Windows 上常见为 Store 占位桩）" >&2
  echo "[selftest] 用 HARNESS_TEST_PYTHON=/path/to/python 指定真解释器" >&2
  exit 2
fi

# 选套件：给参数就只跑那几个；不给就**glob 全部** —— 用 glob 而不是硬编码清单，
# 新增一个 tests/<name>/ 自动被覆盖（清单会漂，而漂的表现是「新套件永远不跑」且没人发现）。
suites=()
if [ $# -gt 0 ]; then
  for s in "$@"; do
    [ -f "$TDIR/$s/run.sh" ] || { echo "[selftest] 无此套件: $s" >&2; exit 2; }
    suites+=("$s")
  done
else
  for d in "$TDIR"/*/run.sh; do
    [ -f "$d" ] || continue
    suites+=("$(basename "$(dirname "$d")")")
  done
fi
[ "${#suites[@]}" -gt 0 ] || { echo "[selftest] tests/ 下没有 run.sh —— 套件自测形同虚设" >&2; exit 1; }

fail=0
declare -a failed=()
for s in "${suites[@]}"; do
  echo "── $s ──"
  if HARNESS_TEST_PYTHON="$PY" bash "$TDIR/$s/run.sh"; then
    :
  else
    fail=1; failed+=("$s")
  fi
done

echo
if [ "$fail" -eq 0 ]; then
  echo "[selftest] 全部通过（${#suites[@]} 个套件）"
  exit 0
fi
echo "[selftest] 失败套件：${failed[*]}"
exit 1
