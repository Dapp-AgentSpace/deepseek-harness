#!/usr/bin/env bash
# harness-notify.sh — 本地系统通知薄适配器（ADR-0004）。只在本地（非 CI）触发系统 app notification；
# CI 环境只落日志（CI 已有邮件/issue 通知路径）。通知瞬时、落盘持久，两者并存。
#
# 用法: harness-notify.sh <title> <body>
# 退出码: 0=已弹通知 / 2=无可用系统通知命令（已落日志；调用方不应因通知失败而失败）
set -euo pipefail

emit() { printf '[notify] %s\n' "$1" >&2; }

TITLE="${1:-Harness}"
BODY="${2:-}"
# 通知内容是「数据」不是「代码」：剥掉控制字符（换行/制表等），既防 osascript/powershell 注入，也保日志 TSV 不被换行拆坏。
sanitize() { printf '%s' "$1" | tr -d '\000-\037\177'; }
TITLE="$(sanitize "$TITLE")"
BODY="$(sanitize "$BODY")"
LOG="${HARNESS_NOTIFY_LOG:-$HOME/.harness/notifications.log}"
mkdir -p "$(dirname "$LOG")"

ts="$(date +%Y-%m-%dT%H:%M:%S%z)"

# CI 环境不弹桌面通知（GitHub/GitLab/通用 CI 任一命中）——CI 已有邮件/issue 通知路径
if [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ] || [ -n "${GITLAB_CI:-}" ]; then
  printf '%s\tCI(skip desktop)\t%s\t%s\n' "$ts" "$TITLE" "$BODY" >> "$LOG"
  exit 0
fi

notified=0
if   command -v osascript >/dev/null 2>&1; then        # macOS
  osascript -e "display notification \"$(printf '%s' "$BODY" | sed 's/\\/\\\\/g; s/"/\\"/g')\" with title \"$(printf '%s' "$TITLE" | sed 's/\\/\\\\/g; s/"/\\"/g')\"" >/dev/null 2>&1 && notified=1
elif command -v notify-send >/dev/null 2>&1; then      # Linux (libnotify)
  notify-send "$TITLE" "$BODY" >/dev/null 2>&1 && notified=1
elif command -v zenity >/dev/null 2>&1; then           # Linux 回退 (GTK)
  zenity --notification --text="$TITLE: $BODY" >/dev/null 2>&1 && notified=1
elif command -v kdialog >/dev/null 2>&1; then          # Linux 回退 (KDE)
  kdialog --title "$TITLE" --passivepopup "$BODY" 5 >/dev/null 2>&1 && notified=1
elif command -v powershell.exe >/dev/null 2>&1; then   # Windows (WSL/Git Bash)，需 BurntToast 模块
  # 内容经环境变量传入（$env:… 读取），命令行本身是静态的——杜绝内容被解析为 PowerShell 代码（命令注入）。
  HARNESS_NOTIFY_TITLE="$TITLE" HARNESS_NOTIFY_BODY="$BODY" \
    powershell.exe -NoProfile -Command "New-BurntToastNotification -Text \$env:HARNESS_NOTIFY_TITLE,\$env:HARNESS_NOTIFY_BODY" >/dev/null 2>&1 && notified=1
fi

if [ "$notified" -eq 1 ]; then
  printf '%s\tnotified\t%s\t%s\n' "$ts" "$TITLE" "$BODY" >> "$LOG"
  exit 0
else
  printf '%s\tfallback(log only)\t%s\t%s\n' "$ts" "$TITLE" "$BODY" >> "$LOG"
  emit "无可用系统通知命令，仅落日志: $TITLE — $BODY"
  exit 2
fi
