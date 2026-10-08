#!/usr/bin/env bash
# harness-baseline.sh — baseline 锚的确认 / 校验 / 只读检索（ADR-0015 决策 3/4）。
#
# baseline = **产出当前线上数据的那个状态**（部署 / 参考态），**不是待评审的改动**；二者语义不同，
# 混用即推演对象错位。它是「跨业务因果校验」的必填输入，**必须由客户显式确认、不得默认**：
# 本脚本**从不**推断 baseline（不取当前分支 / HEAD / 最近提交 / 配置缺省），只把客户显式给出的
# 引用落盘留痕。未确认即 fail-fast（exit 2）。
#
# 为什么 pin 成不可变 SHA：分支会移动，`git show <branch>` 今天与明天取到不同代码，而因果推演要求
# 可复现（ADR-0012 决策 1 内容寻址）。故 confirm 时把引用解析成 commit SHA 一并落盘；check 时若
# 引用已漂移（分支推进）即判「baseline 已不唯一」→ exit 2（need-human），不静默用新代码推演。
#
# **作用域：全仓单锚**（本文件一个）。baseline 是一个 git 引用（分支 / commit）= 一次部署态，产出
# 全仓所有域的数据，故是**仓级**而非 per-domain；各域共享同一 baseline。若日后需按域 pin 不同部署态，
# 另立 baseline-{domain}.yaml（本 ADR 未要求，暂不实现）。
#
# 子命令：
#   confirm <ref> --by <who>   客户显式确认 baseline 引用（分支 / commit / tag）；解析为不可变 SHA 落盘
#   check                      校验「已确认且未漂移」；未确认 / 漂移 / ref 失效 → exit 2
#   show                       打印已确认的 baseline_ref + baseline_sha；未确认 → exit 2
#   resolve <path>             只读取 baseline 代码：git show <baseline_sha>:<path>（决策 4：只读导航）
#
# 退出码：0=OK / 2=未确认 / 漂移 / 引用失效（fail-fast 或 need-human）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=harness-identity.sh
source "$ROOT/ci/bin/harness-identity.sh"   # h_owner：确认人须是已声明的 project.owner（决策 3）
# 文件 seam（B2）：缺省用仓库 .harness/baseline.yaml；测试用 HARNESS_BASELINE_FILE 指向临时文件隔离。
FILE="${HARNESS_BASELINE_FILE:-$ROOT/.harness/baseline.yaml}"

_die2() { echo "[baseline] $*" >&2; exit 2; }

# 读落盘字段（无引号/有引号都吃）。缺失 → 空串。
_read_field() {  # <key>
  [ -f "$FILE" ] || { echo ""; return; }
  sed -nE "s/^${1}:[[:space:]]*\"?([^\"]*)\"?[[:space:]]*\$/\1/p" "$FILE" | head -1
}

# ref → commit SHA。非法/不存在的 ref → 空串（调用方据此 fail-fast）。
_resolve_sha() {  # <ref>
  git -C "$ROOT" rev-parse --verify --quiet "${1}^{commit}" 2>/dev/null || true
}

cmd="${1:-}"; shift || true

