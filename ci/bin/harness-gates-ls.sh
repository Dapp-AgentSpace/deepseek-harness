#!/usr/bin/env bash
# harness-gates-ls.sh — 读 ci/gates.yaml（门禁注册表），输出 TSV：key \t name \t type \t extra \t binding \t on_ramp
#   extra：deterministic → switch（identity.yaml gates.* 路径）；judge → runner。
#   binding：true=铁律永远跑 / false=流程按 on_ramp；on_ramp：light=轻风险也开 / full=仅重风险开。
# 供 harness-gate.sh（跑确定性门禁）与 closed-loop-audit.sh（对账）共用，YAML 解析逻辑只此一处。
set -euo pipefail
export PYTHONUTF8=1  # PEP 540: Windows 强制 UTF-8（避免 GBK 读/写中文出错）

# 环境解析（解释器 / 编码）单源见 ci/bin/harness-env.sh；本机缓存 .harness/toolchain.env 由 harness-preflight.sh 生成。
# 本脚本主体在 python：占位桩下会**静默产出空**，与「真的没问题」不可分（gates-ls 盲区曾使对账变红）。
# shellcheck source=harness-env.sh
source "$(dirname "${BASH_SOURCE[0]}")/harness-env.sh"
py_ok || { echo "[gates-ls] python3 不可用（命令存在但执行失败；Windows 上常见为 Store 占位桩）——拒绝静默无事发生" >&2; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REG="$ROOT/ci/gates.yaml"
[ -f "$REG" ] || { echo "缺少 $REG（门禁注册表）" >&2; exit 2; }

"$HARNESS_PYTHON" - "$REG" <<'PY'
import sys, re
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
text = open(sys.argv[1], encoding="utf-8").read()
blocks = re.split(r"^\s*-\s*key:\s*", text, flags=re.M)[1:]
if not blocks:
    sys.stderr.write("ci/gates.yaml 未解析到任何门禁（缺少 - key: 块或格式不符）\n")
    sys.exit(2)
for b in blocks:
    key = b.split("\n", 1)[0].strip()
    name = re.search(r"^\s*name:\s*(.*)", b, re.M)
    typ  = re.search(r"^\s*type:\s*(\S+)", b, re.M)
    sw   = re.search(r"^\s*switch:\s*(.*)", b, re.M)
    run  = re.search(r"^\s*runner:\s*(.*)", b, re.M)
    bind = re.search(r"^\s*binding:\s*(\S+)", b, re.M)
    ramp = re.search(r"^\s*on_ramp:\s*(\S+)", b, re.M)
    name = name.group(1).strip() if name else ""
    typ  = typ.group(1) if typ else ""
    # binding 缺省：deterministic=铁律(true)；judge=流程(false)。on_ramp 仅 judge 有意义：
    #   deterministic(binding=true) 输出 "-"（不适用）；judge 缺省 light（默认审查）。
    bind = bind.group(1) if bind else ("true" if typ == "deterministic" else "false")
    ramp = ramp.group(1) if ramp else ("-" if bind == "true" else "light")
    extra = ""
    if sw:   extra = sw.group(1).strip()
    elif run: extra = run.group(1).strip()
    print(f"{key}\t{name}\t{typ}\t{extra}\t{bind}\t{ramp}")
PY
