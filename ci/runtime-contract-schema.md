# 运行时契约配置 schema（数据不变量侧）

**本文件是运行时契约数据侧字段的单一真源**（与 [`work-unit-schema.md`](work-unit-schema.md) 同构）。
`harness-close` 步骤 1 只写「要落哪些文件、跑哪条链」，字段级细节在此查。

只有**本项目存在数据不变量**时才读本文件；纯日志类（行为不变量）项目不看。不变量语义本身来自 TSD
的「数据不变量」节（数据链 source→sink + 条件 + 断言 + 只读查询接口 + 变化模型），此处只讲**怎么配**。

配置**三源、单源不重复**（不硬编码、不生成 per-domain 脚本）：

| 源 | 文件 | 承载 |
|---|---|---|
| 1 | `.harness/env.yaml` → `env.data.*` | 接口基址、认证头、白名单（跨域共用） |
| 2 | `.harness/runtime-config.yaml` | 每域的执行参数（endpoint_path / collection_name / conditions / key） |
| 3 | `.harness/runtime-subjects.yaml` | 依赖数据值（subject / accountId） |

## 1. `.harness/env.yaml` → `env.data.*`

| 字段 | 含义 | 缺省 |
|---|---|---|
| `endpoint` | 接口基址 | 必填 |
| `header` | 认证头名 | `Authorization` |
| `auth_scheme` | 头值前缀 | `Bearer`；显式空串 = 裸 token |
| `extra_headers` | 额外头列表 | 空 |
| `allowed_query_account_id` | 允许查询主体白名单，逗号分隔 | 必填（空即 fail fast） |
| `trace_impl` | 数据访问面：`http`（现状，endpoint 远程只读 API）/ `cli`（ADR-0017，经项目本地 `.harness/data_trace/` 统一接口） | `http` |

`HARNESS_DATA_TOKEN`（只读 token）走 CI secrets（CI yml 注入），**不进 env.yaml**。

### 1.1 数据访问面：`http` 直连 vs `cli` 项目本地接口（ADR-0017）

- **`trace_impl: http`（缺省，维持现状）**：执行器按 §2 的 collection_name / conditions 组装
  `{collectionName, accountId, conditions[]}` POST 到 `env.data.endpoint`，根为 `EntityData`（items）。
- **`trace_impl: cli`（ADR-0017，项目本地统一只读接口）**：执行器委托
  `ci/bin/harness-data-trace.sh`，把 `collection_name` / `conditions` 映射为
  `query <entity> --where '<json>'`（等值条件数组），响应归一化为同一 `EntityData` 形状，断言零改动。
  - 接口**项目唯一**：`.harness/data_trace/`（manifest.yaml 已批准方法集 + source.yaml + cli 入口）。
  - 缺本地接口时**维持现状降级**：仍走 `endpoint` 远程抓取，不报错（同 harness-close 降级语义）。
  - 数据源可插拔：`.harness/data_trace/source.yaml` 声明 `source: local`（adapter 直连项目 DB/文件
    只读连接）或 `source: uat`（adapter 用只读 token 代理调用 UAT 只读 API，复用
    `HARNESS_DATA_ENDPOINT` / `HARNESS_DATA_TOKEN` 或 source.yaml 内 `uat.endpoint` 配置，归一化为
    `EntityData`）。同一套断言本地 / UAT 双环境跑，换 source.yaml 即可，契约零改动。
  - 治理：manifest = 已批准方法集（带 `reviewed_by` / `reviewed_at`）；新增数据获取方法须人工审核
    （need-human 出口，ADR-0017 决策 5）；实现含写语义命令 = blocking。接口存在性与方法对账由
    `closed-loop-audit.sh` 在数据校验前检查（缺接口 = rung 3 红，ADR-0017 决策 6）。

## 2. `.harness/runtime-config.yaml`（每域一条）

| 字段 | 含义 |
|---|---|
| `endpoint_path` | 拼到 `env.data.endpoint` 基址后 |
| `collection_name` | Mongo 集合名 |
| `conditions` | 等值条件数组，每项 `{field, value}`；`field` 支持点路径 |
| `subject_key` / `account_id_key` | 指向 `.harness/runtime-subjects.yaml` 的 key |

