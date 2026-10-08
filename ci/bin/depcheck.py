#!/usr/bin/env python3
"""depcheck.py — 依赖安全判定深模块（无 AI、纯标准库）。

输入：`trivy fs --scanners vuln,license --format json` 的输出 + 策略文件（shared 基线 +
可选项目本地）。输出：stdout = blocking findings（人读，逐条一行）；`--report` 落盘 Markdown 报告
（含可直接粘贴进 .harness/dep-policy.yaml 的 ignore 骨架）。

不做的事：不跑 trivy（获取归 ci/bin/harness-gate.sh 的 g_dep）、不判「好/坏」以外的语义、
不引入 PyYAML（策略用最小正则解析，同 ci/bin/checklist.py 的取舍——确定性门禁不得依赖可选包）。

退出码：0=无 blocking / 1=有 blocking（含被 ignore 但已过期）/ 2=输入不可解析（策略缺失、
trivy JSON 损坏）。

用法：
  depcheck.py <trivy.json> --policy <ci/dep-policy.yaml> [--policy-local <.harness/dep-policy.yaml>]
              [--report <.harness/reports/{project.id}-dep-last.md>] [--project <project.id>]
              [--today YYYY-MM-DD]

判据单源见 ci/dep-policy.yaml 头部注释（全量判定、ignore 须带 reason、expires 到期自动失效）。
"""

import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import policy_file as pf  # noqa: E402
import sys
from datetime import date

# 策略允许的顶层 key（其余顶层 key 视为书写错误，响亮报错而非静默忽略）
POLICY_KEYS = ("block_severities", "deny_licenses", "ignore")
SEVERITY_ORDER = ("UNKNOWN", "LOW", "MEDIUM", "HIGH", "CRITICAL")


# 策略文件的机械部分（标量 / 两级解析 / 两层并集 / 例外生命周期）归 **policy_file.py** ——
# 与 compatcheck 是同形兄弟，重复的是「策略文件」这个概念本身。**「判什么」留在本模块**：
# 漏洞严重级与许可证是 dep 门禁的价值，不该被「统一」掉。
_scalar = pf.scalar
parse_policy = lambda text: pf.parse(text, POLICY_KEYS)


def active_ignores(ignore_items, today):
    """dep 的例外主体字段是 `vuln` / `license`（compat 是 `engine`）。判据统一在 policy_file。"""
    return pf.active_ignores(ignore_items, today, ("vuln", "license"))


def norm_license(s):
    """许可证 id 归一：大写、去引号空白、去尾 `+`（`GPL-2.0+` ≡ `GPL-2.0-or-later`）。"""
    return _scalar(str(s)).upper().rstrip("+")


# 同族后缀白名单：只有这两个是「同一授予的强弱变体」（`GPL-3.0` ≡ `GPL-3.0-only`）。
# 刻意不含 `-with-<exception>`：那是**额外授予**，不是同一回事——裸 GPL-2.0 与
# GPL-2.0-with-classpath-exception 的法律效果相反（后者明确允许链接进闭源大作品）。
# 曾用 `startswith(deny + "-")` 一律前缀匹配，结果把 jakarta.annotation-api / jaxb-api 这类
# 标准 Java 依赖的 `GPL-2.0-with-classpath-exception` 判成 GPL-2.0：Java 项目条条假红，
# 而假红的门禁必然被无视——比漏报更糟。要拦某个例外形态，把完整 id 写进 deny_licenses
# （精确匹配即可命中，两条 deny 可同时命中一个 finding）。
_FAMILY_SUFFIXES = ("-ONLY", "-OR-LATER")


def license_match(deny, reported):
    """deny 条目是否命中 reported 许可。

    归一后相等（尾 `+` 已在归一里折掉，`GPL-2.0+` ≡ `GPL-2.0`），或 reported = `deny` +
    家族后缀 `-only` / `-or-later`。**不匹配 `-with-<exception>` 等额外授予形态**——理由见
    `_FAMILY_SUFFIXES` 注释。前缀不裸切，`GPL-2.0` 不会命中 `LGPL-2.0`，也不会命中
    `GPL-2.0-with-classpath-exception`。
    deny 与 ignore 共用同一匹配规则——例外范围必须与禁止范围对称，否则「写宽了放行、
    写窄了不生效」难以察觉。
    """
    d, r = norm_license(deny), norm_license(reported)
    if not d or not r:
        return False
    if r == d:
        return True
    return any(r == d + s for s in _FAMILY_SUFFIXES)


