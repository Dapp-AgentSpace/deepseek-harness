#!/usr/bin/env bash
# harness-gate.sh — 确定性权威门禁（串跑）。无 AI、无 LLM。退出码 0=绿 / 1=红 / 2=黄(未配置/需人工)。
# 门禁身份（key/名称/类型/开关）单源见 ci/gates.yaml；本脚本只按注册表顺序跑确定性门禁。
set -euo pipefail

# 门禁里凡是 **Python 写的**外部工具，都要 UTF-8 默认编码（PEP 540）。Windows 上默认是 GBK，
# 而 `semgrep` 本身是 Python 程序、用 `open()` 默认编码读规则文件 `ci/rules/pitfalls.yaml`（含中文）
# → `UnicodeDecodeError: 'gbk' codec can't decode byte 0x94` → semgrep 直接崩、退出码非零、
# **JSON 产出为空**，于是 g_pitfall 走 HOG-005 防护判红。判红本身是对的（「检查没跑」不能记黄），
# 但真因只藏在 stderr 的 traceback 里，从「坑库 失败」四个字看不出来。
# 实测：`semgrep --version` 有、`--config` 立刻崩；加本变量后 rc=0、JSON 正常。
# 放在门禁顶层而不是 g_pitfall 内：这是**这一类工具**（任何 Python 写的外部 CLI）的共性前提，
# 不是坑库一条门禁的特殊需要；子脚本会继承它（它们各自也 export，此处只是兜底）。
export PYTHONUTF8=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ID_FILE="$ROOT/.harness/identity.yaml"
# shellcheck source=harness-stack.sh
source "$ROOT/ci/bin/harness-stack.sh"
# shellcheck source=harness-identity.sh
source "$ROOT/ci/bin/harness-identity.sh"
# shellcheck source=harness-env.sh
source "$ROOT/ci/bin/harness-env.sh"   # 解释器/编码解析单源 + py_ok（缓存 .harness/toolchain.env 由 harness-preflight.sh 生成）
GATE_SCRIPT="$ROOT/harness.gates"
REG_LS="$ROOT/ci/bin/harness-gates-ls.sh"

red=0; yellow=0
emit() { printf '[harness-gate] %-6s %s\n' "$1" "$2"; }
have() { command -v "$1" >/dev/null 2>&1; }
# py_ok 由 ci/bin/harness-env.sh 提供（同款「命令在 ≠ 能跑」守卫：缓存有效时不实跑探测，失效即回退实跑）。

gate_on() {
  [ -f "$ID_FILE" ] && grep -qE "^[[:space:]]*${1}:[[:space:]]*true" "$ID_FILE"
}

[ -f "$ID_FILE" ] || { emit RED ".harness/identity.yaml 缺失，先跑 harness-init"; exit 1; }

# 项目自定义门禁优先（不发明命令，交给项目约定）
if [ -x "$GATE_SCRIPT" ]; then
  emit INFO "使用项目自定义门禁: $GATE_SCRIPT"
  "$GATE_SCRIPT"
  exit $?
fi

# ---- 确定性门禁执行器（key → g_<key>；身份在 ci/gates.yaml）----

