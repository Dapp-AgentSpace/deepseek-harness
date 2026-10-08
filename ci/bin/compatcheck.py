#!/usr/bin/env python3
"""compatcheck.py — 兼容性判定深模块（无 AI、纯标准库）。

输入：清单文件路径列表（stdin，每行一个）+ 策略文件（shared 基线 + 可选项目本地）。
输出：stdout = blocking findings（人读，逐条一行）；`--report` 落盘 Markdown 报告
（含可直接粘贴进 .harness/compat-policy.yaml 的 ignore 骨架）。

判定对象是仓库**声明的「最低支持版本」**（declared floor）是否低于策略基线：
package.json engines.node/npm · go.mod `go` 指令 · Cargo.toml rust-version（MSRV）·
pom.xml 的 maven.compiler.release|source|target / java.version · build.gradle 的 sourceCompatibility ·
pyproject.toml requires-python / setup.py|setup.cfg python_requires。

不做的事：不跑外部 CLI（API 级 breaking change 需基线产物，不在本门禁的声明式判定范围）、
不判「好/坏」以外的语义、不引入 PyYAML（策略用最小正则解析，同 ci/bin/depcheck.py 的取舍——
确定性门禁不得依赖可选包）。清单发现（找哪些文件）归 shell 的 stack_compat_manifests，
本模块只读 shell 递进来的路径——同 dep 门禁「获取归 gate、判定归 py」的缝。

退出码：0=无 blocking（含「有声明且全达标」与「跑完但零声明」）/ 1=有 blocking（含被 ignore 但已过期）/
        2=无策略、无清单、或输入不可解析。

用法：
  compatcheck.py [--policy <ci/compat-policy.yaml>] [--policy-local <.harness/compat-policy.yaml>]
                 [--report <.harness/reports/{project.id}-compat-last.md>] [--project <project.id>]
                 [--today YYYY-MM-DD] [--probe]
  清单路径从 stdin 逐行读入（POSIX 路径）。

判据单源见 ci/compat-policy.yaml 头部注释（只判声明下界、未声明不违例、ignore 须带 reason、
expires 到期自动失效）。
"""

import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import policy_file as pf  # noqa: E402
import sys
from datetime import date

# 策略允许的顶层 key（其余顶层 key 视为书写错误，响亮报错而非静默忽略）
POLICY_KEYS = ("floors", "ignore")

VER_RE = re.compile(r"\d+(?:\.\d+)*")


# 策略文件的机械部分归 **policy_file.py**（与 depcheck 同形，见该模块头注释）。
# **「判什么」留在本模块**：版本下界比较是 compat 门禁的价值。
_scalar = pf.scalar


def first_version(spec):
    """取约束串里声明的**下界** —— 首个「不是上界」的数值版本 token。

    `>=18`→(18,) · `^18.0.0`→(18,0,0) · `~3.9`→(3,9) · `18.x`→(18,) · `>=3.9,<4`→(3,9) ·
    `1.21`→(1,21) · Java `1.8`→(1,8)。

    **跳过被 `<` / `<=` 前缀的 token** —— 那是上界，不表达下界。纯上界串（`<4`）返回 None
    ＝ 未声明下界：不算违例，也**不臆造一个下界出来**；混合串（`<4,>=3.9`）仍能取到真正的下界。
    曾把 `<4` 当成下界 4 → 与基线 3.9 比较后判「达标 python」，把「本仓未声明 python 下界」
    这条覆盖缺口信号吞掉（docstring 当时写的却是「按未声明放过」—— 声明与落盘不一致）。
    `*` / 空 / 无数字 token → None。
    """
    s = str(spec or "")
    for m in VER_RE.finditer(s):
        pre = s[:m.start()].rstrip()
        if pre.endswith("<=") or pre.endswith("<"):
            continue          # 上界 token：跳过，继续找下界
        return tuple(int(x) for x in m.group(0).split("."))
    return None


def _pad(t, n):
    return tuple(list(t) + [0] * (n - len(t)))


# ---- 各清单的声明抽取器：text → [{"engine", "raw", "bound"}, ...] ----
# bound 为 None（取不到数字）的声明直接丢弃：那是「写法不认识」，不是「声明为 0」，
# 臆造下界会造出假红；真要看它，人读报告里的 raw 更实在。

def _decl(engine, raw):
    b = first_version(raw)
    if b is None:
        return None
    return {"engine": engine, "raw": str(raw).strip(), "bound": b}


