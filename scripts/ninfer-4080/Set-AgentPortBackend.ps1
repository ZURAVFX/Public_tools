[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Auto','NInfer4080','TextGen')]
    [string]$Backend,
    [string]$Distro = 'Ubuntu-24.04'
)

$ErrorActionPreference = 'Stop'
$configDir = Join-Path $env:USERPROFILE '.dsh'
$configFile = Join-Path $configDir 'launcher_config.json'
if(-not (Test-Path $configDir)){ New-Item -ItemType Directory -Force -Path $configDir | Out-Null }

if(Test-Path $configFile){
    $cfg = Get-Content $configFile -Raw | ConvertFrom-Json
}else{
    $cfg = [pscustomobject]@{}
}

if($cfg.PSObject.Properties.Name -contains 'runtime_backend'){
    $cfg.runtime_backend = $Backend
}else{
    $cfg | Add-Member -NotePropertyName runtime_backend -NotePropertyValue $Backend
}
if($cfg.PSObject.Properties.Name -contains 'ninfer_wsl_distro'){
    $cfg.ninfer_wsl_distro = $Distro
}else{
    $cfg | Add-Member -NotePropertyName ninfer_wsl_distro -NotePropertyValue $Distro
}

$cfg | ConvertTo-Json -Depth 12 | Set-Content -Path $configFile -Encoding UTF8
Write-Host "AgentPort runtime backend set to: $Backend" -ForegroundColor Green
Write-Host "Config: $configFile"
if($Backend -eq 'Auto'){
    Write-Host 'Auto currently stays on the proven TextGen path. NInfer remains installed and benchmarkable, but is not auto-selected until it proves faster on the physical RTX 4080.'
}elseif($Backend -eq 'NInfer4080'){
    Write-Host 'NInfer4080 explicitly requests the experimental optimized backend. If prerequisites are missing, AgentPort logs a warning and falls back to TextGen.'
}else{
    Write-Host 'TextGen forces the proven GGUF backend.'
}