# 静态检查（monorepo 感知：跑所有 Java 模块；非 Java 走 go/rust/JS/shell；不发明命令）
g_static() {
  local m d rc=0 found=0
  # Java：逐模块（monorepo 感知）跑构建；构建清单探测谓词来自共享深模块 harness-stack.sh
  while IFS= read -r m; do
    found=1
    d="${m%/*}"
    case "$m" in
      */pom.xml)
        if [ -x "$d/mvnw" ]; then (cd "$d" && ./mvnw -q -DskipTests verify 2>&1 | tail -50) || rc=1
        elif have mvn; then (cd "$d" && mvn -q -DskipTests verify 2>&1 | tail -50) || rc=1
        else [ "$rc" -eq 0 ] && rc=2; fi;;   # 未配置只把 0→2，不覆盖已有失败(1)
      *)
        if [ -x "$d/gradlew" ]; then (cd "$d" && ./gradlew -q check -x test 2>&1 | tail -50) || rc=1
        elif have gradle; then (cd "$d" && gradle -q check -x test 2>&1 | tail -50) || rc=1
        else [ "$rc" -eq 0 ] && rc=2; fi;;
    esac
  done < <(stack_manifests)
  [ "$found" -eq 1 ] && return "$rc"

  # 非 Java：go / rust / JS(lint script) / shell 兜底（栈探测优先级单一来源 stack_detect）
  case "$(stack_detect)" in
    go)
      have go || return 2
      (cd "$ROOT" && go vet ./... 2>&1 | tail -50);;
    rust)
      have cargo || return 2
      (cd "$ROOT" && cargo clippy --all-targets --all-features -- -D warnings 2>&1 | tail -50);;
    npm)
      local pj lrc=0 lint_found=0
      while IFS= read -r pj; do
        if grep -q '"lint"' "$pj" 2>/dev/null; then
          lint_found=1
          if ! (cd "$(dirname "$pj")" && npm run lint 2>&1 | tail -50); then lrc=1; fi
        fi
      done < <(stack_packages)
      [ "$lrc" -ne 0 ] && return 1
      [ "$lint_found" -eq 1 ] && return 0
      return 2;;
    *)
      # shell/unknown：bash -n 全部脚本（探测用 maxdepth 4 只做标签；实际 lint 须穷尽，故这里不设 maxdepth）
      # 不用 `xargs -0 -r`：BSD/macOS 的 xargs 没有 -r（GNU 专有）；而直接删 -r 又会在 GNU 上
      # 变成「无输入也跑一次无参 bash -n」而报错。while 循环两种平台都对。
      # `|| return 1`（不是 `|| exit 1`）：exit 会**终止整个 harness-gate.sh** —— 不打 RESULT 行、
      # 不记 MetricEvent、后续门禁全被跳过。语法错就该只让 static 判红，其余门禁照跑（同本函数其余分支）。
      while IFS= read -r _sh; do bash -n "$_sh" || return 1; done < <(
        find "$ROOT" -name '*.sh' -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null);;
  esac
}

# Schema / 契约校验
g_schema() {
  [ -f "$ROOT/harness.schema-check" ] || return 2
  bash "$ROOT/harness.schema-check"
}

