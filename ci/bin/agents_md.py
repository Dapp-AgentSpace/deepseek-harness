#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""agents_md.py — 项目根 `AGENTS.md` 的 **受管路由块** 播种/对账（深模块）。

## 为什么需要它

`AGENTS.md` 是 agent 选 skill **之前**读的文件，它把研发诉求路由到 `harness` 入口（否则 agent 可能
直接落到 `cs-feat` 等 skill、跳过 harness 闭环）。但「本仓是 harness 项目、研发诉求先经 harness」
此前只是一句**没有落点的声明**：`harness-init` 不检查、`upgrade.sh` 不播种、`closed-loop-audit.sh`
不对账 —— 与套件反复抓的缺陷类同型（声明≠落盘）。

本模块是那个落点，两件事：
  - `ensure`：把 suite 的**受管块**（`ci/agents-routing.md`）播种/合并进项目根 `AGENTS.md`；
  - `check`：对账项目 `AGENTS.md` 是否**含且等于**该受管块（供 audit 判红）。

## 受管块 = `<!-- harness:begin -->` … `<!-- harness:end -->`

用标记界定「harness 拥有的那一段」，**合并而非覆盖**：标记内由 harness 管理、标记外的项目自有内容
原样保留。缺标记时**追加**该块（不删项目已有内容）—— 与 `install.sh` / `shared_sync` 的
「不静默覆盖用户机器状态」同一口径。

## 单一来源

canonical 块 = 项目 `ci/agents-routing.md`（随 `ci/` 由 `upgrade.sh` 整体同步，故 check 在项目内即可
读到最新）。`ci/agents-routing.md` 与套件根 `AGENTS.md` 的受管块必须一致 —— 套件自身的 audit 即守此
（`check` 拿 `$ROOT/ci/agents-routing.md` 对 `$ROOT/AGENTS.md`）。

## 接口

CLI：`agents_md.py <ensure|check> [ROOT]`（ROOT 缺省 = 脚本自身所在仓库根）。
  - `ensure`：幂等合并；stdout 打印 `[agents-md] <状态>`（created/updated/appended/ok/no-canonical）。
  - `check`：对账；ok 时静默退 0，有问题时**每行一个 issue 码**且退 1。
模块：`canonical(root)` / `extract_block(text)` / `merge(text, block)` / `ensure(root)` / `check(root)`。
"""

import os
import sys

BEGIN = "<!-- harness:begin -->"
END = "<!-- harness:end -->"
# canonical 块的文件名（相对项目根）：随 ci/ 分发，故项目内可读到。
CANON_REL = os.path.join("ci", "agents-routing.md")
AGENTS = "AGENTS.md"
# 无 AGENTS.md 时新建文件的头部（标记外内容；不携带任何 project.id —— 块是项目无关的路由声明）。
NEW_HEADER = "# AGENTS.md\n"


def _read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return None


def _write(path, text):
    # 强制 LF：.gitattributes 归一为 LF，混入 CRLF 会让「块比对」在 Windows 上假红。
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)


def canonical(root):
    """读项目 `ci/agents-routing.md`；缺失/不可读 → None。"""
    return _read(os.path.join(root, CANON_REL))


def extract_block(text):
    """取受管块（含标记）；无完整标记 → None。"""
    if text is None:
        return None
    i = text.find(BEGIN)
    if i < 0:
        return None
    j = text.find(END, i + len(BEGIN))
    if j < 0:
        return None
    return text[i:j + len(END)]


def merge(text, block):
    """把 block 合并进 text：有标记则替换标记段，无标记则追加（保留 text 其余内容）。"""
    if text is None or not text.strip():
        return NEW_HEADER + "\n" + block.rstrip("\n") + "\n"
    old = extract_block(text)
    if old is not None:
        i = text.find(BEGIN)
        j = text.find(END, i + len(BEGIN)) + len(END)
        return text[:i] + block.rstrip("\n") + text[j:]
    sep = "" if text.endswith("\n") else "\n"
    return text + sep + "\n" + block.rstrip("\n") + "\n"


def ensure(root):
    """幂等合并受管块进 `<root>/AGENTS.md`。返回状态串（供调用方 emit）。"""
    block = canonical(root)
    if block is None:
        return "no-canonical"
    path = os.path.join(root, AGENTS)
    text = _read(path)
    if text is None:
        _write(path, merge(None, block))
        return "created"
    merged = merge(text, block)
    if merged == text:
        return "ok"
    _write(path, merged)
    # 原本无标记 → 走的是追加分支（项目自有内容保留）；有标记 → 替换。
    return "updated" if extract_block(text) is not None else "appended"


def check(root):
    """对账 `<root>/AGENTS.md`。返回 (ok, issues)；issues 为**码**（消息归 audit_checks.py，单一来源）。

    码：`no-canonical`（ci/agents-routing.md 缺失，无法对账）/ `missing`（无 AGENTS.md）/
    `no-block`（有 AGENTS.md 但无受管块标记）/ `stale`（受管块与 canonical 不一致）。
    """
    block = canonical(root)
    if block is None:
        return False, ["no-canonical"]
    text = _read(os.path.join(root, AGENTS))
    if text is None:
        return False, ["missing"]
    cur = extract_block(text)
    if cur is None:
        return False, ["no-block"]
    if cur.strip() != block.strip():
        return False, ["stale"]
    return True, []


def main(argv):
    if not argv or argv[0] not in ("ensure", "check"):
        sys.stderr.write("用法: agents_md.py <ensure|check> [ROOT]\n")
        return 2
    cmd = argv[0]
    root = argv[1] if len(argv) > 1 else os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
    if cmd == "ensure":
        st = ensure(root)
        print("[agents-md] %s" % st)
        # no-canonical 是环境问题（ci/ 未同步），不是「已处理」——退 2 让调用方看见。
        return 2 if st == "no-canonical" else 0
    ok, issues = check(root)
    for code in issues:
        print("[agents-md] %s" % code)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
