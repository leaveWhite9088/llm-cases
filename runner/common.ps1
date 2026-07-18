$ErrorActionPreference = 'Stop'

function Write-CaseStep {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Utf8File {
    param([string]$Path, [string]$Content)
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Write-JsonFile {
    param([string]$Path, [object]$Value)
    Write-Utf8File -Path $Path -Content ($Value | ConvertTo-Json -Depth 20)
}

function Get-SafeDirectoryName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return 'unknown-model' }
    $safe = $Name
    foreach ($char in [System.IO.Path]::GetInvalidFileNameChars()) {
        $safe = $safe.Replace([string]$char, '_')
    }
    $safe = $safe.Trim().TrimEnd('.')
    if ([string]::IsNullOrWhiteSpace($safe)) { return 'unknown-model' }
    return $safe
}

function Set-ObjectProperty {
    param([object]$Object, [string]$Name, [object]$Value)
    if ($Object.PSObject.Properties.Name -contains $Name) {
        $Object.$Name = $Value
    } else {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Get-ClaudeEffectiveConfig {
    param([string]$ExplicitSettings)

    $settingsCandidates = [System.Collections.Generic.List[string]]::new()
    if ($ExplicitSettings) {
        $settingsCandidates.Add([System.IO.Path]::GetFullPath($ExplicitSettings))
    }
    $settingsCandidates.Add((Join-Path $env:USERPROFILE '.claude\settings.json'))

    $configuredModel = $null
    $baseUrl = $null
    $source = $null

    foreach ($path in $settingsCandidates) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        try {
            $settings = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            if (-not $configuredModel -and $settings.model) {
                $configuredModel = [string]$settings.model
                $source = $path
            }
            if ($settings.env) {
                if (-not $configuredModel -and $settings.env.ANTHROPIC_MODEL) {
                    $configuredModel = [string]$settings.env.ANTHROPIC_MODEL
                    $source = $path
                }
                if (-not $baseUrl -and $settings.env.ANTHROPIC_BASE_URL) {
                    $baseUrl = [string]$settings.env.ANTHROPIC_BASE_URL
                    if (-not $source) { $source = $path }
                }
            }
        } catch {
            # Claude Code will surface invalid settings itself. Preflight remains best-effort.
        }
    }

    if (-not $configuredModel -and $env:ANTHROPIC_MODEL) {
        $configuredModel = $env:ANTHROPIC_MODEL
        $source = 'process environment'
    }
    if (-not $baseUrl -and $env:ANTHROPIC_BASE_URL) {
        $baseUrl = $env:ANTHROPIC_BASE_URL
        if (-not $source) { $source = 'process environment' }
    }

    $provider = $null
    if ($baseUrl) {
        try { $provider = ([uri]$baseUrl).Host } catch { $provider = $baseUrl }
    }

    return [ordered]@{
        configuredModel = $configuredModel
        baseUrl = $baseUrl
        provider = $provider
        source = $source
    }
}

function Get-ActualModelUsage {
    param([string]$ResponsePath)

    if (-not (Test-Path -LiteralPath $ResponsePath -PathType Leaf)) { return @() }
    try {
        $payload = Get-Content -LiteralPath $ResponsePath -Raw | ConvertFrom-Json
        if (-not $payload.modelUsage) { return @() }
        $usage = foreach ($property in $payload.modelUsage.PSObject.Properties) {
            $tokens = 0
            foreach ($tokenField in @('inputTokens', 'outputTokens', 'cacheReadInputTokens', 'cacheCreationInputTokens')) {
                if ($property.Value.PSObject.Properties.Name -contains $tokenField) {
                    $tokens += [int64]$property.Value.$tokenField
                }
            }
            [pscustomobject]@{ model = $property.Name; tokens = $tokens }
        }
        return @($usage | Sort-Object tokens -Descending)
    } catch {
        return @()
    }
}

function Invoke-FreshClaudeSession {
    param(
        [string]$WorkingDirectory,
        [string]$Model,
        [string]$SettingsPath,
        [string]$Prompt,
        [string]$OutputPath,
        [string]$SessionName,
        [string[]]$Tools,
        [string]$JsonSchema,
        [decimal]$MaxBudgetUsd = 20
    )

    $claudeCommand = Get-Command claude -ErrorAction SilentlyContinue
    if (-not $claudeCommand) { throw '找不到 claude 命令。请先安装并登录 Claude Code。' }

    $sessionId = [guid]::NewGuid().ToString()
    $arguments = [System.Collections.Generic.List[string]]::new()
    @(
        '--print',
        '--effort', 'high',
        '--permission-mode', 'bypassPermissions',
        '--no-session-persistence',
        '--session-id', $sessionId,
        '--name', $SessionName,
        '--output-format', 'json',
        '--max-budget-usd', $MaxBudgetUsd.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    ) | ForEach-Object { $arguments.Add($_) }

    if ($Model) {
        $arguments.Add('--model')
        $arguments.Add($Model)
    }
    if ($SettingsPath) {
        $resolvedSettings = (Resolve-Path -LiteralPath $SettingsPath).Path
        $arguments.Add('--settings')
        $arguments.Add($resolvedSettings)
    }
    if ($Tools -and $Tools.Count -gt 0) {
        $arguments.Add('--tools')
        $arguments.Add(($Tools -join ','))
    }
    if ($JsonSchema) {
        $arguments.Add('--json-schema')
        $arguments.Add($JsonSchema)
    }

    $stdoutPath = "$OutputPath.stdout.tmp"
    $stderrPath = "$OutputPath.stderr.log"
    $environmentBackup = @{}

    # An explicit settings file represents a separate execution profile. Apply
    # its env block to this child invocation even when the parent shell already
    # contains another provider's ANTHROPIC_* variables, then restore everything.
    if ($SettingsPath) {
        $resolvedSettingsForEnv = (Resolve-Path -LiteralPath $SettingsPath).Path
        try {
            $profileSettings = Get-Content -LiteralPath $resolvedSettingsForEnv -Raw | ConvertFrom-Json
            if ($profileSettings.env) {
                $processEnvironment = [System.Environment]::GetEnvironmentVariables('Process')
                foreach ($property in $profileSettings.env.PSObject.Properties) {
                    $name = [string]$property.Name
                    $environmentBackup[$name] = [ordered]@{
                        existed = $processEnvironment.Contains($name)
                        value = [System.Environment]::GetEnvironmentVariable($name, 'Process')
                    }
                    [System.Environment]::SetEnvironmentVariable($name, [string]$property.Value, 'Process')
                }
            }
        } catch {
            throw "无法读取 Claude settings 文件：$($_.Exception.Message)"
        }
    }

    Push-Location $WorkingDirectory
    try {
        $Prompt | & $claudeCommand.Source @arguments 1> $stdoutPath 2> $stderrPath
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
        foreach ($name in $environmentBackup.Keys) {
            $previous = $environmentBackup[$name]
            if ($previous.existed) {
                [System.Environment]::SetEnvironmentVariable($name, [string]$previous.value, 'Process')
            } else {
                [System.Environment]::SetEnvironmentVariable($name, $null, 'Process')
            }
        }
    }

    $raw = if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) { Get-Content -LiteralPath $stdoutPath -Raw } else { '' }
    if ($raw) { Write-Utf8File -Path $OutputPath -Content $raw }
    Remove-Item -LiteralPath $stdoutPath -Force -ErrorAction SilentlyContinue

    if ($exitCode -ne 0) {
        $details = [System.Collections.Generic.List[string]]::new()
        if ($raw) {
            try {
                $failurePayload = $raw | ConvertFrom-Json
                if ($failurePayload.api_error_status) { $details.Add("API $($failurePayload.api_error_status)") }
                if ($failurePayload.result) { $details.Add(([string]$failurePayload.result).Trim()) }
                elseif ($failurePayload.terminal_reason) { $details.Add("terminal_reason=$($failurePayload.terminal_reason)") }
            } catch {
                $details.Add($raw.Trim())
            }
        }
        $stderrRaw = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { Get-Content -LiteralPath $stderrPath -Raw } else { $null }
        $stderrText = if ([string]::IsNullOrWhiteSpace([string]$stderrRaw)) { '' } else { ([string]$stderrRaw).Trim() }
        if ($stderrText) { $details.Add($stderrText) }
        $detailText = if ($details.Count) { $details -join ' — ' } else { 'Claude Code 没有返回错误详情。' }
        throw "Claude Code 会话失败（exit $exitCode）：$detailText"
    }
    return $sessionId
}

