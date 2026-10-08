#!/usr/bin/env bash
# harness-data-delta.sh — 变化模型确定性预检（ADR-0007 决策 A）。不判定，只把「变化超预期」的 metric 标存疑。
# 读运行时契约「变化模型」表 + 抓取时间序列 data-{domain}.jsonl → 落 data-{domain}.drift.json（存疑项清单）。
# 存疑 ≠ 违规：语义判定（正当变化 vs 回归）交给 harness-data-judge.sh（LLM）。
# 退出码：0=预检跑完（有/无存疑都不阻断；无变化模型表或时间序列 <2 条降级为跳过，不写 drift 文件）
#        / 2=缺契约或缺时间序列（前置缺失，不假绿）。
# 用法: harness-data-delta.sh <domain>
set -euo pipefail
export PYTHONUTF8=1  # PEP 540: Windows 强制 UTF-8（避免 GBK 读/写中文出错）

# 环境解析（解释器 / 编码）单源见 ci/bin/harness-env.sh；本机缓存 .harness/toolchain.env 由 harness-preflight.sh 生成。
# 本脚本主体在 python：占位桩下会**静默产出空**，与「真的没问题」不可分（gates-ls 盲区曾使对账变红）。
# shellcheck source=harness-env.sh
source "$(dirname "${BASH_SOURCE[0]}")/harness-env.sh"
py_ok || { echo "[data-delta] python3 不可用（命令存在但执行失败；Windows 上常见为 Store 占位桩）——拒绝静默无事发生" >&2; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=harness-identity.sh
source "$ROOT/ci/bin/harness-identity.sh"

DOMAIN="${1:-}"
[ -n "$DOMAIN" ] || { echo "[data-delta] 需要 domain 参数: harness-data-delta.sh <domain>" >&2; exit 2; }
case "$DOMAIN" in *[!A-Za-z0-9._-]*) echo "[data-delta] domain 含非法字符（只允许 [A-Za-z0-9._-]）: $DOMAIN" >&2; exit 2;; esac

PID="$(h_id)"
[ -n "$PID" ] || { echo "[data-delta] identity.yaml 缺 project.id" >&2; exit 2; }

contract="$ROOT/.harness/contracts/${PID}-runtime-${DOMAIN}.md"
history="$ROOT/.harness/reports/data-${DOMAIN}.jsonl"
drift="$ROOT/.harness/reports/data-${DOMAIN}.drift.json"
rm -f "$drift"   # 预检前清旧 drift：本轮跳过分支不写 drift，避免上一轮存疑项残留污染 judge（不假绿）
[ -f "$contract" ] || { echo "[data-delta] 缺少运行时契约: $contract（先 harness-close 生成）" >&2; exit 2; }
[ -s "$history" ] || { echo "[data-delta] 缺少时间序列: $history（先跑 harness-data-check.sh）" >&2; exit 2; }

mkdir -p "$ROOT/.harness/reports"
"$HARNESS_PYTHON" - "$contract" "$history" "$drift" "$DOMAIN" <<'PY'
import sys, json, statistics

contract, history, drift, domain = sys.argv[1:5]

def extract(obj, path):
    """按点路径提取值：a.b.c 逐层；[*] 摊平数组（可写 a[*].b 或 a.[*].b）。无匹配返回 []。"""
    path = path.strip().lstrip("$").strip(".")
    path = path.replace("[*]", ".*").replace("[", ".").replace("]", "")
    segs = [seg for seg in path.split(".") if seg]  # 丢空段（a.[*].b 归一后 a..*.b 的中间空段）
    if not segs:
        return [obj]
    cur = [obj]
    for seg in segs:
        nxt = []
        for c in cur:
            if seg in ("[*]", "*"):
                if isinstance(c, list):
                    nxt.extend(c)
            elif isinstance(c, dict) and seg in c:
                nxt.append(c[seg])
            elif isinstance(c, list):
                for e in c:
                    if isinstance(e, dict) and seg in e:
                        nxt.append(e[seg])
        cur = nxt
        if not cur:
            return []
    return cur