case "$cmd" in
  confirm)
    ref=""; by=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --by) [ $# -ge 2 ] || _die2 "--by 缺值：用法 confirm <ref> --by <who>"; by="$2"; shift 2;;
        --by=*) by="${1#--by=}"; shift;;
        *) [ -z "$ref" ] && ref="$1" || _die2 "多余参数：$1"; shift;;
      esac
    done
    [ -n "$ref" ] || _die2 "用法：harness-baseline.sh confirm <ref> --by <who>（ref 必填，不接受空 / PENDING）"
    case "$ref" in PENDING|pending|"") _die2 "baseline 引用不得为占位值：$ref";; esac
    # 决策 3「agent 不得代替确认」的**结构性守卫**（allowlist，非字符串黑名单）：确认人必须是
    # identity.yaml **显式声明**的 project.owner；任何未声明的来源（含 agent 名）一律拒绝。
    # 局限（如实）：本地脚本无法**证明**人类身份——本守卫只保证「确认人 = 已声明 owner」这一结构约束，
    # 真正的保证是流程（owner 经 AskUserQuestion 应答）。不谎报更强的保证。
    owner="$(h_owner)"
    [ -n "$owner" ] || _die2 "identity.yaml 未声明 project.owner：无法确认 baseline（确认人须是已声明的 owner，agent 不得代替确认）"
    [ -n "$by" ] || _die2 "缺 --by <who>：确认人必填，且须等于 identity.yaml 的 project.owner（$owner）"
    [ "$by" = "$owner" ] || _die2 "确认人 '$by' ≠ project.owner '$owner'：baseline 只能由已声明的 owner 确认（ADR-0015 决策 3，agent 不得代替确认）"
    sha="$(_resolve_sha "$ref")"
    [ -n "$sha" ] || _die2 "baseline 引用无法解析为 commit：$ref（分支 / tag / SHA 均须在仓库中存在）"
    mkdir -p "$(dirname "$FILE")"
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    cat > "$FILE" <<EOF
# baseline 锚 —— 产出当前线上数据的那个状态（ADR-0015 决策 3）。
# 本文件是 baseline 的**唯一权威状态**：由客户经 AskUserQuestion 显式确认后落盘；
# agent 不得自动推断 / 不得取默认（当前分支 / HEAD / 最近提交一概不许）。
schema_version: 1
baseline_ref: "$ref"
baseline_sha: "$sha"
confirmed_by: "$by"
confirmed_at: "$ts"
EOF
    echo "[baseline] 已确认并落盘：ref=$ref sha=$sha by=$by（$FILE）"
    ;;

  check)
    [ -f "$FILE" ] || _die2 "baseline 未确认：缺 $FILE（客户须先显式确认，不得默认；ADR-0015 决策 3）"
    ref="$(_read_field baseline_ref)"
    sha="$(_read_field baseline_sha)"
    [ -n "$ref" ] && [ -n "$sha" ] || _die2 "baseline 记录不完整（缺 baseline_ref / baseline_sha）：$FILE"
    cur="$(_resolve_sha "$ref")"
    [ -n "$cur" ] || _die2 "baseline 引用已失效（$ref 在仓库中解析不到）：baseline 已不唯一 → 需人工重确认"
    [ "$cur" = "$sha" ] || _die2 "baseline 已漂移：$ref 现指向 $cur，确认时为 $sha（分支已推进）→ 需人工重确认，不得静默用新代码推演"
    echo "[baseline] OK：ref=$ref sha=$sha（未漂移）"
    ;;

  show)
    [ -f "$FILE" ] || _die2 "baseline 未确认：缺 $FILE"
    ref="$(_read_field baseline_ref)"; sha="$(_read_field baseline_sha)"
    [ -n "$ref" ] || _die2 "baseline 记录缺 baseline_ref"
    printf '%s\t%s\n' "$ref" "$sha"
    ;;

  resolve)
    path="${1:-}"
    [ -n "$path" ] || _die2 "用法：harness-baseline.sh resolve <path>"
    [ -f "$FILE" ] || _die2 "baseline 未确认：缺 $FILE（先 confirm）"
    sha="$(_read_field baseline_sha)"
    [ -n "$sha" ] || _die2 "baseline 记录缺 baseline_sha"
    # 只读导航（决策 4）：git show 不改工作区状态；path 不存在 → 明确报错，不静默出空。
    if ! git -C "$ROOT" cat-file -e "${sha}:${path}" 2>/dev/null; then
      _die2 "baseline 代码路径不存在于 $sha：$path"
    fi
    git -C "$ROOT" show "${sha}:${path}"
    ;;

  *)
    _die2 "用法：harness-baseline.sh {confirm <ref> --by <who>|check|show|resolve <path>}"
    ;;
esac
