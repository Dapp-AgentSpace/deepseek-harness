#!/usr/bin/env python3
# depgraph.py — 大仓依赖图抽取深模块（tree-sitter 精确解析 import/use/require，只读导航，不下结论）。
#
# 单一归属：把「谁依赖谁」从源码抽成模块级依赖图（node=目录，edge=import 解析到目录）。
# 与 checklist.py 同类：纯函数深模块 + bash 薄包装（harness-depgraph.sh）调用。
# 判断类用途：输出喂 judge 当导航（ADR-0006）。本模块只出图与结构事实，不标「好/坏/违例」。
#
# 用法: python3 depgraph.py <root> <stack> <module_root> [--collapse N] [--fmt mermaid|json|facts] [--no-cache]
#   stack ∈ maven|gradle|java|go|rust|npm|typescript|python|shell|unknown
# 多栈: python3 depgraph.py --multi <root> - [--collapse N] [--fmt ...]（stdin 每行 "stack<TAB>module_root"）
#   tree-sitter 未装（大仓深分析才需要）→ 清晰报错退出 2，不假绿、不降级出错误图。
# 增量：每文件按内容 SHA-256 缓存「提取的 import/package」；文件未变则不重跑 tree-sitter 解析。
#   缓存落 .harness/reports/depgraph-cache.json（派生数据，删了下次自动全量重建）。
#   键控用内容哈希而非 git diff——git diff 漏未跟踪文件/非 git 仓库/revert 到旧内容，漏判即陈旧图。
#   --no-cache 强制全量；HARNESS_DEPGRAPH_CACHE 环境变量覆盖缓存路径。
import sys, os, json, collections, re, hashlib

# Windows 默认 GBK：中文结构事实会写成 GBK 字节，混入 UTF-8 文件/管道会乱码 → 强制 UTF-8 输出。
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")

EXCLUDE_DIRS = {"node_modules", ".git", "target", "vendor", "dist", "build",
                "__pycache__", ".venv", "venv", ".harness", ".codestable", ".mvn"}

