#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""audit_checks.py — `closed-loop-audit.sh` 的确定性检查（深模块）。

## 为什么把检查从 shell 里搬出来

这些检查原先以 6 段**内联 python heredoc** 写在 `closed-loop-audit.sh` 里（该文件本会话改动最频繁，
40 次提交里 15 次）。代价是三条，都是实测：

1. **加一条检查贵 2~3 倍**：逻辑落模块（`runcard.py`）那次是 2 个文件；写在 audit 里是 4~7 个。
2. **测试的分辨力更脆 —— 已咬过两次**：内联检查的唯一接口是「拿整个假项目跑整个 audit」，
   于是夹具少一样东西就**静默**让所有 rc 断言失去分辨力（缺 `.harness/contracts/` → audit 恒红 →
   断言恒为 1；[10] 的夹具没清 → 污染 [10b]）。没有任何一条测试能只喂「这条检查关心的那 3 行」。
3. **它逼出了自相矛盾**：audit 里写着「不 sed 抽函数文本（会静默失配）」，而 `tests/metrics/run.sh`
   正用 sed 抽 `judge-review.sh` 的函数来测 —— 因为那个函数没有可 import 的接口。

## 接口

每条检查一个函数，签名统一：**给输入 → 回 `(failed, lines)`**。`failed=True` 即该检查判红。
CLI：`audit_checks.py <check> <args...>` → 打印 lines，退出 **0=不红 / 1=红 / 2=用法或环境错误**。

## 失败语义按原样保留（**不许「统一」**）

三段原本就不同，搬家必须保住，否则是行为变更：

| 检查 | 原本怎么算红 |
|---|---|
| `review_validity` / `freshness` | **从不**判红（只出 warn） |
| `metric_sources` / `reachability` | **每行**都算红（它们只输出失败行） |
| `checklists` / `gate_identity` | 看**退出码**（内部 `bad` 标志） |

## 消息是契约，逐字不许动