def parse_trivy(text):
    """trivy JSON → findings 列表。找不到 Results 视为不可解析（响亮失败，不当成 0 命中）。"""
    try:
        doc = json.loads(text)
    except json.JSONDecodeError as e:
        raise ValueError(f"trivy JSON 解析失败：{e}")
    if not isinstance(doc, dict) or "Results" not in doc:
        raise ValueError("trivy JSON 缺 Results 字段（非 trivy fs --format json 输出？）")
    results = doc.get("Results") or []
    if not isinstance(results, list):
        raise ValueError("trivy JSON 的 Results 不是数组")

    findings = []
    for r in results:
        if not isinstance(r, dict):
            continue
        target = r.get("Target") or ""
        for v in r.get("Vulnerabilities") or []:
            if not isinstance(v, dict):
                continue
            findings.append({
                "kind": "vuln",
                "id": v.get("VulnerabilityID") or "",
                "pkg": v.get("PkgName") or "",
                "version": v.get("InstalledVersion") or "",
                "severity": (v.get("Severity") or "UNKNOWN").upper(),
                "fixed": v.get("FixedVersion") or "",
                "title": v.get("Title") or "",
                "url": v.get("PrimaryURL") or "",
                "target": target,
            })
        for l in r.get("Licenses") or []:
            if not isinstance(l, dict):
                continue
            name = l.get("Name") or l.get("License") or l.get("ID") or ""
            findings.append({
                "kind": "license",
                "id": str(name),
                "pkg": l.get("PkgName") or "",
                "version": "",
                "severity": (l.get("Severity") or "").upper(),
                "fixed": "",
                "title": l.get("Category") or "",
                "url": "",
                "target": l.get("FilePath") or target,
            })
    return findings


def is_ignored(f, active):
    for it in active:
        if f["kind"] == "vuln" and it.get("vuln") and it["vuln"].upper() == f["id"].upper():
            return it
        if f["kind"] == "license" and it.get("license") and license_match(it["license"], f["id"]):
            return it
    return None


def blocking_findings(findings, policy, active):
    """命中即 red 的判定：漏洞看严重级，许可证看禁止清单；两者都先过 ignore。"""
    blocked_sev = {s.upper() for s in policy["block_severities"]}
    deny = policy["deny_licenses"]
    out = []
    for f in findings:
        if is_ignored(f, active):
            continue
        if f["kind"] == "vuln":
            if f["severity"] in blocked_sev:
                out.append(f)
        else:
            for d in deny:
                if license_match(d, f["id"]):
                    f = dict(f, matched_deny=d)
                    out.append(f)
                    break
    return out


