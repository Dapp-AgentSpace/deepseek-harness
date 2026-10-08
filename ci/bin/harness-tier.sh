#!/usr/bin/env bash
# harness-tier.sh — 风险嗅探深模块（确定性、无 AI）：从 diff 嗅探本次改动是重风险 full（触碰契约信号）
#   还是轻风险 light（纯实现/bug 修）。full/light 是 judge 节点 on_ramp 的档位信号（见 ci/gates.yaml），
#   不再是「分档套餐」——铁律（binding=true）与它无关，永远跑。
#
# 原则：
#   - full/light 由本脚本从 diff 确定性嗅探，开发者不手动选（手动选 = 可绕过的开关）；
#   - 嗅探信号与 TSD「契约变化或不变」同源：只认「是否触碰契约/对外接口/数据模型/依赖」；
#   - 不确定、无 diff、或 git 不可用时默认 full（宁可多查，不可漏检——漏检才是危险失败模式）；
#   - 嗅探可审计：--why 把触发 full 的规则与文件打到 stderr，供 quality 节点回头验证「风险档判定对不对」。
#
# 用法: ./ci/bin/harness-tier.sh [--base <ref>] [--why] [ROOT]
#   --base <ref>   与 <ref> 比较（默认 HEAD：工作区未提交改动 + 未跟踪新文件）
#   --why          打印触发 full 的规则与文件到 stderr
# 退出码: 0=成功（stdout 输出 light 或 full）；非 0=无法判定，调用方按 full 处理
set -euo pipefail

ROOT=""; BASE=""; WHY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="${2:-}"; shift 2;;
    --why)  WHY=1; shift;;
    *)      ROOT="$1"; shift;;
  esac
done
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

emit() { printf '[harness-tier] %s\n' "$1" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }
hit() { [ "$WHY" -eq 1 ] && emit "FULL · $1 · $2"; }
# 依赖清单的判据归 harness-stack.sh（**单一真源**）—— 本脚本此前手抄了同一份 21 个文件名，
# 而 arch.md 的 B5 明写「栈探测谓词一律从它读，不复制第二份」。抄一份的代价：加一个生态要改两处，
# 漏一处的表现是「tier 判 light 而 dep 门禁判有依赖」两套事实不一致。
# shellcheck source=harness-stack.sh
source "$ROOT/ci/bin/harness-stack.sh"

# classify_file <path>：输出 0 = full（触碰契约信号）/ 1 = light。
# 顺序即优先级：先 harness 契约本身，再 依赖/接口/数据模型；测试与文档落到底返回 light。
classify_file() {
  local f="$1" bn
  bn="$(basename "$f")"

  # 1) harness 契约/治理文件（.harness/ 本身：contracts/tsd/identity/checklists 等）
  case "$f" in
    .harness/*|*/.harness/*) hit "harness 契约/治理" "$f"; return 0;;
  esac

  # 2) 依赖清单（增删依赖改变构建边界与契约）—— 判据从 harness-stack.sh 读，不在此抄清单
  if stack_is_dep_manifest "$bn"; then
    hit "依赖清单" "$f"; return 0
  fi

  # 3) 对外接口表面 + 请求/响应传输对象（契约核心信号）
  case "$f" in
    */controller/*|*/controllers/*|*/web/*|*/api/*|*/dto/*|*/vo/*|*/routes/*|*/endpoint/*)
      hit "对外接口层" "$f"; return 0;;
  esac
  case "$bn" in
    *Controller.*|*Response.*|*Request.*|*DTO.*|*Vo.*|*VO.*|*Endpoint.*|*Handler.*|*Resource.*)
      hit "接口/传输对象" "$f"; return 0;;
  esac

  # 4) 数据模型 / schema / 迁移（schema 变化 = 契约变化）
  case "$f" in
    */model/*|*/models/*|*/entity/*|*/entities/*|*/schema/*|*/migrations/*|*/migration/*)
      hit "数据模型/schema" "$f"; return 0;;
  esac
  case "$bn" in
    *Migration.*|schema.*|*Schema.*) hit "迁移/DDL" "$f"; return 0;;
  esac

  return 1   # light：bug 修 / 纯实现内部 / 文档 / 测试 / 其他非契约配置
}

cd "$ROOT" || { emit "无法进入 $ROOT"; exit 2; }
if ! have git; then
  emit "无 git，无法判定 diff，默认 full"
  echo full
  exit 0
fi

# 收集改动文件：已跟踪改动（M/A/D/R）+ 未跟踪新文件。两者并集，避免新 controller/model 未 add 时漏判。
if [ -n "$BASE" ]; then
  files="$( { git diff --name-only --diff-filter=ACDMR "$BASE" 2>/dev/null; \
              git ls-files --others --exclude-standard 2>/dev/null; } | sort -u )"
else
  files="$( { git diff --name-only --diff-filter=ACDMR HEAD 2>/dev/null; \
              git ls-files --others --exclude-standard 2>/dev/null; } | sort -u )"
fi

if [ -z "$files" ]; then
  emit "无改动文件（空 diff），默认 full"
  echo full
  exit 0
fi

full=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if classify_file "$f"; then
    full=1
  fi
done <<< "$files"

if [ "$full" -eq 1 ]; then
  echo full
else
  [ "$WHY" -eq 1 ] && emit "未命中契约信号 → light"
  echo light
fi
