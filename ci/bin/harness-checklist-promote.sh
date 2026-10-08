#!/usr/bin/env bash
# harness-checklist-promote.sh — 晋升执行器：把 project-local 的 `reuse: candidate` 项按
# ci/constraint-model.md §2b 的三条硬条件**校验并改写**后落入 suite 源的 checklists/shared/。
#
# 为什么要有这个脚本：此前晋升是「owner 手动把文本复制过去」（`harness-checklist-candidates.sh`
# 自己写明「只读：不晋升」），于是源项目的 `project` 字段、证据正文、规则措辞**原样带过去**——
# 没有任何一步会问「换一个团队，这东西还成立吗」。结果是 shared 里沉淀了一堆带项目名、
# 没人能复核的事迹。本脚本把「改写 + 校验」机械化，把「何时晋升」留给人。
#
# **默认 dry-run**：只打印校验结果与改写后的成品，不落盘。`--apply` 才写。
# 写的是 `{checklist.shared_store}/{domain}.md`（即 suite 源），跨仓写入，故默认不写。
#
# 用法:
#   harness-checklist-promote.sh <id> [--applies-to "<tags>"] [--maintainer <name>]
#                                [--allow-universal] [--apply]
#
# 退出码: 0=校验通过（dry-run 或已写入）/ 1=§2b 条件不满足（拒绝晋升）/ 2=用法或环境错误
set -euo pipefail
export PYTHONUTF8=1  # PEP 540: Windows 强制 UTF-8（避免 GBK 读/写中文出错）

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=harness-identity.sh
source "$ROOT/ci/bin/harness-identity.sh"

PID="$(h_id)"; [ -n "$PID" ] || { echo "[promote] 缺 project.id，先跑 harness-init" >&2; exit 2; }
SHARED_STORE="$(h_get shared_store)"; SHARED_STORE="${SHARED_STORE/#\~/$HOME}"
[ -n "$SHARED_STORE" ] || { echo "[promote] 未配置 checklist.shared_store（suite 源路径）" >&2; exit 2; }

TARGET_ID=""
APPLIES_TO=""
MAINTAINER="harness"
ALLOW_UNIVERSAL=0
APPLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    # 只查「还有下一个参数」不够：`--applies-to --apply` 会把选项当成值收下（ocr round-4 #10）。
    # 真值不得以 `-` 开头。
    --applies-to) [ $# -ge 2 ] && [ "${2#-}" = "${2}" ] || { echo "[promote] --applies-to 缺值（下一个参数是选项或不存在）" >&2; exit 2; }; APPLIES_TO="$2"; shift;;
    --maintainer) [ $# -ge 2 ] && [ "${2#-}" = "${2}" ] || { echo "[promote] --maintainer 缺值（下一个参数是选项或不存在）" >&2; exit 2; }; MAINTAINER="$2"; shift;;
    --allow-universal) ALLOW_UNIVERSAL=1;;
    --apply) APPLY=1;;
    -h|--help) sed -n '2,20p' "$0"; exit 0;;
    -*) echo "[promote] 未知参数：$1" >&2; exit 2;;
    *)  [ -z "$TARGET_ID" ] || { echo "[promote] 只能指定一个 id" >&2; exit 2; }
        TARGET_ID="$1";;
  esac
  shift
done
[ -n "$TARGET_ID" ] || { echo "[promote] 用法: harness-checklist-promote.sh <id> [--applies-to ...] [--apply]" >&2; exit 2; }

# 环境解析（解释器 / 编码）单源见 ci/bin/harness-env.sh；本机缓存 .harness/toolchain.env 由 harness-preflight.sh 生成。
# 本脚本**全部**校验与改写都在 python：占位桩下会静默什么都不做，「晋升没发生」与「晋升成功」长得一样。
# shellcheck source=harness-env.sh
source "$(dirname "${BASH_SOURCE[0]}")/harness-env.sh"
py_ok || {
  echo "[promote] python3 不可用（命令存在但执行失败；Windows 上常见为 Store 占位桩）——拒绝静默无事发生" >&2
  echo "  修好解释器后重跑，或用 HARNESS_PYTHON 指定；例如 export PATH=\"/c/Users/<你>/AppData/Local/Programs/Python/Python312:\$PATH\"" >&2
  exit 2
}

"$HARNESS_PYTHON" - "$ROOT/ci/bin" "$ROOT/.harness/checklists" "$SHARED_STORE" \
          "$TARGET_ID" "$APPLIES_TO" "$MAINTAINER" "$ALLOW_UNIVERSAL" "$APPLY" "$PID" <<'PY'
