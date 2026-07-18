function Get-ReviewSchema {
    return '{"type":"object","additionalProperties":false,"properties":{"total":{"type":"integer","minimum":0,"maximum":100},"verdict":{"type":"string"},"dimensions":{"type":"array","minItems":1,"items":{"type":"object","additionalProperties":false,"properties":{"name":{"type":"string"},"score":{"type":"integer","minimum":0},"maxScore":{"type":"integer","minimum":1},"evidence":{"type":"array","items":{"type":"string"}},"deductions":{"type":"array","items":{"type":"string"}}},"required":["name","score","maxScore","evidence","deductions"]}},"satisfied":{"type":"array","items":{"type":"string"}},"risks":{"type":"array","items":{"type":"string"}},"improvements":{"type":"array","minItems":1,"items":{"type":"string"}},"evidenceUsed":{"type":"array","items":{"type":"string"}}},"required":["total","verdict","dimensions","satisfied","risks","improvements","evidenceUsed"]}'
}

function Convert-EvaluationToReport {
    param(
        [object]$Evaluation,
        [object]$RunMetadata,
        [string[]]$ActualJudgeModels,
        [string]$RequestedJudgeModel,
        [string]$JudgeProvider,
        [string]$ReviewId,
        [string]$TestModelDisplay
    )

    $calculatedTotal = [int](($Evaluation.dimensions | Measure-Object -Property score -Sum).Sum)
    $dimensionRows = ($Evaluation.dimensions | ForEach-Object {
        $evidenceText = (($_.evidence | ForEach-Object { [string]$_ }) -join '<br>') -replace '\|', '\|'
        $deductionText = if ($_.deductions.Count) { (($_.deductions | ForEach-Object { [string]$_ }) -join '<br>') -replace '\|', '\|' } else { '无' }
        "| $($_.name) | $($_.score) / $($_.maxScore) | $evidenceText | $deductionText |"
    }) -join "`n"

    $satisfied = if ($Evaluation.satisfied.Count) { ($Evaluation.satisfied | ForEach-Object { "- $_" }) -join "`n" } else { '- 无' }
    $risks = if ($Evaluation.risks.Count) { ($Evaluation.risks | ForEach-Object { "- $_" }) -join "`n" } else { '- 无' }
    $improvements = ($Evaluation.improvements | ForEach-Object -Begin { $index = 0 } -Process { $index++; "$index. $_" }) -join "`n"
    $evidence = ($Evaluation.evidenceUsed | ForEach-Object { "- $_" }) -join "`n"
    $judgeDisplay = if ($ActualJudgeModels.Count) { $ActualJudgeModels -join ', ' } elseif ($RequestedJudgeModel) { $RequestedJudgeModel } else { 'unknown-model' }
    $testActual = @($RunMetadata.actualTestModels)
    $sameModel = $testActual.Count -gt 0 -and $ActualJudgeModels.Count -gt 0 -and @($testActual | Where-Object { $ActualJudgeModels -contains $_ }).Count -gt 0
    $totalWarning = if ([int]$Evaluation.total -ne $calculatedTotal) { "（评审返回 total=$($Evaluation.total)，报告按分项和校正）" } else { '' }

    return @"
# Case $($RunMetadata.caseId) 测试验收报告

## 结果

- **Case**：$($RunMetadata.caseTitle)
- **待测模型（实际）**：$TestModelDisplay
- **待测模型（请求参数）**：$($RunMetadata.requestedTestModel)
- **验收模型（实际）**：$judgeDisplay
- **验收模型（请求参数）**：$RequestedJudgeModel
- **验收服务**：$JudgeProvider
- **是否同模型自评**：$(if ($sameModel) { '是' } else { '否' })
- **总分**：**$calculatedTotal / 100** $totalWarning
- **结论**：$($Evaluation.verdict)
- **运行 ID**：$($RunMetadata.runId)
- **验收 ID**：$ReviewId

## 分项评分

| 维度 | 得分 | 证据 | 扣分原因 |
|---|---:|---|---|
$dimensionRows

## 已满足的关键要求

$satisfied

## 缺陷与风险

$risks

## 优先改进建议

$improvements

## 评审证据

$evidence

## 可复核材料

- Case 快照：definition/
- 模型交付物：workspace/
- 自动证据：evidence/
- 待测模型原始输出：test-response.json
- 本次验收材料：reviews/$ReviewId/

> 测试会话与验收会话相互独立；批量执行时，每个 Case 也使用独立的新会话。
"@
}