def extract_npm(text):
    """package.json：engines.node / engines.npm。"""
    out = []
    m = re.search(r'"engines"\s*:\s*\{(.*?)\}', text, re.S)
    if not m:
        return out
    for engine in ("node", "npm"):
        v = re.search(r'"%s"\s*:\s*"([^"]*)"' % engine, m.group(1))
        if v:
            d = _decl(engine, v.group(1))
            if d:
                out.append(d)
    return out


def extract_go(text):
    """go.mod：`go 1.21` 指令（语言/工具链最低版本）。"""
    m = re.search(r"^go\s+(\S+)", text, re.M)
    d = _decl("go", m.group(1)) if m else None
    return [d] if d else []


def extract_rust(text):
    """Cargo.toml：rust-version（MSRV）。"""
    m = re.search(r'^\s*rust-version\s*=\s*["\']([^"\']*)["\']', text, re.M)
    d = _decl("rust", m.group(1)) if m else None
    return [d] if d else []


JAVA_POM_RE = re.compile(
    r"<(maven\.compiler\.(?:release|source|target)|java\.version)>\s*([^<]+?)\s*</", re.I)


def extract_java_pom(text):
    """pom.xml：maven.compiler.release|source|target / java.version（Java 编译级别）。"""
    out = []
    for _k, v in JAVA_POM_RE.findall(text):
        d = _decl("java", v)
        if d:
            out.append(d)
    return out


JAVA_GRADLE_PATTERNS = (
    r"""sourceCompatibility\s*=?\s*["']?([\d._]+)""",
    r"JavaVersion\.VERSION_([\d_]+)",
    r"JavaLanguageVersion\.of\(\s*(\d+)",
)


def extract_java_gradle(text):
    """build.gradle(.kts)：sourceCompatibility / JavaVersion.VERSION_<N> / JavaLanguageVersion.of(N)。"""
    out = []
    for pat in JAVA_GRADLE_PATTERNS:
        for v in re.findall(pat, text):
            d = _decl("java", str(v).replace("_", "."))
            if d:
                out.append(d)
    return out


def extract_python_toml(text):
    """pyproject.toml：requires-python。"""
    m = re.search(r'^\s*requires-python\s*=\s*["\']([^"\']*)["\']', text, re.M)
    d = _decl("python", m.group(1)) if m else None
    return [d] if d else []


def extract_python_setup(text):
    """setup.py：python_requires。"""
    m = re.search(r'python_requires\s*=\s*["\']([^"\']*)["\']', text)
    d = _decl("python", m.group(1)) if m else None
    return [d] if d else []


def extract_python_cfg(text):
    """setup.cfg：python_requires（ini 形态，值不带引号）。"""
    m = re.search(r"^\s*python_requires\s*=\s*(\S+)", text, re.M)
    d = _decl("python", m.group(1)) if m else None
    return [d] if d else []


# basename → 抽取器。未列出的清单（锁文件、requirements.txt 等）不承载「支持基线」声明，跳过。
EXTRACTORS = {
    "package.json": extract_npm,
    "go.mod": extract_go,
    "Cargo.toml": extract_rust,
    "pom.xml": extract_java_pom,
    "build.gradle": extract_java_gradle,
    "build.gradle.kts": extract_java_gradle,
    "pyproject.toml": extract_python_toml,
    "setup.py": extract_python_setup,
    "setup.cfg": extract_python_cfg,
}


def collect(paths):
    """读清单 → 声明列表。

    同一 (engine, 文件) 出现多条时（如 pom 同时写 compiler.source 与 java.version）保留下界**最低**
    的一条——多条声明里最宽松的那个才是本仓真实承诺的支持下界，取高的会把真实下界藏起来。
    """
    best = {}
    for p in paths:
        fn = EXTRACTORS.get(os.path.basename(p))
        if not fn:
            continue
        try:
            text = open(p, encoding="utf-8").read()
        except OSError as e:
            raise ValueError(f"清单不可读：{p}（{e}）")
        except UnicodeDecodeError as e:
            # 编码异常的清单**不能**用 errors="replace" 静默替换：替换会把真声明读成「没有」，
            # 于是「未声明」被当成「无约束」放过 —— 正是本套件最反对的假绿。响亮失败（退出 2）。
            raise ValueError(f"清单非 UTF-8 编码，无法可靠解析：{p}（{e}）")
        for d in fn(text):
            d = dict(d, source=p)
            k = (d["engine"], p)
            if k not in best or d["bound"] < best[k]["bound"]:
                best[k] = d
    return sorted(best.values(), key=lambda d: (d["engine"], d["source"]))


