[CmdletBinding()]
param([string]$Model,[string]$JudgeModel,[string]$TestSettings,[string]$JudgeSettings,[ValidateRange(1,1000)][decimal]$MaxBudgetUsd=20,[ValidateRange(1024,65535)][int]$Port=4173,[switch]$TestOnly)
$cli=Join-Path (Split-Path -Parent $PSScriptRoot) 'case-cli.ps1';$command=if($TestOnly){'test'}else{'run'};$arguments=@($command,'-Cases','1-1-5','-MaxBudgetUsd',$MaxBudgetUsd,'-Port',$Port)
if($Model){$arguments+=@('-TestModel',$Model)};if($JudgeModel){$arguments+=@('-JudgeModel',$JudgeModel)};if($TestSettings){$arguments+=@('-TestSettings',$TestSettings)};if($JudgeSettings){$arguments+=@('-JudgeSettings',$JudgeSettings)};& $cli @arguments
