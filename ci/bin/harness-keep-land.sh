#!/usr/bin/env bash
# harness-keep-land.sh — 把 owner 已批准（status: approved）的 keep 提案落盘。只落 approved，绝不落 proposed。
#
#   check_mode: judge        → 追加 checklist 项到 .harness/checklists/{domain}.md（project-local）
#   check_mode: deterministic→ 追加 checklist 项 + Semgrep 规则到 .harness/pitfalls.yaml（project-local）
#
# 落盘前做 id 冲突检查（checklist id 与 pitfall 规则 id 均不得与已存在冲突），冲突/格式坏则把提案转
# need-human 并告警。落盘成功标记 status: landed。退出码 0=全部落盘或无需落盘 / 1=有 approved 但无法落盘。
set -euo pipefail
export PYTHONUTF8=1  # PEP 540: Windows 强制 UTF-8（避免 GBK 读/写中文出错）

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$ROOT/.harness/work"

[ -d "$WORK" ] || { echo "[keep-land] 无 .harness/work/，没有提案可落"; exit 0; }

# 环境解析（解释器 / 编码）单源见 ci/bin/harness-env.sh；本机缓存 .harness/toolchain.env 由 harness-preflight.sh 生成。
# 同 harness-scaffold / harness-measure：主体在 python，占位桩下会静默无事发生（「没落盘」与「没有提案」长得一样）。
# shellcheck source=harness-env.sh
source "$(dirname "${BASH_SOURCE[0]}")/harness-env.sh"
py_ok || { echo "[keep-land] python3 不可用（命令存在但执行失败；Windows 上常见为 Store 占位桩）——拒绝静默无事发生" >&2; exit 2; }

"$HARNESS_PYTHON" - "$ROOT" <<'PY'
import sys, os, re, glob, tempfile

ROOT = sys.argv[1]
sys.path.insert(0, os.path.join(ROOT, "ci", "bin"))
from checklist import fm, load_items, parse_items, pitfall_ids  # noqa: E402  （解析深模块，需先注入路径）
WORK = os.path.join(ROOT, ".harness", "work")
CK_DIR = os.path.join(ROOT, ".harness", "checklists")
PITFALLS = os.path.join(ROOT, ".harness", "pitfalls.yaml")
_DEFAULT_CATS = {"security", "compliance", "data-integrity", "observability", "architecture", "process", "governance", "correctness"}
def _load_categories():
    """category 枚举双源：suite 共享枚举 ci/constraint-model.md + 项目本地扩展 .harness/categories.yaml。
    项目跑出的新 category 加项目本地文件；跨项目有价值再晋升到 suite 枚举。缺文件则兜底内置列表。"""
    cats = set(_DEFAULT_CATS)
    for p in (os.path.join(ROOT, "ci", "constraint-model.md"),
              os.path.join(ROOT, ".harness", "categories.yaml")):
        if os.path.exists(p):
            m = re.search(r"^categories:[ \t]*(.+)$", open(p, encoding="utf-8").read(), re.M)
            if m:
                cats |= set(m.group(1).split())
    return cats
CATEGORIES = _load_categories()

def write_atomic(path, data):
    """写临时文件 + os.replace 原子落盘，避免崩溃/中断截断原文件（提案状态翻转）。"""
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".keep-land-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(data)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise

def append_atomic(path, data):
    """读改写 + 原子替换，避免追加中途崩溃截断共享文件（checklist/pitfalls）。"""
    d = os.path.dirname(path) or "."
    cur = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".keep-land-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(cur + data)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise

def fenced(text, lang):
    m = re.search(r"```%s[ \t]*\n(.*?)\n```" % lang, text, re.S)
    return m.group(1).rstrip() if m else None

def existing_checklist_ids(domain):
    p = os.path.join(CK_DIR, "%s.md" % domain)
    return {it["id"] for it in load_items(p) if it["id"]}

def existing_pitfall_ids():
    return set(pitfall_ids(PITFALLS))

