# LLM Cases

LLM Cases 是一套面向编码模型的可复现能力测试库。当前版本聚焦“编码能力 / 前端能力”，通过统一的 Case 定义、隔离的 Claude Code 会话、自动检查、浏览器截图和 AI 验收，对不同模型的实际交付能力进行比较。

本仓库只保存稳定、可复用的 Case 与运行器。所有动态产物统一写入同级的 `../runs`，不会污染 Case 源目录，也不与展示和管理系统 Case Hub 耦合。

## 核心特性

- 支持单个、多个或全部 Case 顺序执行。
- 测试与验收可以分开执行，也可以一键串联。
- 每个 Case、每次验收均创建全新的 Claude Code 会话，避免上下文污染。
- 测试模型和验收模型可使用不同的模型路由、服务商或 settings。
- 同时记录请求模型、配置模型和响应中 `modelUsage` 返回的实际模型。
- 自动保存题面快照、交付代码、确定性检查、精确视口截图和 AI 评分报告。
- 每次验收保留完整审计记录，并将最新报告同步到 `../runs/Summary` 方便浏览。

## 环境要求

- Windows PowerShell 7 或兼容的 PowerShell 环境。
- 已安装并能够正常运行的 [Claude Code](https://docs.anthropic.com/en/docs/claude-code)。
- Microsoft Edge，用于通过 Chrome DevTools Protocol 截取精确视口证据。
- Node.js，用于部分 Case 的独立 JavaScript 回归检查。

Claude Code 的模型和服务商由其 settings 决定。仓库不会保存或复制 API Key。

## 快速开始

查看可用 Case：

```powershell
.\case-cli.ps1 list
```

打开交互式菜单：

```powershell
.\case-cli.ps1
```

只测试一个 Case：

```powershell
.\case-cli.ps1 test -Cases 1-1-1
```

测试多个或全部 Case：

```powershell
.\case-cli.ps1 test -Cases 1-1-1,1-1-2
.\case-cli.ps1 test -All
```

测试完成后立即验收：

```powershell
.\case-cli.ps1 run -Cases 1-1-1
.\case-cli.ps1 run -All
```

批量任务按顺序执行，但每个 Case 使用独立会话。单个 Case 失败时，CLI 会记录错误并继续处理批次中的后续 Case，最终以非零退出码报告批次异常。

## 测试与验收分离

`test` 只让待测模型完成任务、运行自动检查并生成截图，不启动 AI 验收：

```powershell
.\case-cli.ps1 test -Cases 1-1-3
```

`review` 只验收已经存在的运行结果，不会重新执行测试：

```powershell
.\case-cli.ps1 review -Run <run-id>
.\case-cli.ps1 review -Batch <batch-id>
.\case-cli.ps1 review -Pending
```

`run` 等价于先测试、再逐个验收：

```powershell
.\case-cli.ps1 run -All
```

同一运行结果可以被重复验收。每次验收都会创建新的 `reviews/<review-id>`，不会覆盖历史报告；`run.json` 中的 `latestReviewId` 和 `latestScore` 指向最新结果。

## 指定测试和验收模型

可以分别传入模型路由：

```powershell
.\case-cli.ps1 run -All `
  -TestModel "待测模型路由" `
  -JudgeModel "验收模型路由"
```

如果测试和验收需要不同服务商、密钥或模型映射，可以分别指定 Claude Code settings：

```powershell
.\case-cli.ps1 run -All `
  -TestSettings "C:\configs\test.settings.json" `
  -JudgeSettings "C:\configs\judge.settings.json"
```

省略参数时，CLI 使用 Claude Code 当前生效的配置。`sonnet`、`opus` 等名称可能只是路由别名，因此运行目录和报告优先采用响应 `modelUsage` 中的实际模型，而不是根据别名猜测。

`-MaxBudgetUsd` 控制单个 Claude Code 会话的预算上限，不是整个批次的总预算。执行 `run -All` 时，每个 Case 分别创建测试和验收会话，请据此控制成本。

## 当前 Case

Case 编号采用 `一级能力-二级能力-序号`：例如 `1-1-2` 表示“编码能力 / 前端能力 / 第 2 个 Case”。

| ID | Case | 主要观察点 | 难度 |
| --- | --- | --- | ---: |
| `1-1-1` | 从零实现一个响应式页面 | 需求转化、响应式、视觉完整性 | 3 |
| `1-1-2` | 根据截图还原页面 | 视觉还原、布局推断、细节质感 | 4 |
| `1-1-3` | 在现有项目修复 Bug | 项目理解、缺陷定位、回归风险 | 4 |
| `1-1-4` | 完成接口与复杂状态交互 | 异步竞态、状态管理、失败回滚 | 5 |
| `1-1-5` | 综合交付真实功能 | CRUD、持久化、导入导出、完整闭环 | 5 |

更详细的能力分类、任务目标和评分维度见 [cases总览.md](./cases总览.md)。每个 Case 目录中的 `README.md` 则说明该 Case 的输入、考点和文件结构。

## 目录结构

```text
llm-cases/
├── case-cli.ps1             # 统一命令行入口
├── runner/                  # 测试、取证和验收运行器
├── cases总览.md             # 能力分类与 Case 总览
└── 1-1-x-Case名称/
    ├── case.json            # Case 元数据与工作流定义
    ├── prompts/
    │   ├── task.md          # 发送给待测模型的任务
    │   └── rubric.md        # 验收量表
    ├── starter/             # 可选的初始项目或固定输入
    ├── reference/           # 可选的参考素材
    ├── tools/               # 确定性检查器
    └── run-case.ps1         # 单 Case 快捷入口
```

## 运行产物

运行结果位于仓库同级的 `runs`：

```text
../runs/
├── Summary/
│   └── <case-id>_<actual-test-model>.md
├── batches/
│   └── <batch-id>/batch.json
└── <case-id>/<actual-test-model>/<run-id>/
    ├── definition/          # 执行时冻结的题面、量表和输入
    ├── workspace/           # 待测模型交付物
    ├── evidence/            # 自动检查结果与桌面/移动截图
    ├── test-response.json   # 待测会话原始返回
    ├── run.json             # 运行状态和模型身份
    └── reviews/<review-id>/
        ├── judge-prompt.md
        ├── judge-response.json
        ├── review.json
        └── report.md
```

`Summary` 中保存同一 Case、同一待测模型的最新报告，便于快速查看；带时间戳的原始 review 始终保留，作为完整审计记录。

## 新增 Case

1. 按编号规则创建独立目录。
2. 编写 `case.json`，至少声明 `id`、`title`、`ability`、`difficulty` 和 `workflow`。
3. 在 `workflow` 中配置题面、量表、可选输入、检查器和截图视口。
4. 保证题面只描述任务，量表提供可复核的评分维度，检查器只承担确定性验证。
5. 使用 `.\case-cli.ps1 list` 确认 Case 被发现，再分别验证 `test`、`review` 和 `run` 流程。

设计新 Case 时，应优先保证可复现、可隔离和可审计，避免依赖审查模型猜测本可通过脚本确定的事实。