parse_policy = pf.parse


def parse_floors(items):
    """`- <engine> <version>` → {engine: bound}。格式/版本不可解析 → ValueError（响亮失败）。"""
    out = {}
    for it in items:
        m = re.match(r"^(\S+)\s+(\S+)$", str(it).strip())
        if not m:
            raise ValueError(f"floors 项须为 `<engine> <version>`：{it}")
        b = first_version(m.group(2))
        if b is None:
            raise ValueError(f"floors 项版本无法解析：{it}")
        out[m.group(1).lower()] = b
    return out


def active_ignores(ignore_items, today):
    """compat 的例外主体字段是 `engine`（dep 是 vuln/license）。判据统一在 policy_file。"""
    return pf.active_ignores(ignore_items, today, ("engine",))


def judge(decls, floors, active):
    """逐引擎判定：声明下界 < 基线 → blocking（先过 ignore）。

    返回 (blocked, ok, undeclared)：undeclared = 策略有基线、本仓无任何声明的引擎——
    不是违例，但要在报告里列出来，让「检查跑完了但这一维没约束可判」可见。
    """
    by_engine = {}
    for d in decls:
        by_engine.setdefault(d["engine"], []).append(d)

    blocked, ok, undeclared = [], [], []
    for engine, floor in floors.items():
        ds = by_engine.get(engine)
        if not ds:
            undeclared.append({"engine": engine, "floor": floor})
            continue
        for d in ds:
            n = max(len(d["bound"]), len(floor))
            if _pad(d["bound"], n) < _pad(floor, n):
                if any(it["engine"].lower() == engine for it in active):
                    continue
                blocked.append(dict(d, floor=floor))
            else:
                ok.append(dict(d, floor=floor))
    return blocked, ok, undeclared


def _v(t):
    return ".".join(str(x) for x in t)


def render_report(blocked, ok, undeclared, floors, expired, invalid, project="", decl_count=0):
    """落盘 Markdown：结论 + blocking 清单 + 可直接粘贴的 ignore 骨架。

    带 project 时写 `project:` frontmatter——`.harness/reports/*.md` 的产出注入核对
    （closed-loop-audit.sh）要求所有报告带 project 字段且文件名带 project.id 前缀（ADR-0001 决策4）。
    """
    lines = ["# 兼容性门禁报告（`compat`）", ""]
    if project:
        lines[0:0] = ["---", f"project: {project}", "kind: compat-report",
                      f"conclusion: {'red' if blocked else 'green'}", "---", ""]
    lines.append(f"- 判定结论：{'RED（有 blocking）' if blocked else 'GREEN（无 blocking）'}")
    lines.append(f"- 声明条数：{decl_count}（达标 {len(ok)}）")
    lines.append(f"- 判定依据：floors {len(floors)} 条 —— "
                 + " · ".join(f"{e} >= {_v(b)}" for e, b in sorted(floors.items())))
    lines.append("")
    if blocked:
        lines.append("## blocking（声明的支持下界低于基线）")
        lines.append("")
        for d in blocked:
            lines.append(f"- **{d['engine']}** 声明 `{d['raw']}`（下界 {_v(d['bound'])}）"
                         f" < 基线 {_v(d['floor'])} · `{d['source']}`")
        lines.append("")
        lines.append("### 若需接受其中某条：写进 `.harness/compat-policy.yaml`（须带 reason）")
        lines.append("")
        lines.append("```yaml")
        lines.append("ignore:")
        for d in blocked:
            lines.append(f"  - engine: {d['engine']}")
            lines.append("    reason: \"\"   # 必填：为什么本项目可接受低于基线")
            lines.append(f"    expires: \"{date.today().replace(year=date.today().year + 1)}\"")
        lines.append("```")
        lines.append("")
    if ok:
        lines.append("## 达标")
        lines.append("")
        for d in ok:
            lines.append(f"- {d['engine']} `{d['raw']}` >= {_v(d['floor'])} · `{d['source']}`")
        lines.append("")
    if undeclared:
        lines.append("## 未声明（策略有基线，本仓无任何声明 —— 不是违例，是覆盖缺口）")
        lines.append("")
        for u in undeclared:
            lines.append(f"- {u['engine']}（基线 {_v(u['floor'])}）：本仓未见声明，"
                         f"该引擎的兼容性底线无从校验")
        lines.append("")
    if expired:
        lines.append("## 已过期的例外（重新变红）")
        lines.append("")
        for it in expired:
            lines.append(f"- `{it.get('engine')}`（expires {it.get('expires')}）→ "
                         f"要么修声明，要么续期并说明")
        lines.append("")
    if invalid:
        lines.append("## 无效例外（缺 reason / engine / expires 非法，未被采纳）")
        lines.append("")
        for it in invalid:
            body = " ".join(f"{k}={v}" for k, v in it.items()) or "(空项)"
            lines.append(f"- `{body}`")
        lines.append("")
    return "\n".join(lines) + "\n"


