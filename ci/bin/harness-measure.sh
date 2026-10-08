#!/usr/bin/env bash
# harness-measure.sh — 度量报表（优化 #1）：聚合运行回路 issue 终局、坑库规则命中、checklist 消费三类落盘证据，
# 渲染自包含 HTML 到 .harness/reports/measure.html，并在 stdout 打文本汇总。
# 只读：只写 .harness/reports/measure.html；不修代码、不判数据。
# 用法: harness-measure.sh [--section] [--run <runcard-id>]
#   --section  只输出 markdown「观测」节到 stdout（供 close 汇总报告内嵌，ADR-0016 决策 1），不写 HTML
#   --run <id> per-run 视图：事件流类格只统计该 run 的事件（源实体类格仍全局，ADR-0016 决策 2）
# 输入（全部可选，缺则优雅降级为「暂无数据」，不假绿）：
#   .harness/work/*.md                  运行回路 issue（kind=issue 且带 disposition frontmatter 的才计）
#   .harness/reports/pitfall-last.json   最近一次 semgrep --json（harness-gate.sh 的 g_pitfall 落盘）
#   .harness/reports/checklist-consumed.log  checklist 消费流水（{pid}\t{cid}）
set -euo pipefail
export PYTHONUTF8=1  # PEP 540: Windows 强制 UTF-8（避免 GBK 读/写中文出错）

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=harness-identity.sh
source "$ROOT/ci/bin/harness-identity.sh"
PID="$(h_id)"
OUT="$ROOT/.harness/reports/measure.html"
mkdir -p "$(dirname "$OUT")"

# 参数（ADR-0016）：
#   --section       只输出 markdown「观测」节到 stdout（供 close 汇总报告内嵌），不写 HTML
#   --run <id>      per-run 视图：事件流类格只统计该 run 的事件（源实体类格仍全局）
MODE=full; RUN=""
while [ $# -gt 0 ]; do
  case "$1" in
    --section) MODE=section ;;
    --run) RUN="${2:-}"; if [ $# -ge 2 ]; then shift; fi ;;
    --run=*) RUN="${1#--run=}" ;;
  esac
  shift
done

# 环境解析（解释器 / 编码）单源见 ci/bin/harness-env.sh；本机缓存 .harness/toolchain.env 由 harness-preflight.sh 生成。
# 本脚本主体在 python：占位桩下会**静默什么都不产出**，与「没有数据」长得一样（同 harness-scaffold 的 gates-ls 盲区）。
# shellcheck source=harness-env.sh
source "$(dirname "${BASH_SOURCE[0]}")/harness-env.sh"
py_ok || { echo "[measure] python3 不可用（命令存在但执行失败；Windows 上常见为 Store 占位桩）——拒绝静默无事发生" >&2; exit 2; }

"$HARNESS_PYTHON" - "$ROOT" "$OUT" "$PID" "$MODE" "$RUN" <<'PY'
import sys, os, re, json, glob, html, datetime

ROOT, OUT, PID = sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "?"
MODE = sys.argv[4] if len(sys.argv) > 4 else "full"
RUN = sys.argv[5] if len(sys.argv) > 5 else ""
run = RUN or None
sys.path.insert(0, os.path.join(ROOT, "ci", "bin"))
from checklist import fm  # noqa: E402  frontmatter 单字段解析（单一归属，与 keep-land/closed-loop-audit 同源）
# 指标模型（ADR-0012 决策 5）的单一真源：模型 + 采集 + 状态全在 metrics.py，本脚本只渲染。
# 此前 measure 自己解析 metric-events.jsonl 统计门禁绿/红/黄 —— 那是同一来源的第二份解析，
# 与模型里的 verify.gate_result 会漂；现统一走 metrics.collect()。
from metrics import collect as collect_metrics, summary as metric_summary, render_text  # noqa: E402

WORK = os.path.join(ROOT, ".harness", "work")
REPORTS = os.path.join(ROOT, ".harness", "reports")
PITFALL_JSON = os.path.join(REPORTS, "pitfall-last.json")
CONSUMED_LOG = os.path.join(REPORTS, "checklist-consumed.log")

def esc(s):
    return html.escape(str(s), quote=True)

def ymd(s):
    try:
        return datetime.datetime.strptime((s or "")[:10], "%Y-%m-%d").date()
    except Exception:
        return None

