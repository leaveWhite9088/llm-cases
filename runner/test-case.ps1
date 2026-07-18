function Invoke-CaseTest {
    param(
        [object]$CaseDefinition,
        [string]$RunsRoot,
        [string]$TestModel,
        [string]$TestSettings,
        [decimal]$MaxBudgetUsd,
        [int]$Port
    )

    $caseRoot = [string]$CaseDefinition._root
    $runId = "$(Get-Date -Format 'yyyyMMdd-HHmmss')-$(([guid]::NewGuid().ToString('N')).Substring(0, 8))"
    $stagingRoot = Join-Path $RunsRoot '.staging'
    $runRoot = Join-Path $stagingRoot $runId
    $workspace = Join-Path $runRoot 'workspace'
    $evidence = Join-Path $runRoot 'evidence'
    $definitionSnapshot = Join-Path $runRoot 'definition'
    New-Item -ItemType Directory -Force -Path $workspace, $evidence, $definitionSnapshot | Out-Null

    $promptRelative = [string]$CaseDefinition.workflow.prompt
    $rubricRelative = [string]$CaseDefinition.workflow.rubric
    $promptSource = Join-Path $caseRoot $promptRelative
    $rubricSource = Join-Path $caseRoot $rubricRelative
    if (-not (Test-Path -LiteralPath $promptSource -PathType Leaf)) { throw "Case $($CaseDefinition.id) 缺少题面：$promptRelative" }
    if (-not (Test-Path -LiteralPath $rubricSource -PathType Leaf)) { throw "Case $($CaseDefinition.id) 缺少量表：$rubricRelative" }

    Copy-Item -LiteralPath (Join-Path $caseRoot 'case.json') -Destination (Join-Path $definitionSnapshot 'case.json')
    Copy-Item -LiteralPath $promptSource -Destination (Join-Path $definitionSnapshot 'task.md')
    Copy-Item -LiteralPath $rubricSource -Destination (Join-Path $definitionSnapshot 'rubric.md')

    # Optional Case inputs (for example reference screenshots) are copied into the
    # fresh workspace, while an immutable copy is kept with the definition snapshot.
    foreach ($inputItem in @($CaseDefinition.workflow.inputs)) {
        if (-not $inputItem) { continue }
        $sourceRelative = [string]$inputItem.source
        $destinationRelative = [string]$inputItem.destination
        if ([string]::IsNullOrWhiteSpace($sourceRelative) -or [string]::IsNullOrWhiteSpace($destinationRelative)) {
            throw "Case $($CaseDefinition.id) 的 workflow.inputs 缺少 source 或 destination。"
        }

        $caseRootFull = [System.IO.Path]::GetFullPath($caseRoot).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        $sourcePath = [System.IO.Path]::GetFullPath((Join-Path $caseRoot $sourceRelative))
        if (-not $sourcePath.StartsWith($caseRootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Case 输入不能位于 Case 目录之外：$sourceRelative"
        }
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw "Case $($CaseDefinition.id) 缺少输入文件：$sourceRelative"
        }

        $workspaceFull = [System.IO.Path]::GetFullPath($workspace).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        $destinationPath = [System.IO.Path]::GetFullPath((Join-Path $workspace $destinationRelative))
        if (-not $destinationPath.StartsWith($workspaceFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Case 输入不能复制到工作目录之外：$destinationRelative"
        }

        $destinationParent = Split-Path -Parent $destinationPath
        if ($destinationParent) { New-Item -ItemType Directory -Force -Path $destinationParent | Out-Null }
        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath

        $snapshotInputRoot = Join-Path $definitionSnapshot 'inputs'
        New-Item -ItemType Directory -Force -Path $snapshotInputRoot | Out-Null
        Copy-Item -LiteralPath $sourcePath -Destination (Join-Path $snapshotInputRoot (Split-Path -Leaf $sourcePath))
    }

    $configured = Get-ClaudeEffectiveConfig -ExplicitSettings $TestSettings
    $metadata = [ordered]@{
        schemaVersion = '1.0'
        runId = $runId
        status = 'test_running'
        caseId = [string]$CaseDefinition.id
        caseTitle = [string]$CaseDefinition.title
        requestedTestModel = $TestModel
        testSettings = $TestSettings
        configuredTestModel = $configured.configuredModel
        testProvider = $configured.provider
        actualTestModels = @()
        startedAt = (Get-Date).ToUniversalTime().ToString('o')
        reviews = @()
    }
    Write-JsonFile -Path (Join-Path $runRoot 'run.json') -Value $metadata

    try {
        Write-CaseStep "测试 $($CaseDefinition.id)：$($CaseDefinition.title)"
        $prompt = Get-Content -LiteralPath $promptSource -Raw
        $responsePath = Join-Path $runRoot 'test-response.json'
        $sessionId = Invoke-FreshClaudeSession -WorkingDirectory $workspace `
            -Model $TestModel -SettingsPath $TestSettings -Prompt $prompt `
            -OutputPath $responsePath -SessionName "case-$($CaseDefinition.id)-test-$runId" `
            -Tools @('Read', 'Write', 'Edit', 'Glob', 'Grep', 'Bash') `
            -JsonSchema '' -MaxBudgetUsd $MaxBudgetUsd

        $usage = @(Get-ActualModelUsage -ResponsePath $responsePath)
        $actualModels = @($usage | ForEach-Object { $_.model })
        $primaryModel = if ($actualModels.Count) { $actualModels[0] } elseif ($configured.configuredModel) { $configured.configuredModel } elseif ($TestModel) { $TestModel } else { 'unknown-model' }

        $finalParent = Join-Path (Join-Path $RunsRoot ([string]$CaseDefinition.id)) (Get-SafeDirectoryName $primaryModel)
        $finalRoot = Join-Path $finalParent $runId
        New-Item -ItemType Directory -Force -Path $finalParent | Out-Null
        Move-Item -LiteralPath $runRoot -Destination $finalRoot
        $runRoot = $finalRoot
        $workspace = Join-Path $runRoot 'workspace'
        $evidence = Join-Path $runRoot 'evidence'

        $metadata.actualTestModels = $actualModels
        $metadata.testSessionId = $sessionId
        $metadata.resultPath = $runRoot

        if ($CaseDefinition.workflow.checker) {
            Write-CaseStep "自动检查 $($CaseDefinition.id)"
            $checker = Join-Path $caseRoot ([string]$CaseDefinition.workflow.checker)
            if (-not (Test-Path -LiteralPath $checker -PathType Leaf)) { throw "找不到检查器：$checker" }
            & $checker -Workspace $workspace -OutputPath (Join-Path $evidence 'checks.json') | Out-Null
        }

        if ($CaseDefinition.workflow.screenshots -and $CaseDefinition.workflow.screenshots.enabled -ne $false) {
            Write-CaseStep "截图 $($CaseDefinition.id)"
            Invoke-StaticScreenshotEvidence -Workspace $workspace -EvidenceDirectory $evidence `
                -ScreenshotConfig $CaseDefinition.workflow.screenshots -Port $Port | Out-Null
        }

        $metadata.status = 'test_complete'
        $metadata.testCompletedAt = (Get-Date).ToUniversalTime().ToString('o')
        Write-JsonFile -Path (Join-Path $runRoot 'run.json') -Value $metadata
        return $runRoot
    } catch {
        $originalError = $_.Exception.Message
        $metadata.status = 'test_failed'
        $metadata.error = $originalError
        $metadata.testCompletedAt = (Get-Date).ToUniversalTime().ToString('o')
        if (Test-Path -LiteralPath $runRoot) {
            if ($runRoot.StartsWith($stagingRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                $failureModel = if ($configured.configuredModel) { [string]$configured.configuredModel } elseif ($TestModel) { $TestModel } else { 'unknown-model' }
                $failureParent = Join-Path (Join-Path $RunsRoot ([string]$CaseDefinition.id)) (Get-SafeDirectoryName $failureModel)
                $failureRoot = Join-Path $failureParent $runId
                New-Item -ItemType Directory -Force -Path $failureParent | Out-Null
                $archiveError = $null
                $stagingRunRoot = $runRoot
                try {
                    Copy-Item -LiteralPath $stagingRunRoot -Destination $failureRoot -Recurse -ErrorAction Stop
                    $runRoot = $failureRoot
                } catch {
                    $archiveError = $_.Exception.Message
                }
                if ($archiveError) {
                    Set-ObjectProperty -Object $metadata -Name archiveError -Value $archiveError
                } elseif (Test-Path -LiteralPath $stagingRunRoot -PathType Container) {
                    try { [System.IO.Directory]::Delete($stagingRunRoot, $true) } catch { }
                }
            }
            $metadata.resultPath = $runRoot
            Write-JsonFile -Path (Join-Path $runRoot 'run.json') -Value $metadata
        }
        $failure = [System.Exception]::new($originalError)
        $failure.Data['RunPath'] = $runRoot
        throw $failure
    }
}