def render_report(blocking, all_findings, policy, expired, no_reason, project="", trivy_note=""):
    """落盘 Markdown：结论 + blocking 清单 + 可直接粘贴的 ignore 骨架。

    带 project 时写 `project:` frontmatter——`.harness/reports/*.md` 的产出注入核对
    （closed-loop-audit.sh）要求所有报告带 project 字段且文件名带 project.id 前缀（ADR-0001 决策4）。
    """
    lines = ["# 依赖安全门禁报告（`dep`）", ""]
    if project:
        lines[0:0] = ["---", f"project: {project}", "kind: dep-report",
                      f"conclusion: {'red' if blocking else 'green'}", "---", ""]
    lines.append(f"- 扫描结论：{'RED（有 blocking）' if blocking else 'GREEN（无 blocking）'}")
    lines.append(f"- findings 总数：{len(all_findings)}（blocking {len(blocking)}）")
    lines.append(f"- 判定依据：block_severities={policy['block_severities']} · "
                 f"deny_licenses {len(policy['deny_licenses'])} 条")
    if trivy_note:
        lines.append(f"- 备注：{trivy_note}")
    lines.append("")
    if blocking:
        lines.append("## blocking")
        lines.append("")
        for f in blocking:
            if f["kind"] == "vuln":
                fix = f" · 修复版本 {f['fixed']}" if f["fixed"] else " · 无修复版本"
                lines.append(f"- **{f['id']}**（{f['severity']}）`{f['pkg']}@{f['version']}`"
                             f"{fix} · {f['target']}")
            else:
                lines.append(f"- **{f['id']}**（许可证，命中禁项 {f.get('matched_deny')}）"
                             f"`{f['pkg']}` · {f['target']}")
        lines.append("")
        lines.append("### 若需接受其中某条：写进 `.harness/dep-policy.yaml`（须带 reason）")
        lines.append("")
        lines.append("```yaml")
        lines.append("ignore:")
        for f in blocking:
            key = "vuln" if f["kind"] == "vuln" else "license"
            lines.append(f"  - {key}: {f['id']}")
            lines.append(f"    reason: \"\"   # 必填：为什么本项目可接受")
            lines.append(f"    expires: \"{date.today().replace(year=date.today().year + 1)}\"")
        lines.append("```")
        lines.append("")
    if expired:
        lines.append("## 已过期的例外（重新变红）")
        lines.append("")
        for it in expired:
            body = it.get("vuln") or it.get("license")
            lines.append(f"- `{body}`（expires {it.get('expires')}）→ 要么修，要么续期并说明")
        lines.append("")
    if no_reason:
        lines.append("## 无效例外（缺 reason / 主体字段 / expires 非法，未被采纳）")
        lines.append("")
        for it in no_reason:
            lines.append(f"- `{json.dumps(it, ensure_ascii=False)}`")
        lines.append("")
    return "\n".join(lines) + "\n"


def main(argv):
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")

    trivy_path = ""
    policy_paths = []
    report_path = ""
    project = ""
    today = date.today()
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
                sys.stderr.write(f"[depcheck] --today 日期格式非法（须 YYYY-MM-DD）：{argv[i]}\n"); return 2
        elif a.startswith("--"):
            sys.stderr.write(f"[depcheck] 未知参数：{a}\n"); return 2
        else:
            trivy_path = a
        i += 1

    if not trivy_path or not os.path.isfile(trivy_path):
        sys.stderr.write(f"[depcheck] 缺少或找不到 trivy JSON：{trivy_path}\n"); return 2
    try:
        # 两层并集 + 「shared 必备 / 本地可选」的守卫都归 policy_file.load ——
        # 与 compatcheck 是**同一份实现**（此前两边各写一遍，靠人记得对齐）
        policy = pf.load(policy_paths, POLICY_KEYS, "ci/dep-policy.yaml")
        findings = parse_trivy(open(trivy_path, encoding="utf-8").read())
    except (ValueError, OSError) as e:
        sys.stderr.write(f"[depcheck] {e}\n"); return 2

    active, expired, no_reason = active_ignores(policy["ignore"], today)
    blocking = blocking_findings(findings, policy, active)

    if report_path:
        try:
            os.makedirs(os.path.dirname(report_path) or ".", exist_ok=True)
            open(report_path, "w", encoding="utf-8").write(
                render_report(blocking, findings, policy, expired, no_reason, project))
        except OSError as e:
            sys.stderr.write(f"[depcheck] 报告写入失败：{e}\n")   # 报告写不出不影响判定

    for it in no_reason:
        print(f"[dep] WARN 无效例外（缺 reason/主体字段/expires 非法），未采纳："
              f"{json.dumps(it, ensure_ascii=False)}")
    for it in expired:
        print(f"[dep] WARN 例外已过期（{it.get('expires')}）："
              f"{it.get('vuln') or it.get('license')}")

    if not blocking:
        print(f"[dep] 无 blocking（findings {len(findings)} 条，生效例外 {len(active)} 条）")
        return 0
    for f in blocking:
        if f["kind"] == "vuln":
            print(f"[dep] RED 漏洞 {f['id']}（{f['severity']}）{f['pkg']}@{f['version']} "
                  f"· {f['target']}")
        else:
            print(f"[dep] RED 许可证 {f['id']}（禁项 {f.get('matched_deny')}）{f['pkg']} "
                  f"· {f['target']}")
    print(f"[dep] blocking {len(blocking)} 条（findings 总数 {len(findings)}）")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
