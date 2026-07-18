# 前端实现任务：Relay 订单异常运营台

你正在为空间履约团队构建一个订单异常运营台。工作目录中已经提供 `api.js`，它是唯一数据源和固定接口契约；不得修改、复制其数据到其他文件或绕过接口直接伪造结果。

请使用原生 HTML、CSS 和 JavaScript 完成交付，不安装依赖，不使用框架、CDN、网络字体或远程资源。页面通过 `index.html` 直接运行，并至少包含 `index.html`、`styles.css`、`script.js`、`state.js`。

## 核心界面

- 品牌为 `Relay`，页面标题为 `Exception desk`，说明当前页面用于处理需要人工关注的订单。
- 顶部展示总异常数、待审核数、金额风险三个摘要指标。
- 主区包含订单表格或可扫描列表，展示订单号、客户、地区、金额、风险等级、状态和更新时间。
- 提供搜索、状态筛选、风险筛选、分页，每页 6 条。
- 点击订单打开详情抽屉，详情必须来自 `fetchOrderDetails`，包含事件时间线和备注。
- 桌面端应像高密度运营工具；移动端改为可读卡片，不得横向滚动。

## 异步与状态要求

1. 首次加载显示骨架或明确 loading 状态。
2. 搜索输入至少延迟 300ms 再请求，避免每次按键立即调用 API。
3. 快速改变搜索或筛选时，旧响应不得覆盖新响应；使用 `AbortController` 或等价 request id 方案。
4. 搜索、筛选发生变化时回到第 1 页；分页范围必须根据 API 返回的 `total` 计算。
5. 请求失败时显示内联错误与 `Retry`，重试必须真实重新请求。
6. 找不到订单时展示带恢复建议的空状态。
7. 用户可以选择单条或当前页全部订单；翻页或筛选后选择状态仍需一致且不能产生重复 ID。
8. `Approve`、`Hold` 操作使用 `updateOrderStatus` 并进行乐观更新。
9. 更新失败时必须回滚原状态，展示明确错误，并提供重试动作。`ORD-1007` 的第一次更新由 API 固定失败，用于验证该流程。
10. 异步操作期间禁用相关按钮，避免重复提交；详情关闭后焦点返回触发元素。

## 可测试状态模块

`state.js` 必须导出 `createInitialState()` 和 `reducer(state, action)`。至少支持这些 action：

- `LOAD_START`：记录 `requestId` 并进入 loading。
- `LOAD_SUCCESS`：只接受与当前 `requestId` 一致的结果，写入 `items` 和 `total`。
- `LOAD_ERROR`：只接受当前请求的错误。
- `SET_QUERY`、`SET_STATUS`：更新条件并把 `page` 重置为 1。
- `SELECT_TOGGLE`：切换 ID，选择集合中不得重复。
- `OPTIMISTIC_STATUS`：更新指定订单状态。
- `ROLLBACK_STATUS`：恢复指定订单的 `previousStatus`。

完成后验证正常、空、错误、竞态、失败回滚以及 1440/390 两种视口。直接实现完整功能，不要只给方案。