def norm(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return v

def _fnum(s, default):
    """安全解析浮点（容忍 % 后缀），失败回退 default，绝不 raise（预检只标存疑不阻断）。"""
    try:
        return float(s.strip("%"))
    except (TypeError, ValueError):
        return default

def _inum(s, default):
    try:
        return int(s)
    except (TypeError, ValueError):
        return default

def metric_series(series, path):
    """每个快照 → 归一化并排序后的值列表（key=str 防 float/str 混排 TypeError）。"""
    return [sorted((norm(v) for v in extract(s.get("data"), path)), key=str) for s in series]

# 解析契约「变化模型」管道表（列契约：metric | json_path | primitive | params）
KNOWN = ("monotonic-nondecreasing", "monotonic-nonincreasing", "constant",
         "bounded-rate", "within-sigma", "reconcile-zero", "unbounded")
rows = []
in_table = False
for ln in open(contract, encoding="utf-8"):
    s = ln.strip()
    if s.startswith("| metric") or (s.startswith("|") and "json_path" in s and "primitive" in s):
        in_table = True
        continue
    if in_table and s.startswith("|---"):
        continue
    if in_table and s.startswith("|"):
        cells = [c.strip() for c in s.strip("|").split("|")]
        # 只收 primitive 命中已知原语的行，避免紧邻的其它管道表被误当变化模型
        if len(cells) >= 3 and cells[0] and cells[0] != "metric" and any(cells[2].startswith(k) for k in KNOWN):
            rows.append(cells)
    elif in_table and not s.startswith("|"):
        in_table = False

if not rows:
    print("[data-delta] 契约无「变化模型」表，跳过 delta 预检（退化为单快照静态判定）")
    sys.exit(0)

series = []
for ln in open(history, encoding="utf-8"):
    ln = ln.strip()
    if not ln:
        continue
    try:
        series.append(json.loads(ln))
    except json.JSONDecodeError:
        continue
if len(series) < 2:
    print("[data-delta] 时间序列不足 2 条（冷启动），跳过 delta 预检（先积累快照）")
    sys.exit(0)

suspicious = []
for cells in rows:
    metric = cells[0]
    path = cells[1]
    primitive = cells[2].strip()
    params = cells[3].strip() if len(cells) > 3 else ""
    ms = metric_series(series, path)

    # 路径在所有快照均未匹配到值 → 契约声明的 metric 可能失效/schema 变化，标存疑（防假绿）
    if not any(snap for snap in ms):
        suspicious.append({"metric": metric, "primitive": primitive,
                           "reason": "json_path 在所有快照均未匹配到值（路径失效或 schema 变化）",
                           "no_match": True})
        continue

    prev, cur = ms[-2], ms[-1]
    allnum = all(isinstance(v, float) for snap in ms for v in snap)
    # 通用 field 消失检测：历史有值、最新快照整字段缺失 → 疑似回归（收口到所有做值判的 primitive，不再各自静默跳过）
    field_gone = bool(any(s for s in ms[:-1] if s)) and not cur
    reason = None
    if primitive in ("reconcile-zero", "unbounded"):
        pass  # reconcile-zero 跨字段、unbounded 无先验 → 确定性预检不做（含 field 消失），交 LLM（constraint-model §2a）
    elif field_gone:
        reason = f"{primitive} 最新快照缺失该 metric（field 消失，疑似回归）"
    elif primitive == "constant":
        if prev != cur:
            reason = f"constant 但值集变化：{prev} → {cur}"
    elif primitive == "monotonic-nonincreasing":
        if allnum and prev and cur and max(cur) > max(prev):
            reason = f"monotonic-nonincreasing 但上界上移：max {max(prev)} → {max(cur)}"
    elif primitive == "monotonic-nondecreasing":
        if allnum and prev and cur and min(cur) < min(prev):
            reason = f"monotonic-nondecreasing 但下界下移：min {min(prev)} → {min(cur)}"
    elif primitive.startswith("bounded-rate"):
        if allnum and prev and cur:
            parts = params.split()
            rate = _fnum(parts[0] if parts else "", 20.0) / 100.0
            window = _inum(parts[1] if len(parts) > 1 else "", 1)
            if window < 1:
                window = 1
            base_sums = [sum(s) for s in ms[-window - 1:-1] if s]
            baseline = statistics.mean(base_sums) if base_sums else 0.0
            c = sum(cur)
            if baseline and abs(c - baseline) / abs(baseline) > rate:
                reason = f"bounded-rate 超界：基线 {baseline:.1f} → 最新 {c:.1f}（Δ {abs(c-baseline)/abs(baseline):.1%} > {rate:.0%}）"
    elif primitive.startswith("within-sigma"):
        if allnum and cur:
            parts = params.split()
            n = _fnum(parts[0] if parts else "", 3.0)
            window = _inum(parts[1] if len(parts) > 1 else "", 0)
            sums = [sum(s) for s in ms if s]  # 非空快照总和（历史基线）
            if len(sums) >= 3:
                base = sums[:-1] if window <= 0 else sums[-window - 1:-1]
                if len(base) >= 2:
                    m = statistics.mean(base)
                    sd = statistics.stdev(base)
                    if sd and abs(sum(cur) - m) > n * sd:
                        reason = f"within-sigma 越界：最新 {sum(cur):.1f} 偏离均值 {m:.1f} ± {n:.0f}σ（σ={sd:.1f}）"
    if reason:
        suspicious.append({"metric": metric, "primitive": primitive, "reason": reason,
                           "prev": prev if allnum else None, "cur": cur if allnum else None})

with open(drift, "w", encoding="utf-8") as f:
    json.dump({"domain": domain, "snapshots": len(series), "suspicious": suspicious},
              f, ensure_ascii=False, indent=2)
print(f"[data-delta] {domain} 变化模型预检完成：{len(rows)} metric，{len(suspicious)} 存疑 → {drift}")
for s in suspicious:
    print(f"[data-delta] 存疑 {s['metric']}（{s['primitive']}）：{s['reason']}")
sys.exit(0)
PY