function Find-HeadlessBrowser {
    $candidates = @(
        "$env:ProgramFiles (x86)\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "$env:ProgramFiles (x86)\Google\Chrome\Application\chrome.exe"
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }
    return $null
}

function Assert-PortAvailable {
    param([int]$Port)
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
    try { $listener.Start() } catch { throw "端口 $Port 已被占用，请通过 -Port 指定其他端口。" } finally { $listener.Stop() }
}

function Capture-BrowserScreenshot {
    param(
        [string]$Browser,
        [string]$Url,
        [string]$OutputPath,
        [int]$Width,
        [int]$Height,
        [string]$ProfilePath
    )

    New-Item -ItemType Directory -Force -Path $ProfilePath | Out-Null
    Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue

    # On Windows, --window-size cannot create a Chromium content viewport below
    # the native minimum window width (typically 492–518 px). Capturing that
    # window and cropping it to 390 px produces false mobile-overflow evidence.
    # CDP device metrics override guarantees that CSS sees the requested width.
    $portProbe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $portProbe.Start()
    $debugPort = ([System.Net.IPEndPoint]$portProbe.LocalEndpoint).Port
    $portProbe.Stop()

    $browserProcess = $null
    $socket = $null
    $commandId = 0

    function Invoke-CdpCommand {
        param([string]$Method, [hashtable]$Params = @{})
        $script:commandId++
        $id = $script:commandId
        $payload = [ordered]@{ id = $id; method = $Method; params = $Params } | ConvertTo-Json -Depth 12 -Compress
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
        $segment = [System.ArraySegment[byte]]::new($bytes)
        $socket.SendAsync($segment, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null

        while ($true) {
            $stream = [System.IO.MemoryStream]::new()
            do {
                $buffer = [byte[]]::new(65536)
                $receiveSegment = [System.ArraySegment[byte]]::new($buffer)
                $receiveTimeout = [System.Threading.CancellationTokenSource]::new(15000)
                try {
                    $received = $socket.ReceiveAsync($receiveSegment, $receiveTimeout.Token).GetAwaiter().GetResult()
                } finally {
                    $receiveTimeout.Dispose()
                }
                if ($received.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                    throw '浏览器在截图完成前关闭了 DevTools 连接。'
                }
                $stream.Write($buffer, 0, $received.Count)
            } while (-not $received.EndOfMessage)
            $message = [System.Text.Encoding]::UTF8.GetString($stream.ToArray()) | ConvertFrom-Json
            if ($message.id -eq $id) {
                if ($message.error) { throw "CDP $Method 失败：$($message.error.message)" }
                return $message.result
            }
        }
    }

    try {
        $arguments = @(
            '--headless=new', '--disable-gpu', '--disable-extensions',
            '--disable-background-networking', '--hide-scrollbars', '--no-first-run',
            '--no-default-browser-check', '--remote-allow-origins=*',
            "--remote-debugging-port=$debugPort", "--user-data-dir=$ProfilePath", 'about:blank'
        )
        $browserProcess = Start-Process -FilePath $Browser -ArgumentList $arguments -WindowStyle Hidden -PassThru

        $pageTarget = $null
        for ($attempt = 0; $attempt -lt 50; $attempt++) {
            try {
                $targets = Invoke-RestMethod -Uri "http://127.0.0.1:$debugPort/json/list" -NoProxy -TimeoutSec 1
                foreach ($candidate in $targets) {
                    if ($candidate.type -eq 'page') { $pageTarget = $candidate; break }
                }
                if ($pageTarget.webSocketDebuggerUrl) { break }
            } catch { }
            Start-Sleep -Milliseconds 100
        }
        if (-not $pageTarget.webSocketDebuggerUrl) { throw '无法连接浏览器 DevTools 端点。' }

        $webSocketUrl = [string]$pageTarget.webSocketDebuggerUrl
        $socket = [System.Net.WebSockets.ClientWebSocket]::new()
        $socket.ConnectAsync([uri]$webSocketUrl, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult() | Out-Null
        Invoke-CdpCommand -Method 'Emulation.setDeviceMetricsOverride' -Params @{
            width = $Width; height = $Height; deviceScaleFactor = 1; mobile = $false
            screenWidth = $Width; screenHeight = $Height
        } | Out-Null
        Invoke-CdpCommand -Method 'Page.navigate' -Params @{ url = $Url } | Out-Null
        Start-Sleep -Milliseconds 800
        $metrics = Invoke-CdpCommand -Method 'Runtime.evaluate' -Params @{
            expression = '({ width: window.innerWidth, height: window.innerHeight, dpr: window.devicePixelRatio })'
            returnByValue = $true
        }
        if ([int]$metrics.result.value.width -ne $Width -or [int]$metrics.result.value.height -ne $Height) {
            throw "浏览器视口校验失败：请求 ${Width}x${Height}，实际 $($metrics.result.value.width)x$($metrics.result.value.height)。"
        }
        $capture = Invoke-CdpCommand -Method 'Page.captureScreenshot' -Params @{
            format = 'png'; fromSurface = $true; captureBeyondViewport = $false
        }
        [System.IO.File]::WriteAllBytes($OutputPath, [Convert]::FromBase64String([string]$capture.data))
        return (Test-Path -LiteralPath $OutputPath -PathType Leaf) -and (Get-Item -LiteralPath $OutputPath).Length -gt 0
    } catch {
        Write-Warning "截图失败：$($_.Exception.Message)"
        return $false
    } finally {
        if ($socket -and $socket.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            try { Invoke-CdpCommand -Method 'Browser.close' | Out-Null } catch { }
            $socket.Dispose()
        }
        if ($browserProcess -and -not $browserProcess.HasExited) {
            Stop-Process -Id $browserProcess.Id -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-StaticScreenshotEvidence {
    param(
        [string]$Workspace,
        [string]$EvidenceDirectory,
        [object]$ScreenshotConfig,
        [int]$Port
    )

    $results = [System.Collections.Generic.List[object]]::new()
    if (-not $ScreenshotConfig -or $ScreenshotConfig.enabled -eq $false) { return @() }

    $entrypoint = if ($ScreenshotConfig.entrypoint) { [string]$ScreenshotConfig.entrypoint } else { 'index.html' }
    if (-not (Test-Path -LiteralPath (Join-Path $Workspace $entrypoint) -PathType Leaf)) {
        return @([ordered]@{ name = 'screenshots'; success = $false; detail = "缺少入口文件 $entrypoint" })
    }

    $browser = Find-HeadlessBrowser
    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) { $python = Get-Command py -ErrorAction SilentlyContinue }
    if (-not $browser -or -not $python) {
        return @([ordered]@{ name = 'screenshots'; success = $false; detail = '未找到 Edge/Chrome 或 Python。' })
    }

    Assert-PortAvailable -Port $Port
    $serverLog = Join-Path $EvidenceDirectory 'server.log'
    $serverError = Join-Path $EvidenceDirectory 'server.log.err'
    $profileRoot = Join-Path (Split-Path -Parent $EvidenceDirectory) '.browser-temp'
    $pythonArguments = if ($python.Name -in @('py.exe', 'py')) {
        @('-3', '-m', 'http.server', [string]$Port, '--bind', '127.0.0.1')
    } else {
        @('-m', 'http.server', [string]$Port, '--bind', '127.0.0.1')
    }

    $server = $null
    try {
        $server = Start-Process -FilePath $python.Source -ArgumentList $pythonArguments `
            -WorkingDirectory $Workspace -RedirectStandardOutput $serverLog `
            -RedirectStandardError $serverError -WindowStyle Hidden -PassThru

        $ready = $false
        for ($attempt = 0; $attempt -lt 30; $attempt++) {
            try {
                Invoke-WebRequest -Uri "http://127.0.0.1:$Port/$entrypoint" -UseBasicParsing -TimeoutSec 1 | Out-Null
                $ready = $true
                break
            } catch { Start-Sleep -Milliseconds 250 }
        }
        if (-not $ready) { throw '本地静态服务器未能启动。' }

        $viewports = @($ScreenshotConfig.viewports)
        if ($viewports.Count -eq 0) {
            $viewports = @(
                [pscustomobject]@{ name = 'desktop'; width = 1440; height = 1000 },
                [pscustomobject]@{ name = 'mobile'; width = 390; height = 844 }
            )
        }

        foreach ($viewport in $viewports) {
            $name = Get-SafeDirectoryName ([string]$viewport.name)
            $output = Join-Path $EvidenceDirectory "$name.png"
            $success = Capture-BrowserScreenshot -Browser $browser `
                -Url "http://127.0.0.1:$Port/$entrypoint" -OutputPath $output `
                -Width ([int]$viewport.width) -Height ([int]$viewport.height) `
                -ProfilePath (Join-Path $profileRoot $name)
            $results.Add([ordered]@{
                name = $name
                success = $success
                width = [int]$viewport.width
                height = [int]$viewport.height
                path = if ($success) { $output } else { $null }
            })
        }
    } finally {
        if ($server -and -not $server.HasExited) { Stop-Process -Id $server.Id -Force }
        Remove-Item -LiteralPath $profileRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-JsonFile -Path (Join-Path $EvidenceDirectory 'screenshots.json') -Value $results
    return @($results)
}