执行器按 data-trace 真实 schema 组装 `{collectionName, accountId, conditions[]}`（POST JSON）；
`value` 用 `$subject` / `$account_id` **哨兵**注入依赖数据值，不手写 body 字符串。

## 3. `.harness/runtime-subjects.yaml`

依赖数据值（`subject` / `accountId`），未填写 `PENDING`。取值依据见 §6。

## 4. 契约 frontmatter 与「变化模型」管道表

`harness-close` 生成的 `.harness/contracts/{pid}-runtime-{domain}.md` 必带：

- frontmatter `source_tsd: <生成该契约的 TSD slug>` —— 供 data-judge 注入源 TSD 的「数据不变量」
  「可观测性」节，让 judge 拿到合法变化语义。
- 正文「变化模型」管道表，列 `metric | json_path | primitive | params`，从 TSD 的「数据不变量」逐条填：

| 列 | 规则 |
|---|---|
| `metric` | 度量名（进报告与 drift 文件） |
| `json_path` | 点路径，数组用 `[*]` 摊平；**根为 data-trace 响应的 `EntityData`**，先经 `items` 再进文档字段，如 `items[*].signItems[*].bSignConfirmQty` |
| `primitive` | 七原语之一，见 [`constraint-model.md`](constraint-model.md) |
| `params` | 原语参数；可带 `except: <逗号分隔合法例外>`（该 metric 在这些情形下合法变化，供 judge 区分正当变化 vs 回归） |

七原语：`monotonic-nondecreasing` / `monotonic-nonincreasing` / `constant` / `bounded-rate` /
`within-sigma` / `reconcile-zero` / `unbounded`。

## 5. 多文档语义（data-trace 无服务端排序 / 限窗 / limit）

`conditions` 命中多条 `items` 时，契约**必须声明该 metric 是逐条还是聚合**；聚合要给口径
（count / max ts / 最新一条）。需时间窗或排序只能在 `items` 上客户端做并写明规则，或靠 `$subject`
等值把结果收敛到单条。否则变化模型在多文档上无定义（delta 的 min/max 比较失效）。

## 6. 依赖数据获取（subject / 入参派生）

只读查询若带入参（如 `?saleOrderId=<refNum>`），**入参不得留空占位**。按 TSD 声明的数据依赖获取
依赖数据（输入/主体，如单号），来源由 TSD 定（日志埋点 key / 另一只读接口 / 已知样本，**不限日志**）。

候选可能很多，须分析去重后给出**选取依据**（如：最近一次已确认签收的订单 / 覆盖 AUDIT 与 DIRECT
两分支的代表样本 / 本次变更验证引用的那张单），把选中主体写入 `.harness/runtime-subjects.yaml`
（key = domain），选取依据落契约或报告可复核。

## 7. 观测缺口（接口不规则）

派生时若声明的不变量 / 变化模型 metric **无法经声明的只读端点观测到**（字段缺失 / 形状不符），
**不得静默删除该 metric**。应：

1. 契约里标注「观测缺口」并写明原因；
2. 用 `ci/bin/harness-runtime-issue.sh`（entry: cs-issue）建一条**接口优化建议**（补字段 / 纠正响应形状）。

该 metric 的变化模型暂不落确定性预检，接口修正后再补。

## 8. 跨业务因果校验（离线，ADR-0015）

与时间轴（§4 变化模型）、单写值断言（DATA-003）**正交**：它只回答一个问题 —— **这份共享数据的变化，
能否被 baseline 代码声明的合法写点 + 日志实际触发链解释？** 不答漂移，也不对多写字段做值断言。
执行入口 `ci/bin/judge-review.sh data-causal <domain>`（委托 `ci/bin/harness-data-causal-judge.sh`）。

### 8.1 共写声明（`writers: multi` 的 sink 字段）

ADR-0008 已确立多写字段的值断言无意义。本轴要判「其他业务的改动对不对」，故契约须对每个多写 sink
字段**声明全部业务写点**。写点用**机器可读行** `write-point: <代码路径>`（供 judge 只读检索 baseline
代码），并在正文表中给人读的语义：

```
## 跨业务因果校验

共写声明（sink 字段 ← 各业务写点）：

| sink 字段 | 业务写点 | 触发事件 key | 代码路径 |
|---|---|---|---|
| signStatus | 签收发起 | sign.initiate | src/.../SignService.java |
| signStatus | 撤销     | sign.revoke   | src/.../RevokeService.java |

write-point: src/.../SignService.java
write-point: src/.../RevokeService.java
```

