#!/usr/bin/env python3
# work_unit.py — work-unit 解析/适配深模块（ADR-0010：work-unit 自包含，CodeStable 降级为可选适配器）。
# 单一归属：work-unit frontmatter 的解析 + CodeStable(.codestable) → harness schema 的适配映射。
# 读侧脚本（status / tsd-sync-check / measure / plan）定位/解析 work-unit 只调这里，不各自重写映射。
#
# 用法:
#   work_unit.py locate <root> <slug>    # 定位 work-unit：.harness/work/{slug}.md 优先，回退 .codestable/work/*-{slug}.md
#   work_unit.py map <codestable-file>   # 把 CodeStable work 文件映射成 harness 格式（stdout；body 不动）
#   work_unit.py migrate <root>          # 一次性把 .codestable/work/*.md 适配进 .harness/work/
#   work_unit.py blockers <root> <slug>  # 输出本单元的阻塞边及其解析状态（TSV：id<TAB>resolved|unresolved|dangling）
import sys
import os
import re
import glob

# 强制 UTF-8 输出（Windows 默认 GBK 会把中文 frontmatter/body 写成乱码）
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

_STATUS = {"planned": "incoming", "in_progress": "building", "done": "done"}
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
# 「frontmatter 从哪到哪」这块知识归 checklist（单一归属）。本模块只需要**整块**（下面把整块
# 拆成 dict），所以借它的块正则，不再自己写一份 —— 同一件事两份正则就是两处会漂的地方。
from checklist import _FM_BLOCK as _FM  # noqa: E402

# 终态：阻塞边指向的 work-unit 达到这些 status 才算「已解析」。
# 分 kind 判：feat/issue 走 done，proposal 走 landed（work-unit-schema 的生命周期）。
_TERMINAL = {"done", "landed"}


def _parse_fm(text):
    m = _FM.search(text)
    if not m:
        return {}
    fm = {}
    for ln in m.group(1).splitlines():
        if ":" in ln:
            k, v = ln.split(":", 1)
            fm[k.strip()] = v.strip()
    return fm


def parse_blocked_by(text_or_fm):
    """解析 `blocked_by` → id 列表（ADR-0012 决策 1 的阻塞边）。

    容忍 `a, b` / `a b` / `[a, b]` / `a;b` 几种写法，空 / `[]` / `none` / `-` / `无` = 无阻塞。
    宽容是刻意的：这是**手写字段**，写法不统一时「解析成空」与「真的没有阻塞」长得一样，
    而两者的含义正相反（空 = 不遗留；解析失败 = 遗留项丢了）。故解析不出来的 token 一律**保留**
    为 id 原样交给上层，让「悬空边」在 `blockers_resolved` 那里显形，不在这里静默丢掉。
    """
    fm = text_or_fm if isinstance(text_or_fm, dict) else _parse_fm(text_or_fm)
    raw = (fm.get("blocked_by") or "").strip()
    raw = raw.strip("[]")
    for none in ("none", "-", "无", "n/a", "null", "~"):
        if raw.lower() == none:
            return []
    out = []
    for tok in re.split(r"[,;、\s]+", raw):
        tok = tok.strip().strip("\"'`")
        if tok and tok not in out:
            out.append(tok)
    return out


def blockers_resolved(root, slug):
    """本单元阻塞边的解析状态：[{id, status, resolved}]。

    `resolved` 的判据：指向的 work-unit **存在**且 status 是终态（`done`/`landed`）。
    - 指向的 id 找不到 → status=`dangling`、resolved=False（悬空边是缺陷，**不当已解析放过**）；
    - 指向的单元存在但非终态 → status=其 status、resolved=False（这就是「遗留项」）。
    """
    p = locate(root, slug)
    if not p:
        return []
    with open(p, encoding="utf-8") as f:
        fm = _parse_fm(f.read())
    out = []
    for bid in parse_blocked_by(fm):
        bp = locate(root, bid)
        if not bp:
            out.append({"id": bid, "status": "dangling", "resolved": False})
            continue
        with open(bp, encoding="utf-8") as f:
            bfm = _parse_fm(f.read())
        st = (bfm.get("status") or "").strip()
        out.append({"id": bid, "status": st or "?", "resolved": st in _TERMINAL})
    return out


def map_codestable(text):
    """CodeStable work 文件正文 → harness 格式（frontmatter 映射，body 原样保留）。"""
    fm = _parse_fm(text)
    out = {
        "schema_version": "1",
        "id": fm.get("slug", ""),
        "kind": "feat" if fm.get("type") == "feat" else "issue",
        "status": _STATUS.get(fm.get("status", ""), "incoming"),
        "producer": fm.get("entry", "cs-issue"),
    }
    # 保留未重命名的字段（created/disposition/check_mode/domain/severity/project 等）
    for k, v in fm.items():
        if k not in ("slug", "type", "entry", "status"):
            out.setdefault(k, v)
    lines = ["---"] + ["%s: %s" % (k, v) for k, v in out.items()] + ["---"]
    body = _FM.sub("", text, count=1).lstrip("\n")
    result = "\n".join(lines) + "\n"
    return result + ("\n" + body if body else "")


def locate(root, slug):
    """定位 work-unit：.harness/work/{slug}.md 优先，回退 .codestable/work/*-{slug}.md（CodeStable 拆解产物）。"""
    p = os.path.join(root, ".harness", "work", slug + ".md")
    if os.path.isfile(p):
        return p
    return next(iter(glob.iglob(os.path.join(root, ".codestable", "work", "*-" + slug + ".md"))), None)


def migrate(root):
    """一次性把 .codestable/work/*.md 适配进 .harness/work/（映射 frontmatter，body 不动）。已存在则跳过。"""
    cw = os.path.join(root, ".codestable", "work")
    hw = os.path.join(root, ".harness", "work")
    os.makedirs(hw, exist_ok=True)
    n = 0
    for src in sorted(glob.glob(os.path.join(cw, "*.md"))):
        base = os.path.basename(src)
        slug = re.sub(r"^(issue|feat|keep-proposal)-", "", base).replace(".md", "")
        dst = os.path.join(hw, slug + ".md")
        if os.path.exists(dst):
            continue
        with open(src, encoding="utf-8") as fs, open(dst, "w", encoding="utf-8") as fd:
            fd.write(map_codestable(fs.read()))
        n += 1
    return n


def main(argv):
    if not argv:
        sys.stderr.write(__doc__)
        sys.exit(2)
    cmd = argv[0]
    if cmd == "locate" and len(argv) == 3:
        p = locate(argv[1], argv[2])
        if p:
            sys.stdout.write(p)
        else:
            sys.exit(1)
    elif cmd == "map" and len(argv) == 2:
        sys.stdout.write(map_codestable(open(argv[1], encoding="utf-8").read()))
    elif cmd == "migrate" and len(argv) == 2:
        print("[work-unit] migrate %d" % migrate(argv[1]))
    elif cmd == "blockers" and len(argv) == 3:
        # TSV：id <TAB> resolved|unresolved|dangling <TAB> status。退出码 0=全部已解析 / 1=有未解析。
        rows = blockers_resolved(argv[1], argv[2])
        for r in rows:
            state = "resolved" if r["resolved"] else ("dangling" if r["status"] == "dangling" else "unresolved")
            sys.stdout.write("%s\t%s\t%s\n" % (r["id"], state, r["status"]))
        if any(not r["resolved"] for r in rows):
            sys.exit(1)
    else:
        sys.stderr.write(__doc__)
        sys.exit(2)


if __name__ == "__main__":
    main(sys.argv[1:])
