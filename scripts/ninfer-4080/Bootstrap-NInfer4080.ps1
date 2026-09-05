[CmdletBinding()]
param(
    [string]$Distro = 'Ubuntu-24.04'
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$installer = Join-Path $here 'Install-NInfer4080.ps1'
$backend = Join-Path $here 'Set-AgentPortBackend.ps1'

function Get-WslDistros {
    $items = & wsl.exe -l -q 2>$null
    if ($LASTEXITCODE -ne 0) { return @() }
    @($items | ForEach-Object { ($_ -replace "`0",'').Trim() } | Where-Object { $_ })
}

if(-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)){
    throw 'WSL is not available on this Windows installation. Enable Windows Subsystem for Linux first.'
}

$distros = Get-WslDistros
if($distros -notcontains $Distro){
    Write-Host "Ubuntu 24.04 WSL is not installed." -ForegroundColor Yellow
    Write-Host 'AgentPort can ask Windows to install it now. A UAC prompt may appear.'
    $answer = Read-Host 'Install Ubuntu-24.04 now? [Y/N]'
    if($answer -notmatch '^(?i)y'){
        throw "NInfer setup requires $Distro."
    }

    $p = Start-Process -FilePath 'wsl.exe' -ArgumentList @('--install','-d',$Distro) -Verb RunAs -Wait -PassThru
    if($p.ExitCode -ne 0){
        throw "wsl --install exited with code $($p.ExitCode)."
    }

    Start-Sleep -Seconds 2
    $distros = Get-WslDistros
    if($distros -notcontains $Distro){
        throw "Windows accepted the WSL install but $Distro is not available yet. Reboot Windows if requested, launch Ubuntu-24.04 once to finish its first-run setup, then run this installer again."
    }
}

# A newly installed distro can require one interactive first launch before normal commands work.
& wsl.exe -d $Distro -- bash -lc 'echo AGENTPORT_WSL_READY' 2>$null | Out-Null
if($LASTEXITCODE -ne 0){
    throw "Ubuntu-24.04 exists but has not completed first-run setup. Open Ubuntu-24.04 from the Start menu once, finish its username/password setup, close it, then rerun this installer."
}

& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $installer -Distro $Distro -Mode BuildAndDownload
if($LASTEXITCODE -ne 0){ throw "NInfer build/download failed with exit code $LASTEXITCODE." }

& powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $backend -Backend Auto -Distro $Distro
if($LASTEXITCODE -ne 0){ Write-Warning 'NInfer installed, but AgentPort backend preference could not be set automatically.' }

Write-Host ''
Write-Host 'NInfer RTX 4080 setup is complete.' -ForegroundColor Green
