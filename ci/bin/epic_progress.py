#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""epic_progress.py — TSD close 后「关联 epic 剩余 item」派生视图（ADR-0012 决策 4）。

## 它是派生视图，不是实体

ADR-0012 决策 4：答不上「谁消费它、怎么检测从未被消费」的产出，一律改为**派生视图（不落盘，用时生成）**。
本模块只往 stdout 打，**不写任何文件**，**不 spawn agent**。消费方 = harness-close 步骤 4 的汇总报告
（`## 关联 epic 剩余 item` 节）与 harness-run 步骤 7 的 close 摘要行；`closed-loop-audit.sh` 的
`close-epic-remaining` 检查据此判红（缺节 = 该产出没有流程内消费者）。

## 数据链（2026-10-01 在真实项目 D:\\code\\dsh\\dsh 实测，见 TSD 正文「现场」节）

    TSD（.harness/tsd/{pid}-{slug}.md）frontmatter `task:`   ← 唯一入口（TSD 上**没有** epic: 字段，0 命中）
      → work_unit.locate(root, task)                        ← work-unit（.harness/work/{id}.md，单一归属）
      → work-unit frontmatter `epic:`（相对路径）            ← 回链字段在 work-unit 上（不在 TSD 上）
      → epic 永久文档（.codestable/epics/{slug}.md）
          · frontmatter `work:` → 游标（.codestable/work/epic-{slug}.md）
          · `## 子项契约` ITEM 行 → item 清单
              `- ITEM-N（{slug}，owning: ...）：...`（括号内第一个 token = work-unit slug）

## 完成态判定（真实数据验证，契约 C1）

item 完成 = work-unit `status ∈ {done, landed}`（work_unit.py `_TERMINAL`）**或**游标 frontmatter
`current_item: ITEM-N（{slug}，done）` 含 done 标记。**任一即完成** —— 真实样本证明 work-unit status
可能停在 cs-epic 上游值（planning）而游标已标 done（gitlab-ux-design 实测）。无 work-unit 的 item
（session-panel 形态：单 work-unit 覆盖多 item，子项契约 slug 无独立文件）靠游标 done 标记兜底，
无标记 = 未完成。

## 四态纪律（同 tsd_board.py / metrics.py）

