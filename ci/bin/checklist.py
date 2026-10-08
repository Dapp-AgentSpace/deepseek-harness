#!/usr/bin/env python3
# checklist.py — checklist/pitfall 文件解析深模块（单一归属）。
#
# 此前 checklist 项 markdown 格式（\n---\n 分段、奇数段 frontmatter）被 harness-checklist-candidates.sh、
# harness-checklist-ls.sh、harness-runtime-gap.sh、harness-keep-land.sh、closed-loop-audit.sh 各自复制
# fm() + split 解析；pitfall 规则 id/reuse 提取也散在 keep-land / candidates。此处收敛成唯一实现，
# 消费方不再重写格式知识，只做自己的过滤/落盘（locality + leverage）。
#
# 两种用法：
#   - import：`sys.path.insert(0, <ci/bin>); from checklist import load_items, pitfall_rules, fm, parse_items`
#   - CLI：`python3 checklist.py items <path> [--json] | ids <path> | pitfalls <path> | pitfall-ids <path>`
import sys
import os
import re
import json

FIELDS = ["id", "check_mode", "category", "severity", "domain", "status", "deterministic_rule", "reuse", "applies_to", "runtime", "project", "problem_domain", "domain_knowledge", "lifecycle", "supersedes", "superseded_by"]


# frontmatter 块：头两条 `---` 之间。**单一归属** —— 全仓读 frontmatter 标量的地方都调 `fm`，
# 不再各自写正则。此前有 4 份实现、两种语义（本模块 `fm` 全文匹配 / `review_record.fm` 与
# `metrics._fm` 块内匹配 / `harness-identity.sh` 的 `h_fld` 又是第三种），实测同一份文本
# 一个返回 `'other-slug'`、一个返回 `None` —— 同一个词两种含义。
#
# 容错 **frontmatter 前置的 HTML 注释行**（如 `<!-- markdownlint-disable -->`）：markdownlint 的
# 「局部豁免」习惯写在文件最前，此时 `---` 不在首行。此前死锚 `^---` → 这类文件整块读不到：
# `fm` 退化成全文匹配、`work_unit._parse_fm` 直接返回 `{}`，与 bash 侧 `h_fld`（首行非 `---`
# 即全文匹配，**能读**）及 `harness-tsd-sync-check.sh` 对同一文件的判定**自相矛盾**（实测
# git-work 仓 3 份 TSD 被 tsd_board 报 error，却被 sync-check 报 ok）。
# 容错后块仍由两条 `---` **精确界定**，不退回全文匹配 —— 避免正文里一行 `key: value` 冒充
# frontmatter（RunCard 的 `premise` 正是往正文追加任意文本的地方）。
_FM_BLOCK = re.compile(r"^(?:<!--[^\n]*?-->[ \t]*\n)*---[ \t]*\n(.*?)\n---[ \t]*", re.S)


def fm(text, key):
    """提取 frontmatter 单行标量。**两种输入都要伺候**：

    - **有定界的整文件**（首两行 `---` 包住）—— TSD / work / RunCard / 评审报告：**只看块内**；
    - **裸块**（不含 `---`）—— `parse_items` 切出来的段就是这种：整段即 frontmatter，全文找。

    判据按「有没有定界」分派，不是一律块内 —— 一律块内会把裸块读空（`parse_items` 的调用方
    全部字段变空，实测 audit 报「缺合法 category」× N）。也不是一律全文 —— 那会让**正文里一行
    `key: value` 冒充 frontmatter**（RunCard 正文正是 `premise` 追加任意文本的地方）。
    `harness-identity.sh` 的 `h_fld` 是同一套分派（那边还要伺候 identity.yaml 这种纯 YAML）。
    """
    m = _FM_BLOCK.match(text)
    scope = m.group(1) if m else text
    mm = re.search(r"^%s:[ \t]*([^\n]+)" % re.escape(key), scope, re.M)
    return mm.group(1).strip().strip('"\'') if mm else None


# frontmatter 行：`key: value`，key 为 ASCII 标识符。**按结构判定，不看字段名**。
_FM_LINE = re.compile(r"^[A-Za-z_][A-Za-z0-9_-]*:[ \t]*")

# 「可复现锚」的启发式（§2b 条件二）：外部规范 / 测试 / 规则 id / ADR 指针 —— 别人顺着能找到、能验证。
# 单一归属：harness-checklist-promote.sh（晋升时拒绝）与 closed-loop-audit.sh（shared 反向复查）共用，
# 不各写一份正则。
ANCHOR_RE = re.compile(
    r"(WCAG|RFC[ \t]*\d|ADR-\d|tests?/|规则[ \t]*id|pitfalls\.yaml|规范|标准|ISO[ \t]*\d"
    r"|skills/harness-|harness\.schema-check|harness-log-\d|harness-hog-\d)", re.I)


