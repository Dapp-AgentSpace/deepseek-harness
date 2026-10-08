#!/usr/bin/env bash
# harness-data-trace-init.sh — data trace 只读接口脚手架（ADR-0017 决策 2）。
# 按技术栈生成 .harness/data_trace/ 的**只读骨架**：统一入口 CLI + manifest + source.yaml + README。
# 骨架能跑（ping / list-entities），但真实连接（DSN / 只读凭据 / UAT 端点）由 owner 填，**不进仓库**；
# 连接未配置时 query 返回 exit 2（「连接未配置，须 owner 提供只读连接」），不假绿。
#
# 用法: harness-data-trace-init.sh [python|java|node] [--force]
#   stack 缺省按 harness-stack 探测（maven/gradle→java, npm→node, python→python, 其它→python 兜底）。
#   --force：接口目录已存在时仍重新生成骨架（覆盖 cli 入口与 manifest 模板；已有实体条目保留）。
# 幂等：不传 --force 且目录已存在时拒绝覆盖，提示用 --force。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=harness-stack.sh
source "$ROOT/ci/bin/harness-stack.sh"

STACK=""
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    *) if [ -z "$STACK" ]; then STACK="$arg"; fi ;;
  esac
done
if [ -z "$STACK" ]; then
  case "$(stack_detect)" in
    maven|gradle) STACK=java ;;
    npm)          STACK=node ;;
    python)       STACK=python ;;
    *)            STACK=python ;;
  esac
fi
case "$STACK" in
  python|java|node) ;;
  *) echo "[data-trace-init] 未知栈: $STACK（python|java|node）" >&2; exit 2;;
esac

DT="${HARNESS_DATA_TRACE_DIR:-$ROOT/.harness/data_trace}"
if [ -d "$DT" ] && [ "$FORCE" -ne 1 ]; then
  echo "[data-trace-init] $DT 已存在（拒绝覆盖；--force 重新生成骨架，已有 manifest 实体保留）" >&2
  exit 2
fi
mkdir -p "$DT"

# 保留既有 manifest 实体（--force 时不清空已批准方法集）
OLD_MANIFEST=""
if [ -f "$DT/manifest.yaml" ] && [ "$FORCE" -eq 1 ]; then
  OLD_MANIFEST="$(awk '/^entities:/{f=1;next} /^[^[:space:]#]/{if(f)exit} f && /^  [A-Za-z0-9_.-]+:$/{gsub(/[:[:space:]]*$/,"",$1);print $1}' "$DT/manifest.yaml")"
fi

write_manifest() {
  cat > "$DT/manifest.yaml" <<'EOF'
# manifest.yaml — data trace 已批准方法集（ADR-0017 决策 5 的人工审核锚）。
# 新增数据获取方法须 owner 审核（只读性 + 用途）后在此追加并留痕；实现多出方法 → need-human。
# 语法：entities: 下每实体一行，附 reviewed_by + reviewed_at（缺任一 = 未审核，check 判 need-human）。
entities:
EOF
  if [ -n "$OLD_MANIFEST" ]; then
    printf '%s\n' "$OLD_MANIFEST" | while IFS= read -r ent; do
      printf '  %s:\n    reviewed_by: owner\n    reviewed_at: 2026-10-02\n' "$ent"
    done >> "$DT/manifest.yaml"
  fi
  cat >> "$DT/manifest.yaml" <<'EOF'
  # 示例（批准方法后取消注释并填审核人/日期）：
  # OrderRecord:
  #   reviewed_by: owner
  #   reviewed_at: 2026-10-02
EOF
}

write_source() {
  cat > "$DT/source.yaml" <<'EOF'
# source.yaml — 数据源声明（ADR-0017 决策 3：CLI 统一访问面，数据源可插拔）。
# source: local = adapter 直连项目 DB/文件（只读连接）；uat = adapter 代理 UAT 只读 API。
# entry: 统一入口覆盖（缺省自动探测 cli.py / cli.mjs / cli.sh）。owner 填连接信息，不进仓库。
source: local
# entry: python3 cli.py
# uat:
#   endpoint: https://uat.example.com/data-trace/query
#   # token 走 HARNESS_DATA_TOKEN（CI secrets）或此处配置；adapter 代理并归一化为 EntityData
EOF
}

