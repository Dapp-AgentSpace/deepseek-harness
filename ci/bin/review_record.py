#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""review_record.py — ReviewRecord 的深模块（ADR-0012 决策 1 把 ReviewRecord 立成实体）。

## 为什么有它

「评审报告」这个实体的**格式知识**此前没有模块承接，散在三个消费方里各写一遍：

| 消费方 | 它自己写的 |
|---|---|
| `metrics.py` | `_target_kind`（按 `[-_/]` 切末段）+ `_review_reports` + `_count_findings` |
| `handoff.py` | `_CODE_SUFFIXES`（`endswith`）+ `review_section` 的 slug 匹配 + `_findings` |
| `closed-loop-audit.sh` | 内联 python：目标→TSD 的两次 `get` 猜测 |

**而且已经互相矛盾**（实测，非推演）：

```
target        metrics   handoff
diff          code      design     ← 分歧
arch          code      design     ← 分歧
```

同一个 target 两个答案 —— 本仓自己的 `target: diff` 报告因此被分到不同格子。

## 三件被收归此处的事（各自只有一处判据）

1. **目标分类**（`kind_of`）：末段 token ∈ {diff, arch, code} → `code`，否则 `design`。
   取 `metrics` 那版，因为它是为一次真 bug 修出来的（`tests/metrics/run.sh` 有断言锁它）。
2. **报告 ↔ TSD 的匹配**（`resolve_tsd`）：target 去掉代码后缀后，与 TSD key **或它的裸 slug** 相等。
   **裸 slug 必须认** —— 否则报告写 `target: order-push`（`harness-review` skill 的措辞恰好邀请这种
   写法）时，audit 的 content_sha 比对会**静默跳过**，而 ADR-0012 说那是「唯一能发现评审针对旧版
   规格的地方」。静默跳过 = 那条检查无声失效。
3. **发现清单解析**（`findings_of`）：认两种形态（`### 子节` / 扁平行），返回**计数 + 条目文本**，
   两个消费方各取所需，不再各写一份正则。

## 格式契约（写者一侧必须满足）

发现清单节标题是 `## 发现清单` 或 `## 发现分级`，其下二选一：

- **形态一**：`### blocking` / `### important` / `### nit` 子节，条目为顶层 `- ` 列表项；
- **形态二**：扁平 `- blocking：…` / `- nit（3，…）：` + **缩进**的条目。

