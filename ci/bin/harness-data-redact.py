#!/usr/bin/env python3
# harness-data-redact.py — 「脱敏但保完整性」深模块（ADR-0015 决策 6）。
#
# 套件的运行时数据不变量大量是**跨字段 / 跨记录**的（reconcile-zero 对账、constant 落定不变、
# monotonic 累计）。字段级 mask 会**直接打断不变量**：mask 金额 → 对账恒不成立；mask ID →
# 跨记录 join 断。故脱敏不是「把敏感字段都盖掉」，而是**保结构 + 保引用完整性 + 保可判定性**。
#
# 本模块把「保完整性」从一句设计口径变成**可执行的守卫**：它按策略逐字段脱敏，并在输出前
# 逐条核对声明的跨字段 / 跨记录不变量 —— 若某字段的脱敏动作会打断它所属的不变量，**拒绝产出**
# （exit 2），而不是静默吐出一份「对账永远失败」的脱敏数据。
#
# 纯标准库（不依赖 PyYAML）：策略是 JSON。确定性门禁不得依赖可选 pip 包（C1），本模块同守。
#
# 策略（JSON）：
#   {
#     "schema_version": 1,
#     "salt": "可复现盐（缺省用固定串；同盐+同值→同 token，保 equality/join）",
#     "rules": [
#       {"path": "items[*].customerPhone", "action": "tokenize"},
#       {"path": "items[*].idCard",        "action": "drop"},
#       {"path": "items[*].amount",        "action": "keep"}
#     ],
#     "invariants": [
#       {"id": "reconcile", "kind": "reconcile-zero", "fields": ["items[*].amount", "items[*].refund"]},
#       {"id": "unique",    "kind": "equality",       "fields": ["items[*].orderId"]}
#     ]
#   }
#
# action：keep（原样，用于参与算术不变量的字段）/ tokenize（确定性令牌，同值同 token）/
#         drop（删键；仅当该字段不参与任何已声明不变量时允许）。
#
# 用法: harness-data-redact.py --policy <policy.json> [--in <raw.json>|stdin] [--out <file>|stdout]
# 退出码：0=已脱敏（完整性守恒）/ 2=策略非法 / 脱敏会打断不变量 / 路径未匹配（静默空转）/ 输入不可解析（fail-fast，不假绿）
import argparse
import hashlib
import json
import sys


# 强制 stdout/stderr 为 UTF-8：Windows 下 Python 默认按 locale(cp936/GBK) 编码，本模块输出含中文
# （JSON 值 + stderr 汇总），消费方（judge / 测试）按 UTF-8 读会乱码 / 匹配失败。与 depgraph.py /
# metrics.py / depcheck.py 等 CLI 同款（套件约定：Python CLI 自锁 UTF-8 输出，不赖调用方 export）。
if hasattr(sys.stdout, "reconfigure"):
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")


def _fail(msg):
    print(f"[redact] {msg}", file=sys.stderr)
    sys.exit(2)


# 不变量类型 → 允许的脱敏动作（保完整性的可执行口径）。缺省动作是 keep。
#  - 变更模型原语（**单源**：ci/bin/harness-data-delta.sh 的 KNOWN = 七原语；别在此另抄一份字面量）：
#    · 算术 / 有序类（reconcile-zero / monotonic-* / bounded-rate / within-sigma）：tokenize 打断
#      数值关系与序，drop 丢值 → 只允许 keep。
#    · unbounded：无先验约束 → 脱敏不破坏它 → 允许 keep / tokenize / drop。
#    · constant：tokenize 保「常量 token 化后仍常量」→ 允许 keep / tokenize；drop 丢值 → 不允许。
#  - 引用完整性类（跨记录，七原语未覆盖，本模块自有的补充口径）：
#    existence / non-empty / equality / join：tokenize 保「同值同 token」故保 equality 与 join；
#    drop 会丢值 / 断 join → 只允许 keep / tokenize。
_ALLOWED = {
    # —— 变更模型七原语（单源见 harness-data-delta.sh:90-91 KNOWN）——
    "reconcile-zero": {"keep"},
    "monotonic-nondecreasing": {"keep"},
    "monotonic-nonincreasing": {"keep"},
    "bounded-rate": {"keep"},
    "within-sigma": {"keep"},
    "unbounded": {"keep", "tokenize", "drop"},
    "constant": {"keep", "tokenize"},
    # —— 引用完整性类（跨记录；七原语未覆盖）——
    "existence": {"keep", "tokenize"},
    "non-empty": {"keep", "tokenize"},
    "equality": {"keep", "tokenize"},
    "join": {"keep", "tokenize"},
}


def _token(value, salt):
    """确定性令牌：同盐 + 同值 → 同 token（保跨记录 equality / join）。"""
    canon = value if isinstance(value, str) else json.dumps(value, sort_keys=True, ensure_ascii=False)
    h = hashlib.sha256(f"{salt}\x1f{canon}".encode("utf-8")).hexdigest()[:12]
    return f"tok_{h}"


def _parse_path(p):
    """点路径 → [(key, star)]；`items[*].x` → [('items', True), ('x', False)]。"""
    segs = []
    for part in p.split("."):
        if part.endswith("[*]"):
            segs.append((part[:-3], True))
        else:
            segs.append((part, False))
    return segs


def _mask_scalar(value, action, ctx):
    if action == "keep":
        return value
    if action == "tokenize":
        if isinstance(value, (dict, list)):
            _fail(f"tokenize 只支持标量，遇到容器：{json.dumps(value, ensure_ascii=False)[:80]}")
        ctx["masked"] += 1
        return _token(value, ctx["salt"])
    _fail(f"内部错误：_mask_scalar 不接受的 action={action}")


