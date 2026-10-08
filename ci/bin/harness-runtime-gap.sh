#!/usr/bin/env bash
# harness-runtime-gap.sh — 只读列出「没爬满 CONTRACT-001 rung 4」的项目规约：checklist 项标了
# runtime: data|log（有线上可观测形态），但缺对应运行时契约 .harness/contracts/{pid}-runtime-{domain}.md
# 或缺执行配置 .harness/runtime-config.yaml 里的 {domain} 项（方向 B：不再生成 per-domain _check.sh）。
# 供 harness-close 收尾时据此补齐爬梯。只读，不落盘。
#
# 用法: harness-runtime-gap.sh
set -euo pipefail
export PYTHONUTF8=1  # PEP 540: Windows 强制 UTF-8（避免 GBK 读/写中文出错）

# 环境解析（解释器 / 编码）单源见 ci/bin/harness-env.sh；本机缓存 .harness/toolchain.env 由 harness-preflight.sh 生成。
# 本脚本主体在 python：占位桩下会**静默产出空**，与「真的没问题」不可分（gates-ls 盲区曾使对账变红）。
# shellcheck source=harness-env.sh
source "$(dirname "${BASH_SOURCE[0]}")/harness-env.sh"
py_ok || { echo "[runtime-gap] python3 不可用（命令存在但执行失败；Windows 上常见为 Store 占位桩）——拒绝静默无事发生" >&2; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=harness-identity.sh
source "$ROOT/ci/bin/harness-identity.sh"
CK_DIR="$ROOT/.harness/checklists"
CONTRACTS="$ROOT/.harness/contracts"
PID="$(h_id)"; [ -n "$PID" ] || PID="unknown"

"$HARNESS_PYTHON" - "$ROOT/ci/bin" "$CK_DIR" "$CONTRACTS" "$ROOT" "$PID" <<'PY'
import sys, os
sys.path.insert(0, sys.argv[1])
from checklist import load_items
try:
    import yaml
except ImportError:
    print("[runtime-gap] 需 PyYAML（pip install -r ci/requirements-runtime.txt）才能核对 runtime-config.yaml")
    sys.exit(2)
ck_dir, contracts, root, pid = sys.argv[2:6]

def load_yaml(path):
    if not os.path.isfile(path):
        return {}
    with open(path, encoding="utf-8") as f:
        return yaml.safe_load(f) or {}

runtime_cfg = load_yaml(os.path.join(root, ".harness", "runtime-config.yaml"))

gaps = 0
if not os.path.isdir(ck_dir):
    print("[runtime-gap] 无 .harness/checklists/，无 checklist 项可爬梯")
    sys.exit(0)

for fn in sorted(os.listdir(ck_dir)):
    if not fn.endswith(".md"):
        continue
    domain = fn[:-3]
    runtime_items = []
    for it in load_items(os.path.join(ck_dir, fn)):
        rt = it["runtime"] or "none"
        if rt in ("data", "log"):
            cid = it["id"] or "?"
            runtime_items.append((cid, rt))
    if not runtime_items:
        continue
    contract = os.path.join(contracts, f"{pid}-runtime-{domain}.md")
    missing = []
    if not os.path.exists(contract):
        missing.append("contract")
    if domain not in runtime_cfg:
        missing.append("runtime-config")
    if missing:
        for cid, rt in runtime_items:
            print(f"[runtime-gap] {cid}  domain={domain}  runtime={rt}  缺 {','.join(missing)}（未爬满 rung 4）")
        gaps += 1

if gaps == 0:
    print("[runtime-gap] 无缺口（所有 runtime 标记项均已落契约 + runtime-config.yaml）")
PY
