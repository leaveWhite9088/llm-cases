[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('menu', 'list', 'test', 'review', 'run', 'runs', 'help')]
    [string]$Command = 'menu',

    [Alias('Case')]
    [string[]]$Cases,

    [switch]$All,

    [string]$TestModel,
    [string]$JudgeModel,
    [string]$TestSettings,
    [string]$JudgeSettings,

    [Alias('Run')]
    [string[]]$RunPaths,

    [string]$Batch,
    [switch]$Pending,

    [ValidateRange(1, 1000)]
    [decimal]$MaxBudgetUsd = 20,

    [ValidateRange(1024, 65535)]
    [int]$Port = 4173
)

$ErrorActionPreference = 'Stop'
$casesRoot = $PSScriptRoot
$workspaceRoot = Split-Path -Parent $casesRoot
$runsRoot = Join-Path $workspaceRoot 'runs'
$runnerRoot = Join-Path $casesRoot 'runner'

. (Join-Path $runnerRoot 'common.ps1')
. (Join-Path $runnerRoot 'test-case.ps1')
. (Join-Path $runnerRoot 'review-run.ps1')

function Get-CaseDefinitions {
    $definitions = foreach ($file in Get-ChildItem -LiteralPath $casesRoot -Directory | ForEach-Object { Join-Path $_.FullName 'case.json' }) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
        try {
            $definition = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
            if (-not $definition.id -or -not $definition.title -or -not $definition.workflow) {
                Write-Warning "跳过无效 Case 定义：$file"
                continue
            }
            $definition | Add-Member -NotePropertyName '_root' -NotePropertyValue (Split-Path -Parent $file)
            $definition
        } catch {
            Write-Warning "无法解析 $file：$($_.Exception.Message)"
        }
    }
    return @($definitions | Sort-Object id)
}

function Show-Cases {
    param([object[]]$Definitions)
    if (-not $Definitions.Count) {
        Write-Host '没有发现可执行的 Case。' -ForegroundColor Yellow
        return
    }
    $Definitions | Select-Object @{n='ID';e={$_.id}}, @{n='标题';e={$_.title}}, @{n='能力';e={$_.ability}}, @{n='难度';e={$_.difficulty}} | Format-Table -AutoSize
}

