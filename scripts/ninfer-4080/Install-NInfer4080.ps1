[CmdletBinding()]
param(
    [string]$Distro = 'Ubuntu-24.04',
    [ValidateSet('BuildOnly','BuildAndDownload')]
    [string]$Mode = 'BuildAndDownload'
)

$ErrorActionPreference = 'Stop'
$InstallerBuild = 'ninfer-4080-installer-v6-2026-09-05'
$Repo = 'https://github.com/aljazceru/ninfer.git'
$Root = '~/.agentport'
$Source = "$Root/ninfer-src"
$Build = "$Source/build-sm89"
$Models = "$Root/models"
$ModelRepo = 'aaaljaz/qwen3.8-27b-ninfer-minq4'
$ModelFile = 'qwen3_8_27b_minq4.ninfer'
$CudaRoot = '/usr/local/cuda-13.1'
$Nvcc = "$CudaRoot/bin/nvcc"
$script:Stage = 'startup'

function Set-Stage {
    param([Parameter(Mandatory)][string]$Name)
    $script:Stage = $Name
    Write-Host ''
    Write-Host "=== $Name ===" -ForegroundColor Cyan
}

function Convert-ToSafeText {
    param($Value)
    if($null -eq $Value){ return '' }
    $parts = @($Value | ForEach-Object { [string]$_ })
    return ($parts -join "`n")
}

function Invoke-WslBash {
    param([Parameter(Mandatory)][string]$Command)
    $normalized = (Convert-ToSafeText $Command) -replace "`r", ''
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalized)
    $encoded = [Convert]::ToBase64String($bytes)
    $encoded | & wsl.exe -d $Distro -- bash -c 'base64 -d | bash'
    $code = $LASTEXITCODE
    if ($code -ne 0) { throw "WSL command failed with exit code $code.`n$normalized" }
}

function Get-WslDistros {
    $items = & wsl.exe -l -q 2>$null
    if ($LASTEXITCODE -ne 0 -or $null -eq $items) { return @() }
    $out = @()
    foreach($item in @($items)){
        $s = (Convert-ToSafeText $item) -replace "`0", ''
        $s = $s -replace '^\s+|\s+$',''
        if($s){ $out += $s }
    }
    return $out
}

try {
    Write-Host "Installer build: $InstallerBuild" -ForegroundColor Green

    Set-Stage '1/8 Validate WSL distro'
    $distros = Get-WslDistros
    if ($distros -notcontains $Distro) {
        throw "WSL distro '$Distro' is not installed. Install it with: wsl --install -d $Distro"
    }
    Write-Host "WSL distro found: $Distro"

    Set-Stage '2/8 Validate RTX 4080 passthrough'
    $gpuRaw = & wsl.exe -d $Distro -- nvidia-smi --query-gpu=name,memory.total,compute_cap --format=csv,noheader
    $gpuLines = @(Convert-ToSafeText $gpuRaw -split "`n")
    $gpu = if($gpuLines.Count -gt 0){ $gpuLines[0] -replace '^\s+|\s+$','' }else{ '' }
    if (-not $gpu) { throw 'NVIDIA GPU is not visible inside WSL. Verify: wsl -d Ubuntu-24.04 -- nvidia-smi' }
    Write-Host "GPU: $gpu"
    if ($gpu -notmatch 'RTX 4080') { Write-Warning 'This installer is tuned for RTX 4080 / RTX 4080 SUPER (Ada sm_89).' }
    if ($gpu -match ',\s*([0-9]+)\s*MiB') {
        $vram = [int]$Matches[1]
        if ($vram -lt 15000) { throw "Only $vram MiB VRAM detected. This profile expects a 16 GB-class GPU." }
    }
    if ($gpu -match ',\s*([0-9]+\.[0-9]+)\s*$' -and $Matches[1] -ne '8.9') { Write-Warning "Compute capability $($Matches[1]) detected. This build explicitly targets sm_89." }

    Set-Stage '3/8 Install Linux build prerequisites'
    Invoke-WslBash @'
set -euo pipefail
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  build-essential git ninja-build pkg-config cmake curl wget ca-certificates \
  libavformat-dev libavcodec-dev libavutil-dev libswscale-dev libcurl4-openssl-dev \
  python3 python3-venv
'@

    Set-Stage '4/8 Detect or install CUDA toolkit'
    & wsl.exe -d $Distro -- test -x $Nvcc
    $hasNvcc = ($LASTEXITCODE -eq 0)
    if($hasNvcc){
        $nvccRaw = & wsl.exe -d $Distro -- $Nvcc --version
        $nvccText = Convert-ToSafeText $nvccRaw
        Write-Host "CUDA compiler already present at $Nvcc"
        Write-Host (($nvccText -split "`n")[-1])
    }else{
        Write-Host 'CUDA compiler not found at the expected CUDA 13.1 path.' -ForegroundColor DarkGray
        Write-Host 'Installing NVIDIA CUDA Toolkit 13.1 inside WSL...'
        Invoke-WslBash @'
set -euo pipefail
. /etc/os-release
case "${VERSION_ID}" in
  24.04) repo=ubuntu2404 ;;
  22.04) repo=ubuntu2204 ;;
  *) echo "Unsupported Ubuntu version ${VERSION_ID}; install CUDA Toolkit 12.4+ manually." >&2; exit 2 ;;
