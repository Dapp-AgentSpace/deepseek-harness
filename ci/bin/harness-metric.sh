#!/usr/bin/env bash
# harness-metric.sh — MetricEvent 的 append-only 写入器（ADR-0012 决策 2）。
# 一事件一行 JSONL，落到 .harness/reports/metric-events.jsonl。
#
# 三约束（ADR-0012 决策 2）：
#   1) append-only：只追加，本脚本永远不改写已有行；
#   2) 单一写者：stage 字段即写者身份，各阶段只写自己的 stage；
#   3) 来源必填：--source 缺省 = 未知来源，仍记但标 unknown（供对账发现）。
#
# 口径（ADR-0012 决策 5）：指标是**观测**，不是门禁 —— 本脚本失败**绝不**影响调用方（返回 0 或
# 静默降级到 stderr），调用方也不得因它失败而改变自己的退出码。
#
# 用法: harness-metric.sh <stage> <metric> <value> [--source <s>] [--run <runcard-id>]
#
# `--run`（ADR-0016 决策 2）：当前 RunCard id（= 该事件的 run 归属），**可选**；缺省不写该字段。
# 调用方（harness-gate.sh / judge-review.sh）从 `HARNESS_RUNCARD` env 取值；取不到就不传。
#
# 门禁事件的退出码就写在 `value` 里（`harness-gate.sh` 传 `$grc`），**没有单独的 gate 参数** ——
# 此前有个 `--gate` 会写 `ev["gate_result"]`，但全仓 0 个调用者，而读者（`metrics.c_gate_result`）
# 读的是 `value`：一个从没被写过的字段 + 一个没人传的参数 = 死接口面（已删）。
set -euo pipefail
export PYTHONUTF8=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUT="$ROOT/.harness/reports/metric-events.jsonl"
# 环境解析（解释器 / 编码）单源见 ci/bin/harness-env.sh；本机缓存 .harness/toolchain.env 由 harness-preflight.sh 生成。
# shellcheck source=harness-env.sh
source "$ROOT/ci/bin/harness-env.sh"

"$HARNESS_PYTHON" - "$OUT" "$@" <<'PY'
import json, os, sys
from datetime import datetime

out, stage, metric, value = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] if len(sys.argv) > 4 else ""
source = ""
run = ""
i = 5
while i < len(sys.argv):
    a = sys.argv[i]
    if a == "--source" and i + 1 < len(sys.argv):
        source = sys.argv[i + 1]; i += 2
    elif a == "--run" and i + 1 < len(sys.argv):
        run = sys.argv[i + 1]; i += 2
    else:
        i += 1

STAGES = {"plan", "build", "verify", "review", "close", "global"}
if stage not in STAGES:
    sys.stderr.write("[metric] stage 非法 %r（须 %s）\n" % (stage, "/".join(sorted(STAGES))))
    sys.exit(0)                                   # 观测不阻断调用方
if not metric or value == "":
    sys.stderr.write("[metric] metric/value 不能为空\n")
    sys.exit(0)

ev = {
    "ts": datetime.now().isoformat(timespec="seconds"),
    "stage": stage,
    "metric": metric,
    "value": value,
    "source": source or "unknown",
}
# run（ADR-0016 决策 2）：**可选**字段 = 当前 RunCard id。取不到就**不带**（不伪造）——
# 缺 `run` 的事件视为「未归属」，不计入任何 per-run 视图（`metrics.py --run` / `harness-measure.sh --run`）。
if run:
    ev["run"] = run

os.makedirs(os.path.dirname(out), exist_ok=True)
try:
    with open(out, "a", encoding="utf-8") as f:   # append-only；永不改写
        f.write(json.dumps(ev, ensure_ascii=False) + "\n")
except OSError as e:
    sys.stderr.write("[metric] 写入失败（%s）—— 观测丢弃，不阻断\n" % e)
sys.exit(0)
PY