import sys, os, re, tempfile
sys.path.insert(0, sys.argv[1])
from checklist import parse_items, fm, looks_like_anchor
ck_dir, shared_store, target_id, applies_to, maintainer, allow_universal, apply_ = sys.argv[2:9]
allow_universal, apply_ = allow_universal == "1", apply_ == "1"

def die(msg, code=2):
    sys.stderr.write("[promote] %s\n" % msg); sys.exit(code)

# ── 1. 在 project-local 里定位该项 ────────────────────────────────────────────
if not os.path.isdir(ck_dir):
    die("本仓无 .harness/checklists/，无可晋升项")
found = None
for fn in sorted(os.listdir(ck_dir)):
    if not fn.endswith(".md"):
        continue
    for fmblock, body in parse_items(open(os.path.join(ck_dir, fn), encoding="utf-8").read()):
        if fm(fmblock, "id") == target_id:
            found = (fn[:-3], fmblock, body)     # (domain, fmblock, body)
            break
    if found:
        break
if not found:
    die("project-local 里找不到 id=%s" % target_id)
domain, fmblock, body = found

# ── 2. §2b 三条硬条件校验（机械能判的拒绝，判不了的警告后交人）────────────────
violations, warnings = [], []

if fm(fmblock, "reuse") != "candidate":
    violations.append("未打 `reuse: candidate` —— 不是候选，无从晋升（打标见 skill harness-keep）")

target_path = os.path.join(shared_store, "%s.md" % domain)
if os.path.isfile(target_path):
    for f2, _b in parse_items(open(target_path, encoding="utf-8").read()):
        if fm(f2, "id") == target_id:
            violations.append("suite 源 %s.md 里已存在同 id —— 先确认是否重复" % domain)

# 条件一：适用范围可表达
eff_applies = applies_to.strip() or (fm(fmblock, "applies_to") or "")
if not eff_applies and not allow_universal:
    # **警告不拒绝**：§2b 条件一把适用范围分两种轴 —— 按「改动类别」限定的项（如 DATA-002
    # 「所有 schema / 迁移改动」）本就该留空 applies_to，由 judge 评审时判。工具分不清是哪种轴，
    # 据此拒绝会把合法的「按改动限定」项挡在门外（OCR round-2 #11，与 §2b 声明相矛盾）。
    warnings.append("未填 `applies_to`。按**项目类别**限定的（只对某类仓库成立）须填；按**改动类别**"
                    "限定的（任何仓库都可能、只在该类改动出现时才有话可说）留空是对的 —— 见 §2b 条件一。"
                    "确认属后者后加 `--allow-universal` 可消掉本警告")

# 条件三：不体现具体项目（机械可判的部分）
src_proj = fm(fmblock, "project") or ""
evidence = ""
m = re.search(r"^证据：(.*)$", body, re.M)
if m:
    evidence = m.group(1).strip()
else:
    violations.append("缺「证据：」行 —— §2b 条件二要求证据是可复现锚")
if not src_proj:
    # 缺 project 是另一回事：无从据此核对。此前与「已是维护方」共用一个分支，
    # 报出「已是维护方（空）」这种自相矛盾的措辞（OCR round-2 #8）。
    warnings.append("frontmatter 缺 `project` 字段 —— 无法据此核对证据/正文里的项目痕迹，请人工检查")
elif src_proj != maintainer:
    for where, text in (("证据", evidence), ("正文", body)):
        if src_proj in text:
            violations.append("%s里仍出现源项目 id `%s` —— 条件三要求整项不体现具体项目" % (where, src_proj))
else:
    warnings.append("frontmatter `project` 已是维护方（%s），但仍需人核证据与正文里有无其他项目痕迹" % src_proj)

# 条件二：证据是可复现锚而非事故叙述（启发式单源见 checklist.looks_like_anchor；警告不拒绝）
if evidence and not looks_like_anchor(evidence):
    warnings.append("证据看不出可复现锚（规范/测试/规则 id/ADR 指针），疑似事故叙述：%s" % evidence[:40])

if violations:
    sys.stderr.write("[promote] 拒绝晋升 %s —— §2b 未通过：\n" % target_id)
    for v in violations:
        sys.stderr.write("  ✗ %s\n" % v)
    sys.exit(1)

# ── 3. 改写（这是本脚本的核心：晋升是改写，不是搬运）────────────────────────────
def set_field(block, key, value):
    """frontmatter 单行字段改写：有则换、无则追加到块尾。

    替换用 lambda 而非替换串：`re.sub` 会把替换串里的 `\\1`、`\\n` 当转义解释，
    `--applies-to` / `--maintainer` 的值（或从源项继承来的值）含反斜杠时抛 `re.error: bad escape`。
    """
    if re.search(r"^%s:.*$" % re.escape(key), block, re.M):
        return re.sub(r"^%s:.*$" % re.escape(key), lambda m: "%s: %s" % (key, value),
                      block, count=1, flags=re.M)
    return block.rstrip("\n") + "\n%s: %s" % (key, value)

