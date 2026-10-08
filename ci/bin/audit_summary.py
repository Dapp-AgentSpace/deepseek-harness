#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""audit_summary.py — 把 closed-loop-audit.sh 的输出行分类，落 `.harness/reports/audit-last.json`。

## 为什么按「输出行」分类，而不是让 audit 自己计数

`declaration_not_landed` 被 ADR-0012 决策 5 称为**整套系统最关键的单一指标**，它的来源必须与
「人读到的审计报告」是同一份事实。若让 audit 在每个失败点各自 `+1`，就出现第二份计数逻辑：
漏改一处 = 静默少记，而**少记的指标看起来更好** —— 这正是本套件反复抓到的缺陷类
（refresh 删非源文件、scaffold 注册表读取失败静默不接线）。

按输出行分类则相反：**报告里说了什么，指标就记什么**，两者不可能漂。代价是「新加一条没被识别的
失败消息会被漏掉」—— 故未识别的一律计入 `unclassified`（**默认计为失败**，方向是「宁可多记」），
并在 JSON 里单列，使分类器漂移可见（`closed-loop-audit` 的回归测试断言它为 0）。

## 分类

- `[audit][warn] …` → 告警，不计
- `[audit] …` 含 `已落盘` 或 `对账通过` → 通过，不计
- `[runcard] 通过` / `[runcard] WARN …` → 通过 / 告警
- `[runcard] N 条 error` → 汇总行，不计（明细在逐条 `[runcard] ERROR …`）
- 其余 `[audit] …` / `[runcard] ERROR …` → 失败，按 kind 归类

