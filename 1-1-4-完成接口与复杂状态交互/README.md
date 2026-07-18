# Case 1-1-4：完成接口与复杂状态交互

这个 Case 提供不可修改的 Mock API，测试模型能否完成真实异步数据流，而不仅是静态页面：防抖、竞态隔离、分页、详情、选择、乐观更新、失败回滚和重试都进入评分。

```powershell
.\case-cli.ps1 test -Cases 1-1-4
.\case-cli.ps1 run -Cases 1-1-4
```

独立检查器会校验 API 文件完整性和 reducer 的关键状态转换。
