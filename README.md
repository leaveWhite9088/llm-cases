# LLM Cases

LLM Cases 是一套面向编码模型的可复现能力测试库。当前版本聚焦"编码能力 / 前端能力"，通过统一的 Case 设计、隔离的 Claude Code 会话、自动检查、浏览器截图和 AI 验收，对不同模型的实际交付能力进行比较。

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

## 设计原则

- **以场景为本。** 每个 Case 是一个完整的真实场景（如"做一只桌面宠物"），不是某项能力的切片。能力点通过 Case 内部结构观察，而不是预先按能力分类。
- **单次 vs 多阶段。** 多数 Case 是单次交付（模型在一个会话里把整个场景做完）。少量实操型 Case 是多阶段（在同一 workspace 内分多步推进），镜像真实开发流程。
- **README 即设计稿。** 每个 Case 目录的 `README.md` 是完整的复现说明，包含场景、需求、提示词（含交付标准）、评分标准、复现运行方式。拿到 README 就能跑。

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
.\case-cli.ps1 test -Cases Case-001
```

测试多个或全部 Case：

```powershell
.\case-cli.ps1 test -Cases Case-001,Case-002
.\case-cli.ps1 test -All
```

测试完成后立即验收：

```powershell
.\case-cli.ps1 run -Cases Case-001
.\case-cli.ps1 run -All
```

批量任务按顺序执行，但每个 Case 使用独立会话。单个 Case 失败时，CLI 会记录错误并继续处理批次中的后续 Case，最终以非零退出码报告批次异常。

## 测试与验收分离

`test` 只让待测模型完成任务、运行自动检查并生成截图，不启动 AI 验收：

```powershell
.\case-cli.ps1 test -Cases Case-003
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

Case 编号采用 `Case-NNN`：三位序号，按规划顺序排列。每个 Case 是一个完整的"场景"，模型在同一个 workspace 内完成。

| ID | 场景 | 主要观察点 | 阶段 |
| --- | --- | --- | ---: |
| `Case-001` | 网页迭代 | 需求转化、视觉层级、代码扩展、打磨度 | 3（多阶段） |
| `Case-002` | 一颗弹珠撞倒一堆多米诺 | 物理直觉、画面感、节奏编排、交互 | 1（单次） |
| `Case-003` | 一只桌面宠物 | 角色艺术、状态机、浏览器 API | 1（单次） |

- **Case-001（多阶段）**：从零搭出 Slow Brew 咖啡店官网第一版 → 在其上迭代「预约」模块 → 响应式与可访问性打磨。三个阶段在同一 workspace 内推进，镜像真实开发流程。
- **Case-002（单次）**：实现一个完整的"弹珠撞倒多米诺"物理动画场景，一次交付。
- **Case-003（单次）**：实现一只住在浏览器角落的桌面宠物，一次交付。

更详细的场景描述、阶段任务和评分维度见 [cases总览.md](./cases总览.md)。每个 Case 目录中的 `README.md` 则是完整的复现说明，包含场景、需求、提示词、交付标准、评分标准。

## 目录结构

```text
llm-cases/
├── case-cli.ps1             # 统一命令行入口
├── runner/                  # 测试、取证和验收运行器
├── cases总览.md             # 能力分类与 Case 速览
└── Case-NNN-名称/
    └── README.md            # Case 设计：场景 + 需求 + 提示词 + 评分 + 复现运行
```

每个 Case 当前只包含一份 README 作为设计稿，CLI runner 接入时会按需补充 `case.json`、`prompts/`、`tools/` 等结构。

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

1. 按 `Case-NNN-名称/` 规则创建独立目录（NNN 为三位序号）。
2. 编写 `README.md`，完整包含：场景、需求、提示词（提示词中含交付标准）、评分标准、复现运行说明。
3. 如果是 Case-001 这类多阶段 Case，每个阶段都要完整给出需求、提示词、评分。
4. 接入 CLI runner 时再补 `case.json`、`prompts/`、`tools/` 等结构。
5. 使用 `.\case-cli.ps1 list` 确认 Case 被发现，再分别验证 `test`、`review` 和 `run` 流程。

设计新 Case 时，应优先保证可复现、可隔离和可审计，避免依赖审查模型猜测本可通过脚本确定的事实。