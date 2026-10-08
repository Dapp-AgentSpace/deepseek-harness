#!/usr/bin/env bash
# harness-llm.sh — 无头 LLM 调用深模块（prompt 型 runner：claude/traecli/opencode/api）。
# prompt 从 stdin 读入，LLM 输出到 stdout；退出码 0=成功 / 非零=失败（未知 runner / api 未实现 / 回退也失败）。
# 回退链（对齐 ADR-0001 决策3）：traecli 无 token → 回退 claude；回退的 claude 也未装才失败，不卡 harness。
# 结构化评审执行器 ocr（评审/扫描 → JSON 文件 → verdict）不是本 seam：judge-review.sh 单独处理。
# 用法: printf '%s' "$prompt" | harness-llm.sh <runner> [model]
#   <runner>  节点绑定的 runner（claude/traecli/opencode/api）
#   [model]   可选：显式模型（claude 分支透传 `--model`，覆盖 settings.json 默认；
#             judge-review.sh 把 identity.yaml 的 judge.model 作为第 2 参传入）
set -euo pipefail

runner="${1:?用法: harness-llm.sh <runner> [model]（prompt 走 stdin）}"
model="${2:-}"
prompt="$(cat)"

have() { command -v "$1" >/dev/null 2>&1; }

# prompt 一律**经 stdin** 交给 runner，不走 argv —— 走 argv 时大 prompt 会撞操作系统的命令行长度上限
# （Windows CreateProcess ≈32K 字符；`doc` 目标注入一份中等大小的 diff 就超了，报
# `Argument list too long` 且判据/对象都没送到）。`claude -p` 无参数即读 stdin，已实测。
# traecli/opencode 是否支持 stdin 未验证：仍走 argv，故大 prompt 在那两个 runner 上仍有此上限
# （已知限制，不静默——超限时 runner 自己会报错，不会假装评过）。
case "$runner" in
  traecli)
    if [ -z "${TRAECLI_PERSONAL_ACCESS_TOKEN:-}" ]; then
      if have claude; then
        printf '%s' "$prompt" | claude -p
      else
        echo "[llm] traecli 无 token 且 claude 未装，无法回退（请在 identity.yaml 把该节点 runner 改成 claude 或 opencode）" >&2
        exit 2
      fi
    else
      traecli exec "$prompt"
    fi;;
  opencode) opencode run "$prompt";;
  claude)
    # auth 引导（跨平台，防「配了 User 级环境变量但进程没继承」的洞）：
    # claude CLI 认证三选一 —— env ANTHROPIC_API_KEY / env ANTHROPIC_AUTH_TOKEN / OAuth 登录态。
    # Windows 上常见「User 级 reg 配了 token，但 harness 进程（bash → claude.cmd）没继承」：
    # 这里在进程 env 缺 token 时，从 HKCU\Environment 读 User 级 ANTHROPIC_AUTH_TOKEN 补上。
    # Unix 不处理（依赖 shell env / ~/.claude 配置，claude 自己会报未登录，不静默）。
    if [ -z "${ANTHROPIC_AUTH_TOKEN:-}" ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
      case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*)
          _tok="$(reg query 'HKCU\Environment' //v ANTHROPIC_AUTH_TOKEN 2>/dev/null | sed -n 's/.*REG_SZ[[:space:]]*//p' | tr -d '\r' || true)"
          if [ -n "$_tok" ]; then
            export ANTHROPIC_AUTH_TOKEN="$_tok"
            echo "[llm] claude：进程 env 无 token，已从 User 级环境变量注入 ANTHROPIC_AUTH_TOKEN" >&2
          fi
          ;;
      esac
    fi
    if [ -n "$model" ]; then
      printf '%s' "$prompt" | claude -p --model "$model"
    else
      printf '%s' "$prompt" | claude -p
    fi;;
  api)      echo "[llm] runner=api 未实现（留作扩展点）" >&2; exit 2;;
  *)        echo "[llm] 未知 runner: $runner" >&2; exit 2;;
esac
