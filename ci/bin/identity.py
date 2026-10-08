#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""identity.py — `.harness/identity.yaml` 的 Python 读取深模块（单一归属）。

`project.id` 在 Python 侧此前有**两份**实现：`handoff.build` 内联一段正则、`tsd_board._identity_pid`
又抄一份同名实现。两处正则一旦漂移，同一个仓会被读出两个 `project.id` —— 正是本套件反复抓的
「同一个词两种含义」。

本模块是 Shell 侧单一归属 `ci/bin/harness-identity.sh` 的 `h_id`（经 `h_fld`）在 Python 侧的镜像，
口径与之一致：取文件里**第一条** `id:` 标量，剥引号与行内 `#` 注释；缺文件 / 缺字段 → 空串（不抛、不臆造）。

只读、无副作用（派生视图与聚合模块共用；不写任何文件）。
"""

import os
import re

# 与 harness-identity.sh 的 h_fld 同口径：首个 `id:` 标量。值可带引号，行内 `#` 注释剥掉（identity.yaml
# 的 YAML 值后面常跟 `# 说明`）。`[^"\s#]+` 在引号 / 空白 / `#` 处止步 —— 与 h_fld 的 `sub` 系列等价。
_ID_RE = re.compile(r"^[ \t]*id:[ \t]*\"?([^\"\s#]+)", re.M)


def project_id(root):
    """`.harness/identity.yaml` 的 `project.id`。缺文件 / 缺字段 → 空串（不抛、不臆造）。"""
    idf = os.path.join(root, ".harness", "identity.yaml")
    if not os.path.isfile(idf):
        return ""
    with open(idf, encoding="utf-8") as f:
        m = _ID_RE.search(f.read())
    return m.group(1) if m else ""