# ---- 1) 运行回路 issue ----
issues = []
for f in sorted(glob.glob(os.path.join(WORK, "*.md"))):
    try:
        text = open(f, encoding="utf-8").read()
    except Exception:
        continue
    if fm(text, "disposition") is None:
        # 跳过非运行回路 issue：cs-issue triage 文件无 disposition frontmatter（另一命名空间，不计入运行回路指标）
        continue
    slug = fm(text, "id") or os.path.basename(f).replace(".md", "")
    disp = (fm(text, "disposition") or "open").strip()
    created = fm(text, "created") or ""
    m = re.search(r"runtime-(.+?)-\d{4}-\d{2}-\d{2}", slug)
    domain = m.group(1) if m else "?"
    c = ymd(created)
    ttf = None
    end_src = ""
    if disp in ("confirmed", "false-alarm") and c:
        # **用 frontmatter 的 `updated`，不用文件 mtime**：mtime 是「文件最后一次被写」，
        # git checkout / 编辑器保存 / touch 都会改它 —— 那之后 TTF 就虚高，而指标使用者无从
        # 知道这个数已失真。work-unit-schema.md 也明说 disposition 是「供 harness-measure 度量
        # precision/TTF」的，实现与 schema 的意图一致才对。
        # `updated` 缺失才退回 mtime，并**计数**（在报告里报出来，不静默混两种来源）。
        end = ymd(fm(text, "updated"))
        end_src = "updated"
        if end is None:
            try:
                end = datetime.datetime.fromtimestamp(os.path.getmtime(f)).date()
                end_src = "mtime"
            except Exception:
                end = None
        if end is not None:
            ttf = max(0, (end - c).days)
    issues.append(dict(slug=slug, disp=disp, domain=domain, created=created, ttf=ttf, ttf_src=end_src))

n_total = len(issues)
n_open = sum(1 for i in issues if i["disp"] == "open")
n_confirmed = sum(1 for i in issues if i["disp"] == "confirmed")
n_false = sum(1 for i in issues if i["disp"] == "false-alarm")
terminated = n_confirmed + n_false
precision = (100.0 * n_confirmed / terminated) if terminated else None
ttf_vals = [i["ttf"] for i in issues if i["ttf"] is not None]
avg_ttf = (sum(ttf_vals) / len(ttf_vals)) if ttf_vals else None
ttf_mtime_n = sum(1 for i in issues if i.get("ttf_src") == "mtime")

domains = {}
for i in issues:
    d = domains.setdefault(i["domain"], {"total": 0, "confirmed": 0, "false": 0, "open": 0})
    d["total"] += 1
    if i["disp"] == "confirmed":
        d["confirmed"] += 1
    elif i["disp"] == "false-alarm":
        d["false"] += 1
    else:
        d["open"] += 1

# ---- 2) 坑库规则命中 ----
pitfalls = []  # [(rule_id, count)]
if os.path.exists(PITFALL_JSON):
    try:
        from collections import Counter
        data = json.load(open(PITFALL_JSON, encoding="utf-8"))
        c = Counter(r.get("check_id", "?") for r in data.get("results", []))
        pitfalls = sorted(c.items())
    except Exception:
        pitfalls = []

# ---- 3) checklist 消费 ----
# 按 pid 分组：流水是 per-repo 台账，但 repo 可能改过 project.id（改名），旧行仍留在文件里。
# 把两个时代的行加在一起报一个数 = 静默混口径；直接丢旧行 = 静默丢数据。两者都不做，分开报。
consumed_by_pid = {}
consumed_cids = set()          # 只统计**当前 pid** 的不同项；旧 pid 的算「历史」
if os.path.exists(CONSUMED_LOG):
    try:
        for ln in open(CONSUMED_LOG, encoding="utf-8"):
            parts = ln.rstrip("\n").split("\t")
            if len(parts) < 2:
                continue
            p_, c_ = parts[0], parts[1]
            d = consumed_by_pid.setdefault(p_, {"events": 0, "cids": set()})
            d["events"] += 1
            d["cids"].add(c_)
            if p_ == PID:
                consumed_cids.add(c_)
    except Exception:
        pass
consumed_events = consumed_by_pid.get(PID, {}).get("events", 0)
stale_events = sum(d["events"] for p_, d in consumed_by_pid.items() if p_ != PID)

# ---- 4) 指标模型（ADR-0012 决策 5）：模型/采集/状态全在 ci/bin/metrics.py，此处只消费 ----
# 口径=观测（只记不挡）：本段任何失败都不改本脚本退出码。四种状态必须分别显示 ——
# 「无来源」「判不了」与「值为 0」是三种不同的事实，塌成一个数就等于把「没在测」伪装成「没问题」。
metric_rows = collect_metrics(ROOT, run)
metric_n = metric_summary(metric_rows)