`not_landed_total` 只累加**真正属于「声明≠落盘」**的 kind（契约/TSD/产出注入/记忆/门禁身份/RunCard/
清单）；suite 自检类（缺脚本、未委托深模块）单列 `selfcheck_total` —— 它们是「套件自己的完整性」，
与「某个声明没有执行点」不是一回事，混成一个数会让人读错这个指标。
"""

import json
import os
import re
import sys
from datetime import datetime

# (正则, kind)。顺序敏感：先匹配到的先用。多数用 search 不锚定 —— 清单类消息前面会带 id
# （`[audit] PROC-1 check_mode 非法/缺失`），锚定 `^` 就匹配不上，于是整类静默变 unclassified。
KIND_PATTERNS = [
    (r"声明未落盘:", "contract"),
    (r"缺少 \.harness/contracts 目录", "contract"),
    # 清单自身校验（python 块打印，消息体常以 id 或 {占位} 开头）
    (r"check_mode 非法/缺失", "checklist"),
    (r"check_mode=deterministic 但缺 deterministic_rule", "checklist"),
    (r"deterministic_rule=.*未在 ci/rules/pitfalls\.yaml", "checklist"),
    (r"frontmatter domain=.*与所在文件", "checklist"),
    (r"severity 非法/缺失", "checklist"),
    (r"缺合法 category", "checklist"),
    (r"段内含 id 却未被解析采纳", "checklist"),
    (r"同时存在于 .*→ 本地那份已是失效孤儿", "checklist"),
    # 记忆治理（R2/R4）：生命周期/取代一致性（domain-attribution 检查）
    (r"lifecycle=.*非法（须 active/superseded/retired）", "checklist"),
    (r"lifecycle=superseded 仍留在 checklist", "checklist"),
    (r"superseded_by=.*指向的项在本域不存在", "checklist"),
    # work-unit 阻塞边（ADR-0012 决策 1）：声明了一个没有落点的依赖
    (r"阻塞边悬空:", "work-unit"),
    # 执行点可达性（ADR-0012 决策 4）：共享域写了 judge 项却没有任何路径请求它 = 死规则
    (r"共享域无执行点", "checklist"),
    # 套件自测的执行点：有 tests/ 却没有入口/执行点 = 回归用例没有任何落点
    (r"套件自测无入口", "selfcheck"),
    (r"套件自测无执行点", "selfcheck"),
    (r"套件自测执行点断链", "selfcheck"),
    # 文件在、引用对，但 hook 未激活（core.hooksPath 未指向 .githooks）= 惰性执行点，仍靠人记得跑
    (r"套件自测执行点未激活", "selfcheck"),
    # MetricEvent 来源对账（ADR-0012 决策 2 约束 3）：来源不可追溯 = 「来源必填」没落盘
    (r"MetricEvent 来源缺失", "metric"),
    (r"MetricEvent 来源指向不存在的脚本", "metric"),
    (r"MetricEvent 坏行", "metric"),
    # 「指标发出即有对应报告落盘」对账（review-landing）：judge 目标发了 MetricEvent 却无对应节点报告
    (r"judge 目标发了指标却无对应节点报告", "review-landing"),
    # TSD / 产出注入 / 记忆
    (r"TSD 未冻结:", "tsd"),
    # TSD status 推进语义门禁（ADR-0019 决策 1）：status 字段 vs status.log 执行证据不一致。
    # 新 kind（不进 not_landed_total）：这是「文档状态与执行证据」的一致性缺陷，不是「声明≠落盘」，
    # 口径不变（ADR-0012 决策 5）；但必须可分类，否则 audit-summary 报 unclassified（分类器漂移）。
    (r"TSD status 非法:", "tsd-status"),
    (r"TSD status 与执行证据不一致:", "tsd-status"),
    (r"TSD 推进序非法:", "tsd-status"),
    # status.log 格式/命名门禁（ADR-0019 决策 2）：证据文件必须可机器判读、命名唯一。
    (r"status\.log 行格式非法:", "status-log"),
    (r"status\.log 命名非法:", "status-log"),
    (r"status\.log 无主:", "status-log"),
    (r"status\.log 同 slug 多文件:", "status-log"),
    # 评审陈旧性 close 前强制门禁（ADR-0019 决策 3）：re-plan 后未重审就 close = 拿旧规格背书新实现。
    # 新 kind（不进 not_landed_total）：状态一致性缺陷，口径不变（与 tsd-status/status-log 同批）。
    (r"评审陈旧性:", "review-staleness"),
    # judge 节点报告格式对账 close 判红（ADR-0019 决策 4）：close 汇总依据不完整，断链在收口前暴露。
    (r"close 场景 judge 节点报告非 ReviewRecord:", "close-report-format"),
    (r"close 场景评审发现清单不可解析:", "close-report-format"),
    (r"identity\.yaml 缺 project\.id", "injection"),
    (r"frontmatter 缺 project 字段:", "injection"),
    (r"文件名缺 project\.id\(", "injection"),
    (r"attention\.md 条目超限", "memory"),
    # 门禁身份三向对账
    (r"identity\.yaml 有孤儿开关", "gate-identity"),
    (r"注册表门禁 .*缺 identity\.yaml 开关", "gate-identity"),
    (r"门禁 .*的 switch\(", "gate-identity"),
    (r"门禁 .*缺执行器 ", "gate-identity"),
    # 套件自检：脚本存在性 / 深模块委托 / 解释器可用性
    (r"缺少 ci/bin/", "selfcheck"),
    (r"未委托 harness-runtime-check\.sh", "selfcheck"),
    (r"仍内联聚合循环", "selfcheck"),
    (r"harness-close 数据不变量规范未指向", "selfcheck"),
    (r"python3 不可用", "selfcheck"),
    # 治理入口：AGENTS.md 受管路由块缺失/不合规（研发入口路由没有落点，声明≠落盘）
    (r"AGENTS\.md", "agents-md"),
    # 收尾报告「观测」节缺失（ADR-0016 决策 1：观测报告没有流程内消费者，声明≠落盘）
    (r"close 报告缺「观测」节", "observation"),
    # 收尾报告「关联 epic 剩余 item」节缺失（owner 2026-10-01 需求：epic 多 item 各自 TSD，close 不汇报
    # 剩余 item 就没有流程内消费者，声明≠落盘）
    (r"close 报告缺「关联 epic 剩余 item」节", "epic-remaining"),
    # audit_checks.py / work_unit.py 子检查**自身没跑成**（退出码 ≥2 或崩了零输出）——
    # closed-loop-audit 不再吞这类错，改成显式判红；归 selfcheck（对账机器自身完整性，不是「某声明没落盘」）
    (r"检查执行失败", "selfcheck"),
    # data trace 接口（ADR-0017）：有数据不变量的 TSD 缺统一只读接口 / 接口存在但不可执行 /
    # 方法未审核（need-human）/ 写语义命令（blocking）——数据 UT 接真实数据的执行点，声明≠落盘
    (r"data trace 接口缺失", "data-trace"),
    (r"data trace 接口不可用", "data-trace"),
    (r"data trace 方法未审核", "data-trace"),
    (r"data trace 只读守卫", "data-trace"),
    (r"^对账失败", "summary"),          # 收尾汇总行，明细已逐条计过
]

# 真正属于「声明≠落盘」的 kind（进 not_landed_total）
NOT_LANDED_KINDS = {"contract", "tsd", "injection", "memory", "gate-identity", "runcard", "checklist",
                    "work-unit", "metric", "review-landing", "agents-md", "observation", "data-trace",
                    "epic-remaining"}

# 通过行：`声明已落盘…` 或收尾的 `对账通过`。
# **不用裸 `通过` 子串**：任何含「通过」二字的失败消息（如「未通过校验」）都会被误判成 pass ——
# 而 pass 不计入失败，方向恰好是「宁可少记」的反面（假绿）。收紧到只有真的通过措辞才匹配。
_PASS_RE = re.compile(r"已落盘|对账通过")
_WARN_RE = re.compile(r"^\[audit\]\[warn\]|^\[runcard\] WARN")
_RUNCARD_COUNT_RE = re.compile(r"^\[runcard\] \d+ 条 error")


def classify(line):
    """返回 (bucket, kind)；bucket ∈ {pass, warn, fail, ignore}。"""
    s = line.strip()
    if not s:
        return "ignore", ""
    if _WARN_RE.search(s):
        return "warn", ""
    if _RUNCARD_COUNT_RE.match(s):
        return "ignore", ""
    # `[runcard] ERROR` 先判：它自带身份，不该再走 `[audit] ` 的前缀剥离（剥了 body 就不再以
    # `[runcard]` 开头，任何锚定它的规则都匹配不上 → 整类静默变 unclassified。踩过）。
    if s.startswith("[runcard] ERROR"):
        return "fail", "runcard"
    if not s.startswith("[audit] "):
        return "ignore", ""
    body = s[len("[audit] "):]
    if _PASS_RE.search(body):
        return "pass", ""
    for pat, kind in KIND_PATTERNS:
        if re.search(pat, body):
            return "fail", kind
    return "fail", "unclassified"


def summarize(text):
    kinds = {}
    n_pass = n_warn = 0
    contracts_total = contracts_not_landed = 0
    contracts_dir_missing = False
    unclassified = []
    for line in text.splitlines():
        bucket, kind = classify(line)
        if bucket == "pass":
            n_pass += 1
            if "声明已落盘" in line:
                contracts_total += 1
            continue
        if bucket == "warn":
            n_warn += 1
            continue
        if bucket != "fail":
            continue
        if kind == "summary":
            continue
        kinds[kind] = kinds.get(kind, 0) + 1
        if kind == "unclassified":
            unclassified.append(line.strip()[:160])
        if kind == "contract":
            if "缺少 .harness/contracts 目录" in line:
                contracts_dir_missing = True
            elif "声明未落盘" in line:
                contracts_not_landed += 1
                contracts_total += 1
    not_landed = sum(n for k, n in kinds.items() if k in NOT_LANDED_KINDS)
    selfcheck = kinds.get("selfcheck", 0)
    fail_total = sum(n for k, n in kinds.items() if k != "unclassified") + len(unclassified)
    return dict(
        kinds=kinds,
        not_landed_total=not_landed,
        selfcheck_total=selfcheck,
        fail_total=fail_total,
        pass_total=n_pass,
        warn_total=n_warn,
        # 目录都不存在时给 null（不是 0）—— 0 会被读成「没有契约，全部落盘」，而真相是「没得对账」
        contracts_total=None if contracts_dir_missing else contracts_total,
        contracts_not_landed=None if contracts_dir_missing else contracts_not_landed,
        unclassified=unclassified,
    )


# `audit-last.json` 的**产物契约**：字段名由本模块（写者）定义，读者调 `read_summary` 取，
# 不各抄一份字面量。此前 `metrics.py` 直接写 `d.get("not_landed_kinds")` 而这里写的是 `kinds`
# —— `or {}` 把失配吞干净，`declaration_not_landed` 的 kind 分解**永远列不出来**，而本仓 audit
# 恰好全绿（`not_landed_total: 0`）所以看不见。这是本套件反复抓的那类缺陷（来源缺字段 /
# 声明与落盘不一致），只不过长在指标层自己身上；根因是**这个产物没有接口定义**，两侧靠约定对齐。
# 归一化成一组稳定的读者名（JSON 的原始 key 是写者的实现细节）：
READ_FIELDS = ("ts", "kinds", "not_landed", "selfcheck", "fail",
               "contracts_total", "contracts_not_landed")


def read_summary(path):
    """读 `audit-last.json` → 归一化 dict；**文件不存在 / 不可解析 / 非对象 → None**。

    返回 None 时调用方报「无来源」或「不可解析」，**不塌成 0** —— 0 会被读成「查过了，没问题」。
    """
    try:
        with open(path, encoding="utf-8") as f:
            d = json.load(f)
    except (OSError, ValueError):
        return None
    if not isinstance(d, dict):
        return None
    return {
        "ts": d.get("ts", "?"),
        "kinds": d.get("kinds") or {},
        "not_landed": d.get("not_landed_total"),
        "selfcheck": d.get("selfcheck_total"),
        "fail": d.get("fail_total"),
        "contracts_total": d.get("contracts_total"),
        "contracts_not_landed": d.get("contracts_not_landed"),
    }


def main(argv):
    if len(argv) < 3:
        sys.stderr.write("用法: audit_summary.py <audit-log-file> <out-json> [<exit-code>]\n")
        return 2
    log, out = argv[1], argv[2]
    rc = argv[3] if len(argv) > 3 else ""
    try:
        text = open(log, encoding="utf-8", errors="replace").read()
    except OSError as e:
        sys.stderr.write("[audit-summary] 读不到审计日志（%s）——不落盘，避免留下假汇总\n" % e)
        return 1
    s = summarize(text)
    s["ts"] = datetime.now().isoformat(timespec="seconds")
    if rc != "":
        s["audit_rc"] = rc
    os.makedirs(os.path.dirname(out), exist_ok=True)
    tmp = out + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(s, f, ensure_ascii=False, indent=2, sort_keys=True)
    os.replace(tmp, out)
    if s["unclassified"]:
        # 分类器漂移必须响亮：新加了一条失败消息却没归类 → 它没被算进任何 kind。
        sys.stderr.write("[audit-summary] %d 条失败消息未被分类（分类器需补 KIND_PATTERNS）:\n%s\n"
                         % (len(s["unclassified"]), "\n".join("  " + u for u in s["unclassified"])))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
