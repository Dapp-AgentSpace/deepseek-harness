#!/usr/bin/env bash
# harness-checklist-ls.sh <domain> — 确定性消费缝 loader：把「适用」的 judge checklist 项（本地 + shared 两层）
# 拼成评审上下文输出，供 judge prompt 注入（见 judge-review.sh --checklist-domain 与 harness-review skill）。
# 只读：不改 checklist，唯一副作用是向消费日志记一行被消费的 shared 项 id（供退役判定）。
#
#   - 本地层 .harness/checklists/{domain}.md：project-local，全部适用。
#   - shared 层 {shared_store}/{domain}.md：按 applies_to 过滤（applies_to ⊆ project.traits 才适用，空=通用）。
#   - 只取 check_mode: judge 项（deterministic 已由确定性门禁覆盖，judge 不重复判，对齐 ADR-0001）。
#   - shared_store 缺失/未配置时降级 local-only 并向 stderr 告警（不假绿）。
#
# 用法: harness-checklist-ls.sh <domain>
set -euo pipefail
export PYTHONUTF8=1  # PEP 540: Windows 强制 UTF-8（避免 GBK 读/写中文出错）

# 环境解析（解释器 / 编码）单源见 ci/bin/harness-env.sh；本机缓存 .harness/toolchain.env 由 harness-preflight.sh 生成。
# 本脚本主体在 python：占位桩下会**静默产出空**，与「真的没问题」不可分（gates-ls 盲区曾使对账变红）。
# shellcheck source=harness-env.sh
source "$(dirname "${BASH_SOURCE[0]}")/harness-env.sh"
py_ok || { echo "[checklist-ls] python3 不可用（命令存在但执行失败；Windows 上常见为 Store 占位桩）——拒绝静默无事发生" >&2; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=harness-identity.sh
source "$ROOT/ci/bin/harness-identity.sh"
# shellcheck source=harness-stack.sh
source "$ROOT/ci/bin/harness-stack.sh"

DOMAIN="${1:?用法: harness-checklist-ls.sh <domain>}"
case "$DOMAIN" in *[!A-Za-z0-9._-]*) echo "[checklist-ls] domain 含非法字符: $DOMAIN" >&2; exit 2;; esac

LOCAL="$ROOT/.harness/checklists/$DOMAIN.md"
SHARED_STORE="$(h_get shared_store)"
SHARED_STORE="${SHARED_STORE/#\~/$HOME}"
TRAITS="$(h_get traits)"
STACK="$(stack_detect)"
# 多栈全集合：单标签 stack_detect 按优先级**只回一个**（Java 后端 + Vue 前端的 monorepo 只回 maven），
# 于是 applies_to: stack:npm 这类「按栈限定」的 shared 项，恰好在最需要它的 polyglot 仓库上被静默排除。
# 这里按 stack_detect_all 枚举**所有**探测到的栈，供 applies_to 用 has:<stack> 标签精确匹配。
STACKS_ALL="$(stack_detect_all 2>/dev/null | cut -f1 | sort -u | tr '\n' ',' || true)"
PID="$(h_id)"; [ -n "$PID" ] || PID="unknown"
LOG="$ROOT/.harness/reports/checklist-consumed.log"

# shared 层解析：suite 仓库自身 → checklists/shared/；项目 → shared_store（suite checkout）。
# 两者都缺则降级 local-only 并向 stderr 告警（不假绿）。
if [ -f "$ROOT/checklists/shared/$DOMAIN.md" ]; then
  SHARED="$ROOT/checklists/shared/$DOMAIN.md"
elif [ -n "$SHARED_STORE" ]; then
  SHARED="$SHARED_STORE/$DOMAIN.md"
else
  echo "[checklist-ls] shared_store 未配置且本仓库无 checklists/shared/，降级为仅消费 project-local 项（不假绿）" >&2
  SHARED=""
fi

"$HARNESS_PYTHON" - "$ROOT/ci/bin" "$DOMAIN" "$LOCAL" "$SHARED" "$TRAITS" "$STACK" "$STACKS_ALL" "$PID" "$LOG" <<'PY'
import sys, os, datetime
sys.path.insert(0, sys.argv[1])
from checklist import load_items
domain, local, shared, traits, stack, stacks_all, pid, log = sys.argv[2:10]

