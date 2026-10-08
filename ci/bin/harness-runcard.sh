#!/usr/bin/env bash
# harness-runcard.sh — RunCard 的**唯一生产者**（落盘/推进/前提/终态）。字段级语义见
# ci/run-card-schema.md，决策见 ADR-0012。
#
# 为什么是「唯一生产者」而非各 skill 手写文件：RunCard 字段有单写者约定（schema 的写者表），
# 手写会漂（frontmatter 拼错、手写 id 撞名、handoff_from 接错链）。本脚本把这些收成确定性动作，
# 各 skill 只调子命令，不直接写卡。校验侧是 ci/bin/runcard.py（挂在 closed-loop-audit）。
#
# 用法:
#   harness-runcard.sh create  <tsd-slug>              # 创建卡（或复开：前任 done/aborted 时）；打印新卡 id
#   harness-runcard.sh advance <runcard-id> <phase>    # 推进 phase（须 ∈ 阶段枚举）
#   harness-runcard.sh round   <runcard-id>            # rounds +1（红 → 回修）
#   harness-runcard.sh premise <runcard-id> <文本>      # 追加一条「本轮前提」
#   harness-runcard.sh finish  <runcard-id> <done|aborted>
#
# 退出码: 0=成功 / 1=前置不满足（如已有进行中的卡、TSD 未冻结）/ 2=用法或环境错误
set -euo pipefail
export PYTHONUTF8=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=harness-identity.sh
source "$ROOT/ci/bin/harness-identity.sh"

# 环境解析（解释器 / 编码）单源见 ci/bin/harness-env.sh；本机缓存 .harness/toolchain.env 由 harness-preflight.sh 生成。
# shellcheck source=harness-env.sh
source "$(dirname "${BASH_SOURCE[0]}")/harness-env.sh"
py_ok || { echo "[runcard] python3 不可用（命令存在但执行失败；Windows 上常见为 Store 占位桩）——拒绝静默无事发生" >&2; exit 2; }

CMD="${1:-}"; shift 2>/dev/null || true
TSD_ARG="${1:-}"
[ -n "$CMD" ] || { echo "[runcard] 用法: harness-runcard.sh <create|advance|round|premise|finish> ..." >&2; exit 2; }
# project.id 由 harness-identity.sh 的 h_id 读（处理缩进）；不在 python 里用 fm 重读 identity.yaml
# —— identity.yaml 的字段是缩进的（project: 下），fm 的 `^id:` 匹配不到，会把 id 算成回退值。
PID="$(h_id)"; [ -n "$PID" ] || PID="proj"

# ── 复开：TSD 的 `status` 回退到 `frozen`（owner 2026-09-19 定，ADR-0012 决策 1）──────────
# 理由：`status: closed` 是**完成标识**，而创建执行卡 = 声明「该规格又进入执行」—— 两者不能同时
# 成立。此前 create 不碰 `status`，复开后 TSD 仍显示 `closed` 而卡是活的（完成标识说谎）。
#
# **委托 harness-status.sh reopen，不自己写**：TSD `status` 与 work 镜像是一对，写者必须唯一
# （镜像规则只该有一处：`closed → done`、`reopen → building`）。本脚本只做**触发**。
#
# **在 shell 侧调而不是从 python 调**：`ROOT` 作为参数传给原生 python 时会被 MSYS 转成 Windows
# 路径，再从 python 调回 MSYS bash 会被二次转换 mangle 掉（实测：`...\ci\bin\` 被吃成 `cibin`）。
# shell 里 `$ROOT` 是原生 MSYS 路径，直接用就对。
#
# 只在真的需要回退时调（`status` 已是 `frozen` 时不动）。放在 create 之前：代价是若随后 create
# 因「已有进行中的卡」被拒，`status` 已经回退了 —— 但那是**良性**的（规格确实在执行中），
# 而反向顺序会让「卡建了、status 没回退」留下一个说谎的完成标识。
if [ "$CMD" = create ] && [ -n "$TSD_ARG" ]; then
  _t="$ROOT/.harness/tsd/${TSD_ARG}.md"
  if [ -f "$_t" ]; then
    _st="$(h_fld "$_t" status)"
    if [ -n "$_st" ] && [ "$_st" != frozen ]; then
      bash "$ROOT/ci/bin/harness-status.sh" reopen "$TSD_ARG" || exit 1
      echo "[runcard] 复开：已委托 harness-status.sh reopen（TSD status → frozen，work → building）"
    fi
  fi
fi

"$HARNESS_PYTHON" - "$ROOT" "$PID" "$CMD" "$@" <<'PY'
import os, re, sys
from datetime import date

sys.path.insert(0, os.path.join(sys.argv[1], "ci", "bin"))
from checklist import fm  # noqa: E402  frontmatter 单字段解析（单一归属，只用于卡字段，卡字段是顶格的）

ROOT, PID, CMD = sys.argv[1], sys.argv[2], sys.argv[3]
ARGS = sys.argv[4:]
RCDIR = os.path.join(ROOT, ".harness", "runcards")
TSDDIR = os.path.join(ROOT, ".harness", "tsd")
PHASES = {"plan", "build", "verify", "review", "close", "done", "aborted"}
FIELDS = ("schema_version", "id", "tsd", "handoff_from", "phase", "rounds", "started", "updated")


def die(msg, code=1):
    sys.stderr.write("[runcard] %s\n" % msg); sys.exit(code)