def _transform(node, segs, action, ctx, path):
    """返回变换后的 node（不可变，返回副本）。segs 为空 = 当前 node 即目标值。
    path 仅用于按 rule 统计命中节点数（B2：命中 0 = 路径打错 → 拒绝静默空转）。"""
    if not segs:
        ctx["hits"][path] = ctx["hits"].get(path, 0) + 1
        return _mask_scalar(node, action, ctx)
    (key, star), rest = segs[0], segs[1:]
    if star:
        if key == "":
            if isinstance(node, list):
                return [_transform(el, rest, action, ctx, path) for el in node]
            return node
        if isinstance(node, dict) and isinstance(node.get(key), list):
            out = dict(node)
            out[key] = [_transform(el, rest, action, ctx, path) for el in node[key]]
            return out
        return node
    if isinstance(node, dict) and key in node:
        out = dict(node)
        if rest:
            out[key] = _transform(node[key], rest, action, ctx, path)
        else:
            ctx["hits"][path] = ctx["hits"].get(path, 0) + 1
            if action == "drop":
                del out[key]
                ctx["dropped"] += 1
            elif action == "tokenize":
                out[key] = _mask_scalar(node[key], "tokenize", ctx)
            # keep: 原样
        return out
    return node


def _load_policy(path):
    try:
        with open(path, encoding="utf-8") as f:
            pol = json.load(f)
    except FileNotFoundError:
        _fail(f"缺少脱敏策略：{path}")
    except Exception as e:
        _fail(f"策略不可解析（{path}）：{e}")
    if not isinstance(pol, dict):
        _fail("策略顶层应为对象")
    rules = pol.get("rules") or []
    invs = pol.get("invariants") or []
    if not isinstance(rules, list) or not isinstance(invs, list):
        _fail("策略的 rules / invariants 应为数组")
    actions = {}
    for r in rules:
        if not isinstance(r, dict) or not r.get("path"):
            _fail(f"rules 每项须含 path：{r!r}")
        act = r.get("action", "keep")
        if act not in ("keep", "tokenize", "drop"):
            _fail(f"未知 action={act}（path={r.get('path')}）")
        actions[str(r["path"])] = act
    return pol, actions, invs


def _guard(actions, invs):
    """保完整性守卫：脱敏动作不得打断任何已声明的不变量。命中即 fail-fast。"""
    for inv in invs:
        if not isinstance(inv, dict):
            _fail(f"invariants 每项应为对象：{inv!r}")
        kind = str(inv.get("kind", ""))
        if kind not in _ALLOWED:
            _fail(f"未知不变量类型 kind={kind!r}（invariant={inv.get('id')}）")
        allowed = _ALLOWED[kind]
        for field in inv.get("fields") or []:
            act = actions.get(str(field), "keep")
            if act not in allowed:
                _fail(
                    f"脱敏会打断不变量「{inv.get('id')}」(kind={kind})：字段 {field} 的动作 {act} "
                    f"不被允许（该类型只允许 {'/'.join(sorted(allowed))}）—— 保完整性口径要求该字段 "
                    f"保持可判定，请改用 keep"
                )


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--policy", required=True)
    ap.add_argument("--in", dest="infile")
    ap.add_argument("--out", dest="outfile")
    args = ap.parse_args()

    pol, actions, invs = _load_policy(args.policy)
    _guard(actions, invs)  # 先判守卫，避免「先脱敏再发现打断」的浪费与误导

    if args.infile:
        try:
            raw = open(args.infile, encoding="utf-8").read()
        except OSError as e:
            _fail(f"输入文件不可读：{args.infile}（{e}）")
    else:
        raw = sys.stdin.read()
    try:
        data = json.loads(raw)
    except Exception as e:
        _fail(f"输入数据不可解析为 JSON：{e}")

    ctx = {"salt": str(pol.get("salt", "harness-redact")), "masked": 0, "dropped": 0, "hits": {}}
    out = data
    for path, act in actions.items():
        out = _transform(out, _parse_path(path), act, ctx, path)

    # B2：路径未匹配任何节点 = 脱敏静默空转（拼写错 / 用了不支持的 [n] 下标语法，只支持 [*]）。
    # 对安全控制而言这是假绿（PII 原样进 prompt 却报「已脱敏」）→ 拒绝产出，不宣称完整性守恒。
    zero = sorted(p for p in actions if ctx["hits"].get(p, 0) == 0)
    if zero:
        _fail(
            "脱敏策略路径未匹配任何节点（疑似拼写错，或用了不支持的 [n] 下标语法，只支持 [*]）："
            + ", ".join(zero)
            + " —— 拒绝宣称「完整性守恒」（安全控制不得静默空转）"
        )

    text = json.dumps(out, ensure_ascii=False, indent=2)
    if args.outfile:
        try:
            with open(args.outfile, "w", encoding="utf-8") as f:
                f.write(text + "\n")
        except OSError as e:
            _fail(f"输出文件不可写：{args.outfile}（{e}）")
    else:
        sys.stdout.write(text + "\n")
    print(
        f"[redact] 已脱敏：tokenize {ctx['masked']} 字段 / drop {ctx['dropped']} 字段；"
        f"核对不变量 {len(invs)} 条，完整性守恒",
        file=sys.stderr,
    )
    sys.exit(0)


if __name__ == "__main__":
    main()