ADR-0012 决策 5：`audit_summary.py` 按**输出行**分类，「报告里说了什么，指标就记什么」；
`tests/metrics/run.sh` 还有一条漂移守卫拿这些**字面**消息喂分类器。故本模块的所有消息
与搬家前**逐字相同**（搬家时的验收方式就是「同一批夹具下输出 diff 为空」）。
"""

import io
import json
import os
import re
import sys
import contextlib
import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import review_record as rr                      # noqa: E402
from checklist import (load_items, pitfall_ids, looks_like_anchor, orphan_fm_blocks,  # noqa: E402
                       needs_domain_backfill, checklist_layers)


def _capture(fn, *args):
    """跑一段检查，捕获它 print 出来的行。返回 (lines, exited_nonzero)。

    **检查体保持逐字不变**（它们内部用 `print` 与 `sys.exit`），捕获而不是改写它们 ——
    搬家的验收标准是「输出逐字不变」，改写检查体就失去这个保证。
    """
    buf = io.StringIO()
    exited = False
    try:
        with contextlib.redirect_stdout(buf):
            fn(*args)
    except SystemExit as e:
        exited = bool(e.code)
    return [ln for ln in buf.getvalue().splitlines() if ln.strip()], exited


def review_validity(root, pid):
    # 以下检查体自 closed-loop-audit.sh **逐字搬入**（仅整体缩进 + 去掉前导）。
    # 失败语义 = 从不判红（原样：该段只出 warn）。
    lines, exited = _capture(_review_validity_body, root, pid)
    return (False, lines)


def _review_validity_body(root, pid):
    root, pid = root, pid

    # TSD key（文件名去 .md）→ content_sha
    tsds = {}
    for fn in sorted(os.listdir(os.path.join(root, ".harness", "tsd"))):
        if not fn.endswith(".md"):
            continue
        t = open(os.path.join(root, ".harness", "tsd", fn), encoding="utf-8").read()
        cs = rr.fm(t, "content_sha")
        if cs:
            tsds[fn[:-3]] = cs

    for r in rr.iter_reports(root):
        # ① 评审有效性：设计评审引用的 content_sha vs TSD 当前的
        # 匹配归 rr.resolve_tsd —— 它**认裸 slug**。此前这里是两次 `get` 猜测
        # （`tsds.get(target) or tsds.get(target.split("-",1)[-1])`），报告写裸 slug 时两次都落空
        # → **静默跳过**，而 ADR-0012 说这条是「唯一能发现评审针对旧版规格的地方」。静默跳过 = 无声失效。
        if r["cited_sha"] and r["kind"] != "code":
            key = rr.resolve_tsd(r["target"], tsds.keys(), pid)
            if key and tsds[key] != r["cited_sha"]:
                print("[audit][warn] 评审针对旧版规格: %s 引用 tsd_content_sha=%s…，而 %s 当前 content_sha=%s…"
                      "（TSD 经 re-plan 改过 → 该评审不再覆盖当前规格，需重审）"
                      % (r["file"], r["cited_sha"][:8], key, tsds[key][:8]))
        # ② 格式契约的执行点：发现清单解析不出来 = 不合规报告。
        # 契约定义在 `ci/bin/review_record.py` 头注释（`## 发现清单`/`## 发现分级` + `### 子节` 或扁平行）。
        # **只做模块不做对账，第三种格式照样会再长出来** —— 本仓 `harness-diff-review.md` 就是第三种
        # （发现清单是 markdown 表格），两个解析器都不认，而该指标是观测不是门禁，所以谁都没发现。
        # 判 **warn 不判红**：报告是判断类产物，且 metrics 已把它如实显示为「判不了」（不是静默）；
        # 为「报告的格式」阻断流程会误伤「确实没有发现、因而没写该节」的报告。
        if r["findings"] is None:
            print("[audit][warn] 评审报告发现清单不可解析: %s（target=%s）—— 不合格式契约，"
                  "依赖它的指标（finding_severity 等）会显示「判不了」。契约见 ci/bin/review_record.py 头注释；"
                  "确实没有发现时也应写该节并注明「无」" % (r["file"], r["target"]))

    # ③ 命名对账：judge 节点报告必须符合 ReviewRecord 格式（文件名 `*-review.md` + frontmatter `target`）。
    # 形态（本仓踩过，quality 节点 F2）：报告**落了盘却无消费方** —— `iter_reports` 只收 `*-review.md` 且有
    # `target` 的，`handoff.review_section` 与上面 ① 的评审陈旧性检查全按它收集，故「有 `node` 无 `target` /
    # 文件名不含 `-review`」的 judge 节点报告静默脱离**所有**消费路径（含 ① 那条「唯一能发现评审针对旧版
    # 规格」的检查 —— 它因此在本仓零主体）。判 **warn 不判红**：同 ②，报告是判断类产物，为格式阻断流程会误伤。
    rdir = os.path.join(root, ".harness", "reports")
    if os.path.isdir(rdir):
        for fn in sorted(os.listdir(rdir)):
            if not fn.endswith(".md"):
                continue
            try:
                t = open(os.path.join(rdir, fn), encoding="utf-8").read()
            except OSError:
                continue
            if rr.fm(t, "node") is None:
                continue                        # 非 judge 节点报告（verify/close/rounds 等，本就不该是 ReviewRecord）
            # 两半都要判：文件名不含 `-review` **或** 缺 `target` —— 任一条即 `iter_reports` 拒收（无消费方）。
            # 只判 target 会漏「有 node+target 但文件名非 -review」（iter_reports 只 glob `*-review.md`）那一半。
            if fn.endswith("-review.md") and rr.fm(t, "target") is not None:
                continue                        # 合规 ReviewRecord（上面 ①② 已判）
            print("[audit][warn] judge 节点报告不是 ReviewRecord: %s（文件名不含 -review 或缺 target）"
                  "—— 无消费方（review_record/handoff/audit 都收不到），也进不了评审陈旧性检查。"
                  "应改名 `{project.id}-{target}-review.md` 并补 target/round/conclusion；"
                  "契约见 ci/bin/review_record.py 头注释" % fn)


def review_landing(root, log, node_map_raw, pid):
    """judge 目标发了指标却无对应节点报告 → 判红（fail-on-line）。

    `judge-review.sh` 发 MetricEvent（`source=judge-review.sh:<target>`，带 `run` 归属），但评审报告由
    agent **事后**落盘、无机制强制 —— 于是「发了指标、报告没落」静默。audit 检查③只扫**已存在**的带
    `node` 文件，对「从未落盘」不可见（本仓踩过：quality 目标发了指标却无 `-quality-review.md`）。
    本检查按 `(run 的 TSD, 目标的 node)` 对账：每个**有 `run` 归属**的 judge 源指标事件，都必须在
    `.harness/reports/*-review.md` 里有对应 `(tsd, node)` 的 ReviewRecord。
    **只查有 `run` 的事件**：无 `run` 的历史事件无法定位 TSD，跳过（不误报）。
    `node` 映射取自 judge-review.sh 的目标登记表（`--list-target-nodes`，单一真源）。
    """
    lines, exited = _capture(_review_landing_body, root, log, node_map_raw, pid)
    return (bool(lines), lines)


def _review_landing_body(root, log, node_map_raw, pid):
    root, log, node_map_raw, pid = root, log, node_map_raw, pid
    if not os.path.isfile(log):
        return                                   # 无指标流 → 无可对账（不判红）
    node_of = {}
    for ln in node_map_raw.splitlines():
        p = ln.split("\t")
        if len(p) >= 2 and p[0].strip():
            node_of[p[0].strip()] = p[1].strip()
    # judge 源指标事件：run → {target}（**只收有 run 归属的**）
    runs = {}
    for ln in open(log, encoding="utf-8"):
        ln = ln.strip()
        if not ln:
            continue
        try:
            e = json.loads(ln)
        except ValueError:
            continue
        src = str(e.get("source", ""))
        if not src.startswith("judge-review.sh:"):
            continue
        run = e.get("run")
        if not run:
            continue
        runs.setdefault(run, set()).add(src.split(":", 1)[1])
    if not runs:
        return
    # TSD key 集合（同 review_validity：把报告 target / runcard tsd 归一后比对）
    tsd_dir = os.path.join(root, ".harness", "tsd")
    tsd_keys = set()
    if os.path.isdir(tsd_dir):
        for fn in sorted(os.listdir(tsd_dir)):
            if fn.endswith(".md"):
                tsd_keys.add(fn[:-3])
    # 已落盘报告：(tsd_key, node)
    landed = set()
    for r in rr.iter_reports(root):
        node = rr.fm(r["text"], "node")
        key = rr.resolve_tsd(r["target"], tsd_keys, pid)
        if key and node:
            landed.add((key, node))
    # run → tsd（读 RunCard 的 tsd 字段）
    import glob as _glob
    rcdir = os.path.join(root, ".harness", "runcards")

    def tsd_of_run(run):
        for c in _glob.glob(os.path.join(rcdir, "*.md")):
            if os.path.basename(c)[:-3] == run:
                try:
                    t = open(c, encoding="utf-8").read()
                except OSError:
                    return None
                return rr.fm(t, "tsd")
        return None

    for run in sorted(runs):
        tsd = tsd_of_run(run)
        if not tsd:
            continue
        key = rr.resolve_tsd(tsd, tsd_keys, pid) or tsd
        for t in sorted(runs[run]):
            node = node_of.get(t, t)
            if (key, node) not in landed:
                print("[audit] judge 目标发了指标却无对应节点报告: target=%s node=%s run=%s tsd=%s"
                      "—— judge-review.sh 已发 MetricEvent 但 .harness/reports/ 无该 (tsd,node) 的 *-review.md；"
                      "报告由 agent 事后落盘、无机制强制，评审陈旧性/发现清单消费方都收不到"
                      % (t, node, run, key))


def metric_sources(root, log):
    # 以下检查体自 closed-loop-audit.sh **逐字搬入**（仅整体缩进 + 去掉前导）。
    # 失败语义 = 每行都算红（原样：该段只输出失败行）。
    lines, exited = _capture(_metric_sources_body, root, log)
    return (bool(lines), lines)


def _metric_sources_body(root, log):
    log, root = log, root
    # 每条失败消息写成**字面量**（而不是 `"[audit] MetricEvent %s: ..." % kind`）。
    # 理由不是好看，是 tests/metrics 的漂移守卫：它从脚本里抽**字面**的 `[audit] ...` 串喂分类器，
    # 拼出来的消息它看不见 —— 于是「新加一条失败消息而没归类」这类漏记会逃过守卫。
    # 实测：写成 `echo "[audit] $msg"` 时守卫报 `[audit] $msg` 未分类，方向完全正确。
    MSG = {
        "bad-line":   "[audit] MetricEvent 坏行（不可解析）: %d 处 —— %s",
        "no-source":  "[audit] MetricEvent 来源缺失: %d 处 —— %s",
        "ghost-src":  "[audit] MetricEvent 来源指向不存在的脚本: %d 处 —— %s",
    }
    bad = {}
    def note(kind, item):
        bad.setdefault(kind, []).append(item)
    for i, ln in enumerate(open(log, encoding="utf-8"), 1):
        ln = ln.strip()
        if not ln:
            continue
        try:
            e = json.loads(ln)
        except ValueError:
            note("bad-line", "第 %d 行" % i)
            continue
        src = str(e.get("source", "")).strip()
        label = "%s=%s（第 %d 行）" % (e.get("metric", "?"), e.get("value", "?"), i)
        if not src or src == "unknown":
            note("no-source", label)
            continue
        head = src.split(":", 1)[0]
        if head.endswith((".sh", ".py")) and not os.path.isfile(os.path.join(root, "ci", "bin", head)):
            note("ghost-src", "%s → %s" % (head, label))
    for kind in sorted(bad):
        items = bad[kind]
        show = ", ".join(items[:5]) + ("…" if len(items) > 5 else "")
        print(MSG[kind] % (len(items), show))


def checklists(root, rules_file, cat_model, shared_store):
    # 以下检查体自 closed-loop-audit.sh **逐字搬入**（仅整体缩进 + 去掉前导）。
    # 失败语义 = 看退出码（原样）。
    lines, exited = _capture(_checklists_body, root, rules_file, cat_model, shared_store)
    return (exited, lines)


def _checklists_body(root, rules_file, cat_model, shared_store):
    ROOT, rules_file, cat_model, shared_store = root, rules_file, cat_model, shared_store
    # deterministic_rule 指向脚本（非 pitfalls 规则 id）时，须是**可产出**的已知脚本：键 = 脚本名，
    # 值 = 产出它的单源。此前是硬编码名集 `{"harness.schema-check"}`，**从不校验存在性** —— 「落盘」
    # 只是名级断言（soft 假绿：脚本其实不存在也过）。改为从 scaffold 派生：脚本须真被
    # `ci/bin/harness-scaffold.sh` 引用，否则对账失败（scaffold 改了名 → 这里红，逼同步）。
    known_scripts = {}
    _scaffold = os.path.join(ROOT, "ci", "bin", "harness-scaffold.sh")
    if os.path.exists(_scaffold) and "harness.schema-check" in open(_scaffold, encoding="utf-8").read():
        known_scripts["harness.schema-check"] = "ci/bin/harness-scaffold.sh"
    rules_ids = set(pitfall_ids(rules_file))
    DEFAULT_CATS = {"security", "compliance", "data-integrity", "observability", "architecture", "process", "governance", "correctness"}
    SEVERITIES = {"blocking", "important"}
    CHECK_MODES = {"deterministic", "judge"}
    # 两层都扫：suite 的 checklists/shared + 项目本地 .harness/checklists。此前只看 shared，于是
    # **项目仓库里整块被 `[ -d "$CK_SHARED" ]` 跳过 = 零校验**——而 keep-land / harness-verify 正是
    # 往项目本地层写，那才是主战场。
    SHARED_DIR = os.path.join(ROOT, "checklists", "shared")
    LOCAL_DIR = os.path.join(ROOT, ".harness", "checklists")
    # 第三处：**配置的 shared_store** —— loader 实际消费共享项的地方（harness-checklist-ls.sh 的
    # 解析顺序：本仓 checklists/shared 优先，否则 shared_store）。此前只扫前两处，于是：
    #   消费项目里 `$ROOT/checklists/shared` 不存在 → **共享层整个没被校验**，而那才是注入评审的项。
    # 按域的解析顺序镜像，逐域取 loader 会选中的那一份，避免把「装载副本 + 本仓源」当成同 id 冲突误报。
    # 本仓 shared 覆盖了哪些域 —— 第三处要按**域**让位（镜像 loader 的逐域解析），
    # 否则把「本仓源 + 装载副本」的同一份当成同 id 冲突，18 条全误报（踩过）。
    _covered = set()
    if os.path.isdir(SHARED_DIR):
        _covered = {f[:-3] for f in os.listdir(SHARED_DIR) if f.endswith(".md")}
    # category 枚举双源（同 harness-keep-land）：suite 单源 + 项目本地扩展（.harness/categories.yaml）。
    # 取并集而非覆盖，兜底内置列表——本地文件缺失不该把 suite 枚举一起丢掉。
    categories = set(DEFAULT_CATS)
    for _p in (cat_model, os.path.join(ROOT, ".harness", "categories.yaml")):
        if os.path.exists(_p):
            _cm = re.search(r"^categories:[ \t]*(.+)$", open(_p, encoding="utf-8").read(), re.M)
            if _cm:
                categories |= set(_cm.group(1).split())
    bad = 0
    # 展平成 (层, 目录, 文件名) 三元组再单层遍历——避免为「两层」多套一层缩进，把下面整块判定体推深。
    def _layer(d):
        """层标：本仓 shared 源 / 项目本地 / 配置的 shared_store（loader 的兜底消费源）。"""
        if d == SHARED_DIR:
            return "shared"
        if d == LOCAL_DIR:
            return "local"
        return "shared(装载)"
    targets = []
    for _d in (SHARED_DIR, LOCAL_DIR):
        if os.path.isdir(_d):
            targets += [(_layer(_d), _d, fn) for fn in sorted(os.listdir(_d)) if fn.endswith(".md")]
    # 第三处：只收本仓 shared 未覆盖的域（逐域解析，与 loader 一致）。
    # 路径按 realpath 比较：shared_store 直接来自 identity.yaml（只展开了行首 `~`），
    # 而 SHARED_DIR/LOCAL_DIR 是拼接出来的绝对路径 —— 裸字符串比较会把同一个目录当两处。
    if shared_store and os.path.isdir(shared_store) \
            and os.path.realpath(shared_store) not in (os.path.realpath(SHARED_DIR), os.path.realpath(LOCAL_DIR)):
        targets += [(_layer(shared_store), shared_store, fn) for fn in sorted(os.listdir(shared_store))
                    if fn.endswith(".md") and fn[:-3] not in _covered]
    DIRS = sorted({d for _l, d, _f in targets})   # 供汇总行统计
    for layer, ck_dir, fn in targets:
        domain = fn[:-3]
        # 静默丢失探测：段内有 `^id:` 却没被 parse_items 采纳 = 该项对所有消费方隐形。
        # 判 blocking —— 丢项不报错的话，「多了一条规则」和「少了一条规则」在报告里长得一样。
        for _orphan in orphan_fm_blocks(open(os.path.join(ck_dir, fn), encoding="utf-8").read()):
            _oid = (re.search(r"^id:[ \t]*(\S+)", _orphan, re.M) or [None, "?"])[1]
            print(f"[audit] {_oid}[{layer}/{domain}] 段内含 id 却未被解析采纳 —— "
                  f"该项对所有消费方隐形（常见因 frontmatter 含 YAML 列表值）")
            bad = 1
        for it in load_items(os.path.join(ck_dir, fn)):
            # 带层标：两层可能有同名 id，报错要能直接定位到是哪一层哪份文件。
            cid = "%s[%s/%s]" % (it["id"] or "?", layer, domain)
            # 1) category 必填 + 在单源枚举内（所有域、所有 severity）
            if not it["category"] or it["category"] not in categories:
                print(f"[audit] {cid} 缺合法 category（未填或不在 constraint-model.md 枚举）")
                bad = 1
            # 2) severity 必填 + 在枚举内。此前只判 `!= "blocking"` 就 continue，拼错（Blocking / 空）
            #    会静默降级成「非 blocking」，连带跳过下面对它的两段式校验——错得无声。
            if it["severity"] not in SEVERITIES:
                print(f"[audit] {cid} severity 非法/缺失：{it['severity']!r}（须 blocking/important）")
                bad = 1
            # 3) check_mode 必填 + 在枚举内（所有域、所有 severity，不再用域白名单）。
            #    留空不是「默认 judge」：harness-checklist-ls 只消费 check_mode=judge 的项，
            #    deterministic 的项由确定性门禁执行——两边都不接 ＝ 这条规则没人跑（死规则）。
            if it["check_mode"] not in CHECK_MODES:
                print(f"[audit] {cid} check_mode 非法/缺失：{it['check_mode']!r}"
                      f"（须 deterministic/judge；留空＝该规则无人执行）")
                bad = 1
            elif it["check_mode"] == "deterministic":
                dr = it["deterministic_rule"]
                if not dr:
                    print(f"[audit] {cid} check_mode=deterministic 但缺 deterministic_rule")
                    bad = 1
                elif dr not in rules_ids and dr not in known_scripts:
                    print(f"[audit] {cid} deterministic_rule={dr} 未在 ci/rules/pitfalls.yaml 或 scaffold 可产出脚本中落盘")
                    bad = 1
            # 4) frontmatter 的 domain 与所在文件名一致。消费路径走**文件名**（harness-checklist-ls 读
            #    {shared_store}/{domain}.md），不一致时行为不变但无人察觉——它是必填字段，就该名副其实。
            if it["domain"] != domain:
                print(f"[audit] {cid} frontmatter domain={it['domain']!r} 与所在文件 {domain!r} 不一致")
                bad = 1
    # 5) 跨层同 id：本地层与 shared 层会**同时**被 loader 注入评审上下文，同 id 等于同一规则进两次。
    #    此前只看 shared（本层内 id 唯一性由 keep-land 落盘时把关），两层一起扫之后冲突才可能发生。
    by_layer = {}
    for layer, ck_dir, fn in targets:
        for it in load_items(os.path.join(ck_dir, fn)):
            if it["id"]:
                by_layer.setdefault(it["id"], {})[layer] = it["status"] or ""
    for dup, layers in sorted(by_layer.items()):
        if len(layers) < 2:
            continue
        # 「已晋升、待同步」是**预期状态**，不是冲突：promote --apply 把源项标 status: approved，
        # 本机同步 suite shared 之前它仍生效；同步后 loader 以 shared 为准、跳过本地那份。
        # 只有**未标 approved** 的跨层同 id 才是真冲突（同一规则被注入两次）。
        if layers.get("local") == "approved":
            print(f"[audit][info] {dup} 本地为 approved（已晋升待同步）—— 同步后以 shared 为准；"
                  f"跑 ./install.sh --refresh-shared 完成交接")
            continue
        # 措辞修正：loader 现在按键消歧（同 id 且共享层有 → 跳过本地那份），故**不会**重复注入；
        # 真问题是「本地那份成了永不生效的孤儿」，要么删要么说明它为何还在（ocr round-4 #11）。
        print(f"[audit] {dup} 同时存在于 {' 与 '.join(sorted(layers))} → 本地那份已是失效孤儿"
              f"（loader 以 shared 为准、会跳过它）—— 若为晋升交接请标 local status: approved，否则删掉本地那份")
        bad = 1
    # 6) §2b 反向复查（只查 shared 侧）：证据看不出可复现锚 → 疑似「事故叙述」被晋升进了基线。
    #    故意**只 warning 不 blocking**：本判据是新增的，存量项普遍不达标（多数证据是事故叙述或结构观察，
    #    只有少数项指向外部规范）；一次性转红会让 audit 整体失去信号价值。先让债可见，再由 owner 分批改。
    for layer, ck_dir, fn in targets:
        if layer != "shared":
            continue
        for it in load_items(os.path.join(ck_dir, fn)):
            _m = re.search(r"^证据：(.*)$", it["body"], re.M)
            _ev = _m.group(1).strip() if _m else ""
            if not _ev:
                print(f"[audit][warn] {it['id'] or '?'} 缺「证据：」行（§2b 条件二要求证据是可复现锚）")
            elif not looks_like_anchor(_ev):
                print(f"[audit][warn] {it['id'] or '?'} 证据看不出可复现锚（§2b 条件二）—— {_ev[:36]}")
    if bad:
        sys.exit(1)
    print("[audit] 两段式对账通过（扫 %s：category/severity/check_mode 完整合法，"
          "domain 与文件名一致，deterministic_rule 落盘＝pitfalls 规则 id 或 scaffold 可产出脚本）"
          % "，".join("%s %d 份" % (_layer(d),
                                   sum(1 for _l, _dd, _f in targets if _dd == d))
                     for d in DIRS))


def gate_identity(id_file, gate_sh, gates_tsv):
    # 以下检查体自 closed-loop-audit.sh **逐字搬入**（仅整体缩进 + 去掉前导）。
    # 失败语义 = 看退出码（原样）。
    lines, exited = _capture(_gate_identity_body, id_file, gate_sh, gates_tsv)
    return (exited, lines)


def _gate_identity_body(id_file, gate_sh, gates_tsv):
    id_file, gate_sh, gates_tsv = id_file, gate_sh, gates_tsv
    gates = [ln.split("\t") for ln in gates_tsv.splitlines() if ln.strip()]
    det = [(g[0], g[1], g[3]) for g in gates if len(g) >= 4 and g[2] == "deterministic"]
    idtext = open(id_file, encoding="utf-8").read()
    gtext = open(gate_sh, encoding="utf-8").read()
    bad = 0
    m = re.search(r"^gates:\s*\n((?:^[ \t]+\w+:[ \t]*(?:true|false)[ \t]*\n?)+)", idtext, re.M)
    id_gates = set(re.findall(r"^[ \t]+(\w+):[ \t]*(?:true|false)", m.group(1), re.M)) if m else set()
    reg_keys = set(d[0] for d in det)
    for k in sorted(id_gates - reg_keys):
        print(f"[audit] identity.yaml 有孤儿开关 gates.{k}（注册表无此门禁）"); bad = 1
    for k in sorted(reg_keys - id_gates):
        print(f"[audit] 注册表门禁 {k} 缺 identity.yaml 开关"); bad = 1
    for key, name, switch in det:
        leaf = (switch or "").split(".")[-1]
        if leaf != key:
            print(f"[audit] 门禁 {key} 的 switch({switch}) 叶子({leaf}) 与 key 不一致"); bad = 1
        if not re.search(rf"^g_{key}\(\)", gtext, re.M):
            print(f"[audit] 门禁 {key}({name}) 缺执行器 g_{key}() in harness-gate.sh"); bad = 1
    if bad:
        sys.exit(1)
    print("[audit] 门禁身份对账通过（注册表 ↔ gates.* ↔ 执行器 三向一致）")


def reachability(root, named_raw, store):
    # 以下检查体自 closed-loop-audit.sh **逐字搬入**（仅整体缩进 + 去掉前导）。
    # 失败语义 = 每行都算红（原样：该段只输出失败行）。
    lines, exited = _capture(_reachability_body, root, named_raw, store)
    return (bool(lines), lines)


def _reachability_body(root, named_raw, store):
    root, named_raw, store = root, named_raw, store
    named = set(named_raw.split())
    dirs = [d for d in (os.path.join(root, "checklists", "shared"), store) if d and os.path.isdir(d)]
    seen = set()
    for d in dirs:
        for fn in sorted(os.listdir(d)):
            if not fn.endswith(".md"):
                continue
            dom = fn[:-3]
            if dom in seen:
                continue
            seen.add(dom)
            items = load_items(os.path.join(d, fn))
            judge = [it["id"] for it in items if it["check_mode"] == "judge" and it["id"]]
            if not judge or dom in named:
                continue
            print("[audit] 共享域无执行点: %s（%d 个 judge 项：%s）—— 没有任何命名路径请求它"
                  "（既不在 judge-review.sh 的 target_domains()，也没有显式 --checklist-domain）。"
                  "写了也永远不会被执行（ADR-0012 决策 4 的「死规则」）；要么接进某条路径，"
                  "要么按 ADR-0005 的退役两步退役" % (dom, len(judge), ", ".join(judge[:5])))


def freshness(ck_dir, local_dir, log, days, named_domains=""):
    # 以下检查体自 closed-loop-audit.sh **逐字搬入**（仅整体缩进 + 去掉前导）。
    # 失败语义 = 从不判红（原样：该段只出 warn）。
    lines, exited = _capture(_freshness_body, ck_dir, local_dir, log, days, named_domains)
    return (False, lines)


def _freshness_body(ck_dir, local_dir, log, days, named_domains=""):
    ck_dir, local_dir, log, days = ck_dir, local_dir, log, int(days)
    # named_domains：judge 目标默认域的并集（closed-loop-audit 经 --list-target-domains 传入，空格分隔）。
    # 用于把本地「从未被注入」的项**区分成因**：域不在并集里 = 结构上不可能被自动注入（无任何目标默认域
    # 请求它）；域在并集里 = 有默认注入路径却从未被请求（多半是评审没按 skill 做）。
    named = set(named_domains.split())
    last = {}          # cid → 最近一次消费日期（None = 有时间未知的旧行，但不确定是否最新）
    untimed = set()    # 只有旧行（无时间戳）的 cid
    if os.path.exists(log):
        for ln in open(log, encoding="utf-8"):
            parts = ln.rstrip("\n").split("\t")
            if len(parts) < 2:
                continue
            cid = parts[1]
            ts = parts[2].strip() if len(parts) >= 3 else ""
            if not ts:
                # 旧行没有时间戳（第三列是本轮才加的）。**不猜**：记下来单独报，
                # 当成「很久以前」会把刚消费过的项误报成退役候选。
                untimed.add(cid)
                last.setdefault(cid, None)
                continue
            try:
                d = datetime.datetime.fromisoformat(ts)
            except ValueError:
                untimed.add(cid)
                last.setdefault(cid, None)
                continue
            if last.get(cid) is None or d > last[cid]:
                last[cid] = d
    def judge_ids_in(d):
        """某层的 judge 项 id 集合。目录不存在 → 空集（该层无项，不是错误）。"""
        out = set()
        if not os.path.isdir(d):
            return out
        for fn in sorted(os.listdir(d)):
            if not fn.endswith(".md"):
                continue
            for it in load_items(os.path.join(d, fn)):
                if it["check_mode"] == "judge" and it["id"]:
                    out.add(it["id"])
        return out

    now = datetime.datetime.now()
    def split(ids):
        """→ (从未注入的, [(id, 天数)] 超期的, 时间未知的)"""
        never = sorted(ids - set(last))
        stale, unknown = [], []
        for cid in sorted(ids & set(last)):
            d = last[cid]
            if d is None:
                unknown.append(cid)          # 时间未知，不判陈旧（单独报）
                continue
            age = (now - d).days
            if age > days:
                stale.append("%s(%d 天前)" % (cid, age))
        return never, stale, unknown

    shared_ids = judge_ids_in(ck_dir)
    never, stale, unknown = split(shared_ids)
    # 措辞刻意**不说「退役候选」**：退役的依据是**执行点可达性**（本脚本上面那段），不是这份日志。
    # 日志是 per-project 的，这里读到的只是**本 checkout** 的记录 —— 「没记录」推不出「没人用」。
    # 说成「退役候选」会让人照它退役，而那正是错的信号（实测反例：a11y 日志里有 5 条记录，
    # 有人用过，却照样该退役 —— 因为没有任何路径请求它）。
    if never:
        print("[audit][warn] 以下 shared judge 项**本 checkout 未见消费记录**（只看得见本 checkout；"
              "**这不是退役依据** —— 退役看「执行点可达性」。此项可能被别的项目在用）: " + ", ".join(never))
    if stale:
        print("[audit][warn] 以下 shared judge 项本 checkout 超过 %d 天未见消费（最后一次在括号内；"
              "同上，只反映本 checkout，不是退役依据）: %s" % (days, ", ".join(stale)))
    if unknown:
        print("[audit][warn] 以下 shared judge 项有消费记录但**无时间戳**（旧格式行），陈旧度判不了: "
              + ", ".join(unknown))

    # ── 本地层：**死守卫**（判据权威）──
    # 语义与共享层不同，故独立的输出行与措辞：本地项的唯一消费者就是本项目，「日志里没有」= 从未被注入。
    #
    # **成因两种，都要人看，不能只报一种**：
    #   (a) **该域从未被任何评审请求过**。注入是 agent 驱动的（skill 要求 agent 调
    #       `harness-checklist-ls.sh <domain>` 并把输出注入评审上下文），**没有任何流程自动传
    #       `--checklist-domain`** —— 所以「从未被注入」常常意味着「没人按 skill 做」，而不是「规则作废」。
    #   (b) 该项确已作废。
    # 早先这里写的是「查 applies_to 是否不匹配」——**对本地项是错的**：loader 的 `applicable()`
    # 只在 `shared_layer=True` 时做 applies_to 过滤，本地项一律注入（契约也写明 applies_to 是
    # 「shared 项的适用前置」）。照那句查会查错方向。
    l_never, l_stale, l_unknown = split(judge_ids_in(local_dir))
    if l_never:
        # 每项归属域（本地层），把「从未被注入」拆成**结构性**（域不在任何目标默认域 → 结构上不可能被自动
        # 注入）与**行为性**（域在默认域内却无消费记录 → 有默认路径却没走）。旧措辞把两种成因一律报成
        # 「从未被注入过」，读者分不出「该接进某目标」还是「评审没按 skill 做」—— 两种修法完全不同。
        dom_of = {}
        if os.path.isdir(local_dir):
            for fn in sorted(os.listdir(local_dir)):
                if not fn.endswith(".md"):
                    continue
                for it in load_items(os.path.join(local_dir, fn)):
                    if it["id"]:
                        dom_of[it["id"]] = it.get("domain", "")
        struct = [c for c in l_never if dom_of.get(c, "") not in named]
        behav = [c for c in l_never if c not in struct]
        if struct:
            print("[audit][warn] 以下本地 judge 项**从未被注入过**（**结构上不可能被自动注入**：其 domain 不在任何 "
                  "judge 目标的默认域，无流程自动传 --checklist-domain —— 要么把该域接进某目标的默认域，要么 owner "
                  "明确接受仅手动携带。注意：本地项**不受 applies_to 过滤**，别往那个方向查）: " + ", ".join(struct))
        if behav:
            print("[audit][warn] 以下本地 judge 项**从未被注入过**（**有默认注入路径却从未被请求**：其 domain 在目标 "
                  "默认域内，却无消费记录 —— 有默认注入路径却没走，多半是评审没按 skill 注入，不是规则作废。注意："
                  "本地项**不受 applies_to 过滤**，别往那个方向查）: " + ", ".join(behav))
    if l_stale:
        print("[audit][warn] 以下本地 judge 项超过 %d 天未被注入（最后一次在括号内；曾注入≠还在守，死守卫候选）: %s"
              % (days, ", ".join(l_stale)))
    if l_unknown:
        print("[audit][warn] 以下本地 judge 项有消费记录但**无时间戳**（旧格式行），陈旧度判不了: "
              + ", ".join(l_unknown))


def _git_hookspath(root):
    """读仓库本地的 core.hooksPath（未设 → 空串；git 不可用 / 非仓库 → 空串）。

    git 默认不读 `.githooks/` —— 只有 `core.hooksPath` 指向它时 `.githooks/pre-commit` 才生效。
    """
    import subprocess
    try:
        p = subprocess.run(["git", "-C", root, "config", "--get", "core.hooksPath"],
                           capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return ""
    return (p.stdout or "").strip()


def selftest_wiring(root):
    """套件自测的执行点必须存在且可达（**只在套件源里判**）。

    `tests/` 此前哪里都不跑：`ci/workflows/*.yml` 与 `ci/gitlab/*.yml` 里 0 处提到它，
    `install.sh`/`upgrade.sh` 也不带它（不分发），只有三处**散文**引用它 ——
    而 HOG 规则把它当「可复现证据」。按本套件自己的标准，那是一句**没有落点的声明**，
    而本脚本所在的 audit 恰恰是为抓这类东西存在的，它自己却漏了。

    判据：`tests/` 存在（= 本仓是套件源）时，
      1. `ci/bin/harness-selftest.sh` 必须在；
      2. `.githooks/pre-commit` 必须存在且引用它；
      3. 该 hook **必须已激活**（`core.hooksPath` = `.githooks`）—— 文件在、引用对，但 git 默认
         不看 `.githooks/`，未激活时它是**惰性的**、永不触发。这正是本套件最危险的一类：
         「绿而无效」（audit 报通过，`tests/` 却仍只靠人记得跑）。
    项目 checkout 没有 `tests/`（不分发）→ **不适用**，不是失败。
    """
    if not os.path.isdir(os.path.join(root, "tests")):
        return (False, [])
    lines = []
    failed = False
    st = os.path.join(root, "ci", "bin", "harness-selftest.sh")
    hook = os.path.join(root, ".githooks", "pre-commit")
    if not os.path.isfile(st):
        lines.append("[audit] 套件自测无入口: 有 tests/ 却没有 ci/bin/harness-selftest.sh —— "
                     "回归用例没有任何执行点（「可复现证据」是一句没有落点的声明）")
        failed = True
    if not os.path.isfile(hook):
        lines.append("[audit] 套件自测无执行点: 有 tests/ 却没有 .githooks/pre-commit —— "
                     "harness-selftest.sh 只能靠人记得跑")
        failed = True
    else:
        if "harness-selftest.sh" not in open(hook, encoding="utf-8").read():
            lines.append("[audit] 套件自测执行点断链: .githooks/pre-commit 没有引用 harness-selftest.sh")
            failed = True
        # 文件在、引用对还不够：hook 必须**已激活**（core.hooksPath 指向 .githooks），否则它是惰性的。
        cur = _git_hookspath(root)
        if cur != ".githooks":
            lines.append("[audit] 套件自测执行点未激活: core.hooksPath=%r（应为 .githooks）—— "
                         ".githooks/pre-commit 是惰性的，tests/ 又变回「靠人记得跑」；"
                         "激活：git config core.hooksPath .githooks" % cur)
            failed = True
    return (failed, lines)


# AGENTS.md 受管路由块对账（治理入口）：项目根必须有 `AGENTS.md`，且含**与 `ci/agents-routing.md`
# 一致**的受管块 —— 否则「研发诉求先经 harness、不得直接走 cs-feat 跳过」这句路由声明没有落点。
# 合并/比对逻辑归深模块 `ci/bin/agents_md.py`（单一来源，ensure 与 check 共用），此处只做消息映射。
# 判**红**（owner 定）：缺路由声明 = 治理缺口；init/scaffold 会先 ensure 播种，存量项目 upgrade 后即合规。
_AGENTS_MSG = {
    "no-canonical": "[audit] AGENTS.md 对账缺 canonical: ci/agents-routing.md 不存在（ci/ 未同步？）—— 无法对账",
    "missing": "[audit] 缺 AGENTS.md（项目根）—— 研发入口路由没有落点，agent 可能直接走 cs-feat 等 skill 跳过 harness",
    "no-block": "[audit] AGENTS.md 缺 harness 受管路由块（无 <!-- harness:begin --> 标记）—— 研发诉求可能不经过 harness 入口",
    "stale": "[audit] AGENTS.md 的 harness 受管路由块与 ci/agents-routing.md 不一致 —— 重跑 ./upgrade.sh 同步",
}


def agents_md(root):
    # 比对逻辑单一来源在 agents_md.py；本函数只把 issue 码映射成 audit 消息（消息须可被 audit_summary 分类）。
    import agents_md as am
    ok, issues = am.check(root)
    return (not ok, [_AGENTS_MSG[c] for c in issues if c in _AGENTS_MSG])


_OBSERVATION_SINCE = "2026-09-28"   # ADR-0016 决策 1 生效日（owner 认可）：之前的 close 报告不回溯要求该节


def observation(root, pid):
    """收尾报告「观测」节对账（ADR-0016 决策 1）。

    声明：`harness-close` 步骤 4 要求汇总报告含「观测」节（四态分布 + error/unavailable 格清单 +
    declaration_not_landed）。缺该节 = 观测报告没有流程内消费者（ADR-0012 决策 4「产出即被消费」没落地）。
    判**红**：这是 close 报告的形状契约（该做的事有没有做），与「报告格式不可解析」不同 —— 后者是判断类
    产物的格式问题（warn）。
    **不回溯**：`date` 早于规则生效日的历史 close 报告跳过（不重写历史；新规则不追溯旧产物）。
    """
    lines = []
    failed = False
    rdir = os.path.join(root, ".harness", "reports")
    if not os.path.isdir(rdir):
        return (False, lines)                 # 无 reports 目录 = 还没收尾过，不算失败
    pat = re.compile(r"^%s-.*-close\.md$" % re.escape(pid))
    for fn in sorted(os.listdir(rdir)):
        if not pat.match(fn):
            continue
        try:
            text = open(os.path.join(rdir, fn), encoding="utf-8").read()
        except OSError:
            continue
        d = (rr.fm(text, "date") or "").strip()
        if d and not _date_ge(d, _OBSERVATION_SINCE):
            continue                          # 规则生效前的历史报告，不回溯（不重写历史）
        if "## 观测" not in text:
            lines.append("[audit] close 报告缺「观测」节: %s（ADR-0016 决策 1：跑 "
                         "ci/bin/harness-measure.sh --section 内嵌其输出）" % fn)
            failed = True
    return (failed, lines)


_EPIC_REMAINING_SINCE = "2026-10-01"   # owner 2026-10-01 需求生效日：之前的 close 报告不回溯要求该节


def _date_ge(d, since):
    """date 字符串规范化后 ≥ since（True = 不早于生效日，需判）。

    直接字符串比较会踩 `2026-9-30` > `"2026-10-01"` 的字典序坑（单月/单日不补零时排序错位），
    把历史报告误判成生效后 → 假红。故按 `-` 拆段补零成 (y,m,d) 元组比较。规范不了（空 / 非数字 /
    段数不对）→ 视为不早于（判红，与「缺 date」同语义：报告没声明合规日期就不享受不回溯）。"""
    if not d or not since:
        return True
    try:
        a = [int(x) for x in d.strip().split("-")]
        b = [int(x) for x in since.strip().split("-")]
    except (ValueError, TypeError):
        return True
    if len(a) != len(b):
        return True          # 段数不对 → 视为不早于（判红）：没声明合规日期就不享受不回溯
    return tuple(a) >= tuple(b)


def close_epic_remaining(root, pid):
    """收尾报告「关联 epic 剩余 item」节对账（owner 2026-10-01 需求）。

    声明：`harness-close` 步骤 4 要求汇总报告含「关联 epic 剩余 item」节（`harness-epic-progress.sh
    <task-slug>` 的四态输出原样内嵌）。缺该节 = epic 多 item 各自 TSD 场景下，「本 TSD close 后关联 epic
    还有哪些 item 未完成」没有流程内消费者（ADR-0012 决策 4「产出即被消费」没落地）—— harness-run 链路按
    单 TSD 推进，close 不汇报剩余 item，跨轮就丢了。
    判**红**：与 `observation` 同 —— 这是 close 报告的形状契约（该做的事有没有做），不是判断类产物的格式。
    **不回溯**：`date` 早于规则生效日的历史 close 报告跳过（不重写历史；新规则不追溯旧产物）。
    """
    lines = []
    failed = False
    rdir = os.path.join(root, ".harness", "reports")
    if not os.path.isdir(rdir):
        return (False, lines)                 # 无 reports 目录 = 还没收尾过，不算失败
    pat = re.compile(r"^%s-.*-close\.md$" % re.escape(pid))
    for fn in sorted(os.listdir(rdir)):
        if not pat.match(fn):
            continue
        try:
            text = open(os.path.join(rdir, fn), encoding="utf-8").read()
        except OSError:
            continue
        d = (rr.fm(text, "date") or "").strip()
        if d and not _date_ge(d, _EPIC_REMAINING_SINCE):
            continue                          # 规则生效前的历史报告，不回溯（不重写历史）
        if "## 关联 epic 剩余 item" not in text:
            lines.append("[audit] close 报告缺「关联 epic 剩余 item」节: %s（owner 2026-10-01 需求：跑 "
                         "ci/bin/harness-epic-progress.sh <task-slug> 内嵌其输出）" % fn)
            failed = True
    return (failed, lines)


def _emit_once(seen, key, line):
    """同一 (id, 域, 违规种类) 只输出一行 —— 同 id **同域**跨层（shared/local/装载）时同一问题只计
    一次，避免按行分类的对账把一条违规重复计成多条；**不同域**的同名 id 是不同项，不合并（否则
    确定性红门会少报违规）。"""
    if key in seen:
        return
    seen.add(key)
    print(line)


def domain_attribution(root, shared_store):
    """R2 生命周期/取代一致性（确定性，**判红**）。

    只查**新增**的不变量：`lifecycle` 值合法、`superseded` 项不得残留、`superseded_by` 指向存在。
    **不重复** domain↔文件名一致 / category 枚举 —— 那两条已由 `checklists` 检查覆盖（消息是契约），
    此处再查会同一问题出两条红线（ADR-0012 决策 5 的按行分类会被重复计数）。
    扫描范围与 `checklists` 检查同源（含配置的 `shared_store`）；否则消费方项目里本检查会静默通过。
    """
    lines, exited = _capture(_domain_attribution_body, root, shared_store)
    return (exited, lines)


def _domain_attribution_body(root, shared_store):
    LIFE = {"active", "superseded", "retired"}
    loaded = [(layer, dom, load_items(p)) for layer, dom, p in checklist_layers(root, shared_store)]
    # 同域跨层 id 全集：superseded_by 常指向**另一层**（装载源/本地）的同名项，只在单文件 id 集里
    # 查会把「另一层有」误报成「本域不存在」。
    ids_by_domain = {}
    for _layer, dom, items in loaded:
        ids_by_domain.setdefault(dom, set()).update(it["id"] for it in items if it["id"])
    seen = set()
    bad = 0
    for layer, domain, items in loaded:
        for it in items:
            iid = it["id"] or "?"
            cid = "%s[%s/%s]" % (iid, layer, domain)
            lc = it["lifecycle"]
            if lc and lc not in LIFE:
                _emit_once(seen, (iid, domain, "lifecycle"),
                           f"[audit] {cid} lifecycle={lc!r} 非法（须 active/superseded/retired）")
                bad = 1
            if lc == "superseded":
                _emit_once(seen, (iid, domain, "lingering"),
                           f"[audit] {cid} lifecycle=superseded 仍留在 checklist —— D2 就地替换后旧项应消失，"
                           f"残留=修正只做了一半")
                bad = 1
            sb = it["superseded_by"]
            if sb and sb not in ids_by_domain.get(domain, set()):
                _emit_once(seen, (iid, domain, "dangling"),
                           f"[audit] {cid} superseded_by={sb} 指向的项在本域不存在")
                bad = 1
    if bad:
        sys.exit(1)
    # 无输出 = 通过：本检查只输出**失败行**（供 _ck_run fol=1 用）。**不要**打印成功行 ——
    # fol=1 会把每一行都当失败行，成功行会让对账假红。


def domain_backfill(root, shared_store):
    """R3 存量债可见（确定性，**只告警不判红**）。

    缺 `problem_domain`/`domain_knowledge` 的项列「待回填」。新项必填的**硬门**在
    `harness-keep-land.sh` 落盘时把守；此处只让历史债可见（owner 决策 D1：存量 grandfather）。
    """
    lines, exited = _capture(_domain_backfill_body, root, shared_store)
    return (False, lines)


def _domain_backfill_body(root, shared_store):
    # 按 (id, 域) 去重：同 id **同域**跨层各缺一次只算一项（不同域的同名 id 是不同项，不合并）。
    # 与 CLI 清单 `checklist.py backfill` 同口径 —— 两处计数不会漂移。
    miss = set()
    for _layer, _dom, p in checklist_layers(root, shared_store):
        for it in load_items(p):
            if needs_domain_backfill(it):
                miss.add((it["id"], _dom))
    # **只报条数、不列 id**：审计输出被多处按 id 子串 grep（如 tests/adr0012 的死守卫计数），
    # 逐条列 id 会污染那些 grep。要清单跑 `ci/bin/checklist.py backfill <root>`。
    if miss:
        print("[audit][warn] 存量 checklist 缺 problem_domain/domain_knowledge：%d 项"
              "（R3 待回填，只告警不判红；清单跑 ci/bin/checklist.py backfill）" % len(miss))


# ── ADR-0019 决策 1：TSD status 字段推进语义门禁（判红）────────────────────────
# 审计实证（2026-10-02，两仓 12 处不一致）：核心缺陷类 G1 —— git-work-ui TSD `status: frozen` 却有
# 12+ 轮 verified + review pass 的执行证据（status.log 25 行），门禁全绿放行。根因：audit 对
# `status` 字段本身**零引用**（frozen/building/verified/reviewed 在 audit_checks.py 里 grep 不到）。
# 本检查让「文档状态必须与执行证据一致」可判定。
#
# 单一真相源 = TSD frontmatter `status`（ADR-0004），唯一推进入口 = `harness-status.sh advance`
# （一处推进 TSD status + work 镜像 + `.harness/reports/{pid}-{slug}.status.log` 证据行，
# 行格式 `timestamp\tstage`，stage ∈ {building,verified,reviewed,closed}，reopen 单独写 `reopen`）。
# 校验面（owner 拍板，全部判红，无回溯豁免 —— 存量不合规立即红）：
#   ① status ∈ {frozen,building,verified,reviewed,closed}；缺失/其它值 → 红；
#   ② status vs status.log **终态行**一致（例外仅 `status: frozen` 且最后推进为 `reopen`）→ 红；
#   ③ status.log 推进序合法：frozen→building→verified→reviewed→closed，`reopen` 重置回 frozen；
#      乱序（如 verified 后直接 closed 缺 reviewed）→ 红；
#   ④ status ≥ verified 但无任何 `*-review.md` 报告引用该 slug → **warn 不判红**（评审证据缺失是
#      判断类问题，与 review_validity 同语义；判定「该不该重审」不塞进确定性检查）。
_STAGES = {"frozen", "building", "verified", "reviewed", "closed"}
_PROG_ORDER = ["frozen", "building", "verified", "reviewed", "closed"]


def _status_log_lines(root, pid, slug):
    """读 {pid}-{slug}.status.log → 行列表（不存在返回 []）。"""
    p = os.path.join(root, ".harness", "reports", "%s-%s.status.log" % (pid, slug))
    if not os.path.isfile(p):
        return []
    try:
        return [ln for ln in open(p, encoding="utf-8").read().splitlines() if ln.strip()]
    except OSError:
        return []


def tsd_status_progression(root, pid):
    """TSD status 推进语义门禁（ADR-0019 决策 1，判红）。"""
    lines = []
    failed = False
    tdir = os.path.join(root, ".harness", "tsd")
    if not os.path.isdir(tdir):
        return (False, lines)
    for fn in sorted(os.listdir(tdir)):
        if not fn.endswith(".md") or not fn.startswith(pid + "-"):
            continue
        slug = fn[len(pid) + 1:-3]
        try:
            text = open(os.path.join(tdir, fn), encoding="utf-8").read()
        except OSError:
            continue
        if rr.fm(text, "tsd_frozen") != "true":
            continue                                   # 只查冻结 TSD（未冻结 = plan 中，无推进义务）
        status = (rr.fm(text, "status") or "").strip()
        # ① 枚举合法
        if status not in _STAGES:
            lines.append("[audit] TSD status 非法: %s status=%r（须 ∈ %s）—— 文档状态与 ADR-0004 "
                         "状态机不一致" % (fn, status, sorted(_STAGES)))
            failed = True
            continue
        # ② status vs status.log 终态行
        log = _status_log_lines(root, pid, slug)
        if log:
            last = log[-1].split("\t", 1)[-1].strip()
            if last == "reopen":
                ok = (status == "frozen")
            else:
                ok = (last == status)
            if not ok:
                lines.append("[audit] TSD status 与执行证据不一致: %s status=%s 但 status.log 终态=%s"
                             "—— 文档状态说谎（推进证据在，状态没跟上 / 状态在，证据缺失）"
                             % (fn, status, last))
                failed = True
        elif status != "frozen":
            # 状态非 frozen 却无 status.log —— 声称推进了但没有证据（frozen = 刚冻结未推进，合法无 log）
            lines.append("[audit] TSD status 与执行证据不一致: %s status=%s 但无 status.log"
                         " —— 文档状态说谎（状态在，证据缺失）" % (fn, status))
            failed = True
        # ③ 推进序合法（reopen 重置回 frozen；重复推进同一阶段 = 幂等，合法）
        # 语义：严格单调递增 + 允许同阶段重复（harness-status.sh advance 是幂等 append，不查当前态，
        # 实际执行中同一阶段可因 fix 轮多次进入 —— 但打回应走 reopen 写 reopen 行；无 reopen 的重复
        # 推进是冗余留痕，不算非法）。非法 = 回退（比前一阶段早，且非 reopen 重置后的新序列）或跳序
        # （前进但跳过中间态，如 building 直接 closed）。
        seq = []
        for ln in log:
            seq.append(ln.split("\t", 1)[-1].strip())
        if len(seq) >= 2:
            prev = None
            expect = "building"      # 首个合法推进；reopen 重置后同样回到 building
            bad = None
            for s in seq:
                if s == "reopen":
                    prev = None
                    expect = "building"
                    continue
                if s not in _STAGES:
                    continue
                if prev is None:
                    if s != expect:
                        bad = "%s（首个推进 %s 非 %s，reopen 重置后必须回到 building）" % (fn, s, expect)
                        break
                    prev = s
                    expect = _PROG_ORDER[min(_PROG_ORDER.index(s) + 1, len(_PROG_ORDER) - 1)]
                    continue
                if s == prev:
                    continue         # 同阶段重复推进（幂等），合法
                if _PROG_ORDER.index(s) > _PROG_ORDER.index(prev):
                    if s == expect:
                        expect = _PROG_ORDER[min(_PROG_ORDER.index(s) + 1, len(_PROG_ORDER) - 1)]
                    else:
                        bad = "%s（跳序 %s→%s，缺中间态）" % (fn, prev, s)
                        break
                else:
                    bad = "%s（回退 %s→%s，推进必须单调前进或经 reopen 打回）" % (fn, prev, s)
                    break
                prev = s
            if bad:
                lines.append("[audit] TSD 推进序非法: %s —— status.log 记录不合法（%s），"
                             "推进必须走 harness-status.sh advance（frozen→building→verified→reviewed→closed，"
                             "reopen 重置回 frozen）" % (fn, bad))
                failed = True
        # ④ status ≥ verified 但无评审证据 → warn（不判红）
        if status in ("verified", "reviewed", "closed"):
            refs = rr.for_tsd(root, slug, pid)
            if not refs:
                lines.append("[audit][warn] TSD status=%s 但无任何评审报告引用（%s）—— 推进到了需评审的"
                             "阶段却没有评审证据，请确认（harness-review 的 ReviewRecord 才会被引用）"
                             % (status, fn))
    return (failed, lines)


def status_log_integrity(root, pid):
    """status.log 格式/命名门禁（ADR-0019 决策 2，判红）。

    审计实证：G2（types-creds 双 status.log：`{pid}-{pid}-{slug}` 双前缀 + `{pid}-{slug}` 两文件）、
    G3（至少 4 种写入机制污染：严格 stage / 自由文本 / 另一种时区 / 裸行）。唯一合法写者 =
    `harness-status.sh`（行格式 `printf '%s\t%s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "${STAGE:-$CMD}"`）。
    校验面（owner 拍板，全部判红，无回溯豁免）：
      ① 每行匹配 `^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}[+-]\\d{4}\\t(stage|reopen)$`
         （stage ∈ {building,verified,reviewed,closed}）；
      ② 文件名严格 `{pid}-{slug}.status.log`（拒绝 `{pid}-{pid}-{slug}` 双前缀等任何其它形状）；
      ③ `{pid}-{slug}` 必须对应已存在的 TSD（孤儿文件 = 无主证据 → 红）；
      ④ 同 slug 不得有多个 status.log（拆分 = 证据链断裂 → 红）。
    """
    lines = []
    failed = False
    rdir = os.path.join(root, ".harness", "reports")
    if not os.path.isdir(rdir):
        return (False, lines)
    # 先收集全部 status.log 文件名（任何形状），再逐个判
    logs = [fn for fn in sorted(os.listdir(rdir)) if fn.endswith(".status.log")]
    seen = {}
    pat = re.compile(r"^%s-([A-Za-z0-9._-]+)\.status\.log$" % re.escape(pid))
    for fn in logs:
        m = pat.match(fn)
        if not m:
            lines.append("[audit] status.log 命名非法: %s —— 文件名必须严格 {project.id}-{slug}.status.log"
                         "（唯一写者 harness-status.sh；双前缀/其它形状 = 手写或脚本污染）" % fn)
            failed = True
            continue
        slug = m.group(1)
        seen.setdefault(slug, []).append(fn)
        # ③ slug 必须有对应 TSD
        if not os.path.isfile(os.path.join(root, ".harness", "tsd", "%s-%s.md" % (pid, slug))):
            lines.append("[audit] status.log 无主: %s 的 slug=%s 无对应冻结 TSD —— 孤儿证据文件"
                         % (fn, slug))
            failed = True
        # ① 每行格式
        for i, ln in enumerate(_status_log_lines(root, pid, slug), 1):
            if not re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}[+-]\d{4}\t"
                            r"(frozen|building|verified|reviewed|closed|reopen)$", ln):
                lines.append("[audit] status.log 行格式非法: %s 第 %d 行 %r —— 须为 "
                             "`YYYY-MM-DDTHH:MM:SS±ZZZZ\\t(stage|reopen)`（harness-status.sh 唯一写者）"
                             % (fn, i, ln))
                failed = True
    # ④ 同 slug 唯一
    for slug, fns in sorted(seen.items()):
        if len(fns) > 1:
            lines.append("[audit] status.log 同 slug 多文件: %s 拆分出 %d 个（%s）—— 证据链断裂，"
                         "应合并为单一 {pid}-{slug}.status.log"
                         % (slug, len(fns), ", ".join(fns)))
            failed = True
    return (failed, lines)


def close_review_staleness(root, pid):
    """评审陈旧性 close 前强制门禁（ADR-0019 决策 3，判红）。

    审计实证：G4 —— 2 份评审针对旧版规格（git-work-ui-review 引用 tsd_content_sha=4b4d58fc，
    tsd_version 16，当前 cc547b32 落后 18 版），`review_validity` 只 warn 不判红，close 照常通过。

    校验面（owner 拍板，判红，无回溯豁免）：
      ① 冻结 TSD 有 re-plan 痕迹（`reconfirmed` 存在）且最新评审报告（`*-review.md` 引用该 TSD）
         的 `tsd_content_sha` ≠ TSD 当前 `content_sha` → 红（评审针对旧版规格，close 前必须重审）。
      ② 边界：reconfirmed 不存在 → 不适用（无 re-plan 痕迹，评审按当前版本出过即可）；
         有 reconfirmed 但**无任何**评审报告 → 由 `tsd-status-progression` ④ 的 warn 兜底，
         本检查不重复报（没有「最新评审」可比对，报「缺」会把未评审 TSD 全变红，那是判断类）。

    **为什么判红**：G4 落后 18 个版本仍可 close —— 「评审覆盖当前规格」是质量底线，
    re-plan 后不重审 = 拿旧规格背书新实现（ADR-0019 决策 3「为什么」）。
    """
    lines = []
    failed = False
    tdir = os.path.join(root, ".harness", "tsd")
    if not os.path.isdir(tdir):
        return (False, lines)
    for fn in sorted(os.listdir(tdir)):
        if not fn.endswith(".md") or not fn.startswith(pid + "-"):
            continue
        slug = fn[len(pid) + 1:-3]
        try:
            text = open(os.path.join(tdir, fn), encoding="utf-8").read()
        except OSError:
            continue
        if rr.fm(text, "tsd_frozen") != "true":
            continue                                   # 只查冻结 TSD
        if rr.fm(text, "reconfirmed") is None:
            continue                                   # 无 re-plan 痕迹 → 不适用
        cur_sha = (rr.fm(text, "content_sha") or "").strip()
        if not cur_sha:
            continue                                   # 没记账 content_sha → 决策 5 的 sync-check 管，不重复
        refs = rr.for_tsd(root, slug, pid)
        if not refs:
            continue                                   # 无评审 → ④ warn 兜底，不重复
        # 最新评审 = round 最大（round 缺失按 0）；round 相同按文件名序取最后
        latest = max(refs, key=lambda r: (r["round"] or 0, r["file"]))
        if latest["cited_sha"] and latest["cited_sha"] != cur_sha:
            lines.append("[audit] 评审陈旧性: %s 有 re-plan 痕迹（reconfirmed）但最新评审 %s 引用 "
                         "tsd_content_sha=%s…，当前 content_sha=%s… —— 评审针对旧版规格，close 前必须重审"
                         "（ADR-0019 决策 3，走 harness-review 对当前版本出评审）"
                         % (fn, latest["file"], latest["cited_sha"][:8], cur_sha[:8]))
            failed = True
    return (failed, lines)


def close_report_format(root, pid):
    """judge 节点报告格式对账 close 判红（ADR-0019 决策 4，判红）。

    审计实证：G5（3 份 judge 节点报告不是 ReviewRecord，无消费方）、G6（3 份评审发现清单不可解析）。
    `review_validity` 的 ②③ 只 warn —— 判断类产物不判红。但 **close 是收口点**：close 汇总依赖
    这些报告做覆盖对账（决策 3 的「最新评审」比对、handoff 的 review_section），格式不合 = 汇总依据
    不完整 → **close 场景判红**（ADR-0019 决策 4「为什么」：断链必须在收口前暴露）。

    校验面（判红，无回溯豁免）：
      ① `.harness/reports/` 下带 `node:` 标记的 judge 节点报告，必须符合 ReviewRecord：
         文件名 `*-review.md` + frontmatter `target`（缺任一 = `iter_reports` 拒收 → 无消费方）→ 红；
      ② 发现清单必须可解析（`findings_of` 非 None）→ 红。

    **与 review_validity 的区别**：review_validity 对所有报告只 warn；本检查只挑 judge 节点报告
    （`node:` 存在者）判红 —— 非 judge 报告（verify/close/rounds 等）不适用。
    """
    lines = []
    failed = False
    rdir = os.path.join(root, ".harness", "reports")
    if not os.path.isdir(rdir):
        return (False, lines)
    for fn in sorted(os.listdir(rdir)):
        if not fn.endswith(".md"):
            continue
        try:
            text = open(os.path.join(rdir, fn), encoding="utf-8").read()
        except OSError:
            continue
        if rr.fm(text, "node") is None:
            continue                                   # 非 judge 节点报告（verify/close/rounds 等）
        # ① 命名对账：文件名必须 `*-review.md` 且有 `target`（ReviewRecord 形态）。
        # 只判 target 会漏「有 node+target 但文件名非 -review」（iter_reports 只 glob `*-review.md`）那一半。
        if not fn.endswith("-review.md") or rr.fm(text, "target") is None:
            lines.append("[audit] close 场景 judge 节点报告非 ReviewRecord: %s（文件名非 -review.md "
                         "或缺 target）—— 无消费方（review_record/handoff/audit 都收不到），close 汇总"
                         "依据不完整。应改名 `{project.id}-{target}-review.md` 并补 target/round/conclusion"
                         "（ADR-0019 决策 4）" % fn)
            failed = True
            continue
        # ② 发现清单可解析
        r = rr.read(os.path.join(rdir, fn))
        if r is not None and r["findings"] is None:
            lines.append("[audit] close 场景评审发现清单不可解析: %s（target=%s）—— close 汇总依赖它做"
                         "覆盖对账，格式不合 = 汇总依据不完整。确实没有发现时也应写该节并注明「无」"
                         "（ADR-0019 决策 4）" % (fn, r["target"]))
            failed = True
    return (failed, lines)


CHECKS = {
    "agents-md": ("agents_md", ("root",)),
    "observation": ("observation", ("root", "pid")),
    "close-epic-remaining": ("close_epic_remaining", ("root", "pid")),
    "review-validity": ("review_validity", ("root", "pid")),
    "review-landing": ("review_landing", ("root", "log", "node_map_raw", "pid")),
    "metric-sources": ("metric_sources", ("root", "log")),
    "checklists": ("checklists", ("root", "rules_file", "cat_model", "shared_store")),
    "gate-identity": ("gate_identity", ("id_file", "gate_sh", "gates_tsv")),
    "reachability": ("reachability", ("root", "named_raw", "store")),
    "freshness": ("freshness", ("ck_dir", "local_dir", "log", "days", "named_domains")),
    "selftest-wiring": ("selftest_wiring", ("root",)),
    "domain-attribution": ("domain_attribution", ("root", "shared_store")),
    "domain-backfill": ("domain_backfill", ("root", "shared_store")),
    "tsd-status-progression": ("tsd_status_progression", ("root", "pid")),
    "status-log-integrity": ("status_log_integrity", ("root", "pid")),
    "close-review-staleness": ("close_review_staleness", ("root", "pid")),
    "close-report-format": ("close_report_format", ("root", "pid")),
}


def run(name, argv):
    """按名字跑一条检查。返回 (failed, lines)。名字不认识 → 抛 KeyError（调用方报用法错）。"""
    fn_name, params = CHECKS[name]
    if len(argv) != len(params):
        raise ValueError("%s 需要 %d 个参数（%s），得 %d 个"
                         % (name, len(params), ", ".join(params), len(argv)))
    return globals()[fn_name](**dict(zip(params, argv)))


def main(argv):
    if len(argv) < 2 or argv[0] not in CHECKS:
        sys.stderr.write("用法: audit_checks.py <%s> <args...>\n" % "|".join(sorted(CHECKS)))
        return 2
    try:
        failed, lines = run(argv[0], argv[1:])
    except (ValueError, OSError) as e:
        sys.stderr.write("[audit-checks] %s 执行失败：%s\n" % (argv[0], e))
        return 2
    for ln in lines:
        print(ln)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