# 坑库：Semgrep 结构化规则（AST 级，非字面 grep）。两层：
#   - shared：ci/rules/pitfalls.yaml（suite 源，随 upgrade 同步）
#   - project-local：.harness/pitfalls.yaml（语义层，upgrade 不覆盖，由 harness-keep-land.sh 落盘）
# 两个都读；都没有 = 黄(未配置)。退出码 0=无命中 / 1=有命中 / 2=出错 —— 与 grep 约定对齐，HOG-005「不吞 exit 2」防护同样适用。
# 注意这条 0/1 语义**依赖 `--error`**：semgrep scan 默认命中时也退 0（详见函数内注释）。
g_pitfall() {
  local CONFIGS=()
  [ -f "$ROOT/ci/rules/pitfalls.yaml" ] && CONFIGS+=(--config "$ROOT/ci/rules/pitfalls.yaml")
  [ -f "$ROOT/.harness/pitfalls.yaml" ] && CONFIGS+=(--config "$ROOT/.harness/pitfalls.yaml")
  [ "${#CONFIGS[@]}" -gt 0 ] || return 2
  have semgrep || return 2            # 未装 semgrep = 黄(未配置)，不假绿
  mkdir -p "$ROOT/.harness/reports"
  local json_file="$ROOT/.harness/reports/pitfall-last.json"
  local err_file="$ROOT/.harness/reports/pitfall-last.err"
  local rc
  # stdout=JSON 直接落 pitfall-last.json（供 harness-measure.sh 读每规则命中数）；stderr=进度另存，两路不混（否则 JSON 被进度行污染）
  # `--error` 不能省：semgrep scan 默认**命中时也退 0**（1.177.0 实测：有命中 rc=0、`--error` 后 rc=1），
  # 少了它就是「有命中 → rc=0 → return 0」的假绿——坑库是铁律门禁，假绿比漏报更糟。
  # 依据是 semgrep 自己的退出码契约，不另解析 JSON（JSON 仍落盘供 harness-measure.sh 用）。
  set +e
  semgrep scan "${CONFIGS[@]}" --error --json "$ROOT" > "$json_file" 2> "$err_file"
  rc=$?                               # HOG-002：set +e 显式取 $?，不吞退出码
  set -e
  case "$rc" in
    0)
      # 无命中。但 semgrep 可能仍在 JSON 的 `errors[]` 里记了**非致命解析告警**（如 .sh 的 PartialParsing /
      # Syntax error，level=warn）—— 这些**不影响退出码**（非 findings），但**不静默吞**：报一行计数到 stderr，
      # 让「坑库其实没完整解析这些文件」可见（否则『无命中』与『没解析』长得一样 —— 同 HOG-005 的缺陷类）。
      # 判定仍只认退出码：告警级判红会是**永久假红**（.sh 的 PartialParsing 无法消除），故不改判。
      local _nwarn
      _nwarn="$(grep -oE '"level"[[:space:]]*:[[:space:]]*"warn"' "$json_file" 2>/dev/null | wc -l | tr -d '[:space:]')"
      if [ -n "$_nwarn" ] && [ "$_nwarn" -gt 0 ]; then
        printf '[harness-gate] %-6s %s\n' WARN "坑库：semgrep 报 ${_nwarn} 条解析告警（errors[]，非 findings，不影响判定；.sh 的 PartialParsing 常见）" >&2
      fi
      # 扫描范围**显式披露**：semgrep 默认忽略表含 `tests/` 等、且只扫 git 跟踪文件。本仓坑库规则针对
      # **产品源码 .sh**，`tests/` 是测试夹具 —— **范围有意如此**（owner 2026-09-26 明确「不需要扫 tests」）。
      # 但**不静默**：把「跳过 N 文件」报出来，让「没命中」与「没扫」可区分（同 HOG-005 缺陷类）。
      local _nskip
      _nskip="$(sed -nE 's/.*Files matching \.semgrepignore patterns: ([0-9]+).*/\1/p' "$err_file" 2>/dev/null | head -1)"
      if [ -n "$_nskip" ] && [ "$_nskip" -gt 0 ]; then
        printf '[harness-gate] %-6s %s\n' WARN "坑库：semgrep 跳过 ${_nskip} 个文件（默认忽略 tests/ 等 + 只扫 git 跟踪文件）—— 扫描范围=产品 .sh，非『没命中』；tests/ 无需扫（owner 定）" >&2
      fi
      return 0;;
    1) cat "$json_file" >&2; cat "$err_file" >&2; return 1;;   # 有命中 = 红
    *) cat "$json_file" >&2; cat "$err_file" >&2; return 1;;   # semgrep 出错(exit 2) = 红，不吞错误
  esac
}