# 修正分支用：定位 checklist 文件里「id == target_id」的那一项，整块替换为新内容（就地替换，D2）。
# 段边界按「行首 ---」切：一项 = 起始 `---` 到下一个行首 `---` 之前。checklist 正文用 `## 规则` 等
# 小节，不出现行首 `---`，故按此切安全；该不变量由落盘时的 `_delims != 2` 守卫把守（#6）。fm() 认
# 裸块（段首 `---` 定界），可直接取 id。
_ITEM_RE = re.compile(r"(?ms)^---[ \t]*\n.*?\n---[ \t]*\n.*?(?=^---[ \t]*\n|\Z)")

def replace_item_text(path, target_id, new_block):
    """按 id 就地替换 checklist 文件里的某一项；找不到返回 None（调用方转 need-human）。"""
    text = open(path, encoding="utf-8").read()
    for m in _ITEM_RE.finditer(text):
        if fm(m.group(0), "id") == target_id:
            return text[:m.start()] + new_block + text[m.end():]
    return None

def find_item_block(path, target_id):
    """返回 checklist 文件里 id==target_id 的项块文本；找不到 / 文件不存在返回 ""（空串，可安全喂 fm）。"""
    if not os.path.exists(path):
        return ""
    text = open(path, encoding="utf-8").read()
    for m in _ITEM_RE.finditer(text):
        if fm(m.group(0), "id") == target_id:
            return m.group(0)
    return ""

def _domain_files():
    """枚举 .harness/checklists 下的域文件 → [(域, 路径)]。"""
    if not os.path.isdir(CK_DIR):
        return []
    return [(f[:-3], os.path.join(CK_DIR, f)) for f in sorted(os.listdir(CK_DIR)) if f.endswith(".md")]

def _placeholder(v):
    """值缺失、或仍是模板占位（以 `<` 开头，如 `<问题域 slug>`）→ 视为未声明。"""
    return (not v) or v.lstrip().startswith("<")

def _structure_ok(text):
    """结构良构判据（用于存量文件**和**替换结果）。返回 (ok, reason)。

    1) 每个 `_ITEM_RE` 匹配块恰 2 个行首 `---` 且**有 id** —— 正文含 `---` 会截断匹配、留下「有内容却
       无 id」的碎片；
    2) `_ITEM_RE` 项数 == canonical `parse_items` 项数（碎片段被 `_is_fm_block` 跳过时两边计数仍可能相等，
       故仅靠计数相等不够）；
    3) 全文行首 `---` 总数 == 2×项数 —— 末项正文尾部以 `---` 结尾等「未被任何项匹配覆盖的 `---`」借此判出。
    """
    ms = list(_ITEM_RE.finditer(text))
    for m in ms:
        if len(re.findall(r"(?m)^---[ \t]*$", m.group(0))) != 2 or not fm(m.group(0), "id"):
            return (False, "某项正文含行首 `---` 致匹配区间被截断")
    if len(ms) != len(parse_items(text)):
        return (False, "_ITEM_RE=%d vs parse_items=%d" % (len(ms), len(parse_items(text))))
    if len(re.findall(r"(?m)^---[ \t]*$", text)) != 2 * len(ms):
        return (False, "存在未被项匹配覆盖的行首 `---`（正文含分隔线）")
    return (True, "")


def validate_existing_for_replace(path, target_id):
    """替换前校验存量文件可否**安全**就地替换。返回 (ok, reason)：结构良构（见 `_structure_ok`）+ 目标 id 唯一。"""
    if not os.path.exists(path):
        return (False, "存量文件不存在")
    text = open(path, encoding="utf-8").read()
    ok, why = _structure_ok(text)
    if not ok:
        return (False, "存量文件结构异常（%s）" % why)
    ids = [it["id"] for it in load_items(path) if it["id"]]
    if ids.count(target_id) != 1:
        return (False, "目标 id %s 在存量文件中出现 %d 次（须恰 1 次）" % (target_id, ids.count(target_id)))
    return (True, "")

