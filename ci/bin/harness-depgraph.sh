#!/usr/bin/env bash
# harness-depgraph.sh — 大仓依赖图抽取薄包装：栈探测 + 默认 module_root + 调 depgraph.py（tree-sitter 深模块）。
# 只读导航（ADR-0006）：出模块级依赖图（node=目录，edge=import 解析到目录）喂 judge，不下结论。
# 增量缓存（按文件内容 SHA-256）落 .harness/reports/depgraph-cache.json——派生数据，删了下次自动全量。
# tree-sitter 未装时 depgraph.py 清晰报错退出 2（大仓深分析才需要，见 ci/requirements-depgraph.txt）。
#
# 用法: harness-depgraph.sh [--stack <s>] [--module-root <dir>] [--fmt mermaid|json|facts] [--collapse N] [--no-cache]
set -euo pipefail
export PYTHONUTF8=1  # PEP 540: Windows 强制 UTF-8（避免 GBK 读/写中文出错）

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=harness-stack.sh
source "$ROOT/ci/bin/harness-stack.sh"
# shellcheck source=harness-identity.sh
source "$ROOT/ci/bin/harness-identity.sh"
# shellcheck source=harness-env.sh
source "$ROOT/ci/bin/harness-env.sh"

STACK=""
MODULE_ROOT=""
FMT="mermaid"
COLLAPSE="2"
NOCACHE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --stack) STACK="${2:-}"; shift 2;;
    --stack=*) STACK="${1#--stack=}"; shift;;
    --module-root) MODULE_ROOT="${2:-}"; shift 2;;
    --module-root=*) MODULE_ROOT="${1#--module-root=}"; shift;;
    --fmt) FMT="${2:-}"; shift 2;;
    --fmt=*) FMT="${1#--fmt=}"; shift;;
    --collapse) COLLAPSE="${2:-}"; shift 2;;
    --collapse=*) COLLAPSE="${1#--collapse=}"; shift;;
    --no-cache) NOCACHE="--no-cache"; shift;;
    *) echo "[depgraph] 未知参数: $1" >&2; exit 2;;
  esac
done

# 配置优先级：CLI --stack > identity judge.depgraph_stack（留空则多栈自动推导，见下）
[ -n "$STACK" ] || STACK="$(h_get depgraph_stack)"

# 配置优先级：CLI --module-root > identity judge.depgraph_module_root（相对仓库根，如 backend/src/main/java）
if [ -z "$MODULE_ROOT" ]; then
  MODULE_ROOT="$(h_get depgraph_module_root)"
  case "$MODULE_ROOT" in
    "") ;;
    /*) ;;                                   # 绝对路径直接用
    *) MODULE_ROOT="$ROOT/$MODULE_ROOT";;    # 相对路径拼到仓库根
  esac
fi
# 显式配置的 root 必须存在：配错了要响亮失败，不静默出空图（空图会被 judge 当无导航跳过 = 假绿）。
if [ -n "$MODULE_ROOT" ] && [ ! -d "$MODULE_ROOT" ]; then
  echo "[depgraph] 配置的 depgraph_module_root 不存在: $MODULE_ROOT" >&2
  exit 2
fi

# 多栈自动推导（无显式 --stack/--module-root、也无 identity 覆盖时）：按仓库清单（pom.xml / package.json
# / go.mod / Cargo.toml）枚举所有模块，逐栈抽图合并，节点按模块命名空间化（ADR-0006 大仓导航）。
if [ -z "$STACK" ] && [ -z "$MODULE_ROOT" ]; then
  SPECS="$(stack_detect_all)"
  if [ -n "$SPECS" ]; then
    WIN_ROOT="$(_winpath "$ROOT")"
    SPECS="$(printf '%s\n' "$SPECS" | while IFS=$'\t' read -r st p; do [ -n "$p" ] && printf '%s\t%s\n' "$st" "$(_winpath "$p")"; done)"
    printf '%s\n' "$SPECS" | "$HARNESS_PYTHON" "$(_winpath "$ROOT/ci/bin/depgraph.py")" --multi "$WIN_ROOT" - --fmt "$FMT" --collapse "$COLLAPSE" $NOCACHE
    exit
  fi
fi

# 单栈路径（显式 --stack / depgraph_stack，或无可探测模块时的兜底）：栈探测 + 默认 module_root。
[ -n "$STACK" ] || STACK="$(stack_detect)"
# 默认 module_root：把「源码根」指向模块/包边界所在目录（Java/Rust/Python 的 src-layout；Go 在仓库根）
if [ -z "$MODULE_ROOT" ]; then
  case "$STACK" in
    maven|gradle|java) MODULE_ROOT="$ROOT/src/main/java"; [ -d "$MODULE_ROOT" ] || MODULE_ROOT="$ROOT";;
    rust|python|npm|typescript) MODULE_ROOT="$ROOT/src"; [ -d "$MODULE_ROOT" ] || MODULE_ROOT="$ROOT";;
    *) MODULE_ROOT="$ROOT";;
  esac
fi

exec "$HARNESS_PYTHON" "$ROOT/ci/bin/depgraph.py" "$ROOT" "$STACK" "$MODULE_ROOT" --fmt "$FMT" --collapse "$COLLAPSE" $NOCACHE
