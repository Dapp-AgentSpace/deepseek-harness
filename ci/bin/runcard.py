#!/usr/bin/env python3
"""runcard.py — RunCard 解析与**确定性校验**深模块（单一真源见 ci/run-card-schema.md，决策见 ADR-0012）。

只做能机械判定的：字段格式、tsd 引用（存在 + 冻结）、handoff_from 链（不断、不跨 TSD、不成环、
无孤儿分支）。语义（「这轮做得好不好」）归 judge，不在此。

用法:
  runcard.py <runcards_dir> <tsd_dir>
退出码: 0=通过 / 1=有 error / 2=用法错误。
stdout = 逐条 `[runcard] 级别 消息`；error 阻塞、warn 只提示。
"""
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__)))
from checklist import fm  # noqa: E402  frontmatter 单字段解析（单一归属，不重复实现）

PHASES = {"plan", "build", "verify", "review", "close", "done", "aborted"}
FIELDS = ("schema_version", "id", "tsd", "handoff_from", "phase", "rounds", "started", "updated")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def load(path):
    """读 RunCard frontmatter → dict。文件不存在返回 None。"""
    if not os.path.isfile(path):
        return None
    text = open(path, encoding="utf-8").read()
    d = {k: (fm(text, k) or "") for k in FIELDS}
    d["_path"] = path
    return d


def field_errors(c):
    errs = []
    cid = c["id"] or os.path.basename(c["_path"])
    if c["schema_version"] != "1":
        errs.append("schema_version 须为 1（见 ci/run-card-schema.md）")
    if not c["id"]:
        errs.append("缺 id")
    if not c["tsd"]:
        errs.append("缺 tsd（单向引用 TSD）")
    if not c["handoff_from"]:
        errs.append("缺 handoff_from（首条为 none）")
    if c["phase"] not in PHASES:
        errs.append("phase 非法 %r（须 %s）" % (c["phase"], "/".join(sorted(PHASES))))
    if c["rounds"] and not re.fullmatch(r"\d+", c["rounds"]):
        errs.append("rounds 须为非负整数，得 %r" % c["rounds"])
    if not DATE_RE.match(c["started"]):
        errs.append("started 须为 YYYY-MM-DD，得 %r" % c["started"])
    return ["%s: %s" % (cid, e) for e in errs]


def check(runcards_dir, tsd_dir):
    """返回 (errors, warnings)。errors 阻塞、warnings 只提示。

    校验五条（对应 run-card-schema.md 的审计核对 + 字段格式 + 环检测）：
    1) 字段格式；2) tsd 存在且冻结；3) handoff_from 链不断、不跨 TSD；
    4) 每个 TSD 至多一个链头（无断开的分支）；5) 链不成环。
    """
    errors, warnings = [], []
    if not os.path.isdir(runcards_dir):
        return errors, warnings          # 尚未使用 RunCard，不算错

    cards = []
    for fn in sorted(os.listdir(runcards_dir)):
        if fn.endswith(".md"):
            c = load(os.path.join(runcards_dir, fn))
            if c:
                cards.append(c)

    by_id = {c["id"]: c for c in cards if c["id"]}

    # 1) 字段格式
    for c in cards:
        errors.extend(field_errors(c))

    # 2) tsd 存在且冻结
    for c in cards:
        if not c["tsd"]:
            continue
        t = os.path.join(tsd_dir, c["tsd"] + ".md")
        if not os.path.isfile(t):
            errors.append("%s: 指向的 TSD 不存在（.harness/tsd/%s.md）" % (c["id"], c["tsd"]))
        else:
            if not re.search(r"^tsd_frozen:[ \t]*true", open(t, encoding="utf-8").read(), re.M):
                errors.append("%s: 指向的 TSD 未冻结（%s）" % (c["id"], c["tsd"]))

    # 3) handoff_from 链不断、不跨 TSD
    referenced = set()
    for c in cards:
        h = c["handoff_from"]
        if not h or h == "none":
            continue
        p = by_id.get(h)
        if p is None:
            errors.append("%s: handoff_from 指向不存在的 RunCard（%s）" % (c["id"], h))
            continue
        if p["tsd"] and c["tsd"] and p["tsd"] != c["tsd"]:
            errors.append("%s: handoff_from 跨 TSD 链（%s 属 %s，本卡属 %s）"
                          % (c["id"], h, p["tsd"], c["tsd"]))
        referenced.add(h)

    # 4) 每个 TSD 至多一个链头（未被任何卡引用的卡）
    heads = [c for c in cards if c["id"] and c["id"] not in referenced]
    heads_by_tsd = {}
    for c in heads:
        heads_by_tsd.setdefault(c["tsd"] or "?", []).append(c)
    for tsd, hs in heads_by_tsd.items():
        if len(hs) > 1:
            errors.append("TSD %s 有 %d 条 RunCard 链头（存在断开的分支）: %s"
                          % (tsd, len(hs), ", ".join(h["id"] for h in hs)))

    # 5) 环检测（沿 handoff_from 走，步数超过卡片数 = 有环）
    for c in cards:
        cur, seen = c, set()
        while cur and cur.get("handoff_from") and cur["handoff_from"] != "none":
            if cur["id"] in seen:
                errors.append("handoff_from 链成环（涉及 %s）" % cur["id"])
                break
            seen.add(cur["id"])
            cur = by_id.get(cur["handoff_from"])

    return errors, warnings


def main(argv):
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    if len(argv) != 2:
        sys.stderr.write("用法: runcard.py <runcards_dir> <tsd_dir>\n")
        return 2
    errors, warnings = check(argv[0], argv[1])
    for w in warnings:
        print("[runcard] WARN %s" % w)
    if errors:
        for e in errors:
            print("[runcard] ERROR %s" % e)
        print("[runcard] %d 条 error" % len(errors))
        return 1
    print("[runcard] 通过")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