traits_set = set((traits or "").split())
if stack and stack != "unknown":
    traits_set.add("stack:" + stack)     # 单标签：按优先级唯一，兼容既有 applies_to: stack:<x>
# 构建栈 → 语言标签：applies_to 是**与匹配**（tags ⊆ traits），表达不了「maven 或 gradle」，
# 于是「Java 专属」的规则只能留空 applies_to = 声称对全世界适用。lang:<x> 补上这一维。
_LANG = {"maven": "java", "gradle": "java", "npm": "js", "go": "go", "rust": "rust", "python": "python"}
for _s in (stacks_all or "").split(","):
    _s = _s.strip()
    if not _s:
        continue
    traits_set.add("has:" + _s)          # 多栈：每个探测到的栈都成立（polyglot 安全）
    if _s in _LANG:
        traits_set.add("lang:" + _LANG[_s])

def applicable(path, shared_layer):
    if not path or not os.path.exists(path):
        return []
    out = []
    for it in load_items(path):
        if it["check_mode"] != "judge":
            continue
        if it.get("lifecycle") == "retired":   # retired=不再适用但保留溯源 → 不注入（否则污染 judge 上下文）
            continue
        cid = it["id"] or "?"
        if shared_layer:
            applies = it["applies_to"]
            tags = set(applies.split())
            if tags and not tags <= traits_set:
                continue
        out.append((cid, it["body"], shared_layer))
    return out

def emit(cid, body, shared_layer):
    src = "shared" if shared_layer else "local"
    print(f"### {cid} [{src}]\n")
    print(body)
    print()

count = 0
consumed = []
if not os.path.exists(local) and not (shared and os.path.exists(shared)):
    print(f"[checklist-ls] 域 {domain} 无任何 checklist 源（本地与 shared 均缺失），请确认域拼写或先落 checklist 项", file=sys.stderr)
    sys.exit(2)
# 跨层同 id：**以 shared 为准**。local 那份可能是「已晋升、尚未同步」的残留
# （promote --apply 把它标成 status: approved）—— 本机同步 shared 前，shared 里没有，
# 它仍生效；同步后 shared 覆盖它，本地这份被跳过，避免同一规则注入两次。
_local_items = applicable(local, shared_layer=False)
_shared_items = applicable(shared, shared_layer=True)
_shared_ids = {cid for cid, _b, _s in _shared_items}
for cid, body, _ in _local_items:
    if cid in _shared_ids:
        continue
    emit(cid, body, False)
    # **本地项也要记消费**。此前只记共享项（日志的原用途是「shared 项跨项目复用」），于是
    # 本地层被注入而日志里查无此据 —— 依赖该日志的「死守卫」检测会把**每一个**本地项都报成
    # 「从未被注入」（假阳性），而假阳性会让检查被无视（HOG-011）。
    # 这正是本套件反复出现的形状：**先补来源，再谈检查** —— 没有记录的事实，检查不出来。
    # 两层 id 在日志里混存，读取侧按各自目录的 id 集合切分；跨层同 id 由对账另行报错，
    # 故切分是可靠的。
    consumed.append(cid)
    count += 1
for cid, body, _ in _shared_items:
    emit(cid, body, True)
    consumed.append(cid)
    count += 1

if consumed:
    os.makedirs(os.path.dirname(log), exist_ok=True)
    # 第三列 = 时间戳（ADR-0012 决策 4 的「N 天未消费」告警需要它）。
    # 此前只记 `{pid}\t{cid}`，**没有时间信息** —— 于是那条告警不是「没实现」，而是**来源缺字段**，
    # 根本无从判定「多久没被消费」。这正是 ADR 自己的规则：可记性由来源这一属性决定。
    # 读取侧对旧行（两列）按「时间未知」处理，**不当成「很久以前」** —— 猜出来的陈旧度会误报退役。
    ts = datetime.datetime.now().isoformat(timespec="seconds")
    with open(log, "a", encoding="utf-8") as f:
        for cid in consumed:
            f.write(f"{pid}\t{cid}\t{ts}\n")

if count == 0:
    print(f"[checklist-ls] 域 {domain} 无适用 judge 项", file=sys.stderr)
PY
