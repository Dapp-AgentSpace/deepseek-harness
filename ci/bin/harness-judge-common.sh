#!/usr/bin/env bash
# harness-judge-common.sh — judge 深模块的共享收口（runner 选择 + 三档判定 + 落 issue）。
#
# **单源**：各 judge（harness-data-judge.sh / harness-data-causal-judge.sh / …）的「选 runner、
# 解析 JUDGE_VERDICT、block 时落 issue 并定退出码」是同一套逻辑，抄多份必然改一处漏一处
# （如 ocr 回落、need-human 归 2、issue 落盘失败不掩盖判定）。此处集中一份，judge 只负责
# 「装配 prompt + 调用 + 收口」。
#
# 本文件是库，勿直接执行；调用方须已 source harness-identity.sh（提供 h_node）并设置 $ISSUE_SCRIPT。
#
#   judge_pick_runner <node>
#       回声契约节点绑定的 runner：h_node <node>；空 / ocr → claude（ocr 不做语义判定）。
#
#   judge_nonce
#       回声一个 per-run 不可预测的定界 nonce（外部输入里即使含字面定界符也无法提前闭合数据块）。
#
#   judge_wrap_untrusted <kind> <nonce> <body>
#       把外部输入 <body> 用 per-run nonce 定界符包裹为 <untrusted_<kind>_<nonce}>…</…>。
#
#   judge_cap <body> <max_chars> <label>
#       超界即截断并**显式标注**（静默截断会让 LLM 误判输入完整），未超界原样回声。
#
#   judge_verdict <out>
#       回声 pass | block | need-human（结构化判定标记分类，**单一真源**；judge_finish 与 judge-review.sh
#       主链路共用，勿在调用点各抄一份 —— 抄多份必然改一处漏一处）。
#
#   judge_finish <out> <label> <pid> <domain> <block_msg> <pass_msg> [<no_verdict_msg>] [<issue_msg>]
#       三档收口：打印 <out>；block → 落 issue + 返回 1；无 pass 标记 → 返回 2；否则返回 0。
#       <no_verdict_msg> 缺省为通用文案；<issue_msg> 缺省等于 <block_msg>（落 issue 的标题）。
#       调用方惯例：rc=0; judge_finish … || rc=$?; exit "$rc"

judge_pick_runner() {  # <node>
  local r
  r="$(h_node "$1")"
  if [ -z "$r" ] || [ "$r" = ocr ]; then r="claude"; fi
  printf '%s' "$r"
}

# judge_nonce — per-run 不可预测的定界 nonce。
# 为什么不能是固定字面（如 `</untrusted_data>`）：外部输入（抓取数据 / 日志 / 代码）里若出现同款
# 字面定界符，即可提前闭合数据块，把后续内容顶出「纯数据」区变成 prompt 结构注入。nonce 不可预测，
# 数据里即使含字面 `</untrusted_data>` 也闭合不了（它拼不出带 nonce 的那一串）。
# **强度如实**：`$RANDOM` 各 15 位、两次拼接 = 30 位 —— 非密码学强度，也**不用于机密/认证**；定界只需
# 「外部输入无法提前猜中本 run 的 nonce」即可，30 位对单次判定的碰撞概率可忽略，够用。
# 这是**安全关键**逻辑，务必走本函数、不要在调用点各抄一份（抄多份必然改一处漏一处）。
judge_nonce() { printf '%08x%08x' "$RANDOM" "$RANDOM"; }

# judge_wrap_untrusted <kind> <nonce> <body> — 用 per-run nonce 定界符包裹外部输入。
# 定界符：`<untrusted_<kind>_<nonce}>` … `</untrusted_<kind>_<nonce}>`（<kind> 如 data / code）。
judge_wrap_untrusted() {  # <kind> <nonce> <body>
  printf '<untrusted_%s_%s>\n%s\n</untrusted_%s_%s>' "$1" "$2" "$3" "$1" "$2"
}

# judge_cap <body> <max_chars> <label> — 超界截断并**显式标注**。
# 静默截断会让 LLM 误判「输入完整」（如误判触发链完整 → 撞决策 8），故截断必须留痕。
# 只收已在内存里的字符串；超大文件（日志）应先用 head -c 限流再进来，避免整文件读入。
judge_cap() {  # <body> <max_chars> <label>
  local body="$1" max="$2" label="$3" n
  n="${#body}"
  if [ "$n" -gt "$max" ]; then
    printf '%s\n…（%s已截断，原文 %s 字符，上限 %s；超出部分**未评**）' "${body:0:$max}" "$label" "$n" "$max"
  else
    printf '%s' "$body"
  fi
}

# judge_verdict <out> — 结构化判定标记分类（**单一真源**）。
# 回声 pass | block | need-human。缺 JUDGE_VERDICT 标记 = need-human（覆盖不完整 / runner 异常，防假绿）。
# 无副作用（不落 issue、不打印），供 judge_finish 与 judge-review.sh 主链路共用。
judge_verdict() {  # <out>
  if printf '%s' "$1" | grep -qiE 'JUDGE_VERDICT:[[:space:]]*block'; then printf 'block'
  elif printf '%s' "$1" | grep -qiE 'JUDGE_VERDICT:[[:space:]]*pass'; then printf 'pass'
  else printf 'need-human'; fi
}

judge_finish() {  # <out> <label> <pid> <domain> <block_msg> <pass_msg> [<no_verdict_msg>] [<issue_msg>]
  local out="$1" label="$2" pid="$3" domain="$4" block_msg="$5" pass_msg="$6"
  local nov="${7:-未输出 JUDGE_VERDICT 标记，需人工}"
  local issue_msg="${8:-$block_msg}"
  echo "$out"
  case "$(judge_verdict "$out")" in
    block)
      echo "[$label] $block_msg"
      if [ -x "${ISSUE_SCRIPT:-}" ]; then
        printf '%s\n' "$out" | "$ISSUE_SCRIPT" "$pid" "$domain" "$issue_msg" || true
      else
        echo "[$label] harness-runtime-issue.sh 缺失，未落 issue" >&2
      fi
      return 1;;
    need-human)
      echo "[$label] $nov"; return 2;;
    *)
      echo "[$label] $pass_msg"; return 0;;
  esac
}
