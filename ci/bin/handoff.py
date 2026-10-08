#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""handoff.py — Handoff 派生视图的聚合深模块（ADR-0012 决策 1 / 决策 4）。

## 它是派生视图，不是实体

ADR-0012 决策 1 明确 Handoff **不落盘**：「完成项/遗留项/风险/决策/下一步 每一项都是别的实体的字段」，
立成独立实体 = 制造第二份须手工同步的事实（正是跨轮撞车的来源）。决策 4 把这条推到结论：
答不上「谁消费它、怎么检测从未被消费」的产出，一律**改为派生视图（不落盘，用时生成）** ——
于是「产出即闲置」在结构上不可能。本模块只往 stdout 打，**不写任何文件**。

「下一轮真的读了它」不靠这个视图自证，靠 `handoff_from` 链强制（`closed-loop-audit` 查链断没断）。

## 来源（每一项都能回指一个实体的字段，不人手另写）

| 段 | 来源 | 怎么取 |
|---|---|---|
| 执行态 | RunCard（`phase`/`rounds`/`tsd`/`handoff_from`） | 直接读卡 |
| 本轮前提 | RunCard 正文「本轮前提（动别处前必读）」 | 直接读卡（**非派生**，唯一该由人/agent 写的一段） |
| 遗留项 | work-unit 的 `blocked_by` 未解析者 | 经 `work_unit.blockers_resolved`（单一归属，不重写解析） |
| 未解 blocking | ReviewRecord（`*.md` 报告的发现清单） | 按 `target` 匹配本 TSD；取**最新一轮** |
| 结构性决定 | ADR（本轮前提里作为「耦合位置」出现的 `ADR/…` 路径） | 扫前提条目里的路径，**不新造回指机制** |

## 取不到就说不出来，不装作没有