# ---- 观测节 / 快照 / 趋势（ADR-0016 决策 1/3）----
HIST = os.path.join(REPORTS, "measure-history.jsonl")
_now_iso = datetime.datetime.now().isoformat(timespec="seconds")


def observation_section(rows, n, run_id):
    """markdown「观测」节（ADR-0016 决策 1）：供 close 汇总报告内嵌 —— measure 的第一个流程内消费者。"""
    L = ["## 观测", ""]
    if run_id:
        L.append("> per-run 视图 `run=%s`：事件流类格（gate/judge）按 run 过滤；"
                 "源实体类格（TSD/Review/Card/audit）为全局。" % run_id)
        L.append("")
    L.append("- 四态分布：ok=%d · 空来源=%d · 无来源=%d · 判不了=%d"
             % (n["ok"], n["empty"], n["unavailable"], n["error"]))
    gaps = [(k, r) for k, r in rows.items() if r["status"] in ("error", "unavailable")]
    if gaps:
        L.append("- **观测缺口**（`error`/`unavailable`，improve 的输入）：")
        for k, r in sorted(gaps):
            L.append("  - `%s`（%s）：%s" % (k, r["status"], r["detail"]))
    else:
        L.append("- 观测缺口：无（所有格均有来源且可解析）")
    dl = rows.get("global.declaration_not_landed", {})
    L.append("- `declaration_not_landed`（ADR-0012 最关键单一指标）：%s（%s）"
             % (dl.get("value"), dl.get("status")))
    L.append("")
    return "\n".join(L)


# --section：只吐观测节就退出（不写 HTML、不追加 history —— 它是「读取视图」，不是一次测量）。
if MODE == "section":
    sys.stdout.write(observation_section(metric_rows, metric_n, run) + "\n")
    sys.exit(0)


def _load_snaps(path):
    out = []
    if os.path.exists(path):
        for ln in open(path, encoding="utf-8"):
            ln = ln.strip()
            if ln:
                try:
                    out.append(json.loads(ln))
                except ValueError:
                    pass
    return out


def trend_lines(prev, cur):
    """相邻快照的同格 diff（ADR-0016 决策 3）。prev=None（首份）时如实说「不足」。"""
    if not prev:
        return ["（历史快照不足 2 份，暂无趋势 —— 每跑一次 measure 追加一份到 measure-history.jsonl）"]
    pc, cc = prev.get("cells", {}), cur.get("cells", {})
    out = []
    for k in sorted(set(pc) | set(cc)):
        a, b = pc.get(k, {}), cc.get(k, {})
        if a.get("value") != b.get("value") or a.get("status") != b.get("status"):
            out.append("%s: %s/%s → %s/%s"
                       % (k, a.get("status", "?"), a.get("value"), b.get("status", "?"), b.get("value")))
    return out or ["（相邻两次快照各格值无变化）"]


_snaps = _load_snaps(HIST)
_prev = _snaps[-1] if _snaps else None
_snapshot = {"ts": _now_iso, "run": run or "", "summary": metric_n,
             "cells": {k: {"status": r["status"], "value": r["value"]} for k, r in metric_rows.items()}}
_trend = trend_lines(_prev, _snapshot)


# ---- 文本汇总（stdout） ----
def pct(v):
    return ("%.1f%%" % v) if v is not None else "—"
def num(v):
    return ("%.1f" % v) if v is not None else "—"
print("[measure] project=%s" % PID)
print("[measure] 运行回路 issue: total=%d open=%d confirmed=%d false-alarm=%d precision=%s avg_ttf_days=%s"
      % (n_total, n_open, n_confirmed, n_false, pct(precision), num(avg_ttf)))
for dm in sorted(domains):
    d = domains[dm]
    print("[measure]   domain=%s total=%d confirmed=%d false-alarm=%d open=%d"
          % (dm, d["total"], d["confirmed"], d["false"], d["open"]))
print("[measure] 坑库规则命中: %d 条规则" % len(pitfalls))
for rid, cnt in pitfalls:
    print("[measure]   %s=%d" % (rid, cnt))
print("[measure] checklist 注入: 本 pid(%s) %d 次 / %d 不同项 · 历史 pid %d 次（不并入）"
      % (PID, consumed_events, len(consumed_cids), stale_events))
