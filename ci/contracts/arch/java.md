> 以下为 `java`（Maven/Gradle）架构最佳实践的基线（harness 提供，按项目实际增删；删掉不适用的比留空更好）。

- B1 分层依赖：service/repository/model 不得反向 import controller/web；依赖单向向下。
- B2 域边界：service.<domain> 每域含自有 .model；跨域只经 service 接口，禁止直连对方 repository。
- B3 模块边界：各子模块之间仅通过 HTTP API 通信，禁止代码层共享（common 例外，且 common 不得依赖业务模块）。
- B4 对外 DTO 契约：同步给外部系统的 DTO 字段与真实 camelCase 对齐；DTO 不承载业务逻辑。
- B5 seam：持久化（repository/DAO）、外部调用（feign/http client）、消息（MQ producer/consumer）是 seam，业务层只依赖接口不依赖实现。
