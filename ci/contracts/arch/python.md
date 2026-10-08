> 以下为 `python` 架构最佳实践的基线（harness 提供，按项目实际增删）。

- B1 分层：路由/视图（view/route）不承载业务逻辑；业务在 service/domain，数据访问在 repository/dao。
- B2 依赖方向：只上层依赖下层（view → service → repository）；domain 不 import 具体框架/驱动。
- B3 包边界：按领域分包；跨域只经公开 service 接口，禁止循环 import。
- B4 seam：DB / 外部 API / 消息是 seam，经 interface/协议隔离，测试可替换 fake。
