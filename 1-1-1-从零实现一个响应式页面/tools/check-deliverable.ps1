param(
    [Parameter(Mandatory = $true)]
    [string]$Workspace,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$workspacePath = (Resolve-Path -LiteralPath $Workspace).Path
$checks = [System.Collections.Generic.List[object]]::new()

function Add-Check {
    param([string]$Name, [bool]$Passed, [string]$Detail)
    $checks.Add([ordered]@{ name = $Name; passed = $Passed; detail = $Detail })
}

$indexPath = Join-Path $workspacePath 'index.html'
$cssPath = Join-Path $workspacePath 'styles.css'
$jsPath = Join-Path $workspacePath 'script.js'

Add-Check 'index.html exists' (Test-Path -LiteralPath $indexPath -PathType Leaf) 'Required runnable entry point.'
Add-Check 'styles.css exists' (Test-Path -LiteralPath $cssPath -PathType Leaf) 'Required stylesheet.'
Add-Check 'script.js exists' (Test-Path -LiteralPath $jsPath -PathType Leaf) 'Required interaction script.'

$html = if (Test-Path -LiteralPath $indexPath) { Get-Content -LiteralPath $indexPath -Raw } else { '' }
$css = if (Test-Path -LiteralPath $cssPath) { Get-Content -LiteralPath $cssPath -Raw } else { '' }
$js = if (Test-Path -LiteralPath $jsPath) { Get-Content -LiteralPath $jsPath -Raw } else { '' }
$allText = "$html`n$css`n$js"

Add-Check 'viewport meta' ($html -match '(?i)<meta[^>]+name=["'']viewport["'']') 'Needed for mobile layout.'
Add-Check 'semantic main' ($html -match '(?i)<main(?:\s|>)') 'A semantic main landmark is present.'
Add-Check 'site header hook' ($html -match '(?i)id=["'']site-header["'']') 'Required header identifier.'
Add-Check 'hero hook' ($html -match '(?i)id=["'']hero["'']') 'Required hero identifier.'
Add-Check 'product preview hook' ($html -match '(?i)id=["'']product-preview["'']') 'Required preview identifier.'
Add-Check 'feature grid hook' ($html -match '(?i)id=["'']feature-grid["'']') 'Required feature identifier.'
Add-Check 'work filter hook' ($html -match '(?i)id=["'']work-filter["'']') 'Required filter identifier.'
Add-Check 'mobile menu hook' ($html -match '(?i)id=["'']menu-toggle["'']') 'Required menu button identifier.'
Add-Check 'aria-expanded state' ($allText -match '(?i)aria-expanded') 'Mobile menu exposes its state.'
Add-Check 'selected filter state' ($allText -match '(?i)(aria-pressed|data-active|classList\.(add|toggle).*active)') 'Filter exposes or updates selected state.'
Add-Check 'responsive media query' ($css -match '(?i)@media\s*\(') 'At least one explicit responsive rule exists.'
Add-Check 'reduced motion support' ($css -match '(?i)prefers-reduced-motion') 'User motion preference is handled.'
Add-Check 'visible focus styling' ($css -match '(?i):focus-visible') 'Keyboard focus has an explicit style.'

$requiredCopy = @(
    'Northstar',
    'Built for focused teams',
    'Turn ambitious plans into shipped work.',
    'Trusted by 2,000+ product teams',
    'Plan with clarity',
    'Stay in sync',
    'Learn and improve',
    'Your best work is waiting.',
    '42%',
    '3.2×',
    '8.5 hrs'
)

foreach ($copy in $requiredCopy) {
    Add-Check "required copy: $copy" ($html.Contains($copy)) 'Exact required copy from the brief.'
}

$remoteMatches = @([regex]::Matches($allText, '(?i)(https?:)?//[^\s"''\)]+') |
    ForEach-Object { $_.Value } |
    Where-Object { $_ -notmatch '^https?://www\.w3\.org/(2000/svg|1999/xhtml)' } |
    Select-Object -Unique)
Add-Check 'no remote resources' ($remoteMatches.Count -eq 0) $(if ($remoteMatches.Count) { "Found: $($remoteMatches -join ', ')" } else { 'No remote URL references found.' })

$files = Get-ChildItem -LiteralPath $workspacePath -Recurse -File
$totalBytes = ($files | Measure-Object -Property Length -Sum).Sum
$passedCount = @($checks | Where-Object { $_.passed }).Count

$result = [ordered]@{
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    workspace = $workspacePath
    summary = [ordered]@{
        passed = $passedCount
        total = $checks.Count
        fileCount = $files.Count
        totalBytes = [int64]$totalBytes
    }
    checks = $checks
}

$outputDirectory = Split-Path -Parent $OutputPath
if ($outputDirectory) { New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null }
[System.IO.File]::WriteAllText($OutputPath, ($result | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
$result | ConvertTo-Json -Depth 8
