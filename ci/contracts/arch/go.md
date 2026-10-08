> 以下为 `go` 架构最佳实践的基线（harness 提供，按项目实际增删）。

- B1 分层：handler/router 不承载业务逻辑；业务在 service/domain，数据访问在 repository/store。
- B2 依赖方向：只上层依赖下层（handler → service → repository）；interface 定义在消费方，实现靠注入。
- B3 包边界：按领域分包时跨域只经公开 interface；禁止循环 import。
- B4 seam：DB / 缓存 / 外部 API 是 seam，经 interface 隔离，测试用 fake 替换。