def main(argv):
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")

    policy_paths = []
    report_path = ""
    project = ""
    today = date.today()
    probe = False
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--policy":
            i += 1; policy_paths.append(argv[i])
        elif a == "--policy-local":
            i += 1; policy_paths.append(argv[i])
        elif a == "--report":
            i += 1; report_path = argv[i]
        elif a == "--project":
            i += 1; project = argv[i]
        elif a == "--today":
            i += 1
            try:
                today = date.fromisoformat(argv[i])
            except ValueError:
                sys.stderr.write(f"[compatcheck] --today 日期格式非法（须 YYYY-MM-DD）：{argv[i]}\n"); return 2
        elif a == "--probe":
            probe = True
        elif a.startswith("--"):
            sys.stderr.write(f"[compatcheck] 未知参数：{a}\n"); return 2
        else:
            sys.stderr.write(f"[compatcheck] 未预期的位置参数：{a}（清单从 stdin 逐行读入）\n"); return 2
        i += 1

    paths = [ln.strip() for ln in sys.stdin.read().splitlines() if ln.strip()]
    if not paths:
        sys.stderr.write("[compatcheck] 未从 stdin 收到清单路径（stack_compat_manifests 为空？）\n")
        return 2
    try:
        decls = collect(paths)
    except ValueError as e:
        sys.stderr.write(f"[compatcheck] {e}\n"); return 2

    # 探针：只回答「本仓有没有可判定的声明」，供 scaffold 的 wire_compat 决定是否接线。
    # 与正式判定共用 collect()，判据不重复实现。
    if probe:
        sys.stderr.write(f"[compatcheck] 探针：清单 {len(paths)} 个，"
                         f"最低支持版本声明 {len(decls)} 条\n")
        return 0 if decls else 1

    try:
        # 两层并集 + 「shared 必备 / 本地可选」的守卫都归 policy_file.load ——
        # 与 depcheck 是**同一份实现**（ADR-0011 决策 2 要的「学一次会两个」，从靠人记得对齐
        # 升级为结构上无法不对齐）
        policy = pf.load(policy_paths, POLICY_KEYS, "ci/compat-policy.yaml")
        floors = parse_floors(policy["floors"])
    except (ValueError, OSError) as e:
        sys.stderr.write(f"[compatcheck] {e}\n"); return 2

    if not floors:
        sys.stderr.write("[compatcheck] 策略 floors 为空：无基线可判 → 不假绿\n"); return 2

    active, expired, invalid = active_ignores(policy["ignore"], today)
    blocked, ok, undeclared = judge(decls, floors, active)

    if report_path:
        try:
            os.makedirs(os.path.dirname(report_path) or ".", exist_ok=True)
            open(report_path, "w", encoding="utf-8").write(
                render_report(blocked, ok, undeclared, floors, expired, invalid,
                              project, len(decls)))
        except OSError as e:
            sys.stderr.write(f"[compatcheck] 报告写入失败：{e}\n")   # 报告写不出不影响判定

    for it in invalid:
        sys.stderr.write(f"[compat] WARN 无效例外（缺 reason/engine/expires 非法），未采纳："
                         f"{' '.join(f'{k}={v}' for k, v in it.items())}\n")
    for it in expired:
        sys.stderr.write(f"[compat] WARN 例外已过期（{it.get('expires')}）：{it.get('engine')}\n")
    for u in undeclared:
        print(f"[compat] NOTE 未声明 {u['engine']}（基线 {_v(u['floor'])}）：本仓无该引擎的支持基线声明，"
              f"此维无从校验")

    if not blocked:
        print(f"[compat] 无 blocking（声明 {len(decls)} 条，达标 {len(ok)}，"
              f"未声明引擎 {len(undeclared)} 个）")
        return 0
    for d in blocked:
        print(f"[compat] RED {d['engine']} 声明 `{d['raw']}`（下界 {_v(d['bound'])}）"
              f"< 基线 {_v(d['floor'])} · {d['source']}")
    print(f"[compat] blocking {len(blocked)} 条（声明总数 {len(decls)}）")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
