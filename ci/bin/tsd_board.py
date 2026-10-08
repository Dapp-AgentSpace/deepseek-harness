#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""tsd_board.py — TSD 花名册派生视图的聚合深模块（ADR-0012 决策 4）。

## 它是派生视图，不是实体

ADR-0012 决策 4：答不上「谁消费它、怎么检测从未被消费」的产出，一律改为**派生视图（不落盘，用时生成）**。
本模块只往 stdout 打，**不写任何文件**，**不 spawn agent**（agent 入口是 harness skill，视图只产出 slug）。

## 来源（每一项都能回指一个实体的字段，不人手另写）

| 卡片字段 | 来源 | 怎么取 |
|---|---|---|
| slug / status / task / 冻结 | TSD frontmatter（`.harness/tsd/{pid}-{slug}.md`） | 直接读（真相源，ADR-0004） |
| RunCard phase | RunCard（`tsd` 回指本 TSD 的最新卡） | 经 handoff.find_runcard + runcard_section（**单一归属**，不另写定位） |
| 未解阻塞 | work-unit 的 `blocked_by` 未解析者 | 经 handoff.leftovers_section（**单一归属**，不重写解析） |

单 TSD 详情**复用** `harness-handoff.sh <slug>`（深链），本视图不重造详情渲染。

## 取不到就说不出来，不装作没有