for p_, d in sorted(consumed_by_pid.items()):
    if p_ != PID:
        print("[measure]   历史 pid %s：%d 次 / %d 项" % (p_, d["events"], len(d["cids"])))

# ---- 指标模型（16 格）文本渲染 ----
for _ln in render_text(metric_rows):
    print(_ln)
print("[measure] 指标模型汇总: ok=%d 空来源=%d 无来源=%d 判不了=%d"
      % (metric_n["ok"], metric_n["empty"], metric_n["unavailable"], metric_n["error"]))
print("[measure] 趋势（vs 上一快照，ADR-0016 决策 3）：")
for _ln in _trend:
    print("[measure]   %s" % _ln)

# ---- HTML 渲染（自包含，无外部 JS/CDN） ----
now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
rows_domains = "".join(
    "<tr><td>%s</td><td>%d</td><td>%d</td><td>%d</td><td>%d</td></tr>"
    % (esc(dm), d["total"], d["confirmed"], d["false"], d["open"])
    for dm in sorted(domains) for d in [domains[dm]]
) if domains else "<tr><td colspan=5 class=muted>暂无运行回路 issue</td></tr>"
rows_pit = "".join(
    "<tr><td>%s</td><td>%d</td></tr>" % (esc(rid), cnt) for rid, cnt in pitfalls
) if pitfalls else "<tr><td colspan=2 class=muted>暂无坑库命中（先跑 harness-gate.sh 的 g_pitfall）</td></tr>"
_STATUS_LABEL = {"ok": "ok", "empty": "空来源", "unavailable": "无来源", "error": "判不了"}
_STAGE_LABEL = {"plan": "plan", "build": "build", "verify": "verify",
                "review": "review", "close": "close", "global": "全局"}


def _cell_value(r):
    if r["status"] == "ok":
        return "—" if r["value"] is None else str(r["value"])
    if r["status"] == "empty":
        return "0"
    return "—"        # 无来源 / 判不了：**不显示 0** —— 0 会被读成「测过了，没问题」


rows_model = "".join(
    "<tr class='st-%s'><td>%s</td><td>%s</td><td class=v>%s</td><td>%s</td><td class=src>%s</td><td class=bad>%s</td></tr>"
    % (r["status"], esc(_STAGE_LABEL.get(r["stage"], r["stage"])), esc(r["metric"]),
       esc(_cell_value(r)), esc(_STATUS_LABEL[r["status"]]), esc(r["source"]), esc(r["bad_signal"]))
    for st in ("plan", "build", "verify", "review", "close", "global")
    for r in [x for x in metric_rows.values() if x["stage"] == st]
)
rows_model_detail = "".join(
    "<tr class='st-%s'><td>%s</td><td>%s</td><td colspan=4>%s</td></tr>"
    % (r["status"], esc(_STAGE_LABEL.get(r["stage"], r["stage"])), esc(r["metric"]), esc(r["detail"]))
    for st in ("plan", "build", "verify", "review", "close", "global")
    for r in [x for x in metric_rows.values() if x["stage"] == st]
)
rows_trend = "".join("<li>%s</li>" % esc(x) for x in _trend)

