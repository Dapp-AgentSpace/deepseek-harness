> 以下为 `rust` 架构最佳实践的基线（harness 提供，按项目实际增删）。

- B1 模块边界：crate 边界即边界；workspace 成员之间只依赖公开 API，禁止 pub use 穿透内部模块。
- B2 依赖方向：上层（api/服务）依赖下层（domain/repo），domain 不依赖具体框架/驱动。
- B3 seam：trait 定义在消费方；DB/网络/文件等副作用经 trait 隔离，测试注入 fake。
- B4 错误边界：错误类型在边界转换，不把内部错误类型裸露到公开 API。
