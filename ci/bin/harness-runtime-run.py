#!/usr/bin/env python3
# harness-runtime-run.py — 运行时数据契约的「纯解析器」深模块（方向 B：消除 per-domain 生成脚本）。
# 只做纯解析：读配置三源 → 校验 → 吐 JSON 执行计划（每域 env + 三步名）。不跨进程调任何 .sh；
# 编排（逐域 抓取→预检→判定）由 harness-runtime-check.sh 用 bash 直接完成（避开 Windows 下 Python→bash
# subprocess 的 WinError 193 / 反斜杠 / WSL bash 之类脆弱性）。只读不修线上。
#
# 配置三源：
#   .harness/env.yaml            env.data.*（endpoint 基址/header/auth_scheme/extra_headers/白名单）单源
#   .harness/runtime-config.yaml 每域 endpoint_path / collection_name / conditions[{field,value}] / subject_key / account_id_key
#   .harness/runtime-subjects.yaml 依赖数据值（subject/accountId，harness-close 抓取后填，PENDING=未填）
# 用法: harness-runtime-run.py [ROOT]    （缺省按本文件位置推导仓库根；harness-runtime-check.sh 薄包装调用）
# 退出码：0=全绿 / 1=至少一域红（不变量违例或抓取失败或配置缺失）；无 runtime-config.yaml 时跳过 exit 0。
import json
import os
import sys


def _fail(msg):
    print(f"[runtime] {msg}", file=sys.stderr)
    sys.exit(2)