html_doc = """<!DOCTYPE html>
<html lang="zh"><head><meta charset="utf-8"><title>harness 度量报表</title>
<style>
 body{font-family:-apple-system,"Segoe UI","PingFang SC",sans-serif;margin:2rem;color:#1f2328;background:#f6f8fa}
 h1{font-size:1.4rem}h2{font-size:1.1rem;margin-top:2rem;border-bottom:1px solid #d0d7de;padding-bottom:.3rem}
 .cards{display:flex;gap:1rem;flex-wrap:wrap}
 .card{background:#fff;border:1px solid #d0d7de;border-radius:6px;padding:1rem 1.2rem;min-width:140px}
 .card .k{font-size:.8rem;color:#57606a}.card .v{font-size:1.6rem;font-weight:600}
 table{border-collapse:collapse;background:#fff;margin-top:.5rem}
 th,td{border:1px solid #d0d7de;padding:.4rem .6rem;text-align:left;font-size:.9rem}
 th{background:#f6f8fa}.muted{color:#8b949e}.ok{color:#1a7f37}.bad{color:#cf222e}
 .foot{color:#8b949e;font-size:.8rem;margin-top:2rem}
 h3{font-size:.95rem;margin-top:1.2rem;color:#57606a}
 td.v{font-weight:600;text-align:right}
 td.src,td.bad{font-size:.8rem;color:#57606a;max-width:22rem}
 tr.st-unavailable td{background:#fff8e6}   /* 无来源：不是 0，给个底色免得被当「没问题」 */
 tr.st-error td{background:#ffebe9}         /* 判不了：响亮 */
</style></head><body>
<h1>harness 度量报表</h1>
<div class="foot">project: %s · 生成于 %s</div>
<h2>运行回路</h2>
<div class="cards">
 <div class="card"><div class="k">issue 总数</div><div class="v">%d</div></div>
 <div class="card"><div class="k">确认真回归</div><div class="v ok">%d</div></div>
 <div class="card"><div class="k">误报</div><div class="v bad">%d</div></div>
 <div class="card"><div class="k">未处置(open)</div><div class="v">%d</div></div>
 <div class="card"><div class="k">precision</div><div class="v">%s</div></div>
 <div class="card"><div class="k">平均 TTF(天)</div><div class="v">%s</div></div>
</div>
<table><tr><th>域</th><th>总数</th><th>confirmed</th><th>false-alarm</th><th>open</th></tr>%s</table>
<h2>坑库（规则命中）</h2>
<table><tr><th>规则 id</th><th>命中数</th></tr>%s</table>
<h2>checklist 注入</h2>
<div class="cards">
 <div class="card"><div class="k">注入次数（本 pid）</div><div class="v">%d</div></div>
 <div class="card"><div class="k">涉及的不同项</div><div class="v">%d</div></div>
 <div class="card"><div class="k">历史 pid（不并入）</div><div class="v">%d</div></div>
</div>
<h2>指标模型（ADR-0012 决策 5）</h2>
<div class="cards">
 <div class="card"><div class="k">算出来了</div><div class="v ok">%d</div></div>
 <div class="card"><div class="k">空来源(真 0)</div><div class="v">%d</div></div>
 <div class="card"><div class="k">无来源</div><div class="v">%d</div></div>
 <div class="card"><div class="k">判不了</div><div class="v bad">%d</div></div>
</div>
<table><tr><th>阶段</th><th>指标</th><th>值</th><th>状态</th><th>来源（实体.字段，谁写）</th><th>坏信号反映什么真问题</th></tr>%s</table>
<h3>各格明细</h3>
<table><tr><th>阶段</th><th>指标</th><th colspan=4>判据 / 口径</th></tr>%s</table>
<div class="foot">「无来源」= 该指标的来源实体/字段尚无落盘机制，或机制存在但尚未跑过（明细里写明是哪种）—— <b>它不等于 0</b>。<br>「判不了」= 来源在但解析不出结论，**响亮报出**，不得与「空来源」混。<br>口径一律<b>观测</b>：指标只记不挡，不与门禁混用（升格成门禁即招 Goodhart，ADR-0012 决策 5）。</div>
<div class="foot">disposition 终局由 owner 在 issue frontmatter 手标 confirmed / false-alarm；precision = confirmed/(confirmed+false-alarm)。<br>TTF 取 frontmatter 的 <code>updated</code>；该字段缺失的条数：%d（退回文件 mtime，会被 checkout/保存改写而虚高）。<br>「注入次数」= loader（harness-checklist-ls.sh）被调用的次数，<b>不等于</b>评审实际采用了这些项 —— 手动/调试调用同样计入，故它是<b>使用量</b>不是质量指标。</div>
<h2>趋势（vs 上一快照，ADR-0016 决策 3）</h2>
<ul>%s</ul>
</body></html>
""" % (
    esc(PID), now,
    n_total, n_confirmed, n_false, n_open,
    pct(precision), num(avg_ttf),
    rows_domains, rows_pit,
    consumed_events, len(consumed_cids), stale_events,
    metric_n["ok"], metric_n["empty"], metric_n["unavailable"], metric_n["error"],
    rows_model, rows_model_detail,
    ttf_mtime_n,
    rows_trend,
)

with open(OUT, "w", encoding="utf-8") as f:
    f.write(html_doc)
print("[measure] HTML → %s" % OUT)
# 快照追加（ADR-0016 决策 3）：append-only，供趋势与「改进有没有效果」判定。
# **只追加全局测量**：per-run 视图（--run）是过滤视图，与全局快照不可比，混进历史会让趋势错位。
if not run:
    with open(HIST, "a", encoding="utf-8") as f:
        f.write(json.dumps(_snapshot, ensure_ascii=False) + "\n")
    print("[measure] 快照 → %s" % HIST)
PY