function Resolve-CaseSelection {
    param([object[]]$Definitions, [string[]]$RequestedCases, [bool]$SelectAll, [bool]$Interactive)

    if ($SelectAll) { return @($Definitions) }
    $ids = @($RequestedCases | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($ids.Count) {
        $selected = foreach ($id in $ids) {
            $match = @($Definitions | Where-Object { $_.id -eq $id })
            if (-not $match.Count) { throw "找不到 Case：$id" }
            $match[0]
        }
        return @($selected)
    }
    if (-not $Interactive) { throw '请使用 -Cases 指定 Case，或使用 -All。' }

    Write-Host "`n可执行的 Case：" -ForegroundColor Cyan
    for ($index = 0; $index -lt $Definitions.Count; $index++) {
        Write-Host "[$($index + 1)] $($Definitions[$index].id)  $($Definitions[$index].title)"
    }
    Write-Host '[A] 全部 Case'
    $answer = (Read-Host '请选择编号，多个编号用逗号分隔').Trim()
    if ($answer -match '^(?i)a(ll)?$') { return @($Definitions) }
    $indexes = @($answer -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $selected = foreach ($item in $indexes) {
        $number = 0
        if (-not [int]::TryParse($item, [ref]$number) -or $number -lt 1 -or $number -gt $Definitions.Count) {
            throw "无效的 Case 编号：$item"
        }
        $Definitions[$number - 1]
    }
    return @($selected)
}

function Get-RunRecords {
    if (-not (Test-Path -LiteralPath $runsRoot)) { return @() }
    $records = foreach ($file in Get-ChildItem -LiteralPath $runsRoot -Recurse -Filter 'run.json' -File -ErrorAction SilentlyContinue) {
        if ($file.FullName -match '[\\/]\.staging[\\/]') { continue }
        if ($file.FullName -match '[\\/]legacy[\\/]') { continue }
        try {
            $record = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
            $record | Add-Member -NotePropertyName '_root' -NotePropertyValue $file.Directory.FullName -Force
            $record
        } catch { }
    }
    return @($records | Sort-Object startedAt -Descending)
}

function Show-Runs {
    param([object[]]$Records)
    if (-not $Records.Count) {
        Write-Host '暂无运行结果。' -ForegroundColor Yellow
        return
    }
    $Records | Select-Object -First 50 `
        @{n='Run ID';e={$_.runId}}, @{n='Case';e={$_.caseId}}, `
        @{n='测试模型';e={
            $actual = @($_.actualTestModels | Where-Object { $_ })
            if ($actual.Count) { $actual -join ',' }
            elseif ($_.configuredTestModel) { "未确认（配置：$($_.configuredTestModel)）" }
            else { '未确认' }
        }}, `
        @{n='状态';e={$_.status}}, @{n='最新分数';e={$_.latestScore}}, `
        @{n='时间';e={$_.startedAt}} | Format-Table -AutoSize
}

function Resolve-RunSelection {
    param([string[]]$RequestedRuns, [string]$BatchId, [bool]$OnlyPending, [bool]$Interactive)

    $records = @(Get-RunRecords)
    if ($BatchId) {
        $batchPath = Join-Path (Join-Path $runsRoot 'batches') "$BatchId\batch.json"
        if (-not (Test-Path -LiteralPath $batchPath)) { throw "找不到批次：$BatchId" }
        $batchData = Get-Content -LiteralPath $batchPath -Raw | ConvertFrom-Json
        return @($batchData.runs | Where-Object { $_.runPath } | ForEach-Object { $_.runPath })
    }
    if ($OnlyPending) {
        return @($records | Where-Object { @($_.reviews).Count -eq 0 -and $_.status -in @('test_complete', 'review_failed') } | ForEach-Object { $_._root })
    }

    $requested = @($RequestedRuns | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($requested.Count) {
        $resolved = foreach ($value in $requested) {
            if (Test-Path -LiteralPath $value -PathType Container) { (Resolve-Path -LiteralPath $value).Path; continue }
            $match = @($records | Where-Object { $_.runId -eq $value -or (Split-Path -Leaf $_._root) -eq $value })
            if (-not $match.Count) { throw "找不到运行结果：$value" }
            $match[0]._root
        }
        return @($resolved)
    }
    if (-not $Interactive) { throw '请使用 -RunPaths、-Batch 或 -Pending 指定待验收结果。' }

    $available = @($records | Select-Object -First 30)
    if (-not $available.Count) { throw '没有可以验收的运行结果。' }
    Write-Host "`n最近的运行结果：" -ForegroundColor Cyan
    for ($index = 0; $index -lt $available.Count; $index++) {
        $reviewState = if (@($available[$index].reviews).Count) { '已验收' } else { '待验收' }
        Write-Host "[$($index + 1)] $($available[$index].runId)  $($available[$index].caseId)  $reviewState"
    }
    $answer = (Read-Host '请选择编号，多个编号用逗号分隔').Trim()
    $selected = foreach ($item in $answer -split ',') {
        $number = 0
        if (-not [int]::TryParse($item.Trim(), [ref]$number) -or $number -lt 1 -or $number -gt $available.Count) {
            throw "无效的运行编号：$item"
        }
        $available[$number - 1]._root
    }
    return @($selected)
}

function New-BatchManifest {
    param([string]$Mode, [object[]]$SelectedCases)
    $batchId = "$(Get-Date -Format 'yyyyMMdd-HHmmss')-$(([guid]::NewGuid().ToString('N')).Substring(0, 8))"
    $batchRoot = Join-Path (Join-Path $runsRoot 'batches') $batchId
    New-Item -ItemType Directory -Force -Path $batchRoot | Out-Null
    $manifest = [ordered]@{
        schemaVersion = '1.0'
        batchId = $batchId
        mode = $Mode
        requestedTestModel = $TestModel
        requestedJudgeModel = $JudgeModel
        testSettings = $TestSettings
        judgeSettings = $JudgeSettings
        caseIds = @($SelectedCases | ForEach-Object { $_.id })
        startedAt = (Get-Date).ToUniversalTime().ToString('o')
        status = 'running'
        runs = @()
    }
    Write-JsonFile -Path (Join-Path $batchRoot 'batch.json') -Value $manifest
    return [pscustomobject]@{ Root = $batchRoot; Manifest = $manifest }
}

function Save-BatchManifest {
    param([object]$BatchInfo)
    Write-JsonFile -Path (Join-Path $BatchInfo.Root 'batch.json') -Value $BatchInfo.Manifest
}

function Invoke-TestBatch {
    param([string]$Mode, [object[]]$SelectedCases, [bool]$AlsoReview)

    New-Item -ItemType Directory -Force -Path $runsRoot | Out-Null
    $batchInfo = New-BatchManifest -Mode $Mode -SelectedCases $SelectedCases
    $successfulRuns = [System.Collections.Generic.List[string]]::new()
    $failures = 0

    foreach ($definition in $SelectedCases) {
        try {
            $runPath = Invoke-CaseTest -CaseDefinition $definition -RunsRoot $runsRoot `
                -TestModel $TestModel -TestSettings $TestSettings `
                -MaxBudgetUsd $MaxBudgetUsd -Port $Port
            $successfulRuns.Add($runPath)
            $BatchInfo.Manifest.runs += [ordered]@{ caseId = $definition.id; status = 'test_complete'; runPath = $runPath }
        } catch {
            $failures++
            Write-Error "Case $($definition.id) 测试失败：$($_.Exception.Message)" -ErrorAction Continue
            $failureEntry = [ordered]@{ caseId = $definition.id; status = 'test_failed'; error = $_.Exception.Message }
            if ($_.Exception.Data.Contains('RunPath')) {
                $failureEntry.runPath = [string]$_.Exception.Data['RunPath']
            }
            $BatchInfo.Manifest.runs += $failureEntry
        }
        Save-BatchManifest -BatchInfo $batchInfo
    }

    if ($AlsoReview) {
        foreach ($runPath in $successfulRuns) {
            try {
                $reportPath = Invoke-RunReview -RunPath $runPath -RunsRoot $runsRoot -JudgeModel $JudgeModel `
                    -JudgeSettings $JudgeSettings -MaxBudgetUsd $MaxBudgetUsd
                $entry = @($BatchInfo.Manifest.runs | Where-Object { $_.runPath -eq $runPath })[0]
                $entry.status = 'complete'
                $entry.reportPath = $reportPath
            } catch {
                $failures++
                Write-Error "运行结果验收失败：$($_.Exception.Message)" -ErrorAction Continue
                $entry = @($BatchInfo.Manifest.runs | Where-Object { $_.runPath -eq $runPath })[0]
                if ($entry) {
                    $entry.status = 'review_failed'
                    $entry.error = $_.Exception.Message
                }
            }
            Save-BatchManifest -BatchInfo $batchInfo
        }
    }

    $BatchInfo.Manifest.status = if ($failures) { 'completed_with_errors' } else { 'complete' }
    $BatchInfo.Manifest.completedAt = (Get-Date).ToUniversalTime().ToString('o')
    Save-BatchManifest -BatchInfo $batchInfo
    Write-Host "`n批次完成：$($BatchInfo.Manifest.batchId)" -ForegroundColor Green
    Write-Host "批次记录：$(Join-Path $BatchInfo.Root 'batch.json')"
    if ($failures) {
        throw "批次 $($BatchInfo.Manifest.batchId) 有 $failures 个步骤失败；详见 batch.json。"
    }
}

function Show-HelpText {
    @'
Case Hub CLI

  .\case-cli.ps1                         交互菜单
  .\case-cli.ps1 list                    列出 Case
  .\case-cli.ps1 test -Cases 1-1-1      只测试
  .\case-cli.ps1 test -Cases 1-1-1,1-1-2
  .\case-cli.ps1 test -All               用统一模型测试全部 Case
  .\case-cli.ps1 run -All                测试全部 Case，随后逐个验收
  .\case-cli.ps1 review -Run <run-id>    只验收已有结果
  .\case-cli.ps1 review -Batch <batch-id>
  .\case-cli.ps1 review -Pending         验收全部未验收结果
  .\case-cli.ps1 runs                    列出运行结果

模型参数：
  -TestModel <name>       测试模型路由；省略时使用 Claude Code 当前配置
  -JudgeModel <name>      验收模型路由；省略时使用 Claude Code 当前配置
  -TestSettings <path>    测试会话专用 Claude settings 文件
  -JudgeSettings <path>   验收会话专用 Claude settings 文件

每个 Case 和每次验收都会创建全新的 Claude Code 会话。最终模型身份从
Claude Code JSON 返回中的 modelUsage 读取，而不是直接采用 sonnet/opus 等别名。
'@ | Write-Host
}

function Invoke-Menu {
    Write-Host "`nCase Hub CLI" -ForegroundColor Cyan
    Write-Host '[1] 只测试'
    Write-Host '[2] 只验收'
    Write-Host '[3] 测试并验收'
    Write-Host '[4] 查看 Case'
    Write-Host '[5] 查看运行结果'
    $choice = (Read-Host '请选择').Trim()
    switch ($choice) {
        '1' { return 'test' }
        '2' { return 'review' }
        '3' { return 'run' }
        '4' { return 'list' }
        '5' { return 'runs' }
        default { throw "无效选择：$choice" }
    }
}

$definitions = @(Get-CaseDefinitions)
$interactiveMenu = $Command -eq 'menu'
if ($interactiveMenu) {
    $Command = Invoke-Menu
    if ($Command -in @('test', 'run') -and -not $TestModel) {
        $TestModel = (Read-Host '测试模型路由（留空使用 Claude Code 当前配置）').Trim()
    }
    if ($Command -in @('review', 'run') -and -not $JudgeModel) {
        $JudgeModel = (Read-Host '验收模型路由（留空使用 Claude Code 当前配置）').Trim()
    }
}

switch ($Command) {
    'help' { Show-HelpText }
    'list' { Show-Cases -Definitions $definitions }
    'runs' { Show-Runs -Records @(Get-RunRecords) }
    'test' {
        $selected = @(Resolve-CaseSelection -Definitions $definitions -RequestedCases $Cases -SelectAll $All.IsPresent -Interactive (-not $Cases -and -not $All))
        Invoke-TestBatch -Mode 'test' -SelectedCases $selected -AlsoReview $false
    }
    'run' {
        $selected = @(Resolve-CaseSelection -Definitions $definitions -RequestedCases $Cases -SelectAll $All.IsPresent -Interactive (-not $Cases -and -not $All))
        Invoke-TestBatch -Mode 'test_and_review' -SelectedCases $selected -AlsoReview $true
    }
    'review' {
        $batchManifestPath = $null
        $batchData = $null
        if ($Batch) {
            $batchManifestPath = Join-Path (Join-Path $runsRoot 'batches') "$Batch\batch.json"
            if (Test-Path -LiteralPath $batchManifestPath) {
                $batchData = Get-Content -LiteralPath $batchManifestPath -Raw | ConvertFrom-Json
            }
        }
        $selectedRuns = @(Resolve-RunSelection -RequestedRuns $RunPaths -BatchId $Batch -OnlyPending $Pending.IsPresent -Interactive (-not $RunPaths -and -not $Batch -and -not $Pending))
        if (-not $selectedRuns.Count) { Write-Host '没有待验收结果。' -ForegroundColor Yellow; break }
        $reviewFailures = 0
        foreach ($runPath in $selectedRuns) {
            try {
                $report = Invoke-RunReview -RunPath $runPath -RunsRoot $runsRoot -JudgeModel $JudgeModel -JudgeSettings $JudgeSettings -MaxBudgetUsd $MaxBudgetUsd
                Write-Host "报告：$report" -ForegroundColor Green
                if ($batchData) {
                    $entry = @($batchData.runs | Where-Object { $_.runPath -eq $runPath })[0]
                    if ($entry) {
                        $entry.status = 'complete'
                        Set-ObjectProperty -Object $entry -Name reportPath -Value $report
                    }
                }
            } catch {
                $reviewFailures++
                Write-Error "验收失败：$($_.Exception.Message)" -ErrorAction Continue
                if ($batchData) {
                    $entry = @($batchData.runs | Where-Object { $_.runPath -eq $runPath })[0]
                    if ($entry) {
                        $entry.status = 'review_failed'
                        Set-ObjectProperty -Object $entry -Name error -Value $_.Exception.Message
                    }
                }
            }
        }
        if ($batchData) {
            $batchData.status = if ($reviewFailures) { 'completed_with_errors' } else { 'complete' }
            Set-ObjectProperty -Object $batchData -Name reviewedAt -Value ((Get-Date).ToUniversalTime().ToString('o'))
            Write-JsonFile -Path $batchManifestPath -Value $batchData
        }
        if ($reviewFailures) {
            throw "有 $reviewFailures 个验收任务失败。"
        }
    }
}
