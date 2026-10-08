> 以下为 `npm`（JS/TS）架构最佳实践的基线（harness 提供，按项目实际增删）。

- B1 分层：presentation（组件/页面）不承载业务逻辑；业务在 service/domain，数据访问在 repository/api client。
- B2 依赖方向：单向依赖（presentation → service → repository）；禁止反向 import 与循环 import。
- B3 模块边界：包/目录按领域划分；跨域只经公开 export 的 service/interface；组件库不反向依赖业务。
- B4 seam：HTTP / 存储 / 第三方 SDK 是 seam，经 interface 隔离，测试可 mock。