每一段若派生不出（来源缺、匹配不上），输出**显式的一行说明 + 原因**，不输出空段 ——
空段读起来像「本项无事」，而真相是「本视图看不到」。同 metrics.py 的四种状态纪律。
"""

import os
import re
import sys
import glob
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from work_unit import blockers_resolved, parse_blocked_by, locate, _parse_fm  # noqa: E402
from identity import project_id  # noqa: E402  project.id 读取单一归属（同 harness-identity.sh 的 h_id）
import review_record as rr  # noqa: E402  ReviewRecord 深模块（单一归属）


def _read(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


# frontmatter 读取归 review_record.fm（**块内**匹配）。此前这里是第 3 份同名实现 ——
# 且它与 `checklist.fm`（**全文**匹配）语义不同，是同一个词两种含义的一处实例。
_fm = rr.fm


def _body(text):
    return re.sub(r"^---[ \t]*\n.*?\n---[ \t]*", "", text, count=1, flags=re.S).lstrip("\n")


# ---- RunCard ----

def find_runcard(root, key):
    """按 RunCard id 或 TSD slug 定位卡片。返回路径或 None。

    接受 id（`{pid}-rc-{slug}[-N]`）或 tsd-slug；同 TSD 多卡时取**最新**（后缀号最大）。
    """
    d = os.path.join(root, ".harness", "runcards")
    if not os.path.isdir(d):
        return None
    cards = sorted(glob.glob(os.path.join(d, "*.md")))
    if not cards:
        return None
    def _seq(p):
        m = re.search(r"-(\d+)$", os.path.basename(p)[:-3])
        return int(m.group(1)) if m else 1
    cands = []
    for c in cards:
        base = os.path.basename(c)[:-3]
        if base == key or base.endswith("-rc-" + key):
            cands.append(c)
            continue
        t = _fm(_read(c), "tsd") or ""
        if t == key or t.endswith("-" + key) or t == os.path.basename(key):
            cands.append(c)
    if not cands:
        return None
    return max(cands, key=_seq)


def runcard_section(root, card_path):
    text = _read(card_path)
    fm = {k: _fm(text, k) for k in ("id", "tsd", "handoff_from", "phase", "rounds", "started", "updated")}
    lines = ["## 执行态（RunCard）", ""]
    lines.append("| 字段 | 值 |")
    lines.append("|---|---|")
    for k in ("id", "tsd", "phase", "rounds", "handoff_from", "started", "updated"):
        v = fm.get(k)
        lines.append("| `%s` | %s |" % (k, ("—" if v in (None, "") else v)))
    return fm, text, lines


def premises_section(text):
    """本轮前提（非派生 context）——RunCard 正文里唯一该手写的一段。"""
    m = re.search(r"^##[ \t]*本轮前提[^\n]*$", text, re.M)
    lines = ["## 本轮前提（非派生：推不出来的假设 + 耦合位置）", ""]
    if not m:
        lines.append("> 本卡无「本轮前提」段。**这不是「本轮没立前提」** —— 是这张卡没写。"
                     "该段是跨轮撞车的根因所在，缺它下一轮只能靠猜。")
        return lines, []
    rest = text[m.end():]
    nxt = re.search(r"^##[ \t]", rest, re.M)
    if nxt:
        rest = rest[:nxt.start()]
    body = rest.strip()
    if not body:
        lines.append("> 「本轮前提」段存在但为空。")
        return lines, []
    lines.append(body)
    lines.append("")
    # 结构性决定：前提里作为「耦合位置」出现的 ADR 路径（不新造回指机制，用现有格式）
    adrs = sorted(set(re.findall(r"(?:^|[\s`(（])(/?ADR/[0-9A-Za-z._-]+\.md)", body)))
    return lines, adrs


# ---- work-unit 遗留项 ----

def _tsd_matches(val, pid, slug):
    """work-unit 的 `tsd` 字段值是否指向本 TSD。

    两种真实写法都要认：schema 写的是 slug（`{pid}-{slug}`），而 `harness-status.sh` 回写的是
    **相对路径**（`.harness/tsd/{pid}-{slug}.md`）。只认一种会把整段遗留项判成空 —— 而空段
    读起来像「本轮没有遗留」，正好反了。
    """
    v = (val or "").strip()
    if not v:
        return False
    base = os.path.basename(v)
    if base.endswith(".md"):
        base = base[:-3]
    want = "%s-%s" % (pid, slug) if pid else slug
    return base == want or base == slug or v == want or v == slug


def leftovers_section(root, pid, slug):
    """返回 (lines, n)：n = 有未解阻塞的 work-unit 数；**判不了时为 None**。

    `None`（无 work-unit 文件 / 无回链指向本 TSD）与 `0`（真有 work-unit 且 `blocked_by` 全部已解析）
    必须严格区分 —— 二者含义相反，塌成同一个 0 会把「本视图看不到」读成「本项无事」，
    正是 metrics 四态纪律（判不了不塌成 0）在派生视图上的落点。
    """
    lines = ["## 遗留项（`blocked_by` 未解析的 work-unit）", ""]
    wd = os.path.join(root, ".harness", "work")
    files = sorted(glob.glob(os.path.join(wd, "*.md")))
    if not files:
        # 也看 CodeStable 侧：适配层（work_unit.locate）会回退到 .codestable/work/
        cs = sorted(glob.glob(os.path.join(root, ".codestable", "work", "*.md")))
        if not cs:
            lines.append("> 无 work-unit（`.harness/work/` 与 `.codestable/work/` 均空）—— 遗留项无从派生。")
            return lines, None
        files = cs
    mine, dangling_note = [], []
    for f in files:
        fm = _parse_fm(_read(f))
        if not _tsd_matches(fm.get("tsd"), pid, slug):
            continue
        mine.append(fm)
    if not mine:
        lines.append("> 没有 work-unit 的 `tsd` 回链指向本 TSD —— **遗留项判不了**。"
                     "回链由 `harness-status.sh` 回写；没回写时本视图看不到任何单元，"
                     "这既可能是「本 TSD 确实没有 work-unit」，也可能是「回链没写」。")
        return lines, None
    n = 0
    for fm in mine:
        wid = fm.get("id") or "?"
        blockers = blockers_resolved(root, wid)
        openb = [b for b in blockers if not b["resolved"]]
        if not openb:
            continue
        n += 1
        lines.append("- **%s**（status=%s）被阻塞：" % (wid, fm.get("status") or "?"))
        for b in openb:
            if b["status"] == "dangling":
                lines.append("  - `%s` —— **悬空边**：该 id 找不到对应 work-unit（已删/改名/写错）。"
                             "悬空边是缺陷，不当已解析放过。" % b["id"])
                dangling_note.append(b["id"])
            else:
                lines.append("  - `%s`（status=%s）—— 未达终态，故本单元是遗留项" % (b["id"], b["status"]))
    if n == 0:
        lines.append("> 本 TSD 的 %d 个 work-unit 的 `blocked_by` 全部已解析 —— 无遗留项。" % len(mine))
    lines.append("")
    return lines, n


# ---- ReviewRecord 未解 blocking ----
# 报告解析（目标分类 / 与 TSD 的匹配 / 发现清单）归 **ci/bin/review_record.py**（深模块，单一归属）。
# 此前这里自带 `_CODE_SUFFIXES` + `_findings` + 一段 slug 匹配，与 metrics.py 的同名实现**已经矛盾**
# （实测 `diff`/`arch` 在本模块判 design、在 metrics 判 code）—— 同一个 target 两个答案。
# 见 review_record.py 的头注释。

def review_section(root, pid, slug):
    lines = ["## 未解 blocking（ReviewRecord）", ""]
    reps = rr.for_tsd(root, slug, pid)
    if not reps:
        lines.append("> 没有 `target` 指向本 TSD 的评审报告 —— 未解 blocking 判不了"
                     "（也可能本 TSD 还没评审过）。")
        return lines, 0
    # 取最新一轮：设计评审与代码评审各取各自最高轮（口径不同，混取会把旧轮当新轮）
    n = 0
    for kind in ("design", "code"):
        sub = sorted([r for r in reps if r["kind"] == kind], key=lambda r: (r["round"] or 0))
        if not sub:
            continue
        r = sub[-1]
        label = "设计/TSD 评审" if kind == "design" else "代码评审"
        fs = r["findings"]
        if fs is None:
            lines.append("- **%s**（`%s` round=%s）：该报告无「发现清单/发现分级」节 —— "
                         "**blocking 数判不了**，不是「没有 blocking」。" % (label, r["file"], r["round"]))
            continue
        items = fs["items"]["blocking"]
        if not items:
            lines.append("- **%s**（`%s` round=%s）：无 blocking。" % (label, r["file"], r["round"]))
            continue
        n += len(items)
        lines.append("- **%s**（`%s` round=%s）%d 条 blocking：" % (label, r["file"], r["round"], len(items)))
        for it in items:
            lines.append("  - %s" % it)
    lines.append("")
    lines.append("> 口径：取**最新一轮**报告的快照。本轮之后是否已修**不在本视图判定范围** ——"
                 "那是 verify / review 的职责，本视图只做聚合。")
    lines.append("")
    return lines, n


def adr_section(root, adrs):
    lines = ["## 本轮结构性决定（ADR）", ""]
    if not adrs:
        lines.append("> 本轮前提里没有引用任何 `ADR/…` 路径 —— 派生不出结构性决定。"
                     "**这不等于本轮没有决定**：它只说明前提条目没把 ADR 记为「耦合位置」。"
                     "（ADR-0012 决策 1 明确不建中心化 TraceLink，故这里不猜。）")
        return lines
    for rel in adrs:
        rel = rel.lstrip("/")
        p = os.path.join(root, rel)
        if not os.path.isfile(p):
            lines.append("- `%s` —— **引用了但文件不存在**" % rel)
            continue
        text = _read(p)
        title = next((ln.lstrip("# ").strip() for ln in text.splitlines() if ln.startswith("# ")), rel)
        status = ""
        m = re.search(r"^状态：([^·\n]+)", text, re.M)
        if m:
            status = m.group(1).strip()
        lines.append("- `%s`%s —— %s" % (rel, ("（%s）" % status if status else ""), title))
    return lines


def build(root, key):
    card = find_runcard(root, key)
    if not card:
        return None
    pid = project_id(root)   # project.id 读取单一归属（ci/bin/identity.py；同 harness-identity.sh h_id）
    fm, text, head = runcard_section(root, card)
    slug = (fm.get("tsd") or "").strip()
    if slug.startswith(pid + "-"):
        slug = slug[len(pid) + 1:]
    prem, adrs = premises_section(text)
    left, n_left = leftovers_section(root, pid, slug)
    rev, n_rev = review_section(root, pid, slug)
    out = []
    out.append("# Handoff（派生视图 · 非落盘产物）")
    out.append("")
    out.append("> 生成于 %s ｜ 来源：RunCard + work-unit + ReviewRecord + ADR（ADR-0012 决策 1）。" %
               datetime.now().isoformat(timespec="seconds"))
    out.append("> **本视图不落盘**：它是从别的实体的字段聚合出来的，用时生成。别把它另存成文件 ——"
               " 那会造出第二份须手工同步的事实（正是跨轮撞车的来源）。")
    out.append("")
    out += head
    out.append("")
    out += prem
    out += left
    out += rev
    out += adr_section(root, adrs)
    out.append("")
    out.append("---")
    out.append("")
    left_txt = "判不了" if n_left is None else "%d 个" % n_left
    out.append("**汇总**：遗留项 %s · 未解 blocking %d 条 · 引用 ADR %d 份。" % (left_txt, n_rev, len(adrs)))
    return "\n".join(out)


def main(argv):
    if len(argv) < 2:
        sys.stderr.write("用法: handoff.py <root> <runcard-id|tsd-slug>\n")
        return 2
    root, key = argv[0], argv[1]
    txt = build(root, key)
    if txt is None:
        sys.stderr.write("[handoff] 找不到 RunCard：%s（.harness/runcards/ 下无匹配；"
                         "RunCard 由 harness-plan 的 harness-runcard.sh create 产生）\n" % key)
        return 1
    sys.stdout.write(txt + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
