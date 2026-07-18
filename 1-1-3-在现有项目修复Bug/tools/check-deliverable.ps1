param([Parameter(Mandatory=$true)][string]$Workspace,[Parameter(Mandatory=$true)][string]$OutputPath)
$ErrorActionPreference='Stop';$workspacePath=(Resolve-Path -LiteralPath $Workspace).Path;$checks=[System.Collections.Generic.List[object]]::new()
function Add-Check{param([string]$Name,[bool]$Passed,[string]$Detail)$checks.Add([ordered]@{name=$Name;passed=$Passed;detail=$Detail})}
foreach($file in @('index.html','styles.css','logic.js','script.js')){Add-Check "$file exists" (Test-Path -LiteralPath (Join-Path $workspacePath $file) -PathType Leaf) 'Required existing project file.'}
$node=Get-Command node -ErrorAction SilentlyContinue
if($node -and (Test-Path -LiteralPath (Join-Path $workspacePath 'logic.js'))){
  $raw=& $node.Source (Join-Path $PSScriptRoot 'verify.mjs') (Join-Path $workspacePath 'logic.js') 2>&1;$exit=$LASTEXITCODE
  try{$result=($raw -join "`n")|ConvertFrom-Json;foreach($item in $result.results){Add-Check "regression: $($item.name)" ([bool]$item.passed) $(if($item.detail){[string]$item.detail}else{'Passed.'})}}catch{Add-Check 'regression suite runs' $false ($raw -join "`n")}
}else{Add-Check 'regression suite runs' $false 'Node or logic.js is unavailable.'}
$html=if(Test-Path -LiteralPath (Join-Path $workspacePath 'index.html')){Get-Content -LiteralPath (Join-Path $workspacePath 'index.html') -Raw}else{''};$css=if(Test-Path -LiteralPath (Join-Path $workspacePath 'styles.css')){Get-Content -LiteralPath (Join-Path $workspacePath 'styles.css') -Raw}else{''};$js=if(Test-Path -LiteralPath (Join-Path $workspacePath 'script.js')){Get-Content -LiteralPath (Join-Path $workspacePath 'script.js') -Raw}else{''}
Add-Check 'mobile width is not forced' ($css -notmatch '(?i)body\s*\{[^}]*min-width\s*:\s*760px') 'The seeded horizontal-overflow cause must be removed.'
Add-Check 'menu exposes aria-expanded updates' ($js -match '(?i)aria-expanded') 'Mobile menu state must be synchronized.'
Add-Check 'Escape close behavior exists' ($js -match '(?i)(Escape|keydown)') 'Keyboard dismissal is required.'
Add-Check 'overlay close behavior exists' ($js -match '(?i)overlay[^\n]*(addEventListener|onclick)') 'The overlay closes navigation.'
Add-Check 'empty state remains' ($html -match 'id=["'']empty-state["'']') 'Existing empty-state behavior is preserved.'
$passed=@($checks|Where-Object{$_.passed}).Count;$result=[ordered]@{generatedAt=(Get-Date).ToUniversalTime().ToString('o');summary=[ordered]@{passed=$passed;total=$checks.Count};checks=$checks}
$parent=Split-Path -Parent $OutputPath;if($parent){New-Item -ItemType Directory -Force -Path $parent|Out-Null};[IO.File]::WriteAllText($OutputPath,($result|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false));$result|ConvertTo-Json -Depth 8