**两者都不认的报告 = 不合规**：`findings_of` 返回 `None`（**不是 0** —— 0 会被读成「没有缺陷」，
而真相是「这份报告的发现清单读不出来」）。`closed-loop-audit` 据此**当场点名**不合规的报告 ——
只做模块不做对账，第三种格式照样会再长出来（本仓 `harness-diff-review.md` 就是第三种，谁都没发现，
因为该指标是观测不是门禁）。
"""

import os
import re
import sys
import glob

# 同僚模块的导入：把本文件所在目录加进 sys.path，**不依赖调用方设好 PYTHONPATH**（同 runcard.py /
# handoff.py / metrics.py）。测试用 `spec_from_file_location` 按路径加载本模块时不会设路径。
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# 目标分类：末段 token 是这三个之一 = 代码类评审（`judge-review.sh` 里走 ocr 的那些）。
CODE_TOKENS = ("diff", "arch", "code")
SEVERITIES = ("blocking", "important", "nit")
_CODE_SUFFIX_RE = re.compile(r"-(?:diff|arch|code)$")
_FINDINGS_HEAD_RE = re.compile(r"^##[ \t]*(?:发现清单|发现分级)[ \t]*$", re.M)
_SEV_SUB_RE = re.compile(r"^###[ \t]+(.+?)[ \t]*$", re.M)
_FLAT_SEV_RE = re.compile(r"^-[ \t]*(blocking|important|nit)\b(.*)$", re.I)
_INDENT_ITEM_RE = re.compile(r"^[ \t]+(?:\d+\.|[-*])[ \t]")


# frontmatter 标量读取归 **checklist.fm**（单一归属，块内匹配）。此前本模块自带一份，而
# `checklist.fm` 当时是**全文匹配** —— 同一份文本两个答案（实测 `'other-slug'` vs `None`）。
# 现在 `checklist.fm` 已统一为块内匹配，这里别名过去，不再留第二份实现。
from checklist import fm  # noqa: E402


def kind_of(target):
    """`code` / `design`。判据：末段 token ∈ CODE_TOKENS。"""
    t = (target or "").strip()
    if not t:
        return "design"
    return "code" if re.split(r"[-_/]", t)[-1].lower() in CODE_TOKENS else "design"


def target_base(target):
    """target 去掉代码类后缀、去掉尾随 `-` —— 用于与 TSD 比对。"""
    return _CODE_SUFFIX_RE.sub("", (target or "").strip()).rstrip("-")


def _bare(s, pid):
    """去掉 `{pid}-` 前缀（不在开头就原样返回）。"""
    return s[len(pid) + 1:] if pid and s.startswith(pid + "-") else s


def resolve_tsd(target, tsd_keys, pid=""):
    """报告 target → 它评的是哪份 TSD（TSD key = 文件名去 `.md`，ADR-0004 锁 `{pid}-{slug}.md`）。

    **两边都归一到裸 slug 再比** —— 因为两侧都可能写成完整段或裸 slug：
    - 报告侧：`target: order-push`（`harness-review` skill 的措辞恰好邀请这种写法）或 `harness-order-push`；
    - TSD 侧：调用方传完整 key（audit 扫文件名）**或**裸 slug（handoff 拿到的就是裸 slug）。
    只做单向比较会在某个方向落空，而落空的后果是调用方**静默跳过**（audit 的 content_sha 比对）
    —— ADR-0012 说那是「唯一能发现评审针对旧版规格的地方」。**实测踩过两个方向各一次。**

    匹配不上返回 None（调用方据此决定是「不适用」还是「报出来」）。
    """
    base = _bare(target_base(target), pid)
    if not base:
        return None
    for k in tsd_keys:
        if _bare(k, pid) == base:
            return k
    return None


def findings_of(text):
    """解析发现清单。返回 `{counts, items, fmt, declared_mismatch}`；**无合规节 → None**。

    - `counts`：三档计数（形状里没出现的档记 0）
    - `items`：三档的条目文本（handoff 要的是 blocking 的原文，metrics 要的是计数）
    - `fmt`：`"### 子节"` / `"扁平"` —— 报告实际用的形态，便于对账时看清
    - `declared_mismatch`：作者自述条数（`（3，…）`）与实际条目数不符的项 —— 报告自相矛盾本身是
      信号，但**以实际条目数为准**（可核对的那个才是事实）
    """
    m = _FINDINGS_HEAD_RE.search(text)
    if not m:
        return None
    rest = text[m.end():]
    nxt = re.search(r"^##[ \t]", rest, re.M)      # 到下一个 H2 为止（`## 未命中（确认无误）` 等）
    if nxt:
        rest = rest[:nxt.start()]

    # 形态一：`### <severity>` 子节，条目为顶层 `- `（续行缩进、嵌套项 `  - `，故 `^- ` 只命中条目）
    parts = _SEV_SUB_RE.split(rest)
    if len(parts) > 1:
        items = {s: [] for s in SEVERITIES}
        for i in range(1, len(parts) - 1, 2):
            head = parts[i].strip().lower()
            for s in SEVERITIES:
                if head.startswith(s):
                    items[s] = [ln[2:].strip() for ln in parts[i + 1].splitlines()
                                if re.match(r"^- ", ln)]
        if not any(items.values()):
            return None
        return dict(counts={s: len(items[s]) for s in SEVERITIES}, items=items,
                    fmt="### 子节", declared_mismatch=[])

    # 形态二：扁平 `- <severity>…` + 缩进条目（`  1. …` / `  - …`）；`无` 行本身就是 0
    lines = rest.splitlines()
    hits = [(i, mm) for i, ln in enumerate(lines)
            for mm in [_FLAT_SEV_RE.match(ln)] if mm]
    if not hits:
        return None
    items = {s: [] for s in SEVERITIES}
    mismatch = []
    for k, (i, mm) in enumerate(hits):
        sev = mm.group(1).lower()
        end = hits[k + 1][0] if k + 1 < len(hits) else len(lines)
        body = [ln.strip() for ln in lines[i + 1:end] if _INDENT_ITEM_RE.match(ln)]
        items[sev] += body
        dm = re.search(r"[（(](\d+)", mm.group(2))
        if dm and int(dm.group(1)) != len(body):
            mismatch.append("%s: 自述 %s 条、实为 %d 条" % (sev, dm.group(1), len(body)))
    return dict(counts={s: len(items[s]) for s in SEVERITIES}, items=items,
                fmt="扁平", declared_mismatch=mismatch)


def read(path):
    """读一份评审报告 → `{path, file, target, kind, round, conclusion, cited_sha, findings, text}`。

    **无 `target` frontmatter → 返回 None**：那不是一个 ReviewRecord（`reports/` 里还有别的产物）。
    """
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return None
    target = fm(text, "target")
    if target is None:
        return None
    rnd = fm(text, "round")
    try:
        rnd = int(str(rnd).strip())
    except (TypeError, ValueError):
        rnd = None
    return dict(
        path=path, file=os.path.basename(path), target=target.strip(), kind=kind_of(target),
        round=rnd, conclusion=(fm(text, "conclusion") or "").strip(),
        cited_sha=(fm(text, "tsd_content_sha") or "").strip(),
        findings=findings_of(text), text=text,
    )


def iter_reports(root):
    """`.harness/reports/*-review.md` 里所有 ReviewRecord，按文件名排序。"""
    d = os.path.join(root, ".harness", "reports")
    if not os.path.isdir(d):
        return []
    out = []
    for p in sorted(glob.glob(os.path.join(d, "*-review.md"))):
        r = read(p)
        if r:
            out.append(r)
    return out


def for_tsd(root, tsd_key, pid=""):
    """评的是这份 TSD 的报告（设计类与代码类都在内）。`tsd_key` 可给完整 key 或裸 slug。

    匹配一律走 `resolve_tsd`（两边归一化）—— 不在这里再补一条「差不多」的比较：
    两份近似规则并存正是本模块要消灭的东西。
    """
    return [r for r in iter_reports(root) if resolve_tsd(r["target"], [tsd_key], pid) is not None]


def main(argv):
    import sys
    import json
    if not argv:
        sys.stderr.write(__doc__)
        return 2
    if argv[0] == "list":
        root = argv[1] if len(argv) > 1 else "."
        rows = [{k: r[k] for k in ("file", "target", "kind", "round", "conclusion")}
                | {"findings": r["findings"]["counts"] if r["findings"] else None}
                for r in iter_reports(root)]
        print(json.dumps(rows, ensure_ascii=False, indent=2))
        return 0
    sys.stderr.write("用法: review_record.py list <root>\n")
    return 2


if __name__ == "__main__":
    import sys
    sys.exit(main(sys.argv[1:]))