`无 epic 关联` / `判不了` / `无剩余` / `有剩余` 都显式输出一行说明，不输出空段；「判不了」不塌成「无剩余」。
退出码：0=已输出（含显式说明）/ 2=用法或环境错误（对齐 tsd_board.py：四态都是正常输出，退 0）。
"""

import os
import re
import sys

# 强制 stdout/stderr 为 UTF-8（Windows 默认 GBK 会把中文消息写成乱码）。与 depgraph.py / metrics.py
# 等同款：Python CLI 自锁 UTF-8 输出，不赖调用方 export。
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from identity import project_id  # noqa: E402  project.id 读取单一归属
from work_unit import locate as work_unit_locate, _parse_fm, _TERMINAL  # noqa: E402  work-unit 定位 / frontmatter 解析 / 终态集合单一归属


def _read(p):
    """读 UTF-8 文本；失败（OSError / UnicodeDecodeError，如 Windows GBK 文件）返回 None。

    调用方按「判不了」处理、不炸 traceback —— 保住退出码契约（0=已输出含显式说明 / 2=用法或环境错误）。
    与 metrics.py / depgraph.py 等派生视图同款：对不可读文件静默降级为「读不到」，不中断整个派生。"""
    if not p:
        return None
    try:
        with open(p, encoding="utf-8") as f:
            return f.read()
    except (OSError, UnicodeDecodeError):
        return None


def _tsd_path(root, pid, slug):
    """定位 TSD 文件：`.harness/tsd/{pid}-{slug}.md`（ADR-0004 命名）。返回路径或 None。

    只认 `{pid}-` 前缀 + frontmatter `slug` 匹配（不把目录里散落的其他 .md 臆造成 TSD）。"""
    if not pid:
        return None                       # 缺 identity.yaml → 无法按 ADR-0004 前缀识别
    p = os.path.join(root, ".harness", "tsd", "%s-%s.md" % (pid, slug))
    if not os.path.isfile(p):
        return None
    return p


# 子项契约 ITEM 行：`- ITEM-N（{slug}，owning: ...）：...`。括号内第一个 token = work-unit slug。
# 两种真实形态都覆盖：gitlab-support `ITEM-1（gitlab-ux-design，owning: harness-plan，**本轮**）` 与
# session-panel `ITEM-1（layout，owning: harness-build）`。括号用中文全角（实测样本如此），兼容半角。
_ITEM_RE = re.compile(r"^\s*-\s*(ITEM-\d+)\s*[（(]\s*([^，,）)]+)[，,]")


def _find_tsd_by_slug(root, pid, slug):
    """按 frontmatter `slug` 在 `.harness/tsd/` 里找（入口 slug 未必等于文件名后缀）。

    只认 `{pid}-` 前缀文件（ADR-0004 命名）—— 同 slug 的异项目 TSD 不跨项目误配。"""
    d = os.path.join(root, ".harness", "tsd")
    if not os.path.isdir(d):
        return None
    for fn in sorted(os.listdir(d)):
        if not fn.endswith(".md"):
            continue
        if pid and not fn.startswith(pid + "-"):
            continue                      # ADR-0004：只认本 project 前缀，不跨项目匹配
        text = _read(os.path.join(d, fn))
        if text is None:
            continue                      # 读不到（GBK/权限）→ 跳过该候选，不炸
        fm = _parse_fm(text)
        if (fm.get("slug") or "").strip() == slug:
            return os.path.join(d, fn)
    return None


def _resolve_work(root, task):
    """work_unit.locate 单一归属。返回路径或 None（找不到 = 判不了）。"""
    return work_unit_locate(root, task)


def _work_status(root, wpath):
    text = _read(wpath)
    if text is None:
        return None                       # 读不到（GBK/权限）→ status 未知，按「无 status」处理
    fm = _parse_fm(text)
    return (fm.get("status") or "").strip() or None


def _epic_path(root, wpath):
    """work-unit frontmatter `epic:`（相对路径）→ 相对 root 解析。无该字段返回 None。"""
    text = _read(wpath)
    if text is None:
        return None                       # 读不到 → 判不了（调用方按「无 epic」显式说明，不炸）
    fm = _parse_fm(text)
    ep = (fm.get("epic") or "").strip()
    if not ep:
        return None
    # epic: 相对 work-unit 所在目录（.harness/work/）还是相对 root？实测样本为 `.codestable/epics/{slug}.md`
    # —— 相对 root。但为稳健，若相对 work-unit 目录能命中则优先（两种相对基准都试）。
    base = os.path.join(root, ep)
    if os.path.isfile(base):
        return base
    alt = os.path.join(os.path.dirname(wpath), ep)
    return alt if os.path.isfile(alt) else base   # 找不到返回 root-相对路径，由调用方判「判不了」


def _cursor_path(root, epic_path, epic_slug):
    """epic frontmatter `work:`（相对 epic 文档目录）→ 游标路径；缺省回退 .codestable/work/epic-{slug}.md。
    返回路径或 None（epic 无 work: 字段且回退也不存在）。"""
    text = _read(epic_path)
    fm = _parse_fm(text) if text is not None else {}
    w = (fm.get("work") or "").strip()
    if w:
        p = os.path.join(os.path.dirname(epic_path), w)
        if os.path.isfile(p):
            return p
    # 回退：epic slug 从文件名剥（epic 文档名 {slug}.md 在 .codestable/epics/）
    if epic_slug:
        p = os.path.join(root, ".codestable", "work", "epic-%s.md" % epic_slug)
        if os.path.isfile(p):
            return p
    return None


def _parse_items(text):
    """解析 `## 子项契约` 段的 ITEM 行 → [(item_id, slug)]。段内无 ITEM 行 → 空列表。"""
    m = re.search(r"^##\s*子项契约\s*$", text, re.M)
    if not m:
        return []
    # 段结束 = 下一个 `## `（同级或更高级）；ITEM 行也可能在段内任意位置（含列表缩进）
    rest = text[m.end():]
    nxt = re.search(r"^\s*##\s", rest, re.M)
    if nxt:
        rest = rest[:nxt.start()]
    items = []
    for ln in rest.splitlines():
        mm = _ITEM_RE.match(ln)
        if mm:
            items.append((mm.group(1), mm.group(2).strip()))
    return items


def _cursor_done(cursor_text, item_id, slug):
    """游标 current_item 完成标记兜底：current_item 行含 `ITEM-N（{slug}...，done）`。"""
    if not cursor_text:
        return False
    fm = _parse_fm(cursor_text)
    cur = (fm.get("current_item") or "").strip()
    if not cur:
        return False
    # 标记形态 `ITEM-N（{slug}，done）`：先定位 ITEM-N（{slug} 片段，再查该片段后同括号内有无 done
    m = re.search(re.escape(item_id) + r"\s*[（(]\s*" + re.escape(slug), cur)
    if not m:
        return False
    tail = cur[m.end():]
    # 同一对括号内（到下一个 `）`）含 done
    close = tail.find("）")
    if close < 0:
        close = tail.find(")")
    if close < 0:
        return False
    return "done" in tail[:close]


def collect(root, slug):
    """派生「关联 epic 剩余 item」。返回 (state, items, info)。

    state ∈ {no-tsd, no-work, no-epic, unresolved, ok}
      no-tsd    = TSD 找不到（入口 slug 无匹配 TSD）
      no-work   = TSD `task:` 指向的 work-unit 不存在（判不了）
      no-epic   = work-unit 无 `epic:` 字段（无 epic 关联）
      unresolved= epic 永久文档缺失 / 无子项契约（判不了）
      ok        = 正常派生；items 为 [(item_id, slug, done, status_or_None)]，status=None 表示无 work-unit
    info: 附加说明 dict（epic 路径 / 游标路径 / 缺失原因等，供渲染）。
    """
    pid = project_id(root)
    info = {}
    tsp = _tsd_path(root, pid, slug) or _find_tsd_by_slug(root, pid, slug)
    if not tsp:
        return "no-tsd", [], info
    tsd_text = _read(tsp)
    if tsd_text is None:
        info["reason"] = "TSD 读取失败（非 UTF-8 / 权限）: %s" % tsp
        return "unresolved", [], info
    fm = _parse_fm(tsd_text)
    task = (fm.get("task") or "").strip()
    if not task:
        info["reason"] = "TSD 无 task: 字段"
        return "no-work", [], info
    wpath = _resolve_work(root, task)
    if not wpath:
        info["reason"] = "TSD task: %s 指向的 work-unit 不存在" % task
        return "no-work", [], info
    info["work"] = wpath
    ep = _epic_path(root, wpath)
    if not ep:
        return "no-epic", [], info
    info["epic"] = ep
    if not os.path.isfile(ep):
        info["reason"] = "epic 永久文档缺失: %s" % ep
        return "unresolved", [], info
    epic_text = _read(ep)
    if epic_text is None:
        info["reason"] = "epic 永久文档读取失败（非 UTF-8 / 权限）: %s" % ep
        return "unresolved", [], info
    items = _parse_items(epic_text)
    if not items:
        info["reason"] = "epic 无 `## 子项契约` 段或段内无 ITEM 行: %s" % ep
        return "unresolved", [], info
    # 游标
    epic_slug = os.path.basename(ep)[:-3] if ep.endswith(".md") else None
    cpath = _cursor_path(root, ep, epic_slug)
    cursor_text = _read(cpath) if cpath else None
    info["cursor"] = cpath
    if not cursor_text:
        info["cursor_missing"] = True      # 缺游标：按 work-unit status 判（契约 G 段）
    # 逐 item 判定
    out = []
    for item_id, islug in items:
        done = False
        status = None
        ipath = work_unit_locate(root, islug)
        if ipath:
            status = _work_status(root, ipath)
            if status in _TERMINAL:
                done = True
        if not done and cursor_text and _cursor_done(cursor_text, item_id, islug):
            done = True
        out.append((item_id, islug, done, status))
    return "ok", out, info


def _render(state, items, info):
    """四态 → 显式说明 / 未完成清单。只往 stdout 打（派生视图不落盘）。"""
    L = []
    if state == "no-tsd":
        L.append("## 关联 epic 剩余 item")
        L.append("")
        L.append("> 找不到 TSD（.harness/tsd/ 无匹配 slug）—— 无法派生 epic 关联，不输出空段。")
        return L
    if state == "no-work":
        L.append("## 关联 epic 剩余 item")
        L.append("")
        L.append("> 判不了：%s（TSD `task:` 无法定位 work-unit → 无法回链 epic）" % info.get("reason", "未知"))
        return L
    if state == "no-epic":
        L.append("## 关联 epic 剩余 item")
        L.append("")
        L.append("> 无 epic 关联：本 TSD 的 work-unit 无 `epic:` 字段（未归属任何 epic）。")
        return L
    if state == "unresolved":
        L.append("## 关联 epic 剩余 item")
        L.append("")
        L.append("> 判不了：%s" % info.get("reason", "未知"))
        return L
    # ok：输出未完成清单（空 = 无剩余）
    L.append("## 关联 epic 剩余 item")
    L.append("")
    if info.get("cursor_missing"):
        L.append("> 注：游标缺失，按 work-unit status 判定（契约 G 段）。")
    remain = [(i, s, st) for (i, s, done, st) in items if not done]
    done_n = len(items) - len(remain)
    if not remain:
        L.append("**无剩余 item**：epic %s 全部 %d 个 item 已完成。" % (os.path.basename(info["epic"]), len(items)))
    else:
        L.append("**未完成 item（%d/%d）**：epic %s：" % (len(remain), len(items), os.path.basename(info["epic"])))
        L.append("")
        L.append("| item | work-unit | 状态 |")
        L.append("|---|---|---|")
        for i, s, st in remain:
            st_disp = st if st else "无 work-unit"
            L.append("| %s | %s | %s |" % (i, s, st_disp))
        L.append("")
        L.append("**汇总**：%d 个 item · 完成 %d · 未完成 %d。" % (len(items), done_n, len(remain)))
    return L


def main(argv):
    if len(argv) != 2 or argv[0].startswith("-") or not os.path.isdir(argv[0]):
        sys.stderr.write("用法: epic_progress.py <root> <tsd-slug>\n")
        return 2
    root, slug = argv[0], argv[1]
    state, items, info = collect(root, slug)
    sys.stdout.write("\n".join(_render(state, items, info)) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