function Publish-ReviewSummary {
    param(
        [string]$ReportPath,
        [object]$RunMetadata,
        [string]$RunsRoot
    )

    if (-not (Test-Path -LiteralPath $ReportPath -PathType Leaf)) {
        throw "找不到待汇总的验收报告：$ReportPath"
    }
    if ([string]::IsNullOrWhiteSpace($RunsRoot)) {
        throw '未提供 Runs 根目录，无法生成 Summary。'
    }

    $actualTestModels = @($RunMetadata.actualTestModels | Where-Object { $_ })
    $testModel = if ($actualTestModels.Count) {
        [string]$actualTestModels[0]
    } elseif ($RunMetadata.configuredTestModel) {
        [string]$RunMetadata.configuredTestModel
    } elseif ($RunMetadata.requestedTestModel) {
        [string]$RunMetadata.requestedTestModel
    } else {
        'unknown-model'
    }

    $caseId = Get-SafeDirectoryName -Name ([string]$RunMetadata.caseId)
    $modelName = Get-SafeDirectoryName -Name $testModel
    $summaryRoot = Join-Path ([System.IO.Path]::GetFullPath($RunsRoot)) 'Summary'
    $summaryPath = Join-Path $summaryRoot "${caseId}_${modelName}.md"
    New-Item -ItemType Directory -Force -Path $summaryRoot | Out-Null
    Copy-Item -LiteralPath $ReportPath -Destination $summaryPath -Force
    return $summaryPath
}