def looks_like_anchor(evidence):
    """证据文本是否看得出可复现锚。

    **启发式**：只判「像不像」，判不了「是不是」—— 故调用方按 warning 用，
    不据此单独拒绝（拒绝权在人）。事故叙述（「某项目曾因此出过问题」）没有锚，返回 False。
    """
    return bool(ANCHOR_RE.search(evidence or ""))





def _is_fm_block(seg):
    """这一段是不是 frontmatter：整段（除空行与残留的 `---`）**每一行都是 `key: value`**。

    为什么不数奇偶：文件开头少一个 header 段落会让奇偶整体位移，**所有项**解析成空字段而无人察觉。
    为什么不按字段名白名单：那会把「首行是未列名字段」的项**整段丢掉** —— 比解析出空字段更糟，
    因为空字段会被 closed-loop-audit 当场点名，被丢掉的项则对所有检查隐形（`load_items` 的
    5 个消费方全部看不见，`harness-keep-land` 的 id 冲突检测也漏，可致落盘重复 id）。
    结构判定与字段名解耦：新增字段、keep-land 前置注入新字段，都不会再让项消失。
    checklist 正文用全角冒号（`规则：`/`适用：`/`证据：`），天然不匹配 ASCII key，不会被误判。
    """
    lines = [ln.strip() for ln in seg.splitlines()]
    lines = [ln for ln in lines if ln and ln != "---"]
    return bool(lines) and all(_FM_LINE.match(ln) for ln in lines)


def orphan_fm_blocks(text):
    """返回「看着是 frontmatter（段内含 `^id:`）却没被 parse_items 采纳」的段 —— 静默丢失的探测口。

    `parse_items` 按结构判定（整段皆 `key: value`），认不出的段**直接跳过**。被跳过的项对
    **所有**消费方隐形：审计不点名、loader 不注入、keep-land 的 id 冲突检测也漏 —— 比解析出
    空字段更糟（空字段会被 closed-loop-audit 当场点名）。已知触发：frontmatter 含 YAML 列表值
    （`applies_to:\n  - has:npm`）时整项消失。
    不靠放宽判定（那会把正文里的 markdown 列表误判成 frontmatter），而是让被丢的段**可见**。

    带**代码围栏**的段不算：那是正文（例如正文里嵌一段 YAML 示例，其中一行以 `id:` 开头），
    不是被漏解析的 frontmatter —— 不排掉就会对合法正文误报（ocr round-4 #8）。
    """
    return [s for s in text.split("\n---\n")
            if not _is_fm_block(s) and re.search(r"^id:", s, re.M) and "```" not in s]


def parse_items(text):
    """把 checklist 文件正文切成 [(frontmatter, body), ...]。

    分段符 `\\n---\\n`；**按段落内容判定 frontmatter**（见 `_is_fm_block`），不靠奇偶下标——
    后者对「文件开头缺 header」这类畸形静默产出空字段。判定失败时跳过该段，而不是把它当 frontmatter。
    """
    segs = text.split("\n---\n")
    out = []
    i = 0
    while i < len(segs):
        if _is_fm_block(segs[i]):
            body = segs[i + 1].strip() if i + 1 < len(segs) else ""
            out.append((segs[i], body))
            i += 2
        else:
            i += 1
    return out


def load_items(path):
    """读 checklist 文件 → [dict]（含全部 FIELDS + body）。文件不存在返回 []。"""
    if not path or not os.path.exists(path):
        return []
    items = []
    # 显式 utf-8：不依赖调用方 export PYTHONUTF8=1。此前裸 open() 在 GBK 默认 locale 的 Windows 上
    # 读本套件自己的中文 checklist 直接 UnicodeDecodeError（同 depcheck.py/compatcheck.py 的写法）。
    for fmblock, body in parse_items(open(path, encoding="utf-8").read()):
        d = {k: (fm(fmblock, k) or "") for k in FIELDS}
        d["body"] = body
        items.append(d)
    return items


def needs_domain_backfill(item):
    """R3 存量待回填判据（**单一归属**：closed-loop-audit 的 domain-backfill 与 `backfill` 子命令共用）。

    缺 `problem_domain` 或 `domain_knowledge` 任一即待回填；无 id 的段不算（不是合法项）。
    谓词只有这一处 —— 审计计数与 CLI 清单不会漂移。
    """
    return bool(item.get("id")) and (not item.get("problem_domain") or not item.get("domain_knowledge"))


