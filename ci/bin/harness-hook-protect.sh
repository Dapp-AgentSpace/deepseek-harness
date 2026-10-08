#!/usr/bin/env bash
# harness-hook-protect.sh — 宿主层写时拦截：阻止 agent 越权改写受保护文件。
set -euo pipefail

# 定位被保护项目：宿主级 hook（指向 suite）须按 cwd 取「当前打开的项目」，否则会一直保护 suite 自己、
# 而不是用户所在项目；cwd 下无 .harness/（尚未 harness-init）时回退脚本所在仓库（per-project 装法）。
ROOT="$(pwd)"
[ -d "$ROOT/.harness" ] || ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROTECTED=(
  ".harness/identity.yaml"
  ".harness/contracts"
)

input="$(cat)"

# 提取目标路径：优先 jq，失败回退 sed，都失败则保守拒绝（不静默放行）
target=""
if command -v jq >/dev/null 2>&1; then
  target="$(echo "$input" | jq -r '.tool_input.file_path // .file_path // .path // empty' 2>/dev/null || true)"
fi
if [ -z "$target" ]; then
  target="$(echo "$input" | sed -nE 's/.*"file_path"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p')"
fi
if [ -z "$target" ]; then
  echo "[protect] 无法解析目标路径，保守拒绝"
  exit 1
fi

# 归一化到仓库绝对路径：解析 ../、//、尾斜杠与符号链接（realpath -m 容忍尚不存在的叶子）
canon_path() {
  # 只用了三种**都可移植**的形式，且都容忍「叶子尚不存在」：
  #   · GNU realpath 需 -m 才容忍不存在的叶子；**BSD/macOS 的 realpath 不接受 -m**（会报错）。
  #   · BSD/macOS 的 readlink **没有 -f**。
  # 两者混用时，`2>/dev/null` 会把失败吞成空串 → canon_path 返回空 → 路径比较全失效（静默）。
  # 故：GNU realpath 先试 -m；失败退到 cd+pwd -P（POSIX，解析 ../ 与符号链接）。
  if [ -d "$1" ]; then
    (cd "$1" 2>/dev/null && pwd -P) || echo "$1"
    return
  fi
  local d b
  d="$(dirname "$1")"; b="$(basename "$1")"
  if command -v realpath >/dev/null 2>&1 && realpath -m "$1" >/dev/null 2>&1; then
    realpath -m "$1"
  elif [ -d "$d" ]; then
    printf '%s/%s
' "$(cd "$d" && pwd -P)" "$b"
  else
    echo "$1"
  fi
}

target="${target#./}"
case "$target" in /*) ;; *) target="$ROOT/$target";; esac
target="$(canon_path "$target")"
[ -n "$target" ] || { echo "[protect] 无法解析目标路径，保守拒绝"; exit 1; }

for p in "${PROTECTED[@]}"; do
  canon="$(canon_path "$ROOT/$p")"
  [ -n "$canon" ] || { echo "[protect] 无法解析受保护路径 $p，保守拒绝"; exit 1; }
  if [ "$target" = "$canon" ] || [[ "$target" == "$canon"/* ]]; then
    echo "[protect] 拦截：$target 属于受保护路径，须经对应 harness skill 变更，禁止直接编辑。"
    exit 1
  fi
done
exit 0