esac
cd /tmp
wget -q https://developer.download.nvidia.com/compute/cuda/repos/${repo}/x86_64/cuda-keyring_1.1-1_all.deb -O cuda-keyring.deb
sudo dpkg -i cuda-keyring.deb
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y cuda-toolkit-13-1
'@
        & wsl.exe -d $Distro -- test -x $Nvcc
        if($LASTEXITCODE -ne 0){ throw "CUDA package installation completed but $Nvcc does not exist or is not executable." }
        $nvccRaw = & wsl.exe -d $Distro -- $Nvcc --version
        if($LASTEXITCODE -ne 0){ throw "CUDA compiler exists at $Nvcc but could not execute." }
        $nvccText = Convert-ToSafeText $nvccRaw
        Write-Host (($nvccText -split "`n")[-1])
    }

    Set-Stage '5/8 Clone/update 16 GB NInfer fork'
    Invoke-WslBash @"
set -euo pipefail
mkdir -p $Root $Models
if [ -d $Source/.git ]; then
  git -C $Source fetch --all --prune
  git -C $Source reset --hard origin/master
else
  git clone --branch master --depth 1 $Repo $Source
fi
"@

    Set-Stage '6/8 Build NInfer for Ada sm_89'
    Invoke-WslBash @"
set -euo pipefail
cmake -S $Source -B $Build -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CUDA_COMPILER=$Nvcc \
  -DCMAKE_CUDA_ARCHITECTURES=89 \
  -DNINFER_BUILD_APPS=ON \
  -DBUILD_TESTING=OFF \
  -DNINFER_BUILD_BENCHMARKS=OFF
cmake --build $Build --parallel `$(nproc) --target ninfer ninfer-serve
"@

    Set-Stage '7/8 Validate NInfer server binary'
    Invoke-WslBash "test -x $Build/apps/ninfer-serve && $Build/apps/ninfer-serve --help >/dev/null"
    Write-Host 'ninfer-serve binary validated.'

    if ($Mode -eq 'BuildAndDownload') {
        Set-Stage '8/8 Download Qwen3.8 min-Q4 NInfer artifact'
        Invoke-WslBash @"
set -euo pipefail
python3 -m venv $Root/hf-venv
$Root/hf-venv/bin/pip install -q -U huggingface_hub
$Root/hf-venv/bin/hf download $ModelRepo $ModelFile --local-dir $Models
"@
        Invoke-WslBash "test -s $Models/$ModelFile"
        Write-Host "Model ready: $Models/$ModelFile"
    } else {
        Set-Stage '8/8 Model download skipped (BuildOnly)'
    }

    Write-Host ''
    Write-Host 'RTX 4080 NInfer backend installed successfully.' -ForegroundColor Green
    Write-Host "Engine: $Build/apps/ninfer-serve"
    if ($Mode -eq 'BuildAndDownload') { Write-Host "Model:  $Models/$ModelFile" }
}
catch {
    Write-Host ''
    Write-Host '================ NINFER INSTALL FAILURE ================' -ForegroundColor Red
    Write-Host "Installer build: $InstallerBuild" -ForegroundColor Yellow
    Write-Host "Failed stage:    $script:Stage" -ForegroundColor Yellow
    Write-Host "Message:         $($_.Exception.Message)" -ForegroundColor Red
    if($_.InvocationInfo){
        Write-Host "Source line:     $($_.InvocationInfo.ScriptLineNumber)" -ForegroundColor Yellow
        Write-Host "Position:        $($_.InvocationInfo.PositionMessage)" -ForegroundColor DarkGray
    }
    if($_.ScriptStackTrace){
        Write-Host 'Stack:' -ForegroundColor Yellow
        Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray
    }
    Write-Host '========================================================' -ForegroundColor Red
    throw
}
