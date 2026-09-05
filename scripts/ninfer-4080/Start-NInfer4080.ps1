[CmdletBinding()]
param(
    [string]$Distro = 'Ubuntu-24.04',
    [ValidateSet('Safe','Balanced','Long')]
    [string]$Profile = 'Balanced',
    [string]$ModelId = 'Qwen3.8-27B-Ridge-3.7bpw.gguf',
    [int]$Port = 5100,
    [string]$ApiKey = 'local-textgen'
)

$ErrorActionPreference = 'Stop'
$profiles = @{
    Safe     = @{ Context = 32768; Draft = 3 }
    Balanced = @{ Context = 49152; Draft = 3 }
    Long     = @{ Context = 98304; Draft = 3 }
}
$p = $profiles[$Profile]
$Root = '~/.agentport'
$Server = "$Root/ninfer-src/build-sm89/apps/ninfer-serve"
$Model = "$Root/models/qwen3_8_27b_minq4.ninfer"
$Log = "$Root/logs/ninfer-serve.log"

function Invoke-WslBash([string]$Command) {
    & wsl.exe -d $Distro -- bash -lc $Command
    if ($LASTEXITCODE -ne 0) { throw "WSL command failed with exit code $LASTEXITCODE.`n$Command" }
}

Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue |
    ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }

& wsl.exe -d $Distro -- bash -lc "pkill -f 'ninfer-serve.*--port $Port' >/dev/null 2>&1 || true" | Out-Null
Invoke-WslBash "test -x $Server"
Invoke-WslBash "test -s $Model"

# The model id and API key are only used as single shell arguments; remove apostrophes to keep
# the WSL launch command unambiguous rather than trying to emulate Bash quoting in PowerShell.
$escapedModelId = $ModelId.Replace("'", '')
$escapedKey = $ApiKey.Replace("'", '')
$cmd = @"
set -euo pipefail
mkdir -p $Root/logs
nohup $Server $Model \
  --host 0.0.0.0 \
  --port $Port \
  --api-key '$escapedKey' \
  --model-id '$escapedModelId' \
  --max-context $($p.Context) \
  --kv-capacity $($p.Context) \
  --max-concurrency 1 \
  --prefill-chunk 64 \
  --kv-dtype i4 \
  --spec mtp \
  --draft-tokens $($p.Draft) \
  --lm-head-draft \
  --preserve-thinking \
  > $Log 2>&1 < /dev/null &
echo `$!
"@

$pidText = (& wsl.exe -d $Distro -- bash -lc $cmd | Select-Object -Last 1).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Failed to launch NInfer inside WSL.' }
Write-Host "NInfer WSL PID: $pidText"
Write-Host "Profile: $Profile ($($p.Context) context, MTP$($p.Draft), INT4 KV)"

$headers = @{ Authorization = "Bearer $ApiKey" }
$ready = $false
for ($i = 0; $i -lt 120; $i++) {
    try {
        $models = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/v1/models" -Headers $headers -TimeoutSec 2
        if ($models) { $ready = $true; break }
    } catch {}
    Start-Sleep -Seconds 1
}

if (-not $ready) {
    $tail = & wsl.exe -d $Distro -- bash -lc "tail -n 80 $Log 2>/dev/null || true"
    throw "NInfer did not become reachable on Windows localhost:$Port.`nWSL log:`n$($tail -join "`n")"
}

Write-Host "NInfer is ready at http://127.0.0.1:$Port/v1" -ForegroundColor Green
Write-Host 'DeepSeek Harness can use the same AgentPort provider/API key as TextGen.'