# 依赖安全：trivy fs 扫漏洞 + 许可证，判定归 ci/bin/depcheck.py（判据单源 ci/dep-policy.yaml）。
# 全量判定、不看 diff：存量既成事实靠 .harness/dep-policy.yaml 的 ignore 逐条登记（带 reason/expires），
# 不靠静默豁免 —— 「已接受的风险」必须是留痕的决定，否则就是无声的绿。
# 退出码：无清单/未装 trivy/无策略 = 2（黄，不假绿）；有 blocking = 1；trivy 跑失败 = 1（不吞错误，
# 同 g_pitfall 的 HOG-005 防护——DB 拉不下来也必须响亮，不能静默放行）；python3 跑不起来 = 1
# （判据评估不了 ≠ 未配置，记黄就等于「检查没跑也不算红」）。
g_dep() {
  local POLICY="$ROOT/ci/dep-policy.yaml"
  [ -f "$POLICY" ] || return 2                       # 无策略 = 未配置
  # 不用 `stack_dep_files | grep -q .`：本脚本 set -o pipefail，grep -q 首个匹配即退出会让上游
  # sort 收到 SIGPIPE → 管道非零 → 明明有依赖却报「本仓无依赖清单」= 黄（同 scaffold 的那处，
  # ocr round-3 #5；当时只修了 scaffold，此处漏掉 —— doc round-4 I4 抓出）。
  local _depf; _depf="$(stack_dep_files)"
  [ -n "$_depf" ] || return 2                        # 本仓无依赖清单/锁文件 = 该门禁不适用
  have trivy || return 2                             # 未装 trivy = 黄（同 g_pitfall 对 semgrep）
  # python3 不可用不是「未配置」而是「检查根本没跑」——必须红，不能记黄混过去（见 py_ok 注释）。
  py_ok || { emit RED "python3 不可用（命令存在但执行失败）——依赖未检查，不放行"; return 1; }
  mkdir -p "$ROOT/.harness/reports"
  local json_file="$ROOT/.harness/reports/dep-last.json"
  local err_file="$ROOT/.harness/reports/dep-last.err"
  # trivy 找不到问题也返回 0，故不靠它的退出码判定；退出码只用来区分「跑没跑成」。
  set +e
  trivy fs --quiet --scanners vuln,license --format json --output "$json_file" "$ROOT" \
    > /dev/null 2> "$err_file"
  local rc=$?
  set -e
  if [ "$rc" -ne 0 ]; then
    cat "$err_file" >&2
    emit RED "trivy 执行失败（exit $rc）——依赖未检查，不放行"
    return 1
  fi
  # 报告带 project.id 前缀 + project: frontmatter —— .harness/reports/*.md 的产出注入核对
  # （closed-loop-audit.sh:80-93）要求如此，缺则 audit 红。
  local pid; pid="$(h_id)"
  set +e
  "$HARNESS_PYTHON" "$ROOT/ci/bin/depcheck.py" "$json_file" \
    --policy "$POLICY" \
    --policy-local "$ROOT/.harness/dep-policy.yaml" \
    --project "$pid" \
    --report "$ROOT/.harness/reports/${pid:-dep}-dep-last.md"
  local drc=$?
  set -e
  case "$drc" in
    0) return 0;;
    1) return 1;;
    *) return 2;;     # 策略缺失/JSON 不可解析 = 需人工
  esac
}

# 兼容性：仓库声明的「最低支持版本」vs 策略基线（判据单源 ci/compat-policy.yaml，
# 判定归 ci/bin/compatcheck.py；清单发现归 harness-stack.sh 的 stack_compat_manifests，不在此重复谓词）。
# 全量判定、不看 diff：与 g_dep 同款「已知但接受必须留痕」纪律——存量低于基线也要 ignore + reason，
# 不靠静默豁免。只管「运行时/生态最低支持版本」声明；API 级 breaking change 需基线产物，不在此门禁
# 的声明式判定范围内（见 ci/compat-policy.yaml 头部）。
# 退出码：无清单/无策略 = 2（黄，不假绿）；有 blocking = 1；python3 跑不起来 = 1
# （判据评估不了 ≠ 未配置，记黄就等于「检查没跑也不算红」）。
g_compat() {
  local POLICY="$ROOT/ci/compat-policy.yaml"
  [ -f "$POLICY" ] || return 2                       # 无策略 = 未配置
  local manifests; manifests="$(stack_compat_manifests)"
  [ -n "$manifests" ] || return 2                    # 本仓无可判定清单 = 该门禁不适用
  py_ok || { emit RED "python3 不可用（命令存在但执行失败）——兼容性未检查，不放行"; return 1; }
  mkdir -p "$ROOT/.harness/reports"
  # 报告带 project.id 前缀 + project: frontmatter —— 同 g_dep，缺则 closed-loop-audit.sh 红。
  local pid; pid="$(h_id)"
  local drc=0
  set +e
  # 清单路径走 stdin 而非位置参数：多模块 monorepo 清单条数无上限，命令行长度会成为失败模式。
  # stdin 也**不会**被 MSYS 自动转 Windows 路径（只有参数会），故逐行过 _winpath 归一，
  # 否则原生 python 收到 /d/... 找不到文件（Linux/macOS 透传）。同 depgraph 的 stdin specs 处理。
  printf '%s\n' "$manifests" \
    | while IFS= read -r p; do [ -n "$p" ] && printf '%s\n' "$(_winpath "$p")"; done \
    | "$HARNESS_PYTHON" "$ROOT/ci/bin/compatcheck.py" \
    --policy "$POLICY" \
    --policy-local "$ROOT/.harness/compat-policy.yaml" \
    --project "$pid" \
    --report "$ROOT/.harness/reports/${pid:-compat}-compat-last.md"
  drc=$?
  set -e
  case "$drc" in
    0) return 0;;
    1) return 1;;
    *) return 2;;     # 策略格式非法/清单不可读 = 需人工
  esac
}