# ── Python 骨架：cli.py（argparse），DATA_TRACE_SOURCE_FILE 指向 JSON {"Entity": [items]} ──
write_python() {
  cat > "$DT/cli.py" <<'EOF'
#!/usr/bin/env python3
# data trace 只读骨架（Python 栈，ADR-0017）。只读：仅实现 ping/list-entities/query/describe。
# 数据源（owner 配，不进仓库）：DATA_TRACE_SOURCE_FILE 指向 JSON {"Entity": [{...}, ...]}，
# 或替换 load_source() 为直连项目 DB 的只读查询（DSN 走 env，不进仓库）。
# 连接未配置时 query/describe 返回 exit 2，不假绿。
import json
import os
import sys

SOURCE_FILE = os.environ.get("DATA_TRACE_SOURCE_FILE", "")

def load_source():
    if not SOURCE_FILE or not os.path.isfile(SOURCE_FILE):
        return None
    with open(SOURCE_FILE, encoding="utf-8") as f:
        return json.load(f)

def ping():
    print(json.dumps({"ok": True, "impl": "python", "version": 1}, ensure_ascii=False))

def list_entities():
    data = load_source()
    ents = sorted(data.keys()) if data else []
    print(json.dumps({"entities": ents}, ensure_ascii=False))

def query(entity, where):
    data = load_source()
    if data is None:
        sys.stderr.write("连接未配置：DATA_TRACE_SOURCE_FILE 未设置或无此文件，须 owner 提供只读连接\n")
        sys.exit(2)
    if entity not in data:
        print(json.dumps({"entity": entity, "count": 0, "items": []}, ensure_ascii=False))
        return
    items = data[entity]
    for cond in where:
        field = cond.get("field")
        value = cond.get("value")
        if not field:
            continue
        def match(item):
            parts = field.split(".")
            v = item
            for p in parts:
                if isinstance(v, dict) and p in v:
                    v = v[p]
                else:
                    return False
            return str(v) == str(value)
        items = [it for it in items if match(it)]
    print(json.dumps({"entity": entity, "count": len(items), "items": items}, ensure_ascii=False))

def describe(entity):
    data = load_source()
    if data is None:
        sys.stderr.write("连接未配置：DATA_TRACE_SOURCE_FILE 未设置或无此文件，须 owner 提供只读连接\n")
        sys.exit(2)
    fields = {}
    items = data.get(entity, [])
    if items and isinstance(items[0], dict):
        fields = {k: type(v).__name__ for k, v in items[0].items()}
    print(json.dumps({"entity": entity, "fields": fields}, ensure_ascii=False))

def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "ping":
        ping()
    elif cmd == "list-entities":
        list_entities()
    elif cmd == "query":
        entity = sys.argv[2] if len(sys.argv) > 2 else ""
        where = []
        if "--where" in sys.argv:
            wi = sys.argv.index("--where")
            if len(sys.argv) > wi + 1:
                try:
                    where = json.loads(sys.argv[wi + 1])
                except json.JSONDecodeError:
                    sys.stderr.write("--where 须为 JSON 列表 [{field, value}, ...]\n")
                    sys.exit(2)
        if not entity:
            sys.stderr.write("query 缺 entity\n")
            sys.exit(2)
        query(entity, where)
    elif cmd == "describe":
        entity = sys.argv[2] if len(sys.argv) > 2 else ""
        if not entity:
            sys.stderr.write("describe 缺 entity\n")
            sys.exit(2)
        describe(entity)
    else:
        sys.stderr.write("未知命令（ping|list-entities|query <entity> --where <json>|describe <entity>）\n")
        sys.exit(2)

if __name__ == "__main__":
    main()
EOF
  chmod +x "$DT/cli.py"
}