def _load_yaml(path, required=False):
    if not os.path.isfile(path):
        if required:
            _fail(f"缺少 {path}")
        return {}
    try:
        import yaml  # PyYAML（runtime 回路依赖，见 ci/requirements-runtime.txt）
    except ImportError:
        _fail(f"需 PyYAML：pip install -r ci/requirements-runtime.txt（{path} 解析依赖）")
    with open(path, encoding="utf-8") as f:
        return yaml.safe_load(f) or {}


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.path.abspath(
        os.path.join(os.path.dirname(__file__), "..", ".."))
    hd = os.path.join(root, ".harness")

    identity = _load_yaml(os.path.join(hd, "identity.yaml"), required=True)
    pid = identity.get("id") or (identity.get("project") or {}).get("id")
    if not pid:
        _fail("identity.yaml 缺 project.id")

    env_cfg = _load_yaml(os.path.join(hd, "env.yaml")).get("env", {}) or {}
    data = env_cfg.get("data", {}) or {}
    endpoint_base = (data.get("endpoint") or "").rstrip("/")
    header = data.get("header") or "Authorization"
    auth_scheme = data.get("auth_scheme")
    auth_scheme = "Bearer" if auth_scheme is None else auth_scheme  # 显式空串=裸 token
    extra_headers = data.get("extra_headers") or []
    if isinstance(extra_headers, str):
        extra_headers = [extra_headers]
    allowlist_raw = data.get("allowed_query_account_id") or ""

    cfg = _load_yaml(os.path.join(hd, "runtime-config.yaml"))
    subjects = _load_yaml(os.path.join(hd, "runtime-subjects.yaml"))
    subjects = subjects if isinstance(subjects, dict) else {}

    if not cfg:
        print(json.dumps({"pid": pid, "domains": []}, ensure_ascii=False))
        return
    if not endpoint_base:
        _fail("缺 env.data.endpoint（只读查询接口基址）——有 runtime-config.yaml 但 env.yaml 未配置 env.data.endpoint")

    # 白名单是循环不变量：提前算一次 + 空检查 fail fast，不在每域循环里重算
    allowed = [a.strip() for a in allowlist_raw.split(",") if a.strip()]
    if not allowed:
        _fail("缺 env.data.allowed_query_account_id（允许查询白名单，逗号分隔）")

    domains = []
    failed = 0
    for domain, d in cfg.items():
        domain = str(domain)
        d = d or {}
        if not isinstance(d, dict):
            print(f"[runtime] 域 {domain} 配置格式错误（应为映射）", file=sys.stderr)
            failed += 1
            continue
        if any(c not in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-" for c in domain):
            print(f"[runtime] 域 {domain} 含非法字符（只允许 [A-Za-z0-9._-]）", file=sys.stderr)
            failed += 1
            continue

        endpoint_path = (d.get("endpoint_path") or "").lstrip("/")
        collection_name = (d.get("collection_name") or "").strip()
        subject_key = d.get("subject_key") or domain
        account_id_key = d.get("account_id_key") or f"{domain}-accountId"

        if not collection_name:
            print(f"[runtime] {domain} 缺 collection_name（data-trace 查询集合名，如 OrderRecord）", file=sys.stderr)
            failed += 1
            continue

        # 结构化查询规格 → data-trace body（真实 schema：collectionName + accountId + conditions[]，均等值）。
        # conditions 每项 {field, value}；value 支持 $subject / $account_id 哨兵注入依赖数据值。
        conditions = d.get("conditions") or []
        if not isinstance(conditions, list):
            print(f"[runtime] {domain} conditions 应为列表（[{field, value}, ...]）", file=sys.stderr)
            failed += 1
            continue
        parsed = []          # [(field, value)]，value 保留哨兵原文
        need_subject = False
        ok = True
        for c in conditions:
            if not isinstance(c, dict):
                print(f"[runtime] {domain} conditions 每项应为映射 {{field, value}}", file=sys.stderr)
                ok = False
                break
            field = (c.get("field") or "").strip()
            value = c.get("value")
            value = "" if value is None else str(value)
            if not field:
                print(f"[runtime] {domain} conditions 项缺 field（查询字段名，支持点路径）", file=sys.stderr)
                ok = False
                break
            if value == "$subject":
                need_subject = True
            parsed.append((field, value))
        if not ok:
            failed += 1
            continue

        # 依赖数据：accountId 必填（data-trace accountId 必须 + 白名单）；subject 仅在 conditions 引用 $subject 时必填
        account_id = (subjects.get(account_id_key) or "").strip()
        if not account_id or account_id.upper() == "PENDING":
            print(f"[runtime] {domain} 缺依赖数据：runtime-subjects.yaml 的 {account_id_key} 未填真实值（PENDING/空）", file=sys.stderr)
            failed += 1
            continue

        if account_id not in allowed:
            print(f"[runtime] {domain} accountId 不在允许查询白名单内（accountId={account_id}, allowed={allowlist_raw}）", file=sys.stderr)
            failed += 1
            continue

        subject = ""
        if need_subject:
            subject = (subjects.get(subject_key) or "").strip()
            if not subject or subject.upper() == "PENDING":
                print(f"[runtime] {domain} 缺依赖数据：conditions 引用 $subject 但 runtime-subjects.yaml 的 {subject_key} 未填真实值（PENDING/空）", file=sys.stderr)
                failed += 1
                continue

        # 哨兵注入 → data-trace body（POST JSON）
        cond_list = []
        for field, value in parsed:
            if value == "$subject":
                value = subject
            elif value == "$account_id":
                value = account_id
            cond_list.append({"field": field, "value": value})
        endpoint = f"{endpoint_base}/{endpoint_path}" if endpoint_path else endpoint_base
        body = json.dumps({"collectionName": collection_name, "accountId": account_id, "conditions": cond_list})

        domains.append({
            "domain": domain,
            "env": {
                "HARNESS_DATA_ENDPOINT": endpoint,
                "HARNESS_DATA_HEADER": header,
                "HARNESS_DATA_AUTH_SCHEME": auth_scheme,
                "HARNESS_DATA_EXTRA_HEADERS": extra_headers,  # 列表；bash 端 join("\n")
                "HARNESS_DATA_METHOD": "POST",   # data-trace /query 为 POST（结构化查询规格专形）
                "HARNESS_DATA_BODY": body,
            },
        })

    if failed:
        # 有域配置/依赖数据缺失：不吐计划（须先修配置再跑）
        sys.exit(1)
    print(json.dumps({"pid": pid, "domains": domains}, ensure_ascii=False))


if __name__ == "__main__":
    main()