# 对账（确定性部分）：委托 closed-loop-audit.sh。原「绕过 gate() 的特判」收编进统一执行器。
g_audit() {
  local s="$ROOT/ci/bin/closed-loop-audit.sh"
  [ -x "$s" ] || return 2
  "$s"                                # 0=对账通过 / 1=声明未落盘
}

# ---- 跑确定性门禁：按 ci/gates.yaml 注册顺序，统一 0/1/2 语义 ----
[ -x "$REG_LS" ] || { emit RED "缺少 $REG_LS（门禁注册表读取器）"; exit 1; }
# 先读注册表 TSV 再跑，检查退出码：注册表缺失/解析失败若被吞，会静默跑 0 条门禁 → 假绿。
reg_tsv="$("$REG_LS")" || { emit RED "门禁注册表读取失败（$REG_LS 退出非零），禁止假绿"; exit 1; }
[ -n "$reg_tsv" ] || { emit RED "门禁注册表为空：无任何门禁被注册"; exit 1; }
while IFS=$'\t' read -r key name typ extra binding on_ramp; do  # binding/on_ramp 供 harness-run 分派；本脚本跑全部确定性门禁（binding=true 铁律），忽略 on_ramp
  [ "$typ" = "deterministic" ] || continue
  # 开关：identity.yaml 的 gates.<key>（key 即叶子，执行器函数 g_<key>）
  if ! gate_on "$key"; then emit INFO "$name 跳过（gates.$key=false）"; continue; fi
  if "g_$key"; then emit GREEN "$name 通过"; grc=0; else
    grc=$?
    if [ "$grc" -eq 2 ]; then emit YELLOW "$name 未配置（gates.$key=true 但缺可执行校验）"; yellow=$((yellow+1)); else emit RED "$name 失败"; red=1; fi
  fi
  # MetricEvent：门禁结果观测（ADR-0012 决策 5）。观测不阻断 —— 写失败也不改门禁退出码。
  # `--run`（ADR-0016 决策 2）：harness-run 跑链路时注入 HARNESS_RUNCARD，事件据此归到该 run；
  # 取不到（手工单跑）就不带该字段（缺 run = 未归属，不伪造）。
  "$ROOT/ci/bin/harness-metric.sh" verify "gate.$key" "$grc" --source "g_$key" --run "${HARNESS_RUNCARD:-}" >/dev/null 2>&1 || true
done <<< "$reg_tsv"

if [ "$red" -ne 0 ]; then emit RESULT "RED"; exit 1; fi
if [ "$yellow" -gt 0 ]; then emit RESULT "YELLOW ($yellow 项未配置/未启用)"; exit 2; fi
emit RESULT "GREEN"
exit 0
