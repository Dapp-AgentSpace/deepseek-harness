#!/usr/bin/env bash
# harness-hook-post-check.sh — 回合结束的快速确定性检查（仅告警，不阻塞）。
# 当前只查「存在未冻结 TSD」这一个信号（< 1s）。「测试红 / 契约漂移」需跑测试与对比契约，超出
# < 1s 预算，未在此实现。权威判定仍在 CI。
set -euo pipefail

# 同 harness-hook-protect.sh：宿主级 hook 按 cwd 取当前项目；cwd 下无 .harness/ 时回退脚本所在仓库。
ROOT="$(pwd)"
[ -d "$ROOT/.harness" ] || ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
warn=0

# 存在未冻结 TSD 时告警（正常应冻结后再实现）
for t in "$ROOT"/.harness/tsd/*.md; do
  [ -f "$t" ] || continue
  if ! grep -Eq '^[[:space:]]*tsd_frozen:[[:space:]]*true([[:space:]]*#.*)?$' "$t"; then
    echo "[post-check] 未冻结 TSD: $t"
    warn=1
  fi
done

[ "$warn" -eq 0 ] && echo "[post-check] 无告警"
exit 0
