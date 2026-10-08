#!/usr/bin/env bash
# harness-identity.sh — .harness/identity.yaml（项目单一锚点，ADR-0001 决策4）的读取深模块。
# source 后使用（本文件是库，勿直接执行）。解析逻辑只此一处，调用方不再各自 sed。
#
#   函数：
#     h_fld <file> <key>         读任意 frontmatter 字段（h_get 的正则，显式文件）
#     h_set <file> <key> <value> 改写 frontmatter 字段（保持行首缩进，tmp+mv）
#     h_get <key>      第一个匹配标量（去引号/注释/首尾空白；缺文件或缺 key 返回空，不因 set -e 中断）
#     h_id             project.id（跨项目去重锚点）
#     h_gate <key>     0 = gates.<key>=true / 1 = 否则（对齐 harness-gate.sh 的 gate_on 语义）
#     h_node <node>    judge.nodes.<node> 绑定的 runner
#     h_owner          project.owner（唯一被授权确认 baseline 锚的人类身份，ADR-0015 决策 3）
#
# 默认按本文件位置推导仓库根；对「接入目标仓库」场景（harness-scaffold.sh），调用方先
# export HARNESS_ID_ROOT=<目标仓库根> 覆盖。

_h_root() {
  printf '%s' "${HARNESS_ID_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
}
_h_file() {
  printf '%s/.harness/identity.yaml' "$(_h_root)"
}

# 读 frontmatter 单字段标量。**只在前两条 `---` 之间找**。
# 此前是 sed 全文匹配（取第一处命中）：frontmatter 里没有该键时，会**读到正文里同名的行** ——
# 而 TSD/work/RunCard 的正文都是自由文本（RunCard 的 `premise` 还专门往里追加任意文本）。
# 与 python 侧 `checklist.fm` 同语义（块内匹配），四份实现合成一处。
# 行内 `#` 注释仍要剥：`identity.yaml` 是 YAML，值后面常跟 `# 说明`。
h_fld() {  # <file> <key>
  awk -v k="$2" '
    # 两种文件都要伺候：① 有 frontmatter 定界的（首行 `---`）—— TSD / work / RunCard；
    # ② 纯 YAML 的（首行不是 `---`）—— identity.yaml。**按首行判定**，不能一律块内匹配：
    # 一律块内会把 identity.yaml 读成空（它没有 `---`），而 `h_id` 正是经它读 `project.id` 的。
    NR == 1 { delim = ($0 ~ /^---[[:space:]]*$/) ? 1 : 0 }
    delim && /^---[[:space:]]*$/ { n++; if (n >= 2) exit; next }
    (!delim || n == 1) && $0 ~ ("^[[:space:]]*" k "[[:space:]]*:") {
      sub("^[[:space:]]*" k "[[:space:]]*:[[:space:]]*", "")
      sub(/[[:space:]]*#.*$/, "")          # 行内注释（identity.yaml 的值后面常跟 `# 说明`）
      sub(/^"/, ""); sub(/"$/, "")
      sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, "")
      print; exit
    }
  ' "$1" 2>/dev/null
}
h_set() {  # <file> <key> <value>
  sed -E "s|^([[:space:]]*)${2}:[[:space:]]*.*|\1${2}: ${3}|" "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}
h_get() {
  local f
  f="$(_h_file)"
  [ -f "$f" ] || return 0
  h_fld "$f" "$1"
}
h_id()  { h_get id; }
h_gate(){ grep -qE "^[[:space:]]*${1}:[[:space:]]*true" "$(_h_file)"; }
h_node(){ h_get "$1"; }
h_owner(){ h_get owner; }   # project.owner：唯一被授权确认 baseline 锚的人类身份（ADR-0015 决策 3）
