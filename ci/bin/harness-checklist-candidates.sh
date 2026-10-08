#!/usr/bin/env bash
# harness-checklist-candidates.sh — 只读扫描「跨项目复用候选」：列出带 `reuse: candidate` 的
# project-local checklist 项与 pitfall 规则，供 owner 审查后手动晋升到 suite 源（checklists/shared/、
# ci/rules/pitfalls.yaml）。只读：不落盘、不改状态、不晋升。晋升是 owner 手动提交 suite 的活。
#
# 用法: harness-checklist-candidates.sh
set -euo pipefail
export PYTHONUTF8=1  # PEP 540: Windows 强制 UTF-8（避免 GBK 读/写中文出错）

# 环境解析（解释器 / 编码）单源见 ci/bin/harness-env.sh；本机缓存 .harness/toolchain.env 由 harness-preflight.sh 生成。
# 本脚本主体在 python：占位桩下会**静默产出空**，与「真的没问题」不可分（gates-ls 盲区曾使对账变红）。
# shellcheck source=harness-env.sh
source "$(dirname "${BASH_SOURCE[0]}")/harness-env.sh"
py_ok || { echo "[candidates] python3 不可用（命令存在但执行失败；Windows 上常见为 Store 占位桩）——拒绝静默无事发生" >&2; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CK_DIR="$ROOT/.harness/checklists"
PITFALLS="$ROOT/.harness/pitfalls.yaml"

"$HARNESS_PYTHON" - "$ROOT/ci/bin" "$CK_DIR" "$PITFALLS" <<'PY'
import sys, os
sys.path.insert(0, sys.argv[1])
from checklist import load_items, pitfall_rules
ck_dir, pitfalls = sys.argv[2], sys.argv[3]

found = 0

# 1) project-local checklist 项：frontmatter 带 reuse: candidate
if os.path.isdir(ck_dir):
    for fn in sorted(os.listdir(ck_dir)):
        if not fn.endswith(".md"):
            continue
        domain = fn[:-3]
        for it in load_items(os.path.join(ck_dir, fn)):
            if it["reuse"] == "candidate":
                cid = it["id"] or "?"
                cat = it["category"] or "-"
                proj = it["project"] or "-"
                print(f"[candidate] checklist {cid}\tdomain={domain}\tcategory={cat}\tproject={proj}")
                found += 1
else:
    print("[candidates] 无 .harness/checklists/，无 project-local checklist 候选")

# 2) project-local pitfall 规则：metadata 带 reuse: candidate
if os.path.exists(pitfalls):
    for rid, reuse in pitfall_rules(pitfalls):
        if reuse == "candidate":
            print(f"[candidate] pitfall {rid}\t（Semgrep 规则，晋升到 ci/rules/pitfalls.yaml）")
            found += 1
else:
    print("[candidates] 无 .harness/pitfalls.yaml，无 project-local pitfall 候选")

if found == 0:
    print("[candidates] 无候选（0 条 reuse: candidate）")
PY