- 契约**至少声明一条** `write-point:`，否则 judge 退出 2（无写点即无法重建触发链，决策 2）。
- 写点路径须在客户确认的 baseline 上存在；取不到时 judge 打警告（不静默）。

### 8.2 baseline 锚（客户确认，不得默认）

- **baseline** = 产出当前线上数据的那个状态（部署 / 参考态），**不是待评审的改动**。
- **作用域 = 全仓单锚**（`.harness/baseline.yaml` 一份）：baseline 是一个 git 引用（分支 / commit）
  = 一次部署态，产出全仓所有域的数据，故是**仓级**而非 per-domain；各域共享同一锚。若日后需按域
  pin 不同部署态，另立 `baseline-{domain}.yaml`（本 ADR 未要求，暂不实现）。
- 落盘（**唯一权威状态**）：`baseline_ref` + `baseline_sha`（确认时解析的不可变 commit，保可复现）
  + `confirmed_by` + `confirmed_at`。
- 取值经 `ci/bin/harness-baseline.sh confirm <ref> --by <who>`；**由客户经 `AskUserQuestion` 显式确认**
  （skill 流程），agent 不得自动推断 / 取默认（当前分支 / HEAD / 最近提交一概不许）。
- **确认人 allowlist（决策 3 的结构性守卫）**：`--by <who>` 必须**等于** `identity.yaml` 声明的
  `project.owner`，任何未声明的来源（含 agent 名）一律拒绝（退出 2）。局限如实：本地脚本无法**证明**
  人类身份，此守卫只保证「确认人 = 已声明 owner」这一结构约束，真正的保证是 owner 经 `AskUserQuestion`
  应答的流程。
- `check` 在未确认或**引用已漂移**（分支推进，SHA 不符）时退出 2。

### 8.3 日志契约（触发证据）

每个合法写点必须埋点，事件 key 见 §8.1 表；日志为触发证据，回答「哪些写点**实际**触发」。
缺日志 = 事件不完整 → judge 判 need-human（决策 8：缺事件不给因果结论）。日志路径由
`HARNESS_CAUSAL_LOG` 指定，缺省 `.harness/reports/causal-{domain}.log.jsonl`。

### 8.4 脱敏策略（脱敏但保完整性，决策 6）

脱敏须保**结构 + 引用完整性 + 可判定性**。策略落 `.harness/redact-{domain}.json`（JSON，纯标准库解析，
不入 `reports/`），由 `ci/bin/harness-data-redact.py` 执行：

```json
{
  "schema_version": 1,
  "salt": "<可复现盐>",
  "rules": [
    {"path": "items[*].customerPhone", "action": "tokenize"},
    {"path": "items[*].amount",        "action": "keep"}
  ],
  "invariants": [
    {"id": "reconcile", "kind": "reconcile-zero", "fields": ["items[*].amount", "items[*].refund"]}
  ]
}
```

- `action`：`keep`（原样，参与算术不变量的字段）/ `tokenize`（确定性令牌，同值同 token，保 equality/join）/
  `drop`（删键，仅当该字段不参与任何已声明不变量时允许）。
- **保完整性守卫**（可执行）：逐条核对 `invariants`，若某字段动作会打断其不变量（如对 `reconcile-zero`
  参与字段 `tokenize` / `drop`），**拒绝产出**并退出 2 —— 把「保完整性」从设计口径变成可失败的门。
- **路径命中守卫**（可执行）：逐条 rule 统计命中节点数，任一路径命中 0 个节点（拼写错 / 用了不支持的
  `[n]` 下标语法，只支持 `[*]`）即**拒绝产出**并退出 2 —— 对安全控制而言静默空转是假绿（PII 原样进
  prompt 却报「已脱敏」）。
- 该策略是 causal 轴的**必填输入**：缺 `.harness/redact-{domain}.json` → judge 退出 2（不把未脱敏
  数据送 LLM）。

### 8.5 落点（决策 7）

脱敏快照是**派生视图**：用时生成、**不落盘**（ADR-0012 决策 4「产出即被消费」——答不上消费者即降级为
派生视图）。**不得**充当漂移判据源（ADR-0006 决策 9「快照当判据源 = 自欺」），只作点时刻证据基。