# stack 归一化 → (grammar 名, 源码扩展名)
STACK_GRAMMAR = {
    "maven": ("java", (".java",)),
    "gradle": ("java", (".java", ".kt")),
    "java": ("java", (".java",)),
    "go": ("go", (".go",)),
    "rust": ("rust", (".rs",)),
    "npm": ("typescript", (".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".vue")),
    "typescript": ("typescript", (".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".vue")),
    "python": ("python", (".py",)),
}

_GRAMMAR_CACHE = {}


def _grammar(name):
    """延迟 import 对应 grammar 包，返回 (Language, Parser)。缺依赖 raise 带 pip 提示。"""
    if name in _GRAMMAR_CACHE:
        return _GRAMMAR_CACHE[name]
    try:
        from tree_sitter import Language, Parser
        import importlib
        mod = importlib.import_module("tree_sitter_" + name)
    except ImportError as e:
        print("[depgraph] tree-sitter 未安装（大仓深分析才需要）。请执行:", file=sys.stderr)
        print("  pip install -r ci/requirements-depgraph.txt", file=sys.stderr)
        print(f"  (缺失: {getattr(e, 'name', name)})", file=sys.stderr)
        raise SystemExit(2) from e
    lang = Language(mod.language_typescript() if name == "typescript" else mod.language())
    parser = Parser(lang)
    _GRAMMAR_CACHE[name] = (lang, parser)
    return _GRAMMAR_CACHE[name]


# ── 抽取（walk CST 精确取 import 节点；注释/字符串/多行块 tree-sitter 已正确消掉） ──

def _walk(node, fn):
    fn(node)
    for c in node.children:
        _walk(c, fn)


def _extract_python(root_node):
    out = []
    def visit(n):
        if n.type == "import_statement":
            for c in n.named_children:
                if c.type == "dotted_name":
                    out.append(c.text.decode())
        elif n.type == "import_from_statement":
            m = n.child_by_field_name("module_name")
            if m is not None:
                out.append(m.text.decode())
    _walk(root_node, visit)
    return out


def _extract_go(root_node):
    out = []
    def visit(n):
        if n.type == "import_spec":
            p = n.child_by_field_name("path")
            if p is not None:
                out.append(p.text.decode().strip('"`'))
    _walk(root_node, visit)
    return out


def _extract_typescript(root_node):
    out = []
    def visit(n):
        if n.type == "import_statement":
            s = n.child_by_field_name("source")
            if s is not None:
                out.append(s.text.decode().strip("'\""))
        elif n.type == "call_expression":
            fn = n.child_by_field_name("function")
            if fn is not None and fn.type == "identifier" and fn.text.decode() == "require":
                args = n.child_by_field_name("arguments")
                if args is not None and args.named_children:
                    first = args.named_children[0]
                    if first.type == "string":
                        out.append(first.text.decode().strip("'\""))
    _walk(root_node, visit)
    return out


def _extract_java(root_node):
    imports, package = [], None
    def visit(n):
        nonlocal package
        if n.type == "import_declaration":
            for c in n.named_children:
                if c.type == "scoped_identifier":
                    imports.append(c.text.decode())
                    break
        elif n.type == "package_declaration":
            for c in n.named_children:
                if c.type == "scoped_identifier":
                    package = c.text.decode()
                    break
    _walk(root_node, visit)
    return imports, package


def _extract_rust(root_node):
    out = []
    def visit(n):
        if n.type == "use_declaration":
            a = n.child_by_field_name("argument")
            if a is not None:
                out.append(a.text.decode())
    _walk(root_node, visit)
    return out


_EXTRACTORS = {
    "python": _extract_python,
    "go": _extract_go,
    "typescript": _extract_typescript,
    "java": _extract_java,
    "rust": _extract_rust,
}

_VUE_SCRIPT_RE = re.compile(rb'<script\b[^>]*>(.*?)</script>', re.DOTALL)


def _vue_script(content):
    """取 .vue SFC 的 <script> 块（含 <script setup lang=ts>）。无 <script> 块返回 b''。"""
    m = _VUE_SCRIPT_RE.search(content)
    return m.group(1) if m else b""


# ── 解析（import 说明符 → 内部目录 node，返回完整相对路径；None = 外部） ──

def _collapse(node_id, depth):
    segs = [s for s in node_id.replace("\\", "/").split("/") if s]
    if not segs:
        return "."
    return "/".join(segs[:depth])


def _resolve_python(spec, _importing, ctx):
    top = spec.split(".")[0]
    root = ctx["module_root"]
    if top and (os.path.isdir(os.path.join(root, top)) or os.path.isfile(os.path.join(root, top + ".py"))):
        return spec.replace(".", "/")
    return None


def _resolve_go(spec, _importing, ctx):
    prefix = ctx.get("go_module") or ""
    if prefix and spec == prefix:
        return "."
    if prefix and spec.startswith(prefix + "/"):
        return spec[len(prefix) + 1:]
    return None


_SRC_EXT_RE = re.compile(r'\.(vue|tsx?|jsx?|mjs|cjs|json)$')


def _load_alias_map(module_root, root):
    """读 jsconfig.json/tsconfig.json 的 compilerOptions.paths，返回 {别名前缀: 绝对目录}。

    找法：从 module_root 起向上到 root，取第一个 jsconfig/tsconfig。解析失败/无配置返回 {}。
    别名 target 相对 baseUrl（baseUrl 相对 config 文件所在目录）。"""
    cfg_dir = os.path.abspath(module_root)
    root = os.path.abspath(root)
    cfg_path = None
    while True:
        for name in ("jsconfig.json", "tsconfig.json"):
            p = os.path.join(cfg_dir, name)
            if os.path.isfile(p):
                cfg_path = p
                break
        if cfg_path or cfg_dir == root:
            break
        parent = os.path.dirname(cfg_dir)
        if parent == cfg_dir:
            break
        cfg_dir = parent
    if not cfg_path:
        return {}
    try:
        data = json.load(open(cfg_path, encoding="utf-8"))
    except Exception:
        return {}
    co = data.get("compilerOptions") or {}
    base_url = co.get("baseUrl") or "."
    paths = co.get("paths") or {}
    aliases = {}
    for key, targets in paths.items():
        if not isinstance(targets, (list, tuple)) or not targets:
            continue
        tgt = str(targets[0]).rstrip("/*")
        aliases[key.rstrip("/*")] = os.path.normpath(os.path.join(cfg_dir, base_url, tgt))
    return aliases


def _ts_node(target_abs, module_root):
    """绝对目标路径 → module_root 相对 node（剥源码扩展名落目录）；在 module_root 外 → None。"""
    if _SRC_EXT_RE.search(target_abs):
        target_abs = os.path.dirname(target_abs)
    rel = os.path.relpath(os.path.abspath(target_abs), os.path.abspath(module_root))
    if rel == ".":
        return "."
    if rel.startswith(".."):
        return None
    return rel


def _resolve_typescript(spec, importing, ctx):
    root = os.path.abspath(ctx["module_root"])
    # 1) 别名（jsconfig/tsconfig paths，最长前缀匹配）：如 @app/* → frontend/*
    for k in sorted((ctx.get("ts_aliases") or {}), key=len, reverse=True):
        if spec == k or spec.startswith(k + "/"):
            suffix = spec[len(k):].lstrip("/")
            return _ts_node(os.path.join(ctx["ts_aliases"][k], suffix), root)
    # 2) 相对导入（./ ../）：import './App.vue' 剥扩展名落目录 node
    if spec.startswith("./") or spec.startswith("../"):
        return _ts_node(os.path.join(root, importing, spec), root)
    return None


def _resolve_rust(spec, importing, _ctx):
    # rust 的 `use` 可导入类型或模块（语法层无类型信息）：尾段 CamelCase 视为类型，剥掉；全小写视为模块路径保留。
    if spec.startswith("crate::"):
        segs = spec[len("crate::"):].split("::")
        while segs and segs[-1][:1].isupper():
            segs.pop()
        return "/".join(segs) if segs else "."
    if spec.startswith("self::"):
        return importing
    if spec.startswith("super::"):
        return os.path.normpath(os.path.join(importing, ".."))
    return None


def _resolve_java(package, _importing, ctx):
    prefix = ctx.get("java_prefix")
    if not prefix or not package.startswith(prefix):
        return None
    rest = package[len(prefix):].lstrip(".")
    return rest.replace(".", "/") if rest else "."


_RESOLVERS = {
    "python": _resolve_python,
    "go": _resolve_go,
    "typescript": _resolve_typescript,
    "rust": _resolve_rust,
    "java": _resolve_java,
}


_SCOPE_RE = re.compile(r"@[A-Za-z0-9_-]+/[A-Za-z0-9_-]+")


def _external_name(spec):
    # 机械命名（不做组织/语言约定判断）：@scope/name → 完整作用域名；./ @ ~ 相对/别名导入 → 丢弃；
    # dotted（Java 风格包名）→ 机械取前两段（com.alibaba / org.springframework / lombok.Data）；
    #   java/javax 是 JDK 平台不是依赖 → 丢弃；slashed（npm 裸包 / go 模块路径）→ 首段。
    #   注：同库拆多个名（lombok.Data / lombok.extern）属「命名分组」判断，留给 LLM/读者，本函数不猜。
    m = _SCOPE_RE.match(spec)
    if m:
        return m.group(0)
    if spec.startswith((".", "@", "~")):
        return None
    if "." in spec:
        segs = spec.split(".")
        if segs[0] in ("java", "javax"):
            return None
        return ".".join(segs[:2])
    parts = [p for p in spec.split("/") if p]
    return parts[0] if parts else None


# ── 图构建 ──

def _common_pkg_prefix(packages):
    parts = [p.split(".") for p in packages]
    if not parts:
        return None
    i = 0
    while all(len(p) > i and p[i] == parts[0][i] for p in parts):
        i += 1
    return ".".join(parts[0][:i]) if i else None


def _go_module_path(root):
    p = os.path.join(root, "go.mod")
    if os.path.isfile(p):
        for ln in open(p, encoding="utf-8", errors="replace"):
            ln = ln.strip()
            if ln.startswith("module "):
                return ln[len("module "):].strip().strip('"')
    return None


def _importing_node(rel_dir, grammar_name, ctx):
    """文件所在目录 → 该语言下的 node 路径（Java 需剥应用根包前缀）。"""
    if grammar_name == "java":
        prefix = ctx.get("java_prefix") or ""
        pkg = rel_dir.replace("\\", "/").replace("/", ".")
        if prefix and (pkg == prefix or pkg.startswith(prefix + ".")):
            rest = pkg[len(prefix):].lstrip(".")
            return rest.replace(".", "/") if rest else "."
    return rel_dir


def _iter_src(root):
    for base, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in EXCLUDE_DIRS]
        for f in files:
            yield base, f


def _cache_path(root):
    return os.environ.get("HARNESS_DEPGRAPH_CACHE") or os.path.join(
        root, ".harness", "reports", "depgraph-cache.json")


def _load_cache(root):
    p = _cache_path(root)
    try:
        with open(p, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return {}
    if isinstance(data, dict) and data.get("version") == 1 and isinstance(data.get("files"), dict):
        return data["files"]
    return {}


def _save_cache(root, files):
    p = _cache_path(root)
    try:
        d = os.path.dirname(p)
        if d:
            os.makedirs(d, exist_ok=True)
        with open(p, "w", encoding="utf-8") as fh:
            json.dump({"version": 1, "files": files}, fh, ensure_ascii=False)
    except OSError as e:
        print("[depgraph] 缓存写入失败（忽略，下次全量）: %s" % e, file=sys.stderr)


def build_graph(root, stack, module_root=None, collapse=1, cache=None):
    """返回 dict: nodes[], edges[{from,to}], external[{name,count}]。node 为 collapse 后的目录。

    cache 为 {relpath: {"sha","imports","package"}}；按文件内容 SHA-256 判是否复用上次提取，
    文件未变则不重跑 tree-sitter 解析（增量，只重解析变更文件）。cache=None 视为空缓存。"""
    entry = STACK_GRAMMAR.get(stack)
    module_root = module_root or root
    ctx = {"module_root": module_root}
    cache = {} if cache is None else cache
    if entry is None:
        # shell/unknown：无 import 语义，只出目录树（node 无 edge）。
        nodes = set()
        for base, f in _iter_src(module_root):
            rel = os.path.relpath(base, module_root)
            nodes.add(_collapse(rel if rel != "." else ".", collapse))
        return {"nodes": sorted(nodes), "edges": [], "external": []}

    grammar_name, exts = entry
    if grammar_name == "go":
        ctx["go_module"] = _go_module_path(module_root)
    elif grammar_name == "typescript":
        ctx["ts_aliases"] = _load_alias_map(module_root, root)

    _, parser = _grammar(grammar_name)

    # 单次遍历：每个源文件取提取事实（缓存命中且内容哈希一致 → 复用；否则 tree-sitter 解析并回填缓存）。
    # 键控用内容 SHA-256 而非 git diff——git diff 漏未跟踪文件/非 git 仓库/revert 到旧内容，漏判即陈旧图。
    per_file = {}   # 绝对路径 -> (imports, package)
    for base, f in _iter_src(module_root):
        if not f.endswith(exts):
            continue
        p = os.path.join(base, f)
        key = os.path.relpath(p, root).replace(os.sep, "/")
        try:
            raw = open(p, "rb").read()
        except OSError:
            continue
        sha = hashlib.sha256(raw).hexdigest()
        ent = cache.get(key)
        if ent and ent.get("sha") == sha and "imports" in ent:
            imports, package = ent.get("imports") or [], ent.get("package")
        else:
            src = raw
            if f.endswith(".vue"):
                src = _vue_script(raw)
                if not src:
                    ent = {"sha": sha, "imports": [], "package": None}
                    cache[key] = ent
                    per_file[p] = ([], None)
                    continue
            tree = parser.parse(src)
            res = _EXTRACTORS[grammar_name](tree.root_node)
            if grammar_name == "java":
                imports, package = res
            else:
                imports, package = res, None
            ent = {"sha": sha, "imports": imports, "package": package}
            cache[key] = ent
        per_file[p] = (imports, package)

    # Java 前缀：从（缓存的）package 声明求公共前缀——任一 package 增删会级联改所有 java 节点，仍按事实重算，不缓存。
    if grammar_name == "java":
        pkgs = [pkg for _, pkg in per_file.values() if pkg]
        ctx["java_prefix"] = _common_pkg_prefix(pkgs)

    # 聚合（无 parse，纯内存）：解析 import 到目录 node、连边。
    nodes, edges, external = set(), set(), collections.Counter()
    for p, (specs, _package) in per_file.items():
        base = os.path.dirname(p)
        rel_dir = os.path.relpath(base, module_root)
        rel_dir = "." if rel_dir in ("", ".") else rel_dir
        from_node = _collapse(_importing_node(rel_dir, grammar_name, ctx), collapse)
        nodes.add(from_node)
        for spec in specs:
            if grammar_name == "java":
                node = _resolve_java(spec.rsplit(".", 1)[0], rel_dir, ctx)
            else:
                node = _RESOLVERS[grammar_name](spec, rel_dir, ctx)
            if node is None:
                name = _external_name(spec)
                if name:
                    external[name] += 1
                continue
            to_node = _collapse(node, collapse)
            if to_node != from_node:
                nodes.add(to_node)
                edges.add((from_node, to_node))

    # 过滤根节点 "."（代表「直接落在 module_root 根的类」，导航无意义、只增噪）
    return {
        "nodes": sorted(n for n in nodes if n != "."),
        "edges": [{"from": a, "to": b} for a, b in sorted(edges) if a != "." and b != "."],
        "external": [{"name": k, "count": v} for k, v in external.most_common()],
    }


def _ns(label, node):
    """多栈合并时给 node/external 加模块命名空间前缀，避免多模块同名目录合并成同一节点。"""
    return f"{label}::{node}" if label else node


def build_multi(root, specs, collapse=1, cache=None):
    """specs = [(stack, module_root), ...] → 逐栈抽图合并，节点/边/外部依赖按模块命名空间化。

    多栈自动推导（harness-depgraph.sh 无显式 --stack 时）用：每个模块各抽一张图，node 前缀
    "<模块相对路径>::"，避免 frontend/components 与 h5/components 撞成同一节点。跨模块间
    通常无 import 边（前端调后端走 HTTP 非 import），故只需并集、不需跨模块连线。"""
    nodes, edges, external = set(), set(), collections.Counter()
    root_abs = os.path.abspath(root)
    for stack, module_root in specs:
        g = build_graph(root, stack, module_root, collapse, cache)
        label = os.path.relpath(os.path.abspath(module_root), root_abs).replace("\\", "/")
        # 剥掉源码根后缀（src/main/java、src 等），只留模块名：backend 而非 backend/src/main/java
        label = re.sub(r"/src(?:/main/(?:java|kotlin))?$", "", label)
        if label == ".":
            label = os.path.basename(root_abs)
        for n in g["nodes"]:
            nodes.add(_ns(label, n))
        for e in g["edges"]:
            edges.add((_ns(label, e["from"]), _ns(label, e["to"])))
        for x in g["external"]:
            external[_ns(label, x["name"])] += x["count"]
    # 过滤根节点 "."（代表「直接落在 module_root 根的类」，导航无意义、只增噪）
    return {
        "nodes": sorted(n for n in nodes if n != "."),
        "edges": [{"from": a, "to": b} for a, b in sorted(edges) if a != "." and b != "."],
        "external": [{"name": k, "count": v} for k, v in external.most_common()],
    }


# ── 结构事实（SCC 环 / 叶子 / 枢纽，只列事实不下结论） ──

def _scc(nodes, edges):
    adj = collections.defaultdict(list)
    for e in edges:
        adj[e["from"]].append(e["to"])
    idx, low, stack, onstack, order = {}, {}, [], set(), [0]
    cycles = []

    def strong(v):
        idx[v] = low[v] = order[0]
        order[0] += 1
        stack.append(v)
        onstack.add(v)
        for w in adj[v]:
            if w not in idx:
                strong(w)
                low[v] = min(low[v], low[w])
            elif w in onstack:
                low[v] = min(low[v], idx[w])
        if low[v] == idx[v]:
            comp = []
            while True:
                w = stack.pop()
                onstack.discard(w)
                comp.append(w)
                if w == v:
                    break
            if len(comp) > 1:
                cycles.append(sorted(comp))

    for n in nodes:
        if n not in idx:
            strong(n)
    return cycles


def facts(graph):
    nodes = set(graph["nodes"])
    outdeg = collections.Counter(e["from"] for e in graph["edges"])
    indeg = collections.Counter(e["to"] for e in graph["edges"])
    cycles = _scc(graph["nodes"], graph["edges"])
    leaves = sorted(n for n in nodes if outdeg[n] == 0)
    hubs = sorted(n for n, d in indeg.items() if d >= 5 and n in nodes)
    return {"cycles": cycles, "leaves": leaves, "hubs": hubs}


# ── 输出 ──

def emit(graph, fmt, collapse=1):
    if fmt == "mermaid":
        lines = ["flowchart LR"]
        for n in graph["nodes"]:
            lines.append(f'  {n!r}')
        for e in graph["edges"]:
            lines.append(f'  {e["from"]!r} --> {e["to"]!r}')
        # 外部依赖：不解析源码，仅标注（供 judge 知道哪些 import 落在仓库外，属正常，不视为缺陷）
        if graph["external"]:
            shown = graph["external"][:15]
            ext = ", ".join(e["name"] for e in shown)
            if len(graph["external"]) > 15:
                ext += f" …（共 {len(graph['external'])} 个）"
            lines.append("%% 外部依赖（不解析源码）: " + ext)
        return "\n".join(lines) + "\n"
    if fmt == "json":
        return json.dumps(graph, ensure_ascii=False, indent=2) + "\n"
    if fmt == "facts":
        f = facts(graph)
        out = ["[depgraph] 结构事实（只列事实，好/坏由 judge 判）"]
        def _cyc(c):
            return "→".join(c) if len(c) <= 6 else "→".join(c[:3]) + f"→…({len(c)} 节点)"
        out.append("环（SCC，>1 节点）: " + (", ".join(_cyc(c) for c in f["cycles"]) if f["cycles"] else "无"))
        out.append("叶子（无出边）: " + (", ".join(f["leaves"]) if f["leaves"] else "无"))
        out.append("枢纽（入度≥5）: " + (", ".join(f["hubs"]) if f["hubs"] else "无"))
        out.append("外部依赖（不解析源码）: " + (", ".join(e["name"] for e in graph["external"]) if graph["external"] else "无"))
        return "\n".join(out) + "\n"
    raise SystemExit("[depgraph] 未知 fmt: %s" % fmt)


def main(argv):
    args = list(argv)
    fmt, collapse, multi, use_cache = "mermaid", 1, False, True
    if "--fmt" in args:
        i = args.index("--fmt")
        fmt, args = args[i + 1], args[:i] + args[i + 2:]
    if "--collapse" in args:
        i = args.index("--collapse")
        collapse, args = int(args[i + 1]), args[:i] + args[i + 2:]
    if "--no-cache" in args:
        use_cache = False
        args.remove("--no-cache")
    if "--multi" in args:
        multi = True
        args.remove("--multi")
    if multi:
        if len(args) < 2:
            raise SystemExit(__doc__)
        root, spec_src = args[0], args[1]
        text = sys.stdin.read() if spec_src == "-" else open(spec_src, encoding="utf-8").read()
        specs = []
        for ln in text.splitlines():
            ln = ln.strip()
            if not ln or "\t" not in ln:
                continue
            stack, module_root = ln.split("\t", 1)
            specs.append((stack, module_root))
        if not specs:
            raise SystemExit("[depgraph] 多栈探测无模块，无依赖图可出")
        cache = _load_cache(root) if use_cache else {}
        sys.stdout.write(emit(build_multi(root, specs, collapse, cache), fmt, collapse))
        if use_cache:
            _save_cache(root, cache)
        return
    if len(args) < 3:
        raise SystemExit(__doc__)
    root, stack, module_root = args[0], args[1], args[2]
    cache = _load_cache(root) if use_cache else {}
    sys.stdout.write(emit(build_graph(root, stack, module_root, collapse, cache), fmt, collapse))
    if use_cache:
        _save_cache(root, cache)


if __name__ == "__main__":
    main(sys.argv[1:])