landed = 0
need_human = 0
for prop in sorted(glob.glob(os.path.join(WORK, "proposal-*.md"))):
    text = open(prop, encoding="utf-8").read()
    if not re.search(r"^status:[ \t]*approved", text, re.M):
        continue

    slug = fm(text, "id") or os.path.basename(prop).replace("proposal-", "").replace(".md", "")
    check_mode = fm(text, "check_mode")
    domain = fm(text, "domain")
    severity = fm(text, "severity")

    ck_block = fenced(text, "markdown")
    if check_mode not in ("judge", "deterministic") or not domain or not ck_block:
        print("[keep-land] %s 提案缺 check_mode/domain/checklist 块，转 need-human" % slug)
        text = re.sub(r"^status:[ \t]*.*", "status: need-human", text, count=1, flags=re.M)
        write_atomic(prop, text)
        need_human += 1
        continue

    # 段边界不变量（#6）：一项正文不得含行首 `---`（checklist 分段符）—— 否则 replace_item_text /
    # parse_items 会在正文的 `---` 处截断，静默损坏。合法块恰好 2 个定界行（fm 认裸块）。写入时把守，
    # 比事后在 audit 里发现便宜。
    _delims = len(re.findall(r"(?m)^---[ \t]*$", ck_block))
    if _delims != 2:
        print("[keep-land] %s checklist 块含 %d 个行首 `---`（须恰 2 个定界行；正文出现 `---` 会截断解析），转 need-human"
              % (slug, _delims))
        text = re.sub(r"^status:[ \t]*.*", "status: need-human", text, count=1, flags=re.M)
        write_atomic(prop, text)
        need_human += 1
        continue

    # domain 直接拼进 .harness/checklists/{domain}.md 路径，必须限制为安全文件名字符，防路径穿越。
    if not re.fullmatch(r"[A-Za-z0-9._-]+", domain):
        print("[keep-land] %s domain %r 含非法字符（仅 [A-Za-z0-9._-]），转 need-human" % (slug, domain))
        text = re.sub(r"^status:[ \t]*.*", "status: need-human", text, count=1, flags=re.M)
        write_atomic(prop, text)
        need_human += 1
        continue

    ck_id = fm(ck_block, "id")
    if not ck_id:
        print("[keep-land] %s checklist 块缺 id，转 need-human" % slug)
        text = re.sub(r"^status:[ \t]*.*", "status: need-human", text, count=1, flags=re.M)
        write_atomic(prop, text)
        need_human += 1
        continue

    category = fm(ck_block, "category")
    if not category or category not in CATEGORIES:
        print("[keep-land] %s category %r 不在枚举（ci/constraint-model.md 或 .harness/categories.yaml），转 need-human" % (slug, category))
        text = re.sub(r"^status:[ \t]*.*", "status: need-human", text, count=1, flags=re.M)
        write_atomic(prop, text)
        need_human += 1
        continue

    # reuse 枚举校验。该字段**由 owner 在批准时手加**（keep-scan 的 prompt 不产出它，这是有意的：
    # 打标是 owner 的判断，不从 keep 流程推断通用性）。但手加就有拼错的可能，而
    # harness-checklist-candidates.sh 用 `it["reuse"] == "candidate"` **精确匹配** ——
    # 写成 Candidate / yes / true 会让候选**静默消失**，且「晋升没发生」看起来和「本来就没有候选」一样。
    # 故在落盘这最后一关把它挡住。
    reuse = fm(ck_block, "reuse")
    if reuse and reuse != "candidate":
        print("[keep-land] %s reuse=%r 非法（只允许 `candidate`；不打算晋升就删掉该行），转 need-human" % (slug, reuse))
        text = re.sub(r"^status:[ \t]*.*", "status: need-human", text, count=1, flags=re.M)
        write_atomic(prop, text)
        need_human += 1
        continue

    # R3 边界纪律：每条项必须声明问题域（problem_domain）+ 相关领域知识（domain_knowledge），缺一即挡回。
    # harness 最忌上下文污染 —— 不写清「这条规则管什么、判定它要懂什么」，未来消费它的人无从判断适用边界。
    if _placeholder(fm(ck_block, "problem_domain")) or _placeholder(fm(ck_block, "domain_knowledge")):
        print("[keep-land] %s 缺 problem_domain/domain_knowledge（R3：必须声明问题域+领域知识），转 need-human" % slug)
        text = re.sub(r"^status:[ \t]*.*", "status: need-human", text, count=1, flags=re.M)
        write_atomic(prop, text)
        need_human += 1
        continue

    supersedes = fm(text, "supersedes")

    # 修正须同名同 id（#4）：supersedes 定位旧项，新块 id 必须与之一致 —— 否则是静默改名，
    # 或（修正路径不走下面的冲突检查）插入重复 id。此校验须在冲突检查之前。
    if supersedes and ck_id != supersedes:
        print("[keep-land] %s supersedes=%s 与 checklist 块 id=%s 不一致（修正须同名同 id），转 need-human" % (slug, supersedes, ck_id))
        text = re.sub(r"^status:[ \t]*.*", "status: need-human", text, count=1, flags=re.M)
        write_atomic(prop, text)
        need_human += 1
        continue

    # 冲突检查（修正路径除外：修正按 supersedes 的 id 就地替换，不新增 id）
    if not supersedes and ck_id in existing_checklist_ids(domain):
        print("[keep-land] %s checklist id %s 已存在，转 need-human" % (slug, ck_id))
        text = re.sub(r"^status:[ \t]*.*", "status: need-human", text, count=1, flags=re.M)
        write_atomic(prop, text)
        need_human += 1
        continue

    # 旧项规则 id（供 #5/#6 判定）：修正路径下就地替换只改 checklist、**不改** pitfalls.yaml；若新项
    # deterministic 且规则 id 与旧项不同，旧规则会成孤儿，故须先取旧 id 比对。
    _old_rule = (fm(find_item_block(os.path.join(CK_DIR, "%s.md" % domain), supersedes), "deterministic_rule") or "") if supersedes else ""
    semgrep_block = None
    rid = ""
    if check_mode == "deterministic":
        semgrep_block = fenced(text, "yaml")
        if not semgrep_block:
            print("[keep-land] %s deterministic 但缺 Semgrep 块，转 need-human" % slug)
            text = re.sub(r"^status:[ \t]*.*", "status: need-human", text, count=1, flags=re.M)
            write_atomic(prop, text)
            need_human += 1
            continue
        rid = fm(semgrep_block, "id") or (re.search(r"-\s*id:\s*(\S+)", semgrep_block) or [None, None])[1]
        if not rid:
            print("[keep-land] %s Semgrep 块缺 id，转 need-human" % slug)
            text = re.sub(r"^status:[ \t]*.*", "status: need-human", text, count=1, flags=re.M)
            write_atomic(prop, text)
            need_human += 1
            continue
        if not supersedes and rid in existing_pitfall_ids():
            print("[keep-land] %s pitfall 规则 id %s 已存在，转 need-human" % (slug, rid))
            text = re.sub(r"^status:[ \t]*.*", "status: need-human", text, count=1, flags=re.M)
            write_atomic(prop, text)
            need_human += 1
            continue
        # 修正路径下 pitfall 规则 id 已存在（#5/#6）：仅当新规则 id == 旧项规则 id（规则未变，无需改
        # pitfalls）才放行；若换成**另一个**已存在的规则 id，就地替换规则不在本工具能力内 → need-human。
        if supersedes and rid in existing_pitfall_ids() and rid != _old_rule:
            print("[keep-land] %s 修正 deterministic 项但 pitfall 规则 id %s 已存在且 ≠ 旧规则 %s（不支持就地替换规则），转 need-human" % (slug, rid, _old_rule or "无"))
            text = re.sub(r"^status:[ \t]*.*", "status: need-human", text, count=1, flags=re.M)
            write_atomic(prop, text)
            need_human += 1
            continue

    # 内外一致性（#7）：land 按**外层** fm(text,...) 路由；内层块同名行若与外层矛盾，会按外层落盘、
    # 内层声明被静默忽略（scan 已在最早挡一层，land 侧再兜一层，防绕过 scan 直接落盘的路径）。
    _inner_cm = fm(ck_block, "check_mode")
    _inner_dom = fm(ck_block, "domain")
    _inner_sev = fm(ck_block, "severity")
    _inconsist = ""
    if _inner_cm and _inner_cm != check_mode:
        _inconsist = "check_mode(%s≠%s)" % (_inner_cm, check_mode)
    elif _inner_dom and _inner_dom != domain:
        _inconsist = "domain(%s≠%s)" % (_inner_dom, domain)
    elif _inner_sev and _inner_sev != fm(text, "severity"):
        _inconsist = "severity(%s≠%s)" % (_inner_sev, fm(text, "severity"))
    if _inconsist:
        print("[keep-land] %s 外层与内层块路由字段不一致：%s，转 need-human" % (slug, _inconsist))
        text = re.sub(r"^status:[ \t]*.*", "status: need-human", text, count=1, flags=re.M)
        write_atomic(prop, text)
        need_human += 1
        continue

    # check_mode 与 deterministic_rule 一致性（#2/#5）：judge 项**不得**带 deterministic_rule（否则存了
    # 一个指向 pitfalls.yaml 里可能不存在、或与本域无关的旧规则 —— 两库不一致被静默接受）；deterministic
    # 项**必须**带 deterministic_rule 且 = Semgrep 块 id（否则落盘项指向的规则 ≠ 实际追加的规则）。
    ck_rule = fm(ck_block, "deterministic_rule")
    if check_mode == "judge" and ck_rule:
        print("[keep-land] %s judge 项不得带 deterministic_rule（两库不一致），转 need-human" % slug)
        text = re.sub(r"^status:[ \t]*.*", "status: need-human", text, count=1, flags=re.M)
        write_atomic(prop, text)
        need_human += 1
        continue
    if check_mode == "deterministic" and (not ck_rule or ck_rule != rid):
        print("[keep-land] %s deterministic 项须带 deterministic_rule 且 = Semgrep 规则 id=%s（实为 %r），转 need-human" % (slug, rid, ck_rule))
        text = re.sub(r"^status:[ \t]*.*", "status: need-human", text, count=1, flags=re.M)
        write_atomic(prop, text)
        need_human += 1
        continue

    # 反链（优化 #4）：checklist 项 frontmatter 写 source_lesson，形成 checklist↔lesson 反链（毕业报告据此回链）。
    source = fm(text, "source") or os.path.join(".codestable", "lessons", slug + ".md")
    ck_block = re.sub(r"^---[ \t]*$", lambda _m: "---\nsource_lesson: " + source, ck_block, count=1, flags=re.M)

    os.makedirs(CK_DIR, exist_ok=True)
    ck_path = os.path.join(CK_DIR, "%s.md" % domain)

    if supersedes:
        # 修正分支（D2 就地替换）：按 supersedes 的 id 定位既有项、整块改写为新内容；旧版靠 git 历史。
        # 不 append、不新增 id —— 这是「过时沉淀修正」的落地点。
        #
        # 存量文件校验（#3）：`_ITEM_RE` 按行首 `---` 切段。若既有项**正文**含行首 `---`（水平线 /
        # YAML 文档分隔符），匹配区间会在正文处截断，替换后留下孤立片段、破坏文件；重复 id 会改错项。
        # 替换前先校验「结构良构 + 目标唯一」，不通过即 need-human（不猜、不假改）。
        _ok, _why = validate_existing_for_replace(ck_path, supersedes)
        if not _ok:
            print("[keep-land] %s 修正目标不可安全替换：%s，转 need-human" % (slug, _why))
            text = re.sub(r"^status:[ \t]*.*", "status: need-human", text, count=1, flags=re.M)
            write_atomic(prop, text)
            need_human += 1
            continue
        # 同域约束（#3）：修正须落在同一域文件。若目标 id 出现在**其它**域文件（跨域搬移/改名），就地替换
        # 会改错项（supersedes 路径刻意跳过 id 冲突检查、existing_checklist_ids 也不查他域）→ need-human。
        _cross = next((_d for _d, _p in _domain_files() if _d != domain and supersedes in existing_checklist_ids(_d)), None)
        if _cross:
            print("[keep-land] %s supersedes=%s 出现在其它域 %s（跨域修正不支持），转 need-human" % (slug, supersedes, _cross))
            text = re.sub(r"^status:[ \t]*.*", "status: need-human", text, count=1, flags=re.M)
            write_atomic(prop, text)
            need_human += 1
            continue
        # 孤儿规则守卫（#1/#6）：旧项是 deterministic 时，修正后若转 judge（check_mode 变化）或换新规则 id，
        # 旧 Semgrep 规则会一直留在 pitfalls.yaml 被 g_pitfall 持续扫描（过时规则继续假阳性），两库不一致
        # 被静默接受 —— 正是本改动声称要防的方向。本工具无「就地删除/替换规则」能力 → need-human（fail-closed）。
        if _old_rule and (check_mode != "deterministic" or rid != _old_rule):
            print("[keep-land] %s 修正 deterministic 项会把旧规则 %s 留成孤儿（pitfalls.yaml 无就地删除能力），转 need-human" % (slug, _old_rule))
            text = re.sub(r"^status:[ \t]*.*", "status: need-human", text, count=1, flags=re.M)
            write_atomic(prop, text)
            need_human += 1
            continue
        replaced = replace_item_text(ck_path, supersedes, ck_block + "\n\n")
        if replaced is None:  # 校验已保证能找到；此为防御，避免 write_atomic(None) 崩
            print("[keep-land] %s supersedes=%s 未找到（校验与替换不一致），转 need-human" % (slug, supersedes))
            text = re.sub(r"^status:[ \t]*.*", "status: need-human", text, count=1, flags=re.M)
            write_atomic(prop, text)
            need_human += 1
            continue
        _rok, _rwhy = _structure_ok(replaced)  # 替换结果再验一次：防「匹配区间被正文 --- 截断」类静默破坏
        if not _rok:
            print("[keep-land] %s 就地替换后结构异常（%s），转 need-human（不写入）" % (slug, _rwhy))
            text = re.sub(r"^status:[ \t]*.*", "status: need-human", text, count=1, flags=re.M)
            write_atomic(prop, text)
            need_human += 1
            continue
        write_atomic(ck_path, replaced)
        print("[keep-land] 修正 checklist 项 %s（就地替换 supersedes=%s）→ .harness/checklists/%s.md" % (ck_id, supersedes, domain))
    else:
        # 落 checklist 项（append）
        header = ""
        if not os.path.exists(ck_path):
            header = "# 共享 checklist · %s（project-local）\n\n" % domain
        append_atomic(ck_path, header + ck_block + "\n\n")
        print("[keep-land] 落 checklist 项 %s → .harness/checklists/%s.md" % (ck_id, domain))

    # 落 pitfall 规则（deterministic）。修正路径下「规则 id 已存在」仅当 id==旧规则时放行（#6），此时
    # 规则未变 → 跳过 append（否则会重复追加同 id 规则）；其余修正路径已转 need-human（#5/孤儿守卫）。
    if semgrep_block and not (supersedes and rid == _old_rule):
        indented = "\n".join(("  " + ln if ln.strip() else ln) for ln in semgrep_block.splitlines())
        data = indented + "\n"
        if not os.path.exists(PITFALLS):
            data = ("# harness 坑库（project-local）— 项目私有的结构化反模式规则（Semgrep）。\n"
                    "# 与 suite 共享规则 ci/rules/pitfalls.yaml 分层；g_pitfall 两个都读。\n"
                    "rules:\n" + indented + "\n")
        append_atomic(PITFALLS, data)
        print("[keep-land] 落 pitfall 规则 %s → .harness/pitfalls.yaml" % rid)

    text = re.sub(r"^status:[ \t]*.*", "status: landed", text, count=1, flags=re.M)
    write_atomic(prop, text)
    landed += 1

print("[keep-land] 落盘 %d 条，转 need-human %d 条" % (landed, need_human))
sys.exit(1 if need_human else 0)
PY
