# Case 1-1-1：从零实现一个响应式页面

这个 Case 用来测试模型能否把一份产品需求独立转化为完整、可运行、可响应式适配的前端页面。

它不是在测试框架记忆，也不要求联网安装依赖。待测模型必须使用原生 HTML、CSS 和 JavaScript，在空目录中完成页面。这样可以把评分重点放在需求理解、页面结构、视觉质量、响应式设计、交互完整性和工程基本功上。

## 一键运行

推荐在 `cases` 根目录使用统一 CLI：

```powershell
.\case-cli.ps1 test -Cases 1-1-1
```

测试并验收：

```powershell
.\case-cli.ps1 run -Cases 1-1-1 -TestModel "测试模型" -JudgeModel "验收模型"
```

本目录的 `run-case.ps1` 仅作为旧命令兼容入口：

```powershell
.\run-case.ps1 -Model "测试模型" -JudgeModel "验收模型"
```

## 运行前提

- Windows PowerShell 7+。
- 已安装并登录 Claude Code，命令 `claude` 可用。
- 默认使用 Claude Code 当前配置；也可以通过 CLI 参数指定模型路由或独立 settings 文件。
- 建议安装 Microsoft Edge 或 Google Chrome，以生成桌面端和移动端截图。没有浏览器时仍可完成代码评审，但视觉评分的证据会减少。

## 脚本会做什么

1. 在 Case Hub 外层的 `runs` 中创建本次运行目录和一个完全空白的 `workspace`。
2. Case 目录始终只保留定义、题面、量表和可复用检查代码。
3. 启动一个新的 Claude Code 非交互会话，让待测模型按照 [task.md](./prompts/task.md) 从零实现页面。
4. 运行确定性检查，验证交付文件、关键需求、离线资源和基本响应式约束。
5. 启动本地静态服务器，尽可能生成桌面端与移动端截图。
6. 使用 `run` 或后续 `review` 时，启动另一个新的 Claude Code 会话，让验收模型依据 [rubric.md](./prompts/rubric.md) 独立评分。
7. 将每次验收写入独立的 `reviews/<review-id>`，并保留题面快照、工作区、原始回复、检查结果和截图。

每次 Claude Code 调用都会使用新的 UUID 和 `--no-session-persistence`，不会续接任何历史对话。验收会话与作答会话完全分离；批量测试中的每个 Case 也分别使用新会话。

## 输出结构

```text
../../runs/1-1-1/<实际模型>/<run-id>/
├── definition/                    # 执行时的 Case、题面和量表快照
├── workspace/                     # 待测模型交付物
├── evidence/
│   ├── checks.json                # 自动检查结果
│   ├── desktop.png                # 1440 × 1000
│   └── mobile.png                 # 390 × 844
├── test-response.json             # 待测模型 CLI 原始输出
├── run.json                       # 模型身份与运行元数据
└── reviews/<review-id>/           # 可由不同模型进行多次独立验收
    ├── judge-response.json
    ├── review.json
    └── report.md
```

## 评分原则

总分 100 分：

| 维度 | 分值 | 重点 |
|---|---:|---|
| 需求覆盖 | 25 | 内容区块、交互和约束是否全部落地 |
| 响应式设计 | 20 | 桌面/移动布局、导航切换、无横向溢出 |
| 视觉与信息层级 | 20 | 排版、间距、色彩、完成度和一致性 |
| 结构与工程质量 | 15 | 语义结构、CSS 组织、JS 清晰度和可维护性 |
| 交互与可用性 | 10 | 菜单、筛选、按钮反馈及状态表达 |
| 可访问性与健壮性 | 10 | 键盘、焦点、标签、降级、离线可用 |

自动检查只提供证据，不直接替代 AI 判断。评审必须结合题面、源码、自动检查和截图给分，并在报告中列出具体证据与扣分原因。

## 重跑策略

脚本不会覆盖以前的结果。每次运行都会在模型文件夹下新建时间戳目录，因此可以比较同一模型的多次运行。