new_fm = fmblock
new_fm = set_field(new_fm, "project", maintainer)     # 条件三：溯源改成维护方
new_fm = set_field(new_fm, "status", "shared")        # 层身份翻转
# 晋升后不再是候选。行尾用 (\n|$)：parse_items 按 \n---\n 切分时吃掉了尾随换行，
# 末行没有 \n —— 只写 `\n` 会匹配不上，reuse 静默留在成品里（踩过）。
new_fm = re.sub(r"^reuse:[ \t]*.*?(\n|$)", "", new_fm, flags=re.M)
new_fm = set_field(new_fm, "applies_to", eff_applies) if eff_applies else new_fm
promoted = (new_fm.rstrip("\n") + "\n---\n\n" + body.strip() + "\n")

# ── 4. 输出/落盘 ──────────────────────────────────────────────────────────────
if warnings:
    sys.stderr.write("[promote] 警告（判不了的，请人核）：\n")
    for w in warnings:
        sys.stderr.write("  ! %s\n" % w)

print("── 目标 ──")
print("  %s  →  %s" % (target_id, target_path))
if not apply_:
    print("\n── 改写后的成品（dry-run，未落盘；加 --apply 写入）──\n")
    print("---\n" + promoted)
    print("[promote] dry-run 结束。落盘后请跑 ci/bin/closed-loop-audit.sh 复核。")
    sys.exit(0)

os.makedirs(os.path.dirname(target_path), exist_ok=True)

# 原子追加 —— 同 harness-keep-land.sh 的 append_atomic。直接 open(...,"a") 中断会落半条，
# 而目标文件是**会被 loader 消费**的共享项；半条 = 畸形项 + 静默失效。
# **追加**：先读原内容，再整体原子替换。此前写成「原子追加」却在写 tmp 时**没读原文件** ——
# os.replace 是**替换**不是追加，会把同域文件里已有的条目整个删掉（已实测：晋升后 OLD-001 从
# 「2 处」变「0 处」）。注释声称的行为与代码不符，正是本次评审反复抓的那类。
_data = (open(target_path, encoding="utf-8").read() if os.path.isfile(target_path)
         else "# 共享 checklist · %s（suite 基线）\n\n" % domain)
_fd, _tmp = tempfile.mkstemp(dir=os.path.dirname(target_path) or ".", prefix=".promote-", suffix=".tmp")
try:
    with os.fdopen(_fd, "w", encoding="utf-8") as f:
        f.write(_data.rstrip("\n") + "\n\n---\n" + promoted + "\n")
    os.replace(_tmp, target_path)
except BaseException:
    try:
        os.unlink(_tmp)
    except OSError:
        pass
    raise
print("[promote] 已写入 %s" % target_path)

# ── 5. 源项退休：标 status: approved（**不删除**）─────────────────────────────
# 语义（README §五）：晋升是「移动」，但跨机同步不是瞬时的 —— 本机还没同步 suite shared 之前，
# 本地这份仍是**生效的那份**；因此不能删。改为标 `status: approved` + `promoted_to:` 留痕。
# 之后由 loader 按「以 shared 为准」消歧：shared 里有同 id 就用 shared，没有就用本地这份。
_src = os.path.join(ck_dir, "%s.md" % domain)
_txt = open(_src, encoding="utf-8").read()
_nb = set_field(fmblock, "status", "approved")
_nb = re.sub(r"^reuse:[ \t]*.*?(\n|$)", "", _nb, flags=re.M)   # 已晋升，不再是候选
_nb = set_field(_nb, "promoted_to", target_path)
if fmblock not in _txt:
    die("源项 frontmatter 在本地文件里定位不到，未改动源项（请手工标 status: approved）", 1)
_fd2, _tmp2 = tempfile.mkstemp(dir=os.path.dirname(_src) or ".", prefix=".promote-src-", suffix=".tmp")
try:
    with os.fdopen(_fd2, "w", encoding="utf-8") as f:
        f.write(_txt.replace(fmblock, _nb, 1))
    os.replace(_tmp2, _src)
except BaseException:
    try:
        os.unlink(_tmp2)
    except OSError:
        pass
    raise
print("[promote] 源项已标 status: approved（未删除：本机同步 shared 前它仍生效）")
print("[promote] 下一步：跑 ci/bin/closed-loop-audit.sh 复核；在 suite 仓提交；"
      "本机跑 ./install.sh --refresh-shared 同步后，shared 版本即覆盖它")
PY