function Invoke-RunReview {
    param(
        [string]$RunPath,
        [string]$RunsRoot,
        [string]$JudgeModel,
        [string]$JudgeSettings,
        [decimal]$MaxBudgetUsd
    )

    $resolvedRun = (Resolve-Path -LiteralPath $RunPath).Path
    $runJsonPath = Join-Path $resolvedRun 'run.json'
    if (-not (Test-Path -LiteralPath $runJsonPath -PathType Leaf)) { throw "不是有效的运行目录：$resolvedRun" }
    $runMetadata = Get-Content -LiteralPath $runJsonPath -Raw | ConvertFrom-Json
    if ($runMetadata.status -notin @('test_complete', 'complete', 'review_failed')) {
        throw "运行 $($runMetadata.runId) 当前状态为 $($runMetadata.status)，不能验收。"
    }

    $taskPath = Join-Path $resolvedRun 'definition\task.md'
    $rubricPath = Join-Path $resolvedRun 'definition\rubric.md'
    if (-not (Test-Path -LiteralPath $taskPath) -or -not (Test-Path -LiteralPath $rubricPath)) {
        throw '运行结果缺少 definition/task.md 或 definition/rubric.md，无法复现原始评分标准。'
    }

    $reviewId = "$(Get-Date -Format 'yyyyMMdd-HHmmss')-$(([guid]::NewGuid().ToString('N')).Substring(0, 8))"
    $reviewRoot = Join-Path (Join-Path $resolvedRun 'reviews') $reviewId
    New-Item -ItemType Directory -Force -Path $reviewRoot | Out-Null

    $configured = Get-ClaudeEffectiveConfig -ExplicitSettings $JudgeSettings
    $task = Get-Content -LiteralPath $taskPath -Raw
    $rubric = Get-Content -LiteralPath $rubricPath -Raw
    $checksPath = Join-Path $resolvedRun 'evidence\checks.json'
    $checks = if (Test-Path -LiteralPath $checksPath) { Get-Content -LiteralPath $checksPath -Raw } else { '{"note":"没有自动检查结果"}' }
    $screenshots = @(Get-ChildItem -LiteralPath (Join-Path $resolvedRun 'evidence') -Filter '*.png' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    $screenshotList = if ($screenshots.Count) { $screenshots -join "`n- " } else { '无' }
    $inputRoot = Join-Path $resolvedRun 'definition\inputs'
    $referenceInputs = if (Test-Path -LiteralPath $inputRoot -PathType Container) {
        @(Get-ChildItem -LiteralPath $inputRoot -Recurse -File | ForEach-Object { $_.FullName })
    } else {
        @()
    }
    $referenceInputList = if ($referenceInputs.Count) { $referenceInputs -join "`n- " } else { '无' }

    $judgePrompt = @"
# 角色

你是严格、可复核的前端 Case 验收员。只对已有测试结果评分，不得修改 workspace、evidence 或 definition 中的任何文件。

# 待验收材料

- 工作目录：$resolvedRun
- 交付物：$(Join-Path $resolvedRun 'workspace')
- 自动证据：$(Join-Path $resolvedRun 'evidence')
- Case 原始输入（参考图等）：
  - $referenceInputList
- 截图：
  - $screenshotList

# 原始测试题面

$task

# 验收量表

$rubric

# 自动检查结果

$checks

# 要求

1. 使用 Read、Glob、Grep 检查源码、检查结果、Case 原始输入与存在的截图。若包含参考图，必须先查看参考图，再比较交付截图。
2. 只依据可复核证据评分；目录或元数据中的模型名称不得影响分数。
3. 每个评分维度必须提供具体证据和扣分原因。
4. total 必须严格等于所有维度 score 之和。
5. 输出必须符合 JSON Schema，不要输出额外文字。
"@

    Write-Utf8File -Path (Join-Path $reviewRoot 'judge-prompt.md') -Content $judgePrompt
    $responsePath = Join-Path $reviewRoot 'judge-response.json'
    Set-ObjectProperty -Object $runMetadata -Name status -Value 'review_running'
    Write-JsonFile -Path $runJsonPath -Value $runMetadata

    try {
        Write-CaseStep "验收 $($runMetadata.caseId) / $($runMetadata.runId)"
        $sessionId = Invoke-FreshClaudeSession -WorkingDirectory $resolvedRun `
            -Model $JudgeModel -SettingsPath $JudgeSettings -Prompt $judgePrompt `
            -OutputPath $responsePath -SessionName "case-$($runMetadata.caseId)-review-$reviewId" `
            -Tools @('Read', 'Glob', 'Grep') -JsonSchema (Get-ReviewSchema) `
            -MaxBudgetUsd $MaxBudgetUsd

        $envelope = Get-Content -LiteralPath $responsePath -Raw | ConvertFrom-Json
        $evaluation = $envelope.structured_output
        if (-not $evaluation -and $envelope.result) {
            try { $evaluation = $envelope.result | ConvertFrom-Json } catch { }
        }
        if (-not $evaluation) { throw '验收返回中没有 structured_output。' }

        $usage = @(Get-ActualModelUsage -ResponsePath $responsePath)
        $actualJudgeModels = @($usage | ForEach-Object { $_.model })
        $testModels = @($runMetadata.actualTestModels)
        $testDisplay = if ($testModels.Count) { $testModels -join ', ' } elseif ($runMetadata.configuredTestModel) { $runMetadata.configuredTestModel } else { 'unknown-model' }
        $report = Convert-EvaluationToReport -Evaluation $evaluation -RunMetadata $runMetadata `
            -ActualJudgeModels $actualJudgeModels -RequestedJudgeModel $JudgeModel `
            -JudgeProvider $configured.provider -ReviewId $reviewId -TestModelDisplay $testDisplay
        $reportPath = Join-Path $reviewRoot 'report.md'
        Write-Utf8File -Path $reportPath -Content $report
        $summaryPath = Publish-ReviewSummary -ReportPath $reportPath -RunMetadata $runMetadata -RunsRoot $RunsRoot

        $reviewMetadata = [ordered]@{
            reviewId = $reviewId
            status = 'complete'
            requestedJudgeModel = $JudgeModel
            judgeSettings = $JudgeSettings
            configuredJudgeModel = $configured.configuredModel
            judgeProvider = $configured.provider
            actualJudgeModels = $actualJudgeModels
            judgeSessionId = $sessionId
            score = [int](($evaluation.dimensions | Measure-Object -Property score -Sum).Sum)
            completedAt = (Get-Date).ToUniversalTime().ToString('o')
            reportPath = $reportPath
            summaryPath = $summaryPath
        }
        Write-JsonFile -Path (Join-Path $reviewRoot 'review.json') -Value $reviewMetadata

        $reviews = @($runMetadata.reviews) + @($reviewMetadata)
        Set-ObjectProperty -Object $runMetadata -Name reviews -Value $reviews
        Set-ObjectProperty -Object $runMetadata -Name latestReviewId -Value $reviewId
        Set-ObjectProperty -Object $runMetadata -Name latestScore -Value $reviewMetadata.score
        Set-ObjectProperty -Object $runMetadata -Name latestSummaryPath -Value $summaryPath
        Set-ObjectProperty -Object $runMetadata -Name status -Value 'complete'
        Write-JsonFile -Path $runJsonPath -Value $runMetadata
        return $reportPath
    } catch {
        Set-ObjectProperty -Object $runMetadata -Name status -Value 'review_failed'
        Set-ObjectProperty -Object $runMetadata -Name reviewError -Value $_.Exception.Message
        Write-JsonFile -Path $runJsonPath -Value $runMetadata
        throw
    }
}