def checklist_layers(root, shared_store=None):
    """镜像 loader（harness-checklist-ls.sh）的逐域解析顺序，产出 `(layer, domain, path)` 三元组。

    顺序与去重同 loader：
      1. 本仓 `checklists/shared`（layer=shared）
      2. 项目本地 `.harness/checklists`（layer=local）
      3. 配置的 `shared_store`（layer=shared(装载)）——**只补本仓 shared 未覆盖的域**（逐域解析；
         否则把「本仓源 + 装载副本」的同一份当成两处，同 id 冲突全误报）。
    层标与 `closed-loop-audit` 的 checklists 检查一致。**单一归属**：checklists 检查的第三处兜底、
    domain-attribution / domain-backfill、`backfill` 子命令共用 —— 扫描范围/项选择的修改只此一处。
    """
    shared_dir = os.path.join(root, "checklists", "shared")
    local_dir = os.path.join(root, ".harness", "checklists")
    out = []
    covered = set()
    if os.path.isdir(shared_dir):
        covered = {f[:-3] for f in os.listdir(shared_dir) if f.endswith(".md")}
    for d, layer in ((shared_dir, "shared"), (local_dir, "local")):
        if os.path.isdir(d):
            for fn in sorted(os.listdir(d)):
                if fn.endswith(".md"):
                    out.append((layer, fn[:-3], os.path.join(d, fn)))
    if shared_store and os.path.isdir(shared_store) \
            and os.path.realpath(shared_store) not in (os.path.realpath(shared_dir), os.path.realpath(local_dir)):
        for fn in sorted(os.listdir(shared_store)):
            if fn.endswith(".md") and fn[:-3] not in covered:
                out.append(("shared(装载)", fn[:-3], os.path.join(shared_store, fn)))
    return out


def pitfall_rules(path):
    """读 pitfalls.yaml → [(rule_id, reuse)]。reuse=candidate 表示该规则标了跨项目复用候选。"""
    if not path or not os.path.exists(path):
        return []
    text = open(path, encoding="utf-8").read()
    out = []
    for b in re.split(r"^[ \t]*-[ \t]*id:[ \t]*", text, flags=re.M)[1:]:
        rid = b.split("\n", 1)[0].strip()
        reuse = "candidate" if re.search(r"reuse:[ \t]*candidate", b) else ""
        out.append((rid, reuse))
    return out


def pitfall_ids(path):
    return [rid for rid, _ in pitfall_rules(path)]


def main(argv):
    if not argv:
        print(__doc__, file=sys.stderr)
        return 2
    cmd = argv[0]
    path = argv[1] if len(argv) > 1 else ""
    if cmd in ("items", "ids", "pitfalls", "pitfall-ids"):
        if not path:
            print("checklist.py %s: 缺少 <path>" % cmd, file=sys.stderr)
            return 2
        if not os.path.isfile(path):
            print("checklist.py %s: 文件不存在 %r（不静默出空结果）" % (cmd, path), file=sys.stderr)
            return 2
    if cmd == "items":
        items = load_items(path)
        if "--json" in argv[2:]:
            print(json.dumps(items, ensure_ascii=False))
        else:
            for it in items:
                print("\t".join(it[k] or "-" for k in FIELDS))
        return 0
    if cmd == "ids":
        for it in load_items(path):
            if it["id"]:
                print(it["id"])
        return 0
    if cmd == "pitfalls":
        for rid, reuse in pitfall_rules(path):
            print("%s\t%s" % (rid, reuse or "-"))
        return 0
    if cmd == "pitfall-ids":
        for rid in pitfall_ids(path):
            print(rid)
        return 0
    if cmd == "backfill":
        # 列出缺 problem_domain/domain_knowledge 的项（R3 存量待回填）。closed-loop-audit 的
        # domain-backfill 只报条数（逐条列 id 会污染审计输出里按 id 的 grep），要清单跑这里。
        # 第二参可选 <shared_store>：与审计同一扫描范围（缺省不扫装载源，仅供本仓自检）。
        if not path or not os.path.isdir(path):
            print("checklist.py backfill: 需要存在的 <root> 目录", file=sys.stderr)
            return 2
        shared_store = argv[2] if len(argv) > 2 else None
        keys = set()   # 计数键 (id, 域)：与审计同口径（同 id 同域跨层只算一项）
        locs = set()   # 展示位置 id[layer/域]（同一项多处物理位置都列出，供 owner 定位）
        for layer, dom, p in checklist_layers(path, shared_store):
            for it in load_items(p):
                if needs_domain_backfill(it):
                    keys.add((it["id"], dom))
                    locs.add("%s[%s/%s]" % (it["id"], layer, dom))
        if not keys:
            print("[domain-backfill] 无待回填项")
        else:
            print("[domain-backfill] %d 项待回填（缺 problem_domain/domain_knowledge）:" % len(keys))
            for x in sorted(locs):
                print("  " + x)
        return 0
    print("未知子命令: %s" % cmd, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
