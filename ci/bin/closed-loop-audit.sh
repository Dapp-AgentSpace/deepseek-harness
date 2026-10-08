#!/usr/bin/env bash
# closed-loop-audit.sh — 对账（确定性部分）：核对 TSD/契约「声明」是否都「落盘」成可执行校验。
set -euo pipefail
export PYTHONUTF8=1  # PEP 540: Windows 强制 UTF-8（避免 GBK 读/写中文出错）

# 环境解析（解释器 / 编码）单源见 ci/bin/harness-env.sh；本机缓存 .harness/toolchain.env 由 harness-preflight.sh 生成。
# 本脚本主体在 python：占位桩下会**静默产出空**，与「真的没问题」不可分（gates-ls 盲区曾使对账变红）。
# shellcheck source=harness-env.sh
source "$(dirname "${BASH_SOURCE[0]}")/harness-env.sh"
py_ok || { echo "[audit] python3 不可用（命令存在但执行失败；Windows 上常见为 Store 占位桩）——拒绝静默无事发生" >&2; exit 2; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# ── 输出同时落审计日志：收尾按**本脚本自己吐出的行**分类，落 .harness/reports/audit-last.json ──
# 这是指标 `global.declaration_not_landed` / `build.contract_landed_rate` 的来源（ADR-0012 决策 5）。
# 按输出行分类而非在各失败点各自 +1：**报告里说了什么，指标就记什么**，两份事实不可能漂；
# 若各自计数，漏改一处 = 静默少记，而少记的指标看起来更好（本套件反复抓到的缺陷类）。
# 主体包成函数：里面的 `exit` 改成 `return`（只退函数），退出码由下面接住 —— 门禁契约（0/1）不变。
# 主体不整体缩进：370 行的纯缩进改动会把真正的改动淹掉，且让本就不短的脚本更难读。
AUDIT_LOG="$(mktemp)"
trap 'rm -f "$AUDIT_LOG"' EXIT

audit_main() {

# shellcheck source=harness-identity.sh
source "$ROOT/ci/bin/harness-identity.sh"
CONTRACTS="$ROOT/.harness/contracts"
TSD="$ROOT/.harness/tsd"
fail=0

# 跑一条 audit_checks.py 子检查并透传它的输出行；**退出码 ≥2（检查自身没跑成）一律判红，绝不静默放行**。
#
# 为什么不能直接用 `... | while` 或进程替换（`< <(...)`）跑：进程替换会**吞掉退出码** —— 检查一崩
# （缺文件、解释器异常）就零输出，而「零输出」与「真的没问题」长得一模一样，于是对账静默通过。
# 这正是本套件反复抓的缺陷类（跑不出来当成没有）。用变量接住输出与退出码才能分辨。
#
# 退出码约定（见 ci/bin/audit_checks.py 头注释）：0=不红 / 1=该检查有发现（正常的「红」，其输出行由
# 下方分类器计）/ 2=用法或环境错误。故只有 ≥2 才算「检查自身没跑成」，判红。
# fol（fail-on-line）=1：每行输出都算红（metric-sources / reachability / selftest-wiring 这类
# **只输出失败行**的检查）；=0：输出行只是告警（review-validity / freshness），红仅来自执行错误。
_ck_run() {  # _ck_run <fail_on_line 0|1> <check-name> <args...>
  local _fol="$1" _name="$2"; shift 2
  local _out="" _rc=0
  _out="$("$HARNESS_PYTHON" "$_ck" "$_name" "$@" 2>/dev/null)" || _rc=$?
  # 两类「检查自身没跑成」都判红，绝不静默放行：
  #   ① rc≥2：audit_checks 的用法/环境错误（见其头注释退出码约定）；
  #   ② rc≠0 且**零输出**：未预期异常（TypeError/AttributeError 等）traceback 到 stderr（此处已吞）、
  #      以 rc=1 退出、stdout 为空 —— 而「空输出」与「真的没问题」长得一样，正是本套件反复抓的缺陷类
  #      （跑不出来当成没有）。正常「有发现」必伴随输出行（同下方 work_unit 那条守卫）。
  if [ "$_rc" -ge 2 ] || { [ "$_rc" -ne 0 ] && [ -z "$_out" ]; }; then
    printf "[audit] audit_checks %s 检查执行失败（python 退出 %s）—— 不静默放行\n" "$_name" "$_rc"
    fail=1
  fi
  while IFS= read -r _msg; do
    [ -n "$_msg" ] || continue
    printf '%s\n' "$_msg"
    # `_fol=1` = 每行都算红，但 **`[audit][warn]` 前缀的行除外**：同一检查可以既输出红行
    # （枚举非法 / 与执行证据不一致 / 推进序非法）又输出 warn 行（status≥verified 无评审证据）——
    # warn 的语义是「请确认」，与 audit_summary.py 的 `_WARN_RE`（`^\[audit\]\[warn\]` 短路不计数）
    # 一致；若对 warn 行也判红，门禁会对「只是告警」的检查误红
    # （实测：fx-x.md status=closed 无评审 → ④ warn 行被 _fol=1 误判红，[10b] 期望 0 实际 1）。
    [ "$_fol" = 1 ] && [[ "$_msg" != \[audit\]\[warn\]* ]] && fail=1
  done <<< "$_out"
}

# 收集存在的测试目录（避免 grep 打到不存在的目录）
search_dirs=()
for d in "$ROOT/src" "$ROOT/test" "$ROOT/tests"; do [ -d "$d" ] && search_dirs+=("$d"); done

# 契约目录缺失 = 无契约可对账，不能静默报「对账通过」（防假绿）
if [ ! -d "$CONTRACTS" ]; then
  echo "[audit] 缺少 .harness/contracts 目录（无契约可对账）"
  fail=1
fi

for c in "$CONTRACTS"/*.md; do
  [ -f "$c" ] || continue
  base="$(basename "$c" .md)"
  # 落盘方向（frontmatter enforcement）：judge → 判断节点执行点；缺省/script → 确定性脚本（向后兼容旧契约）
  enf="$(sed -nE 's/^enforcement:[[:space:]]*"?([^"[:space:]#]+)"?.*$/\1/p' "$c" | head -1)"
  if [ "$enf" = judge ]; then
    # judge 执行：声明必须指向 judge-review.sh 作为执行点（存在性核对；语义判断归 judge 节点）
    if grep -q 'judge-review.sh' "$c"; then
      echo "[audit] 声明已落盘(judge 执行点): $c"
    else
      echo "[audit] 声明未落盘: $c (enforcement=judge 但无 judge-review.sh 执行点)"
      fail=1
    fi
  elif [ -f "$ROOT/${base}_check.sh" ]; then
    echo "[audit] 声明已落盘: $c (${base}_check.sh)"
  # verification: 字段 = 契约自己声明的校验脚本（相对 ROOT）；脚本存在即视为落盘（ADR 声明≠落盘：字段是声明、文件存在才是落盘）。
  # 此前门禁只认 ${base}_check.sh 约定与测试引用，契约 frontmatter 的 verification: 无消费方 —— 声明了却无人兑现（CONTRACT-001 rung2 集成断裂）。
  elif ver="$(sed -nE 's/^verification:[[:space:]]*"?([^"[:space:]#]+)"?.*$/\1/p' "$c" | head -1)"; [ -n "$ver" ] && [ -f "$ROOT/$ver" ]; then
    echo "[audit] 声明已落盘(verification): $c ($ver)"
  # 软信号：测试目录里出现契约名（-w 词边界，避免 foo 命中 fooBar/foobar）；权威落盘仍是 ${base}_check.sh
  elif [ "${#search_dirs[@]}" -gt 0 ] && grep -Rwq "$base" "${search_dirs[@]}" 2>/dev/null; then
    echo "[audit] 声明已落盘(测试引用): $c"
  else
    echo "[audit] 声明未落盘: $c (无 ${base}_check.sh / verification 脚本 / 测试引用)"
    fail=1
  fi
done

# 对账 TSD：冻结标志必须存在
for t in "$TSD"/*.md; do
  [ -f "$t" ] || continue
  if ! grep -Eq 'tsd_frozen:[[:space:]]*true' "$t"; then
    echo "[audit] TSD 未冻结: $t"
    fail=1
  fi
done

# RunCard 校验（ADR-0012 决策 4 的落地）：字段格式 / tsd 冻结 / handoff_from 链不断·不跨 TSD·不成环 / 无孤儿。
# 确定性校验归 ci/bin/runcard.py（单一真源 ci/run-card-schema.md）；语义（这轮做得好不好）归 judge，不在此。
RUNCARDS="$ROOT/.harness/runcards"
if [ -d "$RUNCARDS" ]; then
  "$HARNESS_PYTHON" "$ROOT/ci/bin/runcard.py" "$RUNCARDS" "$TSD"
  rc=$?
  [ "$rc" -eq 0 ] || fail=1
else
  # 无 runcards 目录＝本仓还没起过 RunCard（ADR-0012 决策 4 认可此状态）。**显式说明而非静默跳过**：
  # 「没查」与「查了没问题」不能长得一样（同上面 contracts 目录缺失的显式处理）。判 warn 不判红——
  # 没起过卡不是违规；warn 前缀让 audit_summary 分类器不计入失败（新加 [audit] 消息须可分类，见 tests/metrics [6]）。
  echo "[audit][warn] 无 .harness/runcards 目录（未起过 RunCard）——跳过 RunCard 校验"
fi

# 阻塞边对账（ADR-0012 决策 1）：`blocked_by` 指向不存在的 work-unit = **悬空边**。
# 悬空边是「声明了一个没有落点的依赖」——正是本脚本对账的那类缺陷（声明≠落盘）。
# 判红而非放行：放过它等于让遗留项凭空消失（round N 的遗留 = blocked_by 未解析的单元，
# 悬空边被当「已解析」的话，下一轮就看不到这条遗留）。解析归 ci/bin/work_unit.py，不在此重写。
# 未解析但**存在**的边（前置单元还没做完）是正常状态，不报 —— 那正是「遗留」的定义。
WORK_DIR="$ROOT/.harness/work"
if [ -d "$WORK_DIR" ]; then
  for w in "$WORK_DIR"/*.md; do
    [ -f "$w" ] || continue
    wid="$(basename "$w" .md)"
    # 不吞退出码：work_unit.py blockers 退出 1 = 有未解析边（正常，下面按行判），≥2 = 脚本自身出错。
    # 另有一类静默失效：脚本/解释器崩了会退出 1 且**零输出**，空输出与「全部已解析」看起来一样 ——
    # 用「退出码非 0 且无输出」判它（悬空边一定伴随输出行，故不会误伤）。
    _wu_out="$("$HARNESS_PYTHON" "$ROOT/ci/bin/work_unit.py" blockers "$ROOT" "$wid" 2>/dev/null)"; _wu_rc=$?
    if [ "$_wu_rc" -ge 2 ] || { [ "$_wu_rc" -ne 0 ] && [ -z "$_wu_out" ]; }; then
      printf "[audit] work_unit.py blockers %s 检查执行失败（python 退出 %s）—— 不静默放行\n" "$wid" "$_wu_rc"
      fail=1
    fi
    while IFS=$'\t' read -r bid state _st; do
      [ -n "$bid" ] || continue
      if [ "$state" = dangling ]; then
        echo "[audit] 阻塞边悬空: ${wid} → ${bid}（无此 work-unit：已删/改名/写错）"
        fail=1
      fi
    done <<< "$_wu_out"
  done
fi

# 评审有效性对账（ADR-0012 决策 1 的 content-hash 的第二个消费者）：设计评审报告带
# `tsd_content_sha`（评审时被评 TSD 的 body 哈希），与 TSD 当前的 `content_sha` 比 —— 不等 =
# **这份评审针对的是旧版规格**（TSD 经 re-plan 改过）。评审不会因为规格变了而自动失效，这是唯一
# 能发现它的地方。
#
# 判 **warn 不判红**：机械事实是「版本不符」，而「这个改动大到需要重审吗」是判断 ——
# 把判断塞进确定性检查就是假红。观察期同 runtime 缺口告警。
# 两边都用 body 哈希（同源 `_body_sha`），故不会因定义不同而误报 —— 前提是报告**必须原样取
# `tsd-sha` 的值**（skill 里已写死这条，且说明了为什么不能自己算）。
# 报告缺该字段（旧报告 / 非设计评审）不报：来源没有时无从比对，报「缺」会把历史报告全变成噪音。
if [ -d "$ROOT/.harness/tsd" ] && [ -d "$ROOT/.harness/reports" ]; then
  _ck="$ROOT/ci/bin/audit_checks.py"
  if [ -f "$_ck" ]; then
    _ck_run 0 review-validity "$ROOT" "$(h_id)"
  fi
fi

# 套件自测的执行点（**只在套件源里判**：项目没有 tests/，不分发）。
# `tests/` 此前哪里都不跑 —— 只有三处散文引用它，而 HOG 规则把它当「可复现证据」。
# 按本套件自己的标准那是「没有落点的声明」，而本脚本正是为抓这类东西存在的。
# 判据与消息在 ci/bin/audit_checks.py 的 selftest_wiring（单一归属，本段只触发）。
if [ -f "$ROOT/ci/bin/audit_checks.py" ]; then
  _ck="$ROOT/ci/bin/audit_checks.py"
  _ck_run 1 selftest-wiring "$ROOT"
fi

# AGENTS.md 受管路由块对账（治理入口）：项目根须有 AGENTS.md，且含**与 ci/agents-routing.md 一致**的
# 受管块 —— 否则「研发诉求先经 harness、不得直接走 cs-feat 跳过」这句路由声明没有落点（声明≠落盘）。
# 判**红**（owner 定）。播种在 init/scaffold（`agents_md.py ensure`），存量项目 upgrade 后即合规；此处只对账。
# 合并/比对逻辑归深模块 ci/bin/agents_md.py；消息归 audit_checks.py（须可被 audit_summary 分类）。
if [ -f "$ROOT/ci/bin/audit_checks.py" ]; then
  _ck="$ROOT/ci/bin/audit_checks.py"
  _ck_run 1 agents-md "$ROOT"
fi

# 收尾报告「观测」节对账（ADR-0016 决策 1）：close 报告须内嵌 `harness-measure.sh --section` 的观测节 ——
# 否则「观测报告有流程内消费者」（ADR-0012 决策 4「产出即被消费」）这句声明没有落点。
# 判**红**：close 报告的形状契约（该做的事有没有做），不是判断类产物的格式（那是 warn）。
# 判据与消息归 ci/bin/audit_checks.py（单一归属，本段只触发）。
if [ -f "$ROOT/ci/bin/audit_checks.py" ]; then
  _ck="$ROOT/ci/bin/audit_checks.py"
  _ck_run 1 observation "$ROOT" "$(h_id)"
fi

# 收尾报告「关联 epic 剩余 item」节对账（owner 2026-10-01 需求）：close 报告须内嵌
# `harness-epic-progress.sh <task-slug>` 的四态输出 —— 否则「epic 多 item 各自 TSD，本 TSD close 后关联
# epic 还有哪些 item 未完成」这个产出没有流程内消费者（ADR-0012 决策 4「产出即被消费」没落地），跨轮就丢了。
# 判**红**：与 observation 同 —— close 报告的形状契约（该做的事有没有做），不是判断类产物的格式。
# 判据与消息归 ci/bin/audit_checks.py（单一归属，本段只触发）。
if [ -f "$ROOT/ci/bin/audit_checks.py" ]; then
  _ck="$ROOT/ci/bin/audit_checks.py"
  _ck_run 1 close-epic-remaining "$ROOT" "$(h_id)"
fi

# TSD status 推进语义门禁（ADR-0019 决策 1）：status 字段 vs status.log 执行证据必须一致。
# 审计实证（2026-10-02，两仓 12 处不一致）：核心缺陷类 G1 —— git-work-ui TSD `status: frozen` 却有
# 12+ 轮执行证据（status.log 25 行），门禁全绿放行。根因：audit 对 `status` 字段本身**零引用**。
# 判**红**（owner 拍板，无回溯豁免）：枚举非法 / 终态行与 status 不一致 / 推进序非法 → 红；
# status≥verified 无评审证据 → warn（与 review_validity 同语义，判断类不判红）。
# 判据与消息归 ci/bin/audit_checks.py（单一归属，本段只触发）。
if [ -f "$ROOT/ci/bin/audit_checks.py" ]; then
  _ck="$ROOT/ci/bin/audit_checks.py"
  _ck_run 1 tsd-status-progression "$ROOT" "$(h_id)"
fi

# status.log 格式/命名门禁（ADR-0019 决策 2）：证据文件必须可机器判读、命名唯一。
# 审计实证：G2（双 status.log：双前缀 + 拆分两文件）、G3（≥4 种写入机制污染日志）。
# 判**红**（owner 拍板，无回溯豁免）：行格式非法 / 文件名非严格 {pid}-{slug} / 孤儿文件 / 同 slug 多文件。
# 判据与消息归 ci/bin/audit_checks.py（单一归属，本段只触发）。
if [ -f "$ROOT/ci/bin/audit_checks.py" ]; then
  _ck="$ROOT/ci/bin/audit_checks.py"
  _ck_run 1 status-log-integrity "$ROOT" "$(h_id)"
fi

# 评审陈旧性 close 前强制门禁（ADR-0019 决策 3）：冻结 TSD 有 re-plan 痕迹（reconfirmed）且最新评审
# 报告的 tsd_content_sha ≠ 当前 content_sha → 红（评审针对旧版规格，close 前必须重审）。
# 审计实证：G4 —— git-work-ui-review 引用 tsd_content_sha=4b4d58fc（tsd_version 16），当前 cc547b32
# 落后 18 版仍可 close。review_validity 只 warn 不判红（判断类不假红）；**close 是收口点**，
# 「评审覆盖当前规格」是质量底线 → 判红（owner 拍板，无回溯豁免）。
# 判据与消息归 ci/bin/audit_checks.py（单一归属，本段只触发）。
if [ -f "$ROOT/ci/bin/audit_checks.py" ]; then
  _ck="$ROOT/ci/bin/audit_checks.py"
  _ck_run 1 close-review-staleness "$ROOT" "$(h_id)"
fi

# judge 节点报告格式对账 close 判红（ADR-0019 决策 4）：带 `node:` 标记的报告必须符合 ReviewRecord
# （文件名 `*-review.md` + target + 发现清单可解析）—— 否则 close 汇总依据不完整（覆盖对账无消费方）。
# 审计实证：G5（3 份 judge 节点报告不是 ReviewRecord）、G6（3 份评审发现清单不可解析）。
# review_validity 的 ②③ 只 warn；**close 场景判红**（断链必须在收口前暴露，owner 拍板，无回溯豁免）。
# 判据与消息归 ci/bin/audit_checks.py（单一归属，本段只触发）。
if [ -f "$ROOT/ci/bin/audit_checks.py" ]; then
  _ck="$ROOT/ci/bin/audit_checks.py"
  _ck_run 1 close-report-format "$ROOT" "$(h_id)"
fi

# MetricEvent 来源对账（ADR-0012 决策 2 约束 3）：每行必须写 `source`，且 source 要**指得着**。
# 决策 2 原文说缺省值 `unknown`「仍记但标 unknown（**供对账发现**）」—— 此前这一句只落在
# harness-metric.sh 的注释里，**没有任何对账看它**：记了 unknown 而无人发现 = 声明≠落盘，
# 且长在「声明这条不变量」的那份 ADR 自己身上。
# 判据两条（都属「来源不可追溯」→ 该行的指标无法核对是否伪造/漂移）：
#   1) source 缺失或为 `unknown`；
#   2) source 形如 `<脚本>.sh|.py[:子标识]`，但 ci/bin 下没有这个脚本（指向已删/改名的写者）。
# 不另查 `g_<key>` 门禁函数是否存在 —— 那是「门禁身份对账」已有的检查，重复实现会漂。
# append-only 流里混入坏行不该让整段消失，故坏行单独计一类，不吞。
METRIC_LOG="$ROOT/.harness/reports/metric-events.jsonl"
if [ -f "$METRIC_LOG" ]; then
  _ck="$ROOT/ci/bin/audit_checks.py"
  if [ -f "$_ck" ]; then
    _ck_run 1 metric-sources "$ROOT" "$METRIC_LOG"
    # 「指标发出即有对应报告落盘」的对账：judge 目标发了 MetricEvent 却无对应 (tsd,node) 报告 → 判红。
    # node 映射取自 judge-review.sh 的目标登记表（--list-target-nodes，单一真源）；只查有 run 归属的事件。
    if [ -x "$ROOT/ci/bin/judge-review.sh" ]; then
      _nodes="$("$ROOT/ci/bin/judge-review.sh" --list-target-nodes 2>/dev/null)"
      _ck_run 1 review-landing "$ROOT" "$METRIC_LOG" "$_nodes" "$(h_id)"
    fi
  fi
fi

# 数据 UT 落盘（ADR-0007 B）：冻结 TSD 声明「数据 UT」节的，条目须勾选 + 落点文件存在；未落盘先告警不 blocking（观察期）
for t in "$TSD"/*.md; do
  [ -f "$t" ] || continue
  if grep -qE '^##[[:space:]]*数据 UT' "$t"; then
    ut_section="$(awk '/^##[[:space:]]*数据 UT/{f=1;next} /^##[[:space:]]/{if(f)exit} f' "$t")"
    if printf '%s\n' "$ut_section" | grep -qE '^- \[ \]'; then
      echo "[audit][warn] 数据 UT 未落盘（数据 UT 节有未勾选条目 - [ ]）: $t"
    fi
    land="$(printf '%s\n' "$ut_section" | sed -nE 's/^.*落点：[[:space:]]*`?([^` \t]+)`?.*$/\1/p' | head -1)"
    if [ -n "$land" ] && [ ! -f "$ROOT/$land" ]; then
      echo "[audit][warn] 数据 UT 落点文件不存在: $land ($t)"
    fi
  fi
done

# data trace 接口（ADR-0017）：有数据不变量的 TSD 必须带项目唯一只读接口 .harness/data_trace/，
# 缺 = rung 3 红（决策 6：数据 UT 强制接真实数据）；存在则跑 check（manifest 合法 + ping + 方法对账 + 只读守卫）。
# 判色：接口缺失/不可执行 → 红；need-human（多出方法未审核）/blocking（写语义命令）→ 红；
#       连接未配置（source.yaml 缺 source 声明）/ 实现缺方法等告警 → [audit][warn] 不红。
DT_INV=0
for t in "$TSD"/*.md; do
  [ -f "$t" ] || continue
  inv="$(awk '/^##[[:space:]]*数据不变量/{f=1;next} /^##[[:space:]]/{if(f)exit} f' "$t")"
  if [ -n "$inv" ] && ! printf '%s\n' "$inv" | grep -q '无数据不变量'; then
    DT_INV=1
    break
  fi
done

if [ "$DT_INV" = 1 ]; then
  if [ ! -d "$ROOT/.harness/data_trace" ]; then
    echo "[audit] data trace 接口缺失（有数据不变量的 TSD 缺 .harness/data_trace/，ADR-0017 决策 6）: 先跑 ci/bin/harness-data-trace-init.sh 生成只读骨架"
    fail=1
  elif [ -f "$ROOT/ci/bin/harness-data-trace.sh" ]; then
    _dt_rc=0
    _dt_out="$("$ROOT/ci/bin/harness-data-trace.sh" check 2>&1)" || _dt_rc=$?
    if [ "$_dt_rc" -ge 2 ]; then
      echo "[audit] data trace 接口不可用（check 退出 $_dt_rc：manifest 缺失或 ping 失败）——有数据不变量的 TSD 需要可用只读接口"
      fail=1
    fi
    # 连接状态（决策 4）：连接未配置 = 告警不红（scaffold 预期态「待 owner 配连接」）；
    # 配置了真实连接的接口必有 source: local|uat 声明。只静态判定，不做真实读取探针。
    if [ ! -f "$ROOT/.harness/data_trace/source.yaml" ] || ! grep -qE '^source:[[:space:]]*(local|uat)' "$ROOT/.harness/data_trace/source.yaml"; then
      echo "[audit][warn] data trace 连接未配置（source.yaml 缺 source: local|uat 声明）——owner 需提供只读连接"
    fi
    while IFS= read -r _line; do
      [ -n "$_line" ] || continue
      case "$_line" in
        *"[need-human]"*) echo "[audit] data trace 方法未审核（need-human）: ${_line#*\] }"; fail=1;;
        *"[blocking]"*)   echo "[audit] data trace 只读守卫 blocking: ${_line#*\] }"; fail=1;;
        *"[warn]"*)       echo "[audit][warn] data trace ${_line#*\] }";;
        *"check 通过"*)   echo "[audit] data trace 接口对账通过（存在、manifest 合法、ping ok、方法集一致）";;
        *"[data-trace]"*) echo "[audit][warn] data trace ${_line#*\] }";;
      esac
    done <<< "$_dt_out"
  fi
fi

# TSD 命名一致性由下方「project.id 前缀」检查兜底（ADR-0004 锁 .harness/tsd/{pid}-{slug}.md，无 -tsd 后缀）

# project.id 注入核对：所有 .harness 产出（文件名按任务/运行 + YAML frontmatter）必须携带 project.id（ADR-0001 决策4）
PID="$(h_id)"
if [ -z "$PID" ]; then
  echo "[audit] identity.yaml 缺 project.id，无法核对产出注入"
  fail=1
else
  # 1) frontmatter 必须带非空 project: 字段（所有 .harness 产出）
  for f in "$ROOT/.harness"/{tsd,reports,contracts,checklists}/*.md; do
    [ -f "$f" ] || continue
    if ! grep -qE '^project:[[:space:]]*[^[:space:]#]' "$f"; then
      echo "[audit] frontmatter 缺 project 字段: $f"
      fail=1
    fi
  done
  # 2) 按任务/运行产出（tsd/reports/contracts，不含 arch.md 声明）文件名必须带 ${PID}- 前缀
  for f in "$ROOT/.harness/tsd"/*.md "$ROOT/.harness/reports"/*.md "$ROOT/.harness/contracts"/*.md; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in
      arch.md) ;;   # 架构契约声明（scaffold 生成，单例），不带任务前缀
      "${PID}"-*) ;;
      *) echo "[audit] 文件名缺 project.id(${PID}) 前缀: $f"; fail=1;;
    esac
  done
fi

# 记忆底座 staleness 对账（文件↔代码同步的确定性部分；派生漂移由 scaffold --refresh-base 兜底）
ATTN="$ROOT/.harness/attention.md"
if [ -f "$ATTN" ]; then
  n="$(grep -cE '^[-*][[:space:]]' "$ATTN" 2>/dev/null || true)"
  if [ -n "$n" ] && [ "$n" -gt 25 ]; then
    echo "[audit] attention.md 条目超限($n>25)，需合并/退役（文件↔代码同步）"
    fail=1
  fi
fi
# 两段式坑库对账（suite 自检；项目仓库无 checklists/shared 则跳过）。
# 校验**所有域、所有 severity** 的每一项都必须「名副其实」——一律 fail-closed，不用域白名单：
#   1) category 有值且在 constraint-model.md frontmatter 的 categories 枚举内（单源）；
#   2) severity 有值且 ∈ {blocking, important}——拼错不再静默降级；
#   3) check_mode 有值且 ∈ {deterministic, judge}——留空 ＝ 该规则无人执行（loader 只收 judge）；
#   4) check_mode=deterministic 的 deterministic_rule 指向 ci/rules/pitfalls.yaml 真实规则
#      或已知确定性脚本（harness.schema-check）；
#   5) frontmatter 的 domain 与所在文件名一致（消费走文件名，字段漂移要能被看见）。
# 域白名单是反模式：加新域时新域默认落在保护范围之外（fail-open），而这正是最该被校验的时刻。
CK_SHARED="$ROOT/checklists/shared"
CK_LOCAL="$ROOT/.harness/checklists"
RULES_FILE="$ROOT/ci/rules/pitfalls.yaml"
# loader 解析共享项的兜底目录（本仓 checklists/shared 缺失时用它）——审计必须跟着看同一处，
# 否则消费项目里共享层永远不被校验（那才是注入评审的项）。
SHARED_STORE_CFG="$(h_get shared_store)"; SHARED_STORE_CFG="${SHARED_STORE_CFG/#\~/$HOME}"
if [ -d "$CK_SHARED" ] || [ -d "$CK_LOCAL" ] || [ -d "$SHARED_STORE_CFG" ]; then
  _ck="$ROOT/ci/bin/audit_checks.py"
  if [ -f "$_ck" ]; then
    "$HARNESS_PYTHON" "$_ck" checklists "$ROOT" "$RULES_FILE" "$ROOT/ci/constraint-model.md" "$SHARED_STORE_CFG"
    rc=$?
    [ "$rc" -eq 0 ] || fail=1
    # 记忆治理（R2/R4）：域归属确定性面 —— 生命周期/取代一致性（红）+ 存量缺域字段（告警，grandfather）。
    # domain↔文件名一致、category 枚举已由上面的 checklists 覆盖，此处不重复（避免同一问题两条红线）。
    # 扫描范围与 checklists 同源（含 shared_store 兜底），否则消费项目里装载层不被校验。
    _ck_run 1 domain-attribution "$ROOT" "$SHARED_STORE_CFG"
    _ck_run 0 domain-backfill "$ROOT" "$SHARED_STORE_CFG"
  fi
fi

# 门禁身份对账（A）：注册表 ci/gates.yaml ↔ identity.yaml gates.* ↔ harness-gate.sh 执行器 三向一致
REG_LS="$ROOT/ci/bin/harness-gates-ls.sh"
GATE_SH="$ROOT/ci/bin/harness-gate.sh"
if [ -x "$REG_LS" ]; then
  GATES_TSV="$("$REG_LS")"
  _ck="$ROOT/ci/bin/audit_checks.py"
  if [ -f "$_ck" ]; then
    "$HARNESS_PYTHON" "$_ck" gate-identity "$(_h_file)" "$GATE_SH" "$GATES_TSV"
    rc=$?
    [ "$rc" -eq 0 ] || fail=1
  fi
fi

# 运行回路/数据不变量闭环（suite 自检）：B 聚合逻辑必须委托 harness-runtime-check.sh（不内联循环），
# C 的数据不变量深模块 harness-data-check.sh 存在且 harness-close 规范指向它。
if [ -d "$ROOT/checklists/shared" ]; then
  RC_SH="$ROOT/ci/bin/harness-runtime-check.sh"
  [ -x "$RC_SH" ] || { echo "[audit] 缺少 ci/bin/harness-runtime-check.sh（运行回路聚合器）"; fail=1; }
  for yml in "$ROOT/ci/workflows/runtime-check.yml" "$ROOT/ci/gitlab/runtime-check.yml"; do
    [ -f "$yml" ] || continue
    if ! grep -q 'harness-runtime-check.sh' "$yml"; then
      echo "[audit] $yml 未委托 harness-runtime-check.sh"; fail=1
    elif grep -qE 'for s in .*_check\.sh' "$yml"; then
      echo "[audit] $yml 仍内联聚合循环（应委托 harness-runtime-check.sh）"; fail=1
    fi
  done
  DATA_SH="$ROOT/ci/bin/harness-data-check.sh"
  [ -x "$DATA_SH" ] || { echo "[audit] 缺少 ci/bin/harness-data-check.sh（数据不变量深模块）"; fail=1; }
  DELTA_SH="$ROOT/ci/bin/harness-data-delta.sh"
  [ -x "$DELTA_SH" ] || { echo "[audit] 缺少 ci/bin/harness-data-delta.sh（变化模型预检深模块）"; fail=1; }
  CLOSE_SKILL="$ROOT/skills/harness-close/SKILL.md"
  if [ -f "$CLOSE_SKILL" ] && ! grep -q 'harness-data-check.sh' "$CLOSE_SKILL"; then
    echo "[audit] harness-close 数据不变量规范未指向 harness-data-check.sh"; fail=1
  fi
  # keep 沉淀管道（D）：扫描/落盘脚本必须存在（workflows/keep-scan.yml 委托它们）
  KEEP_SCAN="$ROOT/ci/bin/harness-keep-scan.sh"
  KEEP_LAND="$ROOT/ci/bin/harness-keep-land.sh"
  [ -x "$KEEP_SCAN" ] || { echo "[audit] 缺少 ci/bin/harness-keep-scan.sh（keep 沉淀扫描）"; fail=1; }
  [ -x "$KEEP_LAND" ] || { echo "[audit] 缺少 ci/bin/harness-keep-land.sh（keep 沉淀落盘）"; fail=1; }
fi

# ── 跨项目复用 + 静态→运行时 两缝 staleness 告警（只读，先 warning 不 blocking，观察一段） ──
# 晋升侧：project-local 的 reuse:candidate 长期未晋升 → 提示 owner 晋升或退役
CANDIDATES_SH="$ROOT/ci/bin/harness-checklist-candidates.sh"
if [ -x "$CANDIDATES_SH" ]; then
  cand_out="$("$CANDIDATES_SH" 2>&1 || true)"
  cand_n="$(printf '%s\n' "$cand_out" | grep -c '^\[candidate\]' || true)"
  if [ "${cand_n:-0}" -gt 0 ]; then
    echo "[audit][warn] 存在 ${cand_n} 条 reuse:candidate 待 owner 晋升到 suite 源或退役（harness-checklist-candidates.sh 复核）" >&2
  fi
fi
# 纵向爬梯侧：runtime:data|log 项未落运行时契约 = 未爬满 rung 4
GAP_SH="$ROOT/ci/bin/harness-runtime-gap.sh"
if [ -x "$GAP_SH" ]; then
  gap_out="$("$GAP_SH" 2>&1 || true)"
  if printf '%s\n' "$gap_out" | grep -q '未爬满'; then
    echo "[audit][warn] 存在 runtime:data|log 项未爬满 rung 4（harness-runtime-gap.sh 列缺口，harness-close 收尾补齐契约+runtime-config）" >&2
  fi
fi
# ── 执行点可达性（**退役的正确依据**，取代消费日志）──────────────────────────────
# 判据：一个共享域里**只要还有 judge 项**，该域就必须被某条**命名路径**请求到 —— 否则那些项写了
# 也永远不会被执行，即 ADR-0012 决策 4 说的「死规则」。
#
# **为什么按「域里有没有 judge 项」判、而不是按域判**：确定性项的执行点在别处（`deterministic_rule`
# 指向 Semgrep 规则，由 `g_pitfall` 跑），根本不需要 checklist 路径 —— 按域判会把 `log`（LOG-001/002
# 全是 deterministic）误报成死域。确定性项的落盘另有校验（两段式那段已查 `deterministic_rule` 存在），
# 不在这里重复。
#
# **为什么不用消费日志判退役**：日志只能证明「有人用过」，证明不了「没人会用」，而退役需要的恰是后者。
# 实测反例：`a11y` 的日志里有 5 条消费记录（有人用过），但它照样该退役 —— 因为没有任何路径请求它。
# 两个信号冲突时可达性是对的：那 5 条是早期手工跑 loader 留下的，不代表任何评审真的带着它跑过。
#
# 命名路径两条（就这两条，穷尽）：
#   ① `judge-review.sh` 的 `target_domains()`（按目标自动带）—— 经 `--list-target-domains` 查询，
#      **不 sed 抽函数文本**（抽文本会随改名/换行静默失配，失配表现为「所有域都不可达」= 全量误报）；
#   ② 显式 `--checklist-domain <域>`（skill / ci / 文档里的**具体域**，不是 `<domain>` 占位符）。
# 判**红**：与「声明≠落盘」同类 —— 规则声明了适用，却没有任何执行点。
#
# 只查**共享层**：本地域可以由项目 ad-hoc 手工请求（skill 就是这么教的），不命名不等于死。
# 与下面消费新鲜度那条的分层口径一致（共享层=跨项目语境，本地层=本项目自己的事）。
if [ -x "$ROOT/ci/bin/judge-review.sh" ]; then
  _named="$("$ROOT/ci/bin/judge-review.sh" --list-target-domains 2>/dev/null \
    | while IFS=$'\t' read -r _t _d; do printf '%s ' $_d; done)"
  # 显式 flag 的具体域（逗号拆开）。只是**额外**命名来源：占位符 `<domain>` 不是已知域，
  # 由 python 侧与真实域集合比对时自然排除。
  _named="$_named$(grep -rhoE -- '--checklist-domain[= ][a-zA-Z0-9_-]+' \
      "$ROOT/skills" "$ROOT/ci" "$ROOT/README.md" 2>/dev/null \
    | sed -E 's/--checklist-domain[= ]//' | tr ',' '\n' | tr '\n' ' ')"
  _ck="$ROOT/ci/bin/audit_checks.py"
  if [ -f "$_ck" ]; then
    _ck_run 1 reachability "$ROOT" "$_named" "$SHARED_STORE_CFG"
  fi
fi

# 消费侧：judge 项在消费日志里的新鲜度。**两层分开报，语义不同**（ADR-0012 决策 4）。
#
# ADR-0012 决策 4 要求两种检测「至少其一」，并给了两种：
#   ① 链式回指（handoff_from / source_lesson）—— 已在别处落地；
#   ② **「N 天未消费」告警** —— 本段。
# 两者看见的问题不同：① 查断链，② 查「曾消费过、后来再没人用」。只有 ① 时，「7 月用过一次、
# 之后三个月无人问津」的项永远看不见 —— 而它和「从未用过」一样是候选。
#
# 阈值 HARNESS_STALE_DAYS（缺省 90）：告警**带阈值一起报**，否则读者无从判断「多久算久」。
# 是 warn 不是 fail：退役/删除是 owner 的决定，不是自动判罚。
#
# ── 为什么两层要分开、且判据强度不同 ──
# 此前只扫共享层（`.harness/checklists/` 被查字段有效性、不被查有没有人用），而**本地层恰恰是
# 这套检测最可靠的地方**：消费日志是 per-project 的 —— 共享项的「本 checkout 日志里没有」只说明
# **本项目**没用它（跨项目聚合是 ADR-0005 的「另议」），而本地项的唯一消费者就是本项目，
# 「日志里没有」= 「从未被注入」是**权威**判定。最可靠的那层原先没做。
#
# 但**语义不同，故不共用一个集合**：共享项报「退役候选」（跨项目复用语境的判断），
# 本地项报「**死守卫**」（写了但永远不会被注入）—— 把两者混成一个告警，就等于把
# 「本项目用不上」和「谁都永远用不上」混为一谈。
if [ -f "$ROOT/.harness/reports/checklist-consumed.log" ]; then
  _ck="$ROOT/ci/bin/audit_checks.py"
  if [ -f "$_ck" ]; then
    # judge 目标默认域的并集：传给 freshness，用于把本地「从未被注入」拆成结构性 vs 行为性（域不在并集
    # = 结构上不可能被自动注入；在并集 = 有默认路径却没走）。同 --list-target-domains，不 sed 抽函数文本。
    _named_domains="$("$ROOT/ci/bin/judge-review.sh" --list-target-domains 2>/dev/null \
      | while IFS=$'\t' read -r _t _d; do printf '%s ' $_d; done)"
    _ck_run 0 freshness "$ROOT/checklists/shared" "$ROOT/.harness/checklists" \
      "$ROOT/.harness/reports/checklist-consumed.log" "${HARNESS_STALE_DAYS:-90}" "$_named_domains"
  fi
fi

if [ "$fail" -ne 0 ]; then echo "[audit] 对账失败（声明≠落盘）"; return 1; fi
echo "[audit] 对账通过"
return 0
}

# ── 跑主体（输出实时透传 + 同时落 AUDIT_LOG），再按日志分类落 audit-last.json ──
# 主体里的 `return` 只退函数；`set +e` 是因为要自己接住非零退出码（门禁契约 0/1 原样透传）。
set +e
audit_main 2>&1 | tee "$AUDIT_LOG"
rc="${PIPESTATUS[0]}"
set -e

# 汇总落盘**绝不改退出码**：写失败只告警（同 MetricEvent 的「观测不阻断」口径，ADR-0012 决策 5）。
# 落盘失败时旧文件仍在 → 指标会显示陈旧汇总（带 ts），比「显示 0」可查。
if [ -x "$ROOT/ci/bin/audit_summary.py" ] || [ -f "$ROOT/ci/bin/audit_summary.py" ]; then
  "$HARNESS_PYTHON" "$ROOT/ci/bin/audit_summary.py" "$AUDIT_LOG" \
    "$ROOT/.harness/reports/audit-last.json" "$rc" || \
    echo "[audit][warn] audit-last.json 未落盘（audit_summary.py 退出非零）——指标将显示陈旧汇总" >&2
fi

exit "$rc"