def read_cards():
    cards = []
    if os.path.isdir(RCDIR):
        for fn in sorted(os.listdir(RCDIR)):
            if fn.endswith(".md"):
                p = os.path.join(RCDIR, fn)
                t = open(p, encoding="utf-8").read()
                cards.append({k: (fm(t, k) or "") for k in FIELDS} | {"_p": p, "_t": t})
    return cards


def get(cards, cid):
    for c in cards:
        if c["id"] == cid:
            return c
    return None


def write_atomic(path, text):
    d = os.path.dirname(path) or "."
    fd, tmp = __import__("tempfile").mkstemp(dir=d, prefix=".rc-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def set_field(text, key, value):
    """改写 frontmatter 单行字段（有则换、无则追加到块尾），原子返回新文本。"""
    if re.search(r"^%s:" % re.escape(key), text, re.M):
        return re.sub(r"^%s:.*$" % re.escape(key), "%s: %s" % (key, value), text, count=1, flags=re.M)
    m = re.search(r"^---[ \t]*$", text, re.M)
    assert m, "卡缺 frontmatter 分隔 ---"
    return text[:m.end()] + "\n%s: %s" % (key, value) + text[m.end():]


def touch_updated(text):
    return set_field(text, "updated", date.today().isoformat())


def head_of(cards, tsd):
    refs = {c["handoff_from"] for c in cards if c["handoff_from"] and c["handoff_from"] != "none"}
    return [c for c in cards if c["tsd"] == tsd and c["id"] not in refs]


# ---- create ----
if CMD == "create":
    if len(ARGS) != 1:
        die("用法: create <tsd-slug>", 2)
    tsd = ARGS[0]
    if not os.path.isfile(os.path.join(TSDDIR, tsd + ".md")):
        die("TSD 不存在（.harness/tsd/%s.md）" % tsd, 1)
    t = open(os.path.join(TSDDIR, tsd + ".md"), encoding="utf-8").read()
    if not re.search(r"^tsd_frozen:[ \t]*true", t, re.M):
        die("TSD 未冻结（%s），冻结后再起 RunCard" % tsd, 1)
    cards = read_cards()
    heads = head_of(cards, tsd)
    if len(heads) > 1:
        die("TSD %s 已有 %d 条链头（断开的分支），先修" % (tsd, len(heads)), 1)
    handoff = "none"
    if heads:
        h = heads[0]
        if h["phase"] not in ("done", "aborted"):
            die("TSD %s 已有进行中的 RunCard %s（phase=%s）——先 finish/abort 或推进它" % (tsd, h["id"], h["phase"]), 1)
        handoff = h["id"]
    n = sum(1 for c in cards if c["tsd"] == tsd)
    cid = "%s-rc-%s" % (PID, tsd)
    if n > 0:
        cid = "%s-%d" % (cid, n + 1)
    os.makedirs(RCDIR, exist_ok=True)
    body = ("---\nschema_version: 1\nid: %s\ntsd: %s\nhandoff_from: %s\nphase: plan\nrounds: 0\n"
            "started: %s\nupdated: %s\n---\n\n# RunCard %s\n\n## 本轮前提（动别处前必读）\n\n"
            % (cid, tsd, handoff, date.today().isoformat(), date.today().isoformat(), cid))
    write_atomic(os.path.join(RCDIR, cid + ".md"), body)

    print("[runcard] 已创建 %s（handoff_from=%s）" % (cid, handoff))

# ---- advance / round / finish / premise（都需要 <runcard-id>）----
elif CMD in ("advance", "round", "finish", "premise"):
    if len(ARGS) < 1:
        die("用法: %s <runcard-id> ..." % CMD, 2)
    cid = ARGS[0]
    cards = read_cards()
    c = get(cards, cid)
    if c is None:
        die("RunCard 不存在：%s" % cid, 1)
    t = c["_t"]

    if CMD == "advance":
        if len(ARGS) != 2 or ARGS[1] not in PHASES:
            die("用法: advance <id> <%s>" % "/".join(sorted(PHASES)), 2)
        if c["phase"] in ("done", "aborted"):
            die("卡已终态（%s），不复推进；复开用 create" % c["phase"], 1)
        t = set_field(t, "phase", ARGS[1])
    elif CMD == "round":
        r = int(c["rounds"] or 0) + 1
        t = set_field(t, "rounds", str(r))
    elif CMD == "finish":
        if len(ARGS) != 2 or ARGS[1] not in ("done", "aborted"):
            die("用法: finish <id> <done|aborted>", 2)
        t = set_field(t, "phase", ARGS[1])
    elif CMD == "premise":
        if len(ARGS) != 2 or not ARGS[1].strip():
            die("用法: premise <id> <文本>", 2)
        # 分隔符按「上一行是不是列表项」选：首条要空行 —— create 模板在标题后写了空行，但
        # 这里的 rstrip("\n") 会把它吃掉，不补就成 `## 标题` 紧贴 `- 前提：`，撞 markdownlint
        # MD022（标题需空行）+ MD032（列表需空行）；后续条只换行，免得在条目之间插空行把紧列表
        # 变成松列表（渲染会多出行距）。
        _base = t.rstrip("\n")
        _last = _base.split("\n")[-1].lstrip() if _base else ""
        _sep = "\n" if _last.startswith("- ") else "\n\n"
        t = _base + _sep + "- 前提：%s\n" % ARGS[1].strip()

    t = touch_updated(t)
    write_atomic(c["_p"], t)
    new_phase = fm(t, "phase")
    new_rounds = fm(t, "rounds")
    print("[runcard] %s → phase=%s rounds=%s" % (cid, new_phase, new_rounds))

else:
    die("未知子命令：%s" % CMD, 2)
PY
