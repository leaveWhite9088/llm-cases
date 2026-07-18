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

$implementationFiles = @(Get-ChildItem -LiteralPath $workspacePath -Recurse -File | Where-Object {
    $_.FullName -notlike (Join-Path $workspacePath 'reference\*')
})
$textExtensions = @('.html', '.htm', '.css', '.js', '.mjs', '.svg')
$allText = ($implementationFiles | Where-Object { $textExtensions -contains $_.Extension.ToLowerInvariant() } | ForEach-Object {
    Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue
}) -join "`n"
$html = if (Test-Path -LiteralPath $indexPath) { Get-Content -LiteralPath $indexPath -Raw } else { '' }
$css = if (Test-Path -LiteralPath $cssPath) { Get-Content -LiteralPath $cssPath -Raw } else { '' }

Add-Check 'viewport meta' ($html -match '(?i)<meta[^>]+name=["'']viewport["'']') 'Needed for mobile layout.'
Add-Check 'semantic main' ($html -match '(?i)<main(?:\s|>)') 'A semantic main landmark is present.'
Add-Check 'primary heading' ($html -match '(?i)<h1(?:\s|>)') 'The page has a primary heading.'
Add-Check 'responsive media query' ($css -match '(?i)@media\s*\(') 'At least one explicit responsive rule exists.'
Add-Check 'reduced motion support' ($css -match '(?i)prefers-reduced-motion') 'User motion preference is handled.'
Add-Check 'visible focus styling' ($css -match '(?i):focus-visible') 'Keyboard focus has an explicit style.'

$requiredCopy = @('Prism', 'Good morning, Alex.', 'Portfolio overview', 'Revenue', 'Active projects', 'On-time rate', 'Team pulse')
foreach ($copy in $requiredCopy) {
    Add-Check "visible copy: $copy" ($html.Contains($copy)) 'Recognizable copy visible in the reference screenshot.'
}

$remoteMatches = @([regex]::Matches($allText, '(?i)(https?:)?//[^\s"''\)]+') |
    ForEach-Object { $_.Value } |
    Where-Object { $_ -notmatch '^https?://www\.w3\.org/(2000/svg|1999/xhtml)' } |
    Select-Object -Unique)
Add-Check 'no remote resources' ($remoteMatches.Count -eq 0) $(if ($remoteMatches.Count) { "Found: $($remoteMatches -join ', ')" } else { 'No remote URL references found.' })

$referenceImageUse = $allText -match '(?i)(target-desktop\.png|reference[/\\].*\.(png|jpe?g|webp))'
Add-Check 'reference image is not embedded' (-not $referenceImageUse) 'The input screenshot must not be rendered as page content or background.'

$referencePath = Join-Path $workspacePath 'reference\target-desktop.png'
$referenceHash = if (Test-Path -LiteralPath $referencePath -PathType Leaf) {
    (Get-FileHash -LiteralPath $referencePath -Algorithm SHA256).Hash
} else {
    $null
}
$copiedReference = if ($referenceHash) {
    @($implementationFiles | Where-Object { $_.Extension -match '(?i)^\.(png|jpe?g|webp|bmp)$' } | Where-Object {
        (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash -eq $referenceHash
    })
} else {
    @()
}
Add-Check 'no copied reference screenshot' ($copiedReference.Count -eq 0) $(if ($copiedReference.Count) { "Exact screenshot copies: $($copiedReference.Name -join ', ')" } else { 'No implementation image matches the reference screenshot hash.' })

$embeddedRaster = $allText -match '(?i)data:image/(png|jpe?g|webp|bmp);base64,'
Add-Check 'no embedded raster screenshot' (-not $embeddedRaster) 'Raster data URLs are not allowed in this Case.'

$totalBytes = ($implementationFiles | Measure-Object -Property Length -Sum).Sum
$passedCount = @($checks | Where-Object { $_.passed }).Count
$result = [ordered]@{
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
    workspace = $workspacePath
    summary = [ordered]@{
        passed = $passedCount
        total = $checks.Count
        fileCount = $implementationFiles.Count
        totalBytes = [int64]$totalBytes
    }
    checks = $checks
}

$outputDirectory = Split-Path -Parent $OutputPath
if ($outputDirectory) { New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null }
[System.IO.File]::WriteAllText($OutputPath, ($result | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
$result | ConvertTo-Json -Depth 8
