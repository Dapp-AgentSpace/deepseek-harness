#!/usr/bin/env bash
# harness-env.sh — 环境解析库（source 后使用，勿直接执行）。
#
# 为什么存在：解释器与外部工具的**探测**此前散落在 ~20 个 ci/bin 脚本顶部（每处重复
# `python3 -c 'pass'` 实跑守卫）。本库把这件「本机相关、只需解析一次」的事收成单源：
#   - 优先读 .harness/toolchain.env（harness-preflight.sh 生成的本机解析缓存，**不入库**）；
#   - 缓存缺失/失效则回退到即时探测（与历史行为一致，保证未跑 preflight 也能工作）。
#
# 与 attention.md 的分工（务必分清）：
#   attention.md        = **项目通用**的高频事实，随源码入库；
#   本库/ toolchain.env = **本机相关**的依赖路径，缓存不入库（见 .gitignore）。
#
# 提供（source 后可用）：
#   HARNESS_PYTHON   要调用的解释器（优先绝对路径，回退为命令名）
#   HARNESS_ENV_OK   1=解释器可用 / 0=不可用（供调用方决定是否 exit 2）
#   PYTHONUTF8       已 export=1（Python 类 CLI 的共性前提，见 harness-gate.sh 头注释）
#   py_ok            0=可用（即 HARNESS_ENV_OK=1）
#
# 覆盖优先级：HARNESS_TEST_PYTHON > 调用方预设的 HARNESS_PYTHON > toolchain.env 缓存 > 即时探测。

: "${ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
HARNESS_LOCAL_ENV="$ROOT/.harness/toolchain.env"

harness_env__fp() {
  printf '%s-%s' "$(uname -s 2>/dev/null || echo unknown)" "$(uname -m 2>/dev/null || echo unknown)"
}

# 即时探测：把 HARNESS_PYTHON 落到一个**实跑得起来**的解释器。恒返回 0，可用性写 HARNESS_ENV_OK。
harness_env__resolve() {
  local c
  HARNESS_ENV_OK=0
  for c in "${HARNESS_PYTHON:-}" python3 python; do
    [ -n "$c" ] || continue
    if command -v "$c" >/dev/null 2>&1 && "$c" -c 'pass' >/dev/null 2>&1; then
      HARNESS_PYTHON="$(command -v "$c")"
      HARNESS_ENV_OK=1
      return 0
    fi
  done
  : "${HARNESS_PYTHON:=python3}"   # 探测不到也留个名字（调用方据 HARNESS_ENV_OK=0 报错）
  return 0
}

# 调用方在 source 前显式设的 HARNESS_PYTHON（覆盖优先，区别于缓存里的值）
_harness_env_pre="${HARNESS_PYTHON:-}"

# 载入本机缓存（信任其内容；有效性在下面廉价复核）
if [ -f "$HARNESS_LOCAL_ENV" ]; then
  # shellcheck disable=SC1090
  . "$HARNESS_LOCAL_ENV"
fi

if [ -n "${HARNESS_TEST_PYTHON:-}" ]; then
  HARNESS_PYTHON="$HARNESS_TEST_PYTHON"; harness_env__resolve
elif [ -n "$_harness_env_pre" ]; then
  HARNESS_PYTHON="$_harness_env_pre"; harness_env__resolve
elif [ -n "${HARNESS_PYTHON:-}" ] && [ "${HARNESS_ENV_OS:-}" = "$(harness_env__fp)" ] && [ -x "$HARNESS_PYTHON" ]; then
  # 缓存有效：信任，**不再实跑探测**（这正是「不每次校验、减少失败与重试」的省）。
  # 只做一行存在性检查（[ -x ]）—— 工具被卸载/移动即失效，避免陈旧缓存变假绿。
  HARNESS_ENV_OK=1
else
  HARNESS_PYTHON="$_harness_env_pre"
  harness_env__resolve
fi

export PYTHONUTF8=1
export HARNESS_PYTHON HARNESS_ENV_OK
py_ok() { [ "${HARNESS_ENV_OK:-0}" = 1 ]; }