# ── Node 骨架：cli.mjs（同构契约），数据源同 DATA_TRACE_SOURCE_FILE ──
write_node() {
  cat > "$DT/cli.mjs" <<'EOF'
// data trace 只读骨架（Node 栈，ADR-0017）。只读：仅实现 ping/list-entities/query/describe。
// 数据源（owner 配，不进仓库）：DATA_TRACE_SOURCE_FILE 指向 JSON {"Entity": [{...}, ...]}。
// 连接未配置时 query/describe 返回 exit 2，不假绿。
import { readFileSync } from "node:fs";

const SOURCE_FILE = process.env.DATA_TRACE_SOURCE_FILE || "";

function loadSource() {
  try {
    return JSON.parse(readFileSync(SOURCE_FILE, "utf8"));
  } catch {
    return null;
  }
}

function ping() { console.log(JSON.stringify({ ok: true, impl: "node", version: 1 })); }

function listEntities() {
  const data = loadSource();
  const ents = data ? Object.keys(data).sort() : [];
  console.log(JSON.stringify({ entities: ents }));
}

function matchItem(item, field, value) {
  let v = item;
  for (const p of field.split(".")) {
    if (v && typeof v === "object" && p in v) v = v[p];
    else return false;
  }
  return String(v) === String(value);
}

function query(entity, where) {
  const data = loadSource();
  if (!data) {
    process.stderr.write("连接未配置：DATA_TRACE_SOURCE_FILE 未设置或无此文件，须 owner 提供只读连接\n");
    process.exit(2);
  }
  let items = data[entity] || [];
  for (const cond of where || []) {
    const field = cond?.field;
    const value = cond?.value;
    if (!field) continue;
    items = items.filter((it) => matchItem(it, field, value));
  }
  console.log(JSON.stringify({ entity, count: items.length, items }));
}

function describe(entity) {
  const data = loadSource();
  if (!data) {
    process.stderr.write("连接未配置：DATA_TRACE_SOURCE_FILE 未设置或无此文件，须 owner 提供只读连接\n");
    process.exit(2);
  }
  const items = data[entity] || [];
  const fields = items[0] && typeof items[0] === "object"
    ? Object.fromEntries(Object.entries(items[0]).map(([k, v]) => [k, typeof v]))
    : {};
  console.log(JSON.stringify({ entity, fields }));
}

const [,, cmd, entity, flag, whereArg] = process.argv;
if (cmd === "ping") ping();
else if (cmd === "list-entities") listEntities();
else if (cmd === "query") {
  let where = [];
  if (flag === "--where" && whereArg) { try { where = JSON.parse(whereArg); } catch { process.stderr.write("--where 须为 JSON 列表\n"); process.exit(2); } }
  if (!entity) { process.stderr.write("query 缺 entity\n"); process.exit(2); }
  query(entity, where);
}
else if (cmd === "describe") {
  if (!entity) { process.stderr.write("describe 缺 entity\n"); process.exit(2); }
  describe(entity);
}
else { process.stderr.write("未知命令（ping|list-entities|query <entity> --where <json>|describe <entity>）\n"); process.exit(2); }
EOF
  chmod +x "$DT/cli.mjs"
}

# ── Java 骨架：Cli.java（单文件源码启动，JDK 11+ `java Cli.java`）+ cli.sh 包装 ──
write_java() {
  cat > "$DT/Cli.java" <<'EOF'
// data trace 只读骨架（Java 栈，ADR-0017）。只读：仅实现 ping/list-entities/query/describe。
// 数据源（owner 配，不进仓库）：DATA_TRACE_SOURCE_FILE 指向 JSON {"Entity": [{...}, ...]}，
// 或替换 loadSource() 为直连项目 DB 的只读查询（JDBC DSN 走 env，不进仓库）。
// 连接未配置时 query/describe 返回 exit 2，不假绿。启动：java Cli.java <cmd> [args]
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.*;
import java.util.stream.Collectors;

public class Cli {
  static Map<String, Object> loadSource() {
    String f = System.getenv().getOrDefault("DATA_TRACE_SOURCE_FILE", "");
    try {
      String text = Files.readString(Path.of(f));
      @SuppressWarnings("unchecked")
      Map<String, Object> m = parseMap(text);
      return m;
    } catch (Exception e) {
      return null;
    }
  }
  // 极简 JSON 解析：只支持 {"E":[{...}]} 与嵌套对象/基本类型，满足骨架契约；真实项目可换 Jackson。
  @SuppressWarnings("unchecked")
  static Map<String, Object> parseMap(String s) {
    String t = s.trim();
    t = t.substring(1, t.length() - 1);
    Map<String, Object> out = new LinkedHashMap<>();
    // 仅处理顶层 { "Key": [ ... ] } —— 用正则按 key 切
    java.util.regex.Matcher m = java.util.regex.Pattern.compile("\"([^\"]+)\"\\s*:\\s*(\\[[^]]*\\]|\\{[^{}]*\\}|[^,}]+)")
      .matcher(t);
    while (m.find()) {
      out.put(m.group(1), m.group(2).trim());
    }
    return out;
  }
  static boolean matchItem(Object item, String field, String value) {
    String cur = String.valueOf(item);
    for (String p : field.split("\\.")) {
      java.util.regex.Matcher mm = java.util.regex.Pattern.compile("\"" + p + "\"\\s*:\\s*\"?([^\",}]*)\"?")
        .matcher(cur);
      if (!mm.find()) return false;
      cur = mm.group(1);
    }
    return cur.equals(value);
  }
  public static void main(String[] args) {
    String cmd = args.length > 0 ? args[0] : "";
    switch (cmd) {
      case "ping":
        System.out.println("{\"ok\":true,\"impl\":\"java\",\"version\":1}");
        return;
      case "list-entities": {
        Map<String, Object> data = loadSource();
        if (data == null) { System.out.println("{\"entities\":[]}"); return; }
        String ents = data.keySet().stream().sorted().map(k -> "\"" + k + "\"")
          .collect(Collectors.joining(","));
        System.out.println("{\"entities\":[" + ents + "]}");
        return;
      }
      case "query": {
        if (args.length < 2) { System.err.println("query 缺 entity"); System.exit(2); }
        String entity = args[1];
        Map<String, Object> data = loadSource();
        if (data == null) {
          System.err.println("连接未配置：DATA_TRACE_SOURCE_FILE 未设置或无此文件，须 owner 提供只读连接");
          System.exit(2);
        }
        Object raw = data.get(entity);
        List<String> items = new ArrayList<>();
        if (raw != null) {
          String r = String.valueOf(raw).trim();
          if (r.startsWith("[")) r = r.substring(1, r.length() - 1);
          for (String it : r.split("(?<=}),\\s*\\{")) items.add(it.trim());
        }
        // 等值过滤（骨架级：逐条子串匹配 field/value 对）
        List<Map<String, String>> conds = new ArrayList<>();
        for (int i = 0; i < args.length - 1; i++) {
          if (args[i].equals("--where") && i + 1 < args.length) {
            String w = args[i + 1];
            java.util.regex.Matcher cm = java.util.regex.Pattern.compile("\"field\"\\s*:\\s*\"([^\"]+)\"\\s*,\\s*\"value\"\\s*:\\s*\"([^\"]*)\"")
              .matcher(w);
            while (cm.find()) { Map<String, String> c = new HashMap<>(); c.put("field", cm.group(1)); c.put("value", cm.group(2)); conds.add(c); }
          }
        }
        List<String> kept = new ArrayList<>();
        for (String it : items) {
          boolean ok = true;
          for (Map<String, String> c : conds) if (!matchItem(it, c.get("field"), c.get("value"))) { ok = false; break; }
          if (ok) kept.add(it);
        }
        System.out.println("{\"entity\":\"" + entity + "\",\"count\":" + kept.size()
          + ",\"items\":[" + String.join(",", kept) + "]}");
        return;
      }
      case "describe": {
        if (args.length < 2) { System.err.println("describe 缺 entity"); System.exit(2); }
        Map<String, Object> data = loadSource();
        if (data == null) {
          System.err.println("连接未配置：DATA_TRACE_SOURCE_FILE 未设置或无此文件，须 owner 提供只读连接");
          System.exit(2);
        }
        System.out.println("{\"entity\":\"" + args[1] + "\",\"fields\":{}}");
        return;
      }
      default:
        System.err.println("未知命令（ping|list-entities|query <entity> --where <json>|describe <entity>）");
        System.exit(2);
    }
  }
}
EOF
  cat > "$DT/cli.sh" <<EOF
#!/usr/bin/env bash
# data trace Java 栈入口（ADR-0017）。单文件源码启动（JDK 11+）：java Cli.java <args...>。
set -euo pipefail
DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
exec java "\$DIR/Cli.java" "\$@"
EOF
  chmod +x "$DT/cli.sh"
}