`.harness/tsd/` **缺失** / **为空** 时输出**显式一行说明**，不输出空段 —— 空段读起来像「本项无事」，
而真相是「本视图看不到」。同 metrics.py 的四种状态纪律。
"""

import glob
import json
import os
import sys
from datetime import datetime

# 强制 stdout/stderr 为 UTF-8（Windows 默认 GBK 会把中文消息写成乱码）。与 depgraph.py / metrics.py
# 等同款：Python CLI 自锁 UTF-8 输出，不赖调用方 export。
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import handoff  # noqa: E402  RunCard 定位 / 遗留项解析的单一归属（本模块不另抄一份）
from identity import project_id  # noqa: E402  project.id 读取单一归属（同 harness-identity.sh 的 h_id）
from work_unit import _parse_fm  # noqa: E402  frontmatter 块 → dict（单一归属，同 handoff）


def _read(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def _tsd_files(root, pid):
    """`.harness/tsd/{pid}-*.md` 列表（ADR-0004 命名）；目录**缺失**返回 None（与「空目录返回 []」不同 —— 见四种状态纪律）。
    只认 `{pid}-` 前缀：散落在目录里的非 TSD `.md`（如 README）不臆造成卡片（同 harness-tsd-sync-check 口径）。"""
    d = os.path.join(root, ".harness", "tsd")
    if not os.path.isdir(d):
        return None
    pat = (pid + "-*.md") if pid else "*.md"
    files = sorted(glob.glob(os.path.join(d, pat)))
    if not pid:
        # 缺 identity.yaml（pid 为空）时**无法**按 ADR-0004 的 `{pid}-` 前缀识别 —— 不能退回 `*.md`
        # 把目录里任意文件（如 README）臆造成卡片（那会重开 L3 修掉的缺陷）。退一步只认 frontmatter
        # `type: tsd`，与 pid 分支同口径：非 TSD 一律不入册。
        files = [f for f in files if _parse_fm(_read(f)).get("type") == "tsd"]
    return files


def _slug_of(path, fm, pid):
    """slug：优先 frontmatter `slug`，否则从文件名 `{pid}-{slug}.md` 剥前缀。"""
    s = (fm.get("slug") or "").strip()
    if s:
        return s
    base = os.path.basename(path)[:-3]
    if pid and base.startswith(pid + "-"):
        return base[len(pid) + 1:]
    return base


def collect(root):
    """派生每张 TSD 卡片。返回 (state, cards, errors)；state ∈ {missing, empty, ok, error}。

    `error` = 有 TSD 文件解析不了（无 frontmatter 块）—— 与 `ok` 严格区分：解析不了的卡片不能
    静默降级成 `status: ?` 混进正常名单（同 metrics 四态纪律：来源在但解析不了必须响亮报出）。
    """
    pid = project_id(root)
    files = _tsd_files(root, pid)
    if files is None:
        return "missing", [], []
    if not files:
        return "empty", [], []
    cards, errors = [], []
    for p in files:
        fm = _parse_fm(_read(p))
        if not fm:
            errors.append(os.path.basename(p))   # 无 frontmatter 块 = 解析不了（不是「字段为空」）
            continue
        slug = _slug_of(p, fm, pid)
        # RunCard phase：经 handoff 的定位/解析（单一归属，不另写「同 TSD 取最新卡」的逻辑）
        phase = ""
        card = handoff.find_runcard(root, slug)
        if card:
            cfm, _text, _lines = handoff.runcard_section(root, card)
            phase = (cfm.get("phase") or "").strip()
        # 未解阻塞：经 handoff.leftovers_section（单一归属）；None = 判不了（无 work-unit / 无回链指向
        # 本 TSD），与 0（真有 work-unit 且 blocked_by 全解析）严格区分 —— 不把「判不了」塌成 0。
        _left, n_open = handoff.leftovers_section(root, pid, slug)
        cards.append({
            "slug": slug,
            "status": (fm.get("status") or "").strip() or "?",
            "task": (fm.get("task") or "").strip() or "?",
            "frozen": (fm.get("tsd_frozen") or "").strip().lower() == "true",
            "runcard_phase": phase,
            "unresolved_blockers": n_open,
        })
    cards.sort(key=lambda c: c["slug"])
    if errors:
        return "error", cards, errors
    return "ok", cards, []


def _entry_lines(slug):
    """每张卡的「看详情」（深链，复用 handoff）+「引用开工」（产出 slug，交给 harness 入口）两个入口。"""
    return ("- **%s** — 看详情：`./ci/bin/harness-handoff.sh %s` ｜ 引用开工：把 slug 交给 harness 入口，"
            "如 `harness-run %s`" % (slug, slug, slug))


def _cell(v):
    """markdown 表格单元格：转义 `|`（一个未转义的竖线会撑破整张表，破坏派生视图的可信度）。"""
    return (v or "").replace("|", "\\|")


def render_text(state, cards, errors):
    out = []
    out.append("# TSD 花名册（派生视图 · 非落盘产物）")
    out.append("")
    out.append("> 生成于 %s ｜ 来源：`.harness/tsd/*.md`（+ RunCard phase / work-unit 未解阻塞，派生）。"
               % datetime.now().isoformat(timespec="seconds"))
    out.append("> **本视图不落盘**：从 TSD frontmatter 等实体的字段聚合，用时生成（ADR-0012 决策 4）。"
               "别把它另存成文件 —— 那会造出第二份须手工同步的事实。")
    out.append("")
    if state == "missing":
        out.append("> **无 TSD 目录**：`.harness/tsd/` 不存在 —— 本仓可能尚未跑过 `harness-plan` / "
                   "`harness-init`。**本视图无从派生**（这不等于「没有 TSD」）。")
        return "\n".join(out) + "\n"
    if state == "empty":
        out.append("> **无 TSD**：`.harness/tsd/` 为空（0 份）—— 本视图无从派生。"
                   "先经 `harness-plan` 落一份冻结 TSD。")
        return "\n".join(out) + "\n"
    if state == "error":
        out.append("> **有 TSD 解析不了**（无 frontmatter 块）：%s。花名册**不完整** —— 这不是"
                   "「只有下列 TSD」，是「下列可解析，另有上述文件解析不了」。" %
                   "、".join("`%s`" % e for e in errors))
        out.append("")
        out.append("可解析 %d 份 TSD。" % len(cards))
    else:
        out.append("共 %d 份 TSD。" % len(cards))
    out.append("")
    out.append("| slug | status | task | 冻结 | RunCard phase | 未解阻塞 |")
    out.append("|---|---|---|---|---|---|")
    for c in cards:
        out.append("| `%s` | %s | %s | %s | %s | %s |" % (
            _cell(c["slug"]), _cell(c["status"]), _cell(c["task"]),
            "是" if c["frozen"] else "否",
            _cell(c["runcard_phase"] or "—"),
            "判不了" if c["unresolved_blockers"] is None else "%d" % c["unresolved_blockers"]))
    out.append("")
    out.append("## 入口（每张卡）")
    out.append("")
    for c in cards:
        out.append(_entry_lines(c["slug"]))
    out.append("")
    out.append("> 口径：本视图**只读、不落盘、不 spawn agent**。status 的真相源是 TSD frontmatter（ADR-0004），"
               "视图不另存状态；开工/推进由 harness skill 执行，视图只产出 slug。")
    return "\n".join(out) + "\n"


def render_json(state, cards, errors):
    doc = {
        "schema_version": 1,
        "state": state,          # ok | empty | missing | error（四态：判不了不塌成空/缺）
        "count": len(cards),
        "errors": errors,        # state=error 时非空：解析不了的 TSD 文件名（花名册不完整）
        "tsds": [
            {
                "slug": c["slug"],
                "status": c["status"],
                "task": c["task"],
                "frozen": c["frozen"],
                "runcard_phase": c["runcard_phase"] or None,
                "unresolved_blockers": c["unresolved_blockers"],
                "handoff": "./ci/bin/harness-handoff.sh " + c["slug"],
                "harness_call": "harness-run " + c["slug"],
            }
            for c in cards
        ],
    }
    return json.dumps(doc, ensure_ascii=False, indent=2) + "\n"


def main(argv):
    if not argv or argv[0].startswith("-") or not os.path.isdir(argv[0]):
        sys.stderr.write("用法: tsd_board.py <root> [--json]\n")
        return 2
    root = argv[0]
    as_json = "--json" in argv[1:]
    state, cards, errors = collect(root)
    sys.stdout.write(render_json(state, cards, errors) if as_json else render_text(state, cards, errors))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
