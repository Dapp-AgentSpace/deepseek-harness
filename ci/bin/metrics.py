#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""metrics.py — 指标模型的**单一真源**（ADR-0012 决策 5）。

模型（哪些格、来源、坏信号、口径）定义在 ADR-0012 决策 5 的表里；本文件是它的**可执行副本**：
每一格一条登记（`CELLS`），每条登记带一个采集器或 `None`。改模型先改 ADR，再改这里 —— 两处不一致
时以 ADR 为准（同 `run-card-schema.md` / `work-unit-schema.md` 的定位）。

## 为什么要有这个文件

指标采集此前散在 `harness-measure.sh` 里（运行回路 issue / 坑库 / checklist 三块），各阶段自己的
产出质量没有落点。本文件把「模型」与「渲染」分开：模型只回答「这一格的值是什么、从哪来、信不信得过」，
渲染（measure 的文本 + HTML）只消费，不再各自写解析。

## 四种状态，不是两种（本文件的核心纪律）

一格的值有四个可能，**绝不能把后三种塌成「0」**：

| 状态 | 含义 | 渲染要求 |
|---|---|---|
| `ok` | 从来源算出来了（值可能是 0，那是真的 0） | 报值 |
| `empty` | 来源存在、且明确是空的（如「无开放决策」） | 报 0 并注明「来源为空」 |
| `unavailable` | **来源尚未落地**（该实体/字段还没有落盘机制） | 报「来源未落地」，**不报 0** |
| `error` | 来源在，但解析不了 / 读失败 | **响亮报出**，不得与 `empty` 混 |

「来源在但解析出 0 条」一律是 `error` 不是 `empty` —— 这正是本套件反复抓到的缺陷类
（`couldn't run` 被当成 `nothing there`：refresh 删非源文件、scaffold 注册表读取失败静默不接线、
`xargs -r`、parser 静默丢项）。一个数不出来却显示为 0 的指标，比没有指标更糟。

## 口径

