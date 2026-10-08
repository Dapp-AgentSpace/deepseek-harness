#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""policy_file.py — 「策略文件」这一概念的深模块（ADR-0011 决策 2 要求的同构机制）。

## 为什么有它

`depcheck.py` 与 `compatcheck.py` 是**同形兄弟**：「读策略 yaml（两层并集）→ 拆例外（生效/过期/无效）
→ 判定 → 写带 project frontmatter 的报告」这套形状逐字重复。实测：

- `_scalar` 两份基本逐字相同；
- `parse_policy` 各 43 行，difflib 相似度 **0.884**（差别只有 `not in ("[]",)` vs `!= "[]"` 这类等价写法）；
- `active_ignores` 同形（三分类 + `expires` 到期 + 缺 reason 不采纳），只是主体字段名不同；
- 两层并集那几行、报告 frontmatter 那几行逐字相同。

**ADR-0011 决策 2 明确要求**「机制与 dep 同构，不发明第二套……读法、例外纪律、退出码语义一致，
**学一次会两个**」。此前那个「一致」是**巧合维持的一致**，不是结构保证的一致 —— 加一种例外写法要改
两个文件，漏一处的表现是「一边认一边不认」，而两边都不报错。
按本套件自己的判据：**一个 adapter = 假想接缝，两个 = 真接缝**。

## 边界

本模块只提供**策略文件这一概念**的机械部分：标量去引号、两级结构解析、两层并集、例外生命周期、
报告 frontmatter。**「判什么」留在各自脚本里**（dep 比漏洞严重级与许可证、compat 比版本下界）——
那才是两个门禁各自的价值，不该被「统一」掉。
"""

import os
import re
from datetime import date

# 例外项的主体字段：`- vuln: X` / `- license: Y` / `- engine: Z`。缺任一（按各自允许的集合判）
# 即「未定义例外」，不采纳 —— 否则「必须写 reason」形同虚设。
_SCALAR_COMMENT = re.compile(r"\s+#.*$")
_TOP_KEY = re.compile(r"^([A-Za-z_][\w-]*):\s*(.*)$")
_LIST_ITEM = re.compile(r"^\s+-\s+(.*)$")
_KV_LINE = re.compile(r"^\s+([A-Za-z_][\w-]*):\s*(.*)$")


def scalar(s):
    """去引号/空白/行尾注释。"""
    s = (s or "").strip()
    s = _SCALAR_COMMENT.sub("", s)   # 行尾注释（值里带 # 的许可 id 不存在，安全）
    if len(s) >= 2 and s[0] == s[-1] and s[0] in "\"'":
        s = s[1:-1]
    return s.strip()


def parse(text, keys):
    """解析策略 YAML（两级结构：顶层 key + 二级 `- ` 列表项）。

    `ignore` 的列表项是 dict（首行 `- <字段>: <值>`，后续缩进行为其余字段）；其余 section 是标量列表。
    未知顶层 key → ValueError（**响亮失败，不静默丢弃** —— 静默丢弃 = 假绿）。
    """
    out = {k: [] for k in keys}
    section = None
    cur = None
    for raw in text.splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        top = _TOP_KEY.match(raw)
        if top:
            key = top.group(1)
            if key not in keys:
                raise ValueError("未知顶层 key: %s（允许：%s）" % (key, "/".join(keys)))
            section = key
            cur = None
            rest = scalar(top.group(2))
            if rest and rest != "[]":      # 行内标量（`ignore: []` 视为空列表）
                out[section].append(rest)
            continue
        item = _LIST_ITEM.match(raw)
        if item and section:
            body = item.group(1).strip()
            if section == "ignore":
                kv = _TOP_KEY.match(body)
                if not kv:
                    raise ValueError("ignore 项须以 `- <字段>: <值>` 开头：%s" % raw.strip())
                cur = {kv.group(1): scalar(kv.group(2))}
                out["ignore"].append(cur)
            else:
                cur = None
                out[section].append(scalar(body))
            continue
        kv = _KV_LINE.match(raw)
        if kv and cur is not None:
            cur[kv.group(1)] = scalar(kv.group(2))
            continue
        raise ValueError("无法解析的策略行：%s" % raw.strip())
    return out


def load(paths, keys, policy_name):
    """两层并集：`paths[0]` = shared 基线（**必备**），其余为项目本地层（可选，不存在即跳过）。

    shared 缺失 → ValueError（**不假绿**：没有基线就没有判据，不能退化成「全放过」）。
    本地层只增不减：并集语义 —— 本地可以加例外，但删不掉基线。
    """
    existing = [p for p in paths if p and os.path.isfile(p)]
    if not existing:
        raise ValueError("缺少策略文件（%s），无法判定 → 不假绿" % policy_name)
    if not paths or not os.path.isfile(paths[0]):
        raise ValueError("shared 基线缺失：%s → 不假绿" % (paths[0] if paths else policy_name))
    out = {k: [] for k in keys}
    for p in existing:
        one = parse(open(p, encoding="utf-8").read(), keys)
        for k in keys:                 # 两层并集：只增不减
            out[k].extend(one[k])
    return out


def active_ignores(items, today, subject_fields):
    """把 ignore 拆成 `(生效中的, 已过期的, 无效的)`。

    **无效**（不采纳）的三种情形，判据统一在这里，两个门禁不再各写一遍：
    缺主体字段（`subject_fields` 里一个都没有）/ 缺 `reason` / `expires` 格式非法。
    后两者刻意从严：`reason` 是「这是留痕的决定」的唯一载体，`expires` 格式错就**不敢**当作有效例外
    （猜一个日期 = 猜一个决定）。
    """
    active, expired, invalid = [], [], []
    for it in items:
        if not any(it.get(f) for f in subject_fields) or not it.get("reason"):
            invalid.append(it)
            continue
        exp = it.get("expires")
        if exp:
            try:
                if date.fromisoformat(exp) < today:
                    expired.append(it)
                    continue
            except ValueError:
                invalid.append(it)     # expires 格式非法 → 不敢当作有效例外
                continue
        active.append(it)
    return active, expired, invalid


def report_frontmatter(project, kind, conclusion):
    """报告的 frontmatter 行（含尾随空行）。`project` 为空则返回 []。

    `.harness/reports/*.md` 的产出注入核对（`closed-loop-audit.sh`）要求所有报告带 `project` 字段，
    且文件名带 project.id 前缀（ADR-0001 决策 4）。
    """
    if not project:
        return []
    return ["---", "project: %s" % project, "kind: %s" % kind,
            "conclusion: %s" % conclusion, "---", ""]


def write_report(path, text):
    """落盘报告。**写不出不影响判定** —— 报告是留痕不是门禁，故只把错误交给调用方打印。"""
    try:
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        open(path, "w", encoding="utf-8").write(text)
        return None
    except OSError as e:
        return str(e)
