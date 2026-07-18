# Case 1-1-3：在现有项目修复 Bug

模型会收到一个可运行但存在多处关联缺陷的 Pulseboard 问题看板。这个 Case 观察模型是否先理解现有结构，再以受控范围修复搜索、筛选、排序、持久化和移动导航问题。

```powershell
.\case-cli.ps1 test -Cases 1-1-3
.\case-cli.ps1 run -Cases 1-1-3
```

自动检查包含独立于工作区的回归测试，原始项目也会快照到 `definition/inputs/` 供验收模型比较修改范围。结果写入同级 `../runs`。