一律 `观测`（ADR-0012 决策 5）：本模块只读，**不阻断任何东西**，也不写 MetricEvent。谁要把某格写成
事件由调用方决定（如 `harness-gate.sh` 写 `verify.gate.*`）。指标升格成门禁即招 Goodhart，不做。
"""

import os
import re
import json
import glob
import sys

# 强制 UTF-8 输出（Windows 控制台默认 GBK：直接跑本模块渲染表格时，`∅` 等符号会 UnicodeEncodeError，
# 表现为「CLI 跑一半崩掉」）。同 work_unit.py / handoff.py 的既有做法。
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

# 同僚模块的导入：把本文件所在目录加进 sys.path，**不依赖调用方设好 PYTHONPATH**。
# 这是本仓既有做法（runcard.py:16 / handoff.py:36 同款）—— 测试用
# `spec_from_file_location` 按文件路径加载本模块时不会往 sys.path 加目录，靠调用方设路径就会失败。
# （此前本文件因此复制了 checklist.fm / handoff 的报告解析各一份，见 review_record.py 的头注释。）
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import review_record  # noqa: E402
import audit_summary  # noqa: E402  audit-last.json 的产物契约（字段名由写者定义，见其 read_summary）

# ---- 模型登记表（ADR-0012 决策 5 的表，逐格对应）----
# 每格：key（stage.metric）、来源（实体.字段，谁写）、坏信号（偏高/偏低反映什么真问题）。
# `collector` 为 None = 来源未落地，状态恒为 unavailable —— 登记在此是为了**模型里不缺席**，
# 而不是「以后再说」（ADR 决策 5：不分批，可记性由「来源」这一属性决定）。
CELLS = [
    # ---- plan ----
    dict(key="plan.tsd_review_rounds", stage="plan", metric="tsd_review_rounds",
         source="ReviewRecord.round（target 非代码类；judge-review.sh 写）",
         bad_signal="规格反复评审 = 上游需求没想清；偏低也可能是评审走过场（须与 blocking 数一起看）",
         collector="tsd_review_rounds"),
    dict(key="plan.open_decisions_missing_d", stage="plan", metric="open_decisions_missing_d",
         source="TSD「开放决策」块（REQ-002；harness-plan 写）",
         bad_signal="决策权未落（无 owner）= agent 可能代拍；偏高即流程失效",
         collector="open_decisions_missing_d"),
    dict(key="plan.w2h_completeness", stage="plan", metric="w2h_completeness",
         source="judge（`judge-review.sh tsd` 的 JUDGE_METRIC 标记 → MetricEvent）",
         bad_signal="规格敷衍（五维有空过）；须与缺哪维一起看（值只给比例，缺项在报告正文）",
         collector="judge_metric"),
    # ---- build ----
    dict(key="build.fix_rounds", stage="build", metric="fix_rounds",
         source="RunCard.rounds（触发回修的那次判定写）",
         bad_signal="偏高 = 首遍质量差或规格不可测；须与原因字段同看，单看轮次绝对值无意义",
         collector="fix_rounds"),
    dict(key="build.antipattern_hits", stage="build", metric="antipattern_hits",
         source="pitfall-last.json（g_pitfall 写）+ ReviewRecord 反 TSD/反模式类发现",
         bad_signal="实现偏离规格 / 踩坑密度高",
         collector="antipattern_hits"),
    dict(key="build.contract_landed_rate", stage="build", metric="contract_landed_rate",
         source="closed-loop-audit（CONTRACT-001）",
         bad_signal="声明没落盘成可执行校验 = 死声明；偏低即「写了规矩没人执行」",
         collector="contract_landed_rate"),
    # ---- verify ----
    dict(key="verify.gate_result", stage="verify", metric="gate_result",
         source="MetricEvent（`gate.<key>` 事件，退出码写在 value；harness-gate.sh 写）",
         bad_signal="黄多 = 门禁名存实亡（检查没跑却不算红）；红多 = 质量差或门禁过严",
         collector="gate_result"),
    dict(key="verify.false_green", stage="verify", metric="false_green",
         source="quality 节点判（断言空跑/未触达）→ MetricEvent",
         bad_signal="确定性门禁失真 —— 最危险的一类，绿而无效",
         collector="judge_metric"),
    # ---- review ----
    dict(key="review.finding_severity", stage="review", metric="finding_severity",
         source="ReviewRecord 发现清单（judge-review.sh 写）",
         bad_signal="缺陷密度与严重度；blocking 占比高 = 前序阶段没挡住",
         collector="finding_severity"),
    dict(key="review.review_rounds", stage="review", metric="review_rounds",
         source="ReviewRecord.round（target 为代码类；judge-review.sh 写）",
         bad_signal="复审轮次高 = 修复没一次到位",
         collector="review_rounds"),
    dict(key="review.false_positive_rate", stage="review", metric="false_positive_rate",
         source="quality 节点判（judge↔verify 对账）→ MetricEvent",
         bad_signal="judge 判据过宽（误报消耗 owner 注意力）；值取 `n/m` 形式，基线随值一起报",
         collector="judge_metric"),
    # ---- close ----
    dict(key="close.pipeline_conversion", stage="close", metric="pipeline_conversion",
         source="work-unit（proposal 的 status 分布；harness-keep-land.sh 写）",
         bad_signal="沉淀管道是否在产高质量；大量 proposed 滞留 = 没人批或提案质量差",
         collector="pipeline_conversion"),
    dict(key="close.routing_accuracy", stage="close", metric="routing_accuracy",
         source="quality 节点回看（两段式分流判对的比例）→ MetricEvent",
         bad_signal="两段式分流不准（确定性项进了 agent / 语义项漏判）；值取 `n/m` 形式，基线随值一起报",
         collector="judge_metric"),
    dict(key="close.promoted_shared", stage="close", metric="promoted_shared",
         source="work-unit / checklist 项的 promoted_to（harness-checklist-promote.sh 写）",
         bad_signal="复用产出的体量（纯观测，无好坏方向）",
         collector="promoted_shared"),
    # ---- global ----
    dict(key="global.declaration_not_landed", stage="global", metric="declaration_not_landed",
         source="closed-loop-audit.sh（落 audit-last.json）",
         bad_signal="**整套系统最关键的单一指标**：声明无执行点 = 死声明（本会话反复靠它抓真问题）",
         collector="declaration_not_landed"),
    dict(key="global.metric_events_by_stage", stage="global", metric="metric_events_by_stage",
         source="MetricEvent（各阶段 append）",
         bad_signal="某阶段计数为空 = 该阶段**未走事件流**（ADR-0016 决策 4：≠「该阶段无观测」——"
                    "plan/build 的观测在源实体，由各自采集器直读）；空不是「做得好」",
         collector="metric_events_by_stage"),
]

CELL_BY_KEY = {c["key"]: c for c in CELLS}

OK, EMPTY, UNAVAIL, ERROR = "ok", "empty", "unavailable", "error"


# ---------------------------------------------------------------------------
# 解析工具
# ---------------------------------------------------------------------------

# frontmatter 标量读取归 **checklist.fm**（单一归属，块内匹配）。此前本模块自带一份，docstring
# 还写着「与 checklist.py 的 fm 同语义」—— 那句是**假的**（那份当时是全文匹配，这份是块内匹配；
# 实测同一份文本一个返回 `'other-slug'`、一个返回 `None`）。现在两份合一，docstring 也不必说谎。
from checklist import fm as _fm  # noqa: E402


def _read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def _md_files(d):
    return sorted(glob.glob(os.path.join(d, "*.md"))) if os.path.isdir(d) else []


# 评审报告（ReviewRecord）的解析归 **ci/bin/review_record.py**（深模块，单一归属）。
# 此前这里自带一套 `_target_kind` / `_review_reports` / `_count_findings`，与 handoff.py 的同名实现
# **已经矛盾**（实测 `diff`/`arch` 在本模块判 code、在 handoff 判 design）—— 同一个 target 两个答案。
# 三件格式知识（目标分类 / 与 TSD 的匹配 / 发现清单解析）现在各自只有一处判据。
_review_reports = review_record.iter_reports
_SEV = review_record.SEVERITIES
_target_kind = review_record.kind_of


def _int_or_none(s):
    try:
        return int(str(s).strip())
    except (TypeError, ValueError):
        return None


# ---- 开放决策解析（REQ-002）----
# 真实世界的块有四种形态（都在生产 TSD 里出现过），判据必须覆盖全部，否则误报：
#   A `## 开放决策（REQ-002）` + 每条 `` `D` = owner（…）``          → 逐条有 D
#   B `## 开放决策（REQ-002，owner X 已拍板 OD-1~OD-3）` + 每条 `D`=owner → 块级 + 逐条
#   C `## 开放决策（REQ-002，已拍板 owner X）` + `- **D1 …**` 无逐条 D → **仅块级**
#   D `## 开放决策（REQ-002，已拍板 owner X）` + 引用块 `> A…；I…。各条 D 见下` → **仅块级**
# 只认「逐条 `` `D` ``」会把 C/D 全判成缺 D —— 那是误报，而误报会让人不再信这个指标。
_BLOCK_OWNER_RE = re.compile(r"已拍板[^\n）)]{0,20}?(owner|负责人|@[A-Za-z0-9_-]+)", re.I)
_ENTRY_OWNER_RE = re.compile(r"`D`\s*[=:：]|(?<![A-Za-z0-9_])D\s*[=:：]")
_ENTRY_RE = re.compile(r"^-[ \t]+\*\*(.+?)\*\*")


def _open_decision_block(text):
    """返回 (entries, block_owner, body)；entries = [(label, body)]。无该节返回 (None, False, "")。"""
    m = re.search(r"^##[ \t]*开放决策.*$", text, re.M)
    if not m:
        return None, False, ""
    heading = m.group(0)
    rest = text[m.end():]
    nxt = re.search(r"^##[ \t]", rest, re.M)
    if nxt:
        rest = rest[:nxt.start()]
    block_owner = bool(_BLOCK_OWNER_RE.search(heading))
    # 引用块里的块级归属（形态 D 的 `> A…= …`）：只看 `>` 行，且只在「声明了 owner」时算
    for ln in rest.splitlines():
        if ln.lstrip().startswith(">"):
            if _BLOCK_OWNER_RE.search(ln) or re.search(r"[（(]\s*必须同意方\s*[）)]\s*[=:：]", ln):
                # 引用块里出现 A/I 定义但没写 owner 归属时不算 —— 光有 A/I 不等于 D 已落
                if _BLOCK_OWNER_RE.search(ln) or re.search(r"owner|负责人", ln, re.I):
                    block_owner = True
    # 逐条切
    entries = []
    cur = None
    for ln in rest.splitlines():
        mm = _ENTRY_RE.match(ln)
        if mm:
            if cur:
                entries.append(cur)
            # 同一行的**余下部分也是条目正文**：真实块里 `` `D`=owner `` 就常跟在 `**标签**：` 之后。
            # 只留 mm.group(1) 会把同行的 D 归属整段丢掉 → 全判成「缺 D」（误报，已实测）。
            cur = [mm.group(1).strip(), [ln[mm.end():]]]
        elif cur is not None:
            cur[1].append(ln)
    if cur:
        entries.append(cur)
    return [(lbl, "\n".join(body)) for lbl, body in entries], block_owner, rest


def _decisions_are_empty(body):
    """块体是否明确声明「无开放决策」（而非「解析不出来」）。"""
    s = re.sub(r"^[>\s]*", "", body or "", flags=re.M).strip()
    return bool(re.fullmatch(r"[（(]?无[）)]?[。.]?|无开放决策[。.]?", s))


# ---------------------------------------------------------------------------
# 采集器：签名 (root) -> (status, value, detail)
# ---------------------------------------------------------------------------

def c_tsd_review_rounds(root):
    reps = [r for r in _review_reports(root) if r["kind"] == "design"]
    if not reps:
        return EMPTY, 0, "无设计类评审报告（.harness/reports/*-review.md 且 target 非代码类）"
    per = {}
    for r in reps:
        if r["round"] is not None:
            per[r["target"]] = max(per.get(r["target"], 0), r["round"])
    if not per:
        return ERROR, None, "有 %d 份设计类评审报告但 frontmatter 缺 round，无法判轮次" % len(reps)
    return OK, max(per.values()), "各 target 最高轮次: " + ", ".join(
        "%s=%d" % (t, n) for t, n in sorted(per.items()))


def c_open_decisions_missing_d(root):
    tsds = _md_files(os.path.join(root, ".harness", "tsd"))
    if not tsds:
        return EMPTY, 0, "无 TSD（.harness/tsd/ 为空）"
    missing = 0
    no_block, unparsed, details = [], [], []
    n_entries = 0        # 真解析出条目的 TSD 数：一个都没有 = 来源为空（empty），不是「全都有 D」（ok）
    for t in tsds:
        try:
            text = _read(t)
        except OSError:
            unparsed.append(os.path.basename(t) + "(读失败)")
            continue
        entries, block_owner, body = _open_decision_block(text)
        name = os.path.basename(t)
        if entries is None:
            no_block.append(name)
            continue
        if not entries:
            if _decisions_are_empty(body):
                details.append("%s: 无开放决策（明确声明）" % name)
                continue
            # 有该节、却解析不出任何条目 —— 这是「判不了」，不是「全都有 D」。报 error，不报 0。
            unparsed.append(name + "(有开放决策节但无 `- **` 条目)")
            continue
        lack = [lbl for lbl, body in entries if not (_ENTRY_OWNER_RE.search(body) or block_owner)]
        n_entries += len(entries)
        if lack:
            missing += len(lack)
            details.append("%s: 缺 D %d/%d（%s）" % (name, len(lack), len(entries), "; ".join(lack[:3])))
        else:
            details.append("%s: %d 条均有 D%s" % (name, len(entries), "（块级 owner）" if block_owner else ""))
    if unparsed:
        # 部分 TSD 判不了 → 整体 error（宁可报「判不了」，也不给一个偏低的数当结论）
        return ERROR, missing, "有 %d 份 TSD 无法判定：%s ｜ 已判出的缺 D 数=%d。%s" % (
            len(unparsed), ", ".join(unparsed), missing, " / ".join(details))
    if not details:
        return ERROR, None, "全部 TSD 都无「开放决策」节（REQ-002 未落？）"
    if n_entries == 0:
        # 有该节、且逐份都明确写了「无」 → 来源为空，值是 0 但性质是 empty（不是「全部有 D」）
        return EMPTY, 0, " / ".join(details)
    return OK, missing, " / ".join(details)


def c_fix_rounds(root):
    cards = _md_files(os.path.join(root, ".harness", "runcards"))
    if not cards:
        return UNAVAIL, None, "无 RunCard（.harness/runcards/ 为空）——来源未落地：该 TSD 尚未经 harness-plan 起卡"
    per, unparsed = {}, []
    for c in cards:
        try:
            text = _read(c)
        except OSError:
            unparsed.append(os.path.basename(c))
            continue
        r = _int_or_none(_fm(text, "rounds"))
        if r is None:
            unparsed.append(os.path.basename(c))
            continue
        per[os.path.basename(c)] = r
    if unparsed:
        return ERROR, None, "RunCard 缺 rounds 字段：%s" % ", ".join(unparsed)
    return OK, max(per.values()), "各卡 rounds: " + ", ".join("%s=%d" % (k, v) for k, v in sorted(per.items()))


def c_antipattern_hits(root):
    reports = os.path.join(root, ".harness", "reports")
    pit = None
    pj = os.path.join(reports, "pitfall-last.json")
    if os.path.exists(pj):
        try:
            data = json.load(open(pj, encoding="utf-8"))
            pit = len(data.get("results", []))
        except (OSError, ValueError) as e:
            return ERROR, None, "pitfall-last.json 不可解析（%s）——命中数判不了" % e
    # 评审报告里的反 TSD / 反模式类发现（blocking + important）
    rev_hits, rev_detail = 0, []
    for r in _review_reports(root):
        if not r["findings"]:
            continue
        try:
            body = _read(os.path.join(reports, r["file"]))
        except OSError:
            continue
        n = len(re.findall(r"^-[ \t]+\*\*.*?(反 TSD|反模式).*?\*\*", body, re.M))
        if n:
            rev_hits += n
            rev_detail.append("%s=%d" % (r["file"], n))
    if pit is None and not rev_detail:
        return UNAVAIL, None, "无 pitfall-last.json（先跑 g_pitfall）且评审报告无反 TSD/反模式发现"
    total = (pit or 0) + rev_hits
    det = "坑库命中=%s" % ("—" if pit is None else pit)
    if rev_detail:
        det += " · 评审反 TSD/反模式: " + ", ".join(rev_detail)
    elif pit is not None:
        det += " · 评审反 TSD/反模式: 0"
    return OK, total, det


def c_contract_landed_rate(root):
    """来源 = closed-loop-audit 落盘的 audit-last.json（该脚本写自己的 stage 文件，单一写者）。

    audit 未跑过 → unavailable（不报 0：没跑 ≠ 全部落盘）。
    """
    p = os.path.join(root, ".harness", "reports", "audit-last.json")
    if not os.path.exists(p):
        return UNAVAIL, None, "无 audit-last.json —— 未跑过 closed-loop-audit.sh，落盘率无从判定"
    s = audit_summary.read_summary(p)      # 字段名归写者定义，此处不写自己的字面量
    if s is None:
        return ERROR, None, "audit-last.json 不可解析"
    total, not_landed = s["contracts_total"], s["contracts_not_landed"]
    if total is None or not_landed is None:
        return ERROR, None, "audit-last.json 缺 contracts_total/contracts_not_landed 字段"
    if not total:
        return EMPTY, None, "本仓无契约（.harness/contracts/*.md 为空）"
    return OK, round(100.0 * (total - not_landed) / total, 1), \
        "契约 %d 条，未落盘 %d 条（audit %s）" % (total, not_landed, s["ts"])


def c_gate_result(root, run=None):
    ev = _metric_events(root, run)
    if ev is None:
        return UNAVAIL, None, "无 metric-events.jsonl —— 未跑过 harness-gate.sh"
    g = {}
    for e in ev:
        m = e.get("metric", "")
        if not m.startswith("gate."):
            continue
        v = str(e.get("value", ""))
        if v in ("0", "1", "2"):
            g.setdefault(m, {"0": 0, "1": 0, "2": 0})[v] += 1
    if not g:
        if run:
            return EMPTY, 0, "该 run（%s）无 gate.* 事件（事件流存在，但无归属本 run 的 gate 事件）" % run
        return EMPTY, 0, "有 MetricEvent 但无 gate.* 事件"
    green = sum(d["0"] for d in g.values())
    red = sum(d["1"] for d in g.values())
    yellow = sum(d["2"] for d in g.values())
    return OK, red + yellow, "绿=%d 红=%d 黄=%d ｜ %s" % (
        green, red, yellow, "; ".join("%s: 绿%d红%d黄%d" % (k, d["0"], d["1"], d["2"]) for k, d in sorted(g.items())))


def c_finding_severity(root):
    reps = _review_reports(root)
    if not reps:
        return EMPTY, 0, "无评审报告"
    tot = {"blocking": 0, "important": 0, "nit": 0}
    countable, mismatch = 0, []
    for r in reps:
        if r["findings"]:
            countable += 1
            for s in _SEV:
                tot[s] += r["findings"]["counts"][s]
            mismatch += ["%s %s" % (r["file"], x) for x in r["findings"]["declared_mismatch"]]
    if not countable:
        return ERROR, None, "有 %d 份评审报告但均无「发现清单/发现分级」节，严重度分布判不了" % len(reps)
    det = "blocking=%d important=%d nit=%d（%d/%d 份报告有可数清单）" % (
        tot["blocking"], tot["important"], tot["nit"], countable, len(reps))
    if mismatch:
        det += " ｜ **报告自述与实条目不符**：" + "; ".join(mismatch)
    return OK, tot["blocking"], det


def c_review_rounds(root):
    reps = [r for r in _review_reports(root) if r["kind"] == "code"]
    if not reps:
        return EMPTY, 0, "无代码类评审报告（target 末段 ∈ %s，见 review_record.CODE_TOKENS）" % (
            "/".join(review_record.CODE_TOKENS),)
    per = {}
    for r in reps:
        if r["round"] is not None:
            per[r["target"]] = max(per.get(r["target"], 0), r["round"])
    if not per:
        return ERROR, None, "有 %d 份代码类评审报告但缺 round 字段" % len(reps)
    return OK, max(per.values()), "各 target 最高轮次: " + ", ".join(
        "%s=%d" % (t, n) for t, n in sorted(per.items()))


def c_pipeline_conversion(root):
    props = [f for f in _md_files(os.path.join(root, ".harness", "work"))
             if os.path.basename(f).startswith("proposal-")]
    if not props:
        return EMPTY, 0, "无 keep 提案（.harness/work/proposal-*.md）"
    dist, unparsed = {}, []
    for f in props:
        try:
            st = _fm(_read(f), "status")
        except OSError:
            unparsed.append(os.path.basename(f))
            continue
        if not st:
            unparsed.append(os.path.basename(f))
            continue
        dist[st] = dist.get(st, 0) + 1
    if unparsed:
        return ERROR, None, "提案缺 status 字段：%s" % ", ".join(unparsed)
    landed = dist.get("landed", 0)
    return OK, round(100.0 * landed / len(props), 1), \
        "提案 %d 条：%s" % (len(props), ", ".join("%s=%d" % kv for kv in sorted(dist.items())))


def c_promoted_shared(root):
    n, detail = 0, []
    # 1) 本地 checklist 项被晋升（promote 脚本写 `promoted_to`）
    ck = os.path.join(root, ".harness", "checklists")
    for f in _md_files(ck):
        try:
            text = _read(f)
        except OSError:
            continue
        promoted = re.findall(r"^promoted_to:[ \t]*(\S+)", text, re.M)
        if promoted:
            n += len(promoted)
            detail.append("%s: %s" % (os.path.basename(f), ", ".join(promoted)))
    # 2) keep 提案里记录了晋升目标
    for f in _md_files(os.path.join(root, ".harness", "work")):
        if not os.path.basename(f).startswith("proposal-"):
            continue
        try:
            text = _read(f)
        except OSError:
            continue
        for v in re.findall(r"^promoted_to:[ \t]*(\S+)", text, re.M):
            n += 1
            detail.append("%s: %s" % (os.path.basename(f), v))
    if not detail:
        return EMPTY, 0, "无晋升记录（本地 checklist 与 proposal 中均无 promoted_to）"
    return OK, n, " / ".join(detail)


def c_declaration_not_landed(root):
    """来源 = closed-loop-audit.sh 落盘的 audit-last.json（同 contract_landed_rate）。"""
    p = os.path.join(root, ".harness", "reports", "audit-last.json")
    if not os.path.exists(p):
        return UNAVAIL, None, "无 audit-last.json —— 未跑过 closed-loop-audit.sh，死声明数无从判定"
    s = audit_summary.read_summary(p)      # 字段名归写者定义（此前这里写的是 `not_landed_kinds`，
    if s is None:                          # 而写者写的是 `kinds` —— `or {}` 吞掉了失配，明细永远列不出）
        return ERROR, None, "audit-last.json 不可解析"
    n = s["not_landed"]
    if n is None:
        return ERROR, None, "audit-last.json 缺 not_landed_total 字段（旧版 audit 产物？重跑 audit）"
    kinds = s["kinds"]
    det = "死声明 %d 条（audit %s）" % (n, s["ts"])
    if kinds:
        det += " ｜ " + ", ".join("%s=%d" % kv for kv in sorted(kinds.items()))
    return OK, n, det


def c_metric_events_by_stage(root):
    ev = _metric_events(root)
    if ev is None:
        return UNAVAIL, None, "无 metric-events.jsonl（各阶段尚未写事件）"
    if not ev:
        return EMPTY, 0, "metric-events.jsonl 为空文件"
    dist = {}
    for e in ev:
        s = e.get("stage", "?")
        dist[s] = dist.get(s, 0) + 1
    # 模型里声明的 6 个阶段：**空阶段要显式点名**（计数为空 = 该阶段没在记，不是「做得好」）
    stages = ["plan", "build", "verify", "review", "close", "global"]
    silent = [s for s in stages if s not in dist]
    det = "共 %d 条：%s" % (len(ev), ", ".join("%s=%d" % kv for kv in sorted(dist.items())))
    if silent:
        det += " ｜ **无事件的阶段**：" + ", ".join(silent)
    # 口径澄清（ADR-0016 决策 4）：本格只答「哪些阶段在用 MetricEvent 流」，**不**等于「哪些阶段有观测」。
    det += "（口径：本格只答「哪些阶段在用事件流」，非「哪些阶段有观测」——plan/build 的观测在源实体）"
    return OK, len(ev), det


def _latest_metric(root, name, run=None):
    """取某 metric 名的**最新一条** MetricEvent。返回 (event|None, detail)。

    judge 判定类四格（w2h_completeness / false_green / false_positive_rate / routing_accuracy）的
    结论由 judge 产出、经 `judge-review.sh` 写成 MetricEvent —— 没有别的落点。
    标记缺失**不判失败**（口径=观测，见 ADR-0012 决策 5）：指标一旦升格成门禁即招 Goodhart。
    但缺失必须**可见**，且**原因要写准** —— 只从事件流里分不出「该目标没跑过」与「跑了没输出标记」，
    故两种都列出来，不假装知道是哪一种。绝不塌成 0（0 会被读成「测过了，没问题」）。
    """
    ev = _metric_events(root, run)
    if ev is None:
        return None, "无 metric-events.jsonl —— 该格的写者（judge-review.sh）尚未跑过"
    vals = [e for e in ev if e.get("metric") == name]
    if not vals:
        return None, ("metric-events.jsonl 里没有 %s 事件 —— 要么该 judge 目标没跑过（或跑的是"
                      "不请求该格的目标），要么跑了但未输出该标记（口径=观测，缺失不阻断）" % name)
    last = vals[-1]
    return last, "%d 条事件，取最新（%s，source=%s）" % (
        len(vals), last.get("ts", "?"), last.get("source", "?"))


def c_judge_metric(root, name, run=None):
    """judge 判定类指标的通用采集器（四个格共用）。"""
    last, det = _latest_metric(root, name, run)
    if last is None:
        return UNAVAIL, None, det
    return OK, last.get("value"), det


def _metric_events(root, run=None):
    p = os.path.join(root, ".harness", "reports", "metric-events.jsonl")
    if not os.path.exists(p):
        return None
    out = []
    with open(p, encoding="utf-8") as f:
        for ln in f:
            ln = ln.strip()
            if not ln:
                continue
            try:
                e = json.loads(ln)
            except ValueError:
                continue          # 坏行跳过：append-only 流里混入坏行不该让整表消失
            # per-run 过滤（ADR-0016 决策 2）：只留 run 匹配的事件；无 run 字段的旧事件不计入。
            if run is not None and str(e.get("run", "")) != run:
                continue
            out.append(e)
    return out


_COLLECTORS = {
    "tsd_review_rounds": c_tsd_review_rounds,
    "open_decisions_missing_d": c_open_decisions_missing_d,
    "fix_rounds": c_fix_rounds,
    "antipattern_hits": c_antipattern_hits,
    "contract_landed_rate": c_contract_landed_rate,
    "gate_result": c_gate_result,
    "finding_severity": c_finding_severity,
    "review_rounds": c_review_rounds,
    "pipeline_conversion": c_pipeline_conversion,
    "promoted_shared": c_promoted_shared,
    "declaration_not_landed": c_declaration_not_landed,
    "metric_events_by_stage": c_metric_events_by_stage,
}


def collect(root, run=None):
    """跑全部登记格，返回 {key: {stage, metric, source, bad_signal, status, value, detail}}。

    `run`（ADR-0016 决策 2）：非 None 时，**事件流类**采集器（gate_result / judge 四格）只统计该 run
    的事件；**源实体类**采集器（TSD/ReviewRecord/RunCard/audit）仍为全局（其来源不带 run，见
    ADR-0016 决策 2 的边界）。采集器抛异常**不吞**：转成 ERROR 状态并带异常文本 —— 一格采集崩了
    不该让整张表消失，但也不该静默显示成 0。
    """
    out = {}
    for c in CELLS:
        row = {k: c[k] for k in ("key", "stage", "metric", "source", "bad_signal")}
        name = c["collector"]
        if name == "judge_metric":
            # 参数化采集器：judge 判定类四格共用，靠 metric 名区分
            fn = lambda r, _n=c["metric"], _run=run: c_judge_metric(r, _n, _run)   # noqa: E731
        elif name == "gate_result":
            fn = lambda r, _run=run: c_gate_result(r, _run)                        # noqa: E731
        else:
            fn = _COLLECTORS.get(name) if name else None
        if fn is None:
            row.update(status=UNAVAIL, value=None, detail="来源未落地（该实体/字段尚无落盘机制，见 ADR-0012 决策 5）")
        else:
            try:
                st, val, det = fn(root)
            except Exception as e:                      # noqa: BLE001 —— 转状态，不吞
                st, val, det = ERROR, None, "采集器异常：%s: %s" % (type(e).__name__, e)
            row.update(status=st, value=val, detail=det)
        out[c["key"]] = row
    return out


def summary(rows):
    """按状态计数 —— 渲染方用它报「多少格未落地 / 判不了」，避免只看到一堆 0。"""
    n = {OK: 0, EMPTY: 0, UNAVAIL: 0, ERROR: 0}
    for r in rows.values():
        n[r["status"]] = n.get(r["status"], 0) + 1
    return n


def render_text(rows, indent="  "):
    """文本渲染（measure 的 stdout 段用）。"""
    lines = []
    for stage in ("plan", "build", "verify", "review", "close", "global"):
        sub = [r for r in rows.values() if r["stage"] == stage]
        if not sub:
            continue
        lines.append("[metric] %s" % stage)
        for r in sub:
            if r["status"] == OK:
                v = "—" if r["value"] is None else r["value"]
                lines.append("%s%-30s %s  (%s)" % (indent, r["metric"], v, r["detail"]))
            elif r["status"] == EMPTY:
                lines.append("%s%-30s 0  (来源为空：%s)" % (indent, r["metric"], r["detail"]))
            elif r["status"] == UNAVAIL:
                lines.append("%s%-30s ∅无来源  (%s)" % (indent, r["metric"], r["detail"]))
            else:
                lines.append("%s%-30s ⚠判不了  (%s)" % (indent, r["metric"], r["detail"]))
    return lines


def main(argv):
    # root = 第一个**非旗标**位置参数。旧写法 `argv[1]` 在 `metrics.py --json`（省略 root）时会把
    # "--json" 当成 root 传给 collect —— 静默得到「全格 unavailable」而非报错，症状看起来像采集坏了。
    args = list(argv[1:])
    run = None
    if "--run" in args:                     # ADR-0016 决策 2：per-run 过滤（事件流类采集器）
        i = args.index("--run")
        run = args[i + 1] if i + 1 < len(args) else None
        args = args[:i] + args[i + 2:]
    _flags = ("--json", "--keys")
    _pos = [a for a in args if a not in _flags]
    root = _pos[0] if _pos else "."
    as_json = "--json" in args
    if "--keys" in args:
        # 已知格键清单（供 judge-review.sh 校验 JUDGE_METRIC 标记：**注册表单一真源**，
        # 脚本不另抄一份 key 列表 —— 抄一份就会漂，而漂的表现是「写了没人认」）。
        for c in CELLS:
            print(c["key"])
        return 0
    rows = collect(root, run)
    if as_json:
        print(json.dumps(dict(summary=summary(rows), cells=rows), ensure_ascii=False, indent=2))
    else:
        for ln in render_text(rows):
            print(ln)
        n = summary(rows)
        print("[metric] 汇总: ok=%d empty=%d 无来源=%d 判不了=%d" % (n[OK], n[EMPTY], n[UNAVAIL], n[ERROR]))
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main(sys.argv))