case "$STACK" in
  python) write_python ;;
  node)   write_node ;;
  java)   write_java ;;
esac

write_manifest
write_source

cat > "$DT/README.md" <<EOF
# data_trace — 项目唯一只读数据访问接口（ADR-0017）

- **位置**：本项目唯一（\`.harness/data_trace/\`），数据校验（数据 UT rung3 / 运行时 rung4）经
  \`ci/bin/harness-data-trace.sh\` 统一调用，不关心实现语言。
- **栈**：$STACK（骨架 \`cli.$( [ "$STACK" = python ] && echo py || { [ "$STACK" = node ] && echo mjs || echo sh; })\`）。
- **统一契约**：\`ping\` / \`list-entities\` / \`query <entity> --where <json>\`（等值 \`[{field,value},...]\`
  → EntityData 形状）/ \`describe <entity>\`。**只读**：无写命令；写语义命令被审计判红。
- **数据源**：\`source.yaml\` 声明 \`local\`（直连项目 DB/文件只读连接）或 \`uat\`（代理 UAT 只读 API）。
- **连接配置（owner 填，不进仓库）**：local = 设置 \`DATA_TRACE_SOURCE_FILE\` 或替换骨架加载逻辑为
  项目只读查询；uat = 填 \`source.yaml\` 的 \`uat.endpoint\` + token（\`HARNESS_DATA_TOKEN\`）。连接未配置时
  \`query\` 返回 exit 2「连接未配置」，不假绿。
- **方法治理**：\`manifest.yaml\` = 已批准方法集（人工审核锚）。新增数据获取方法须 owner 审核
  （只读性 + 用途）后追加并留痕；实现多出方法 → need-human，写语义命令 → blocking。
EOF

echo "[data-trace-init] 已生成 $STACK 栈只读骨架 → $DT"
echo "  下一步：owner 在 source.yaml / 骨架数据访问层配只读连接（不进仓库），并按需把实体加入 manifest.yaml"
