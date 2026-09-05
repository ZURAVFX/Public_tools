[CmdletBinding()]
param(
    [int]$MaxTokens = 384,
    [int]$Context = 49152,
    [string]$Distro = 'Ubuntu-24.04',
    [switch]$SkipNInfer,
    [switch]$IncludeNativeMtp
)

$ErrorActionPreference = 'Stop'
$ConfigFile = Join-Path $env:USERPROFILE '.dsh\launcher_config.json'
if(-not (Test-Path -LiteralPath $ConfigFile)){ throw "AgentPort config not found: $ConfigFile" }
$config = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json
$textgenRoot = [string]$config.textgen_root
if(-not $textgenRoot){ $textgenRoot = Join-Path $env:PUBLIC 'AgentPort\textgen' }
$flagsFile = Join-Path $textgenRoot 'user_data\CMD_FLAGS.txt'
$python = Join-Path $textgenRoot 'installer_files\env\python.exe'
$conda = Join-Path $textgenRoot 'installer_files\conda\condabin\conda.bat'
$server = Join-Path $textgenRoot 'server.py'
$baseUrl = 'http://127.0.0.1:5100/v1'
$apiKey = 'local-textgen'
$headers = @{ Authorization = "Bearer $apiKey"; 'Content-Type'='application/json' }

foreach($p in @($flagsFile,$python,$conda,$server)){
    if(-not (Test-Path -LiteralPath $p)){ throw "Required AgentPort/TextGen file missing: $p" }
}

$originalFlags = Get-Content -LiteralPath $flagsFile -Raw
if(-not $originalFlags.Trim()){ throw "TextGen CMD_FLAGS.txt is empty: $flagsFile" }

function Get-SelectedModel([string]$Flags){
    $m = [regex]::Match($Flags,'(?m)^--model\s+"?([^"\r\n]+)"?\s*$')
    if($m.Success){ return $m.Groups[1].Value.Trim() }
    if($config.active_model){ return [string]$config.active_model }
    if($config.last_model){ return [string]$config.last_model }
    throw 'Could not determine the selected model from AgentPort/TextGen.'
}

$model = Get-SelectedModel $originalFlags
$projectorWasPresent = ($originalFlags -match '(?im)^--(?:mmproj|multimodal-projector)\b')

$FreshPrompts = @(
    'Implement a production-quality Python async TTL plus LRU cache. Include type hints, O(1) get/set behavior, expiry handling, an asyncio lock strategy, complete code, and a concise complexity discussion.',
    'Debug this TypeScript requirement from first principles: a debounced async search function must cancel stale requests, preserve the newest result, expose a flush method, and never resolve an older request after a newer one. Provide a complete implementation and explain the race-condition fix.',
    'Write a robust Windows PowerShell script that recursively finds duplicate files by SHA-256, skips inaccessible paths without aborting, prints reclaimable bytes, and supports a dry-run delete plan. Include clear error handling and comments.',
    'Design a local AI-agent process supervisor for Windows. It must launch an inference API and an agent harness, detect dead processes, avoid port collisions, preserve logs, recover after crashes, and shut down cleanly. Give the architecture, state machine, and implementation pseudocode.',
    'Return a valid JSON plan for a coding agent that must inspect a repository, identify a failing unit test, patch the smallest responsible code path, run targeted tests, then run the full suite. Use an array of steps with keys action, target, reason, and success_criteria, followed by a short risk analysis.'
)

# These deliberately share structure without repeating an identical prompt. That lets ngram-mod
# show its real advantage on tool schemas and repetitive agent output without memorising one answer.
$RepetitivePrompts = @(
    'Output exactly 20 JSON objects for a file-edit plan. Every object must use keys action, path, operation, reason, verify. Use action edit and create only. Paths should describe a Python API project with auth, users, tests, and docs. No prose outside the JSON array.',
    'Output exactly 20 JSON objects for a file-edit plan. Every object must use keys action, path, operation, reason, verify. Use action edit and create only. Paths should describe a TypeScript desktop app with settings, IPC, tests, and packaging. No prose outside the JSON array.',
    'Output exactly 20 JSON objects for a file-edit plan. Every object must use keys action, path, operation, reason, verify. Use action edit and create only. Paths should describe a PowerShell Windows launcher with logging, config, recovery, and tests. No prose outside the JSON array.',
    'Output exactly 20 JSON objects for a file-edit plan. Every object must use keys action, path, operation, reason, verify. Use action edit and create only. Paths should describe a local LLM inference service with model loading, health checks, benchmarking, and docs. No prose outside the JSON array.',
    'Output exactly 20 JSON objects for a file-edit plan. Every object must use keys action, path, operation, reason, verify. Use action edit and create only. Paths should describe a CI pipeline with build, lint, unit tests, integration tests, artifacts, and release notes. No prose outside the JSON array.'
)

Write-Host ''
Write-Host 'AgentPort RTX 4080 REAL-WORLD benchmark' -ForegroundColor Cyan
Write-Host ('Model:       {0}' -f $model)
Write-Host ('Context:     {0:N0}' -f $Context)
Write-Host ('Output cap:  {0:N0} tokens per task' -f $MaxTokens)
Write-Host ('Fresh tasks: {0}' -f $FreshPrompts.Count)
Write-Host ('Agent tasks: {0}' -f $RepetitivePrompts.Count)
if($projectorWasPresent){ Write-Host 'Vision projector: temporarily disabled for text-only TextGen measurements.' -ForegroundColor DarkGray }
Write-Host ''

function Stop-LocalBackend {
    Get-NetTCPConnection -State Listen -LocalPort 5100 -ErrorAction SilentlyContinue |
        ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandLine -like '*llama-server.exe*' -or
        ($_.CommandLine -like '*installer_files\env\python.exe*server.py*' -and $_.CommandLine -like ('*'+$textgenRoot+'*'))
    } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    try { & wsl.exe -d $Distro -- bash -lc "pkill -f 'ninfer-serve.*--port 5100' >/dev/null 2>&1 || true" 2>$null | Out-Null } catch {}
    Start-Sleep -Milliseconds 700
}

function Wait-Api([int]$TimeoutSec=240){
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while((Get-Date) -lt $deadline){
        try{
            $r = Invoke-RestMethod -Uri ($baseUrl+'/models') -Headers $headers -TimeoutSec 2
            if($r){ return $r }
        }catch{}
        Start-Sleep -Milliseconds 750
    }
    throw "API did not become ready at $baseUrl within $TimeoutSec seconds."
}

function Start-TextGenBackend {
    $logDir = Join-Path $textgenRoot 'logs'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $out = Join-Path $logDir 'benchmark-textgen.out.log'
    $err = Join-Path $logDir 'benchmark-textgen.err.log'
    Remove-Item -LiteralPath $out,$err -Force -ErrorAction SilentlyContinue
    $envDir = Join-Path $textgenRoot 'installer_files\env'
    $cmd = 'set "PYTHONNOUSERSITE=1"&& set "PYTHONPATH="&& set "PYTHONHOME="&& set "PYTHONUTF8=1"&& set "CUDA_PATH={0}"&& set "CUDA_HOME={0}"&& call "{1}" activate "{0}" && "{2}" server.py > "{3}" 2> "{4}"' -f $envDir,$conda,$python,$out,$err
    Start-Process -FilePath 'cmd.exe' -ArgumentList '/d','/s','/c',$cmd -WorkingDirectory $textgenRoot -WindowStyle Hidden | Out-Null
    try { Wait-Api 240 | Out-Null }
    catch {
        $tail = if(Test-Path $err){ (Get-Content $err -Tail 100) -join "`n" }else{ 'No TextGen error log found.' }
        throw "TextGen failed to start.`n$tail"
    }
}

function Set-TextGenMode([string]$Name){
    $lines = @($originalFlags -split "`r?`n" | Where-Object { $_.Trim() })
    $lines = @($lines | Where-Object {
        $_ -notmatch '^--spec-type\b' -and
        $_ -notmatch '^--spec-ngram-size-n\b' -and
        $_ -notmatch '^--spec-ngram-size-m\b' -and
        $_ -notmatch '^--draft-max\b' -and
        $_ -notmatch '^--spec-draft-n-max\b' -and
        $_ -notmatch '(?i)^--(?:mmproj|multimodal-projector)\b'
    })

    $ctxChanged = $false
    for($i=0;$i -lt $lines.Count;$i++){
        if($lines[$i] -match '^--ctx-size\b'){
            $lines[$i] = '--ctx-size '+$Context
            $ctxChanged = $true
        }
    }
    if(-not $ctxChanged){ $lines += '--ctx-size '+$Context }

    switch($Name){
        'Off'                {}
        'NGram Conservative' { $lines += '--spec-type ngram-mod'; $lines += '--spec-ngram-size-n 16'; $lines += '--spec-ngram-size-m 32' }
        'NGram Medium'       { $lines += '--spec-type ngram-mod'; $lines += '--spec-ngram-size-n 24'; $lines += '--spec-ngram-size-m 48' }
        'NGram Aggressive'   { $lines += '--spec-type ngram-mod'; $lines += '--spec-ngram-size-n 32'; $lines += '--spec-ngram-size-m 64' }
        'MTP2 Reference'     { $lines += '--spec-type draft-mtp'; $lines += '--draft-max 2' }
        default              { throw "Unknown TextGen benchmark mode: $Name" }
    }
    [IO.File]::WriteAllLines($flagsFile,$lines,([Text.UTF8Encoding]::new($false)))
}

function Test-NInferReady {
    if($SkipNInfer){ return $false }
    if($model -notmatch '(?i)Qwen3\.8-27B-Ridge-3\.7bpw\.gguf$'){ return $false }
    try{
        & wsl.exe -d $Distro -- bash -lc "test -x ~/.agentport/ninfer-src/build-sm89/apps/ninfer-serve -a -s ~/.agentport/models/qwen3_8_27b_minq4.ninfer" 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    }catch{ return $false }
}

function Start-NInferBackend {
    $safeModel = $model.Replace("'",'')
    $cmd = "mkdir -p ~/.agentport/logs; nohup ~/.agentport/ninfer-src/build-sm89/apps/ninfer-serve ~/.agentport/models/qwen3_8_27b_minq4.ninfer --host 0.0.0.0 --port 5100 --api-key local-textgen --model-id '$safeModel' --max-context $Context --kv-capacity $Context --max-concurrency 1 --prefill-chunk 64 --kv-dtype i4 --spec mtp --draft-tokens 3 --lm-head-draft --preserve-thinking > ~/.agentport/logs/ninfer-benchmark.log 2>&1 < /dev/null &"
    & wsl.exe -d $Distro -- bash -lc $cmd | Out-Null
    if($LASTEXITCODE -ne 0){ throw "WSL NInfer launch exited $LASTEXITCODE" }
    try { Wait-Api 240 | Out-Null }
    catch {
        $tail = & wsl.exe -d $Distro -- bash -lc "tail -n 100 ~/.agentport/logs/ninfer-benchmark.log 2>/dev/null || true"
        throw "NInfer failed to start.`n$($tail -join "`n")"
    }
}

function Get-ApiModelId {
    try{
        $m = Invoke-RestMethod -Uri ($baseUrl+'/models') -Headers $headers -TimeoutSec 5
        if($m.data -and $m.data.Count -gt 0 -and $m.data[0].id){ return [string]$m.data[0].id }
    }catch{}
    return $model
}

function Invoke-OneRequest([string]$ApiModel,[string]$TaskPrompt,[int]$TokenLimit){
    $body = @{
        model = $ApiModel
        messages = @(@{ role='user'; content=$TaskPrompt })
        max_tokens = $TokenLimit
        temperature = 0
        stream = $false
    } | ConvertTo-Json -Depth 8
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $response = Invoke-RestMethod -Method Post -Uri ($baseUrl+'/chat/completions') -Headers $headers -Body $body -TimeoutSec 1200
    $sw.Stop()
    $completion = if($response.usage -and $response.usage.completion_tokens){ [int]$response.usage.completion_tokens }else{ 0 }
    $promptTokens = if($response.usage -and $response.usage.prompt_tokens){ [int]$response.usage.prompt_tokens }else{ 0 }
    $tps = if($completion -gt 0 -and $sw.Elapsed.TotalSeconds -gt 0){ $completion / $sw.Elapsed.TotalSeconds }else{ 0 }
    [pscustomobject]@{
        PromptTokens = $promptTokens
        CompletionTokens = $completion
        Seconds = $sw.Elapsed.TotalSeconds
        TokPerSec = $tps
    }
}

function Get-VramUsedMiB {
    try{
        $v = (& nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>$null | Select-Object -First 1).Trim()
        if($v -match '^\d+$'){ return [int]$v }
    }catch{}
    return 0
}

function Start-BenchmarkMode([string]$Backend,[string]$Mode){
    Stop-LocalBackend
    if($Backend -eq 'TextGen'){
        Set-TextGenMode $Mode
        Start-TextGenBackend
    }else{
        Start-NInferBackend
    }
    $apiModel = Get-ApiModelId
    $warm = Invoke-OneRequest $apiModel 'Reply with READY only.' 16
    Write-Host ('  warmup: {0:N2}s' -f $warm.Seconds) -ForegroundColor DarkGray
    return $apiModel
}

function Invoke-Suite([string]$Backend,[string]$Mode,[string]$Suite,[string[]]$Prompts){
    Write-Host ("$Backend / $Mode / $Suite") -ForegroundColor Yellow
    $apiModel = Start-BenchmarkMode $Backend $Mode
    $samples = @()
    for($i=0;$i -lt $Prompts.Count;$i++){
        $x = Invoke-OneRequest $apiModel $Prompts[$i] $MaxTokens
        $samples += $x
        Write-Host ('  task {0}/{1}: {2:N2} tok/s  ({3} tokens, {4:N2}s)' -f ($i+1),$Prompts.Count,$x.TokPerSec,$x.CompletionTokens,$x.Seconds)
    }
    $valid = @($samples | Where-Object CompletionTokens -gt 0)
    if(-not $valid.Count){ throw 'API returned no completion token counts.' }
    $avg = ($valid | Measure-Object TokPerSec -Average).Average
    $min = ($valid | Measure-Object TokPerSec -Minimum).Minimum
    $max = ($valid | Measure-Object TokPerSec -Maximum).Maximum
    $tokens = ($valid | Measure-Object CompletionTokens -Sum).Sum
    [pscustomobject]@{
        Backend=$Backend
        Mode=$Mode
        Suite=$Suite
        AverageTokPerSec=[math]::Round($avg,2)
        MinTokPerSec=[math]::Round($min,2)
        MaxTokPerSec=[math]::Round($max,2)
        CompletionTokens=[int]$tokens
        VramMiB=Get-VramUsedMiB
        Status='OK'
    }
}

$modes = @(
    [pscustomobject]@{Backend='TextGen';Mode='Off'},
    [pscustomobject]@{Backend='TextGen';Mode='NGram Conservative'},
    [pscustomobject]@{Backend='TextGen';Mode='NGram Medium'},
    [pscustomobject]@{Backend='TextGen';Mode='NGram Aggressive'}
)
if($IncludeNativeMtp){ $modes += [pscustomobject]@{Backend='TextGen';Mode='MTP2 Reference'} }
$ninferReady = Test-NInferReady
if($ninferReady){ $modes += [pscustomobject]@{Backend='NInfer';Mode='MTP3 min-Q4'} }

$results = @()
try{
    foreach($m in $modes){
        foreach($suite in @('Fresh','RepetitiveAgent')){
            $prompts = if($suite -eq 'Fresh'){ $FreshPrompts }else{ $RepetitivePrompts }
            try{
                $results += Invoke-Suite $m.Backend $m.Mode $suite $prompts
            }catch{
                Write-Warning ("$($m.Backend) / $($m.Mode) / $suite failed: "+$_.Exception.Message)
                $results += [pscustomobject]@{Backend=$m.Backend;Mode=$m.Mode;Suite=$suite;AverageTokPerSec=0;MinTokPerSec=0;MaxTokPerSec=0;CompletionTokens=0;VramMiB=Get-VramUsedMiB;Status='FAILED'}
            }
            Write-Host ''
        }
    }
}
finally{
    Write-Host 'Restoring original TextGen flags and backend...' -ForegroundColor DarkGray
    try{
        [IO.File]::WriteAllText($flagsFile,$originalFlags,([Text.UTF8Encoding]::new($false)))
        Stop-LocalBackend
        Start-TextGenBackend
        Write-Host 'Original AgentPort/TextGen backend restored.' -ForegroundColor Green
    }catch{
        Write-Warning ('Could not automatically restart the original backend: '+$_.Exception.Message)
        Write-Warning 'CMD_FLAGS.txt was restored. Click Apply / Switch in AgentPort to restart it.'
    }
}

$summary = @()
foreach($m in $modes){
    $fresh = $results | Where-Object { $_.Backend -eq $m.Backend -and $_.Mode -eq $m.Mode -and $_.Suite -eq 'Fresh' } | Select-Object -First 1
    $agent = $results | Where-Object { $_.Backend -eq $m.Backend -and $_.Mode -eq $m.Mode -and $_.Suite -eq 'RepetitiveAgent' } | Select-Object -First 1
    $freshAvg = if($fresh){[double]$fresh.AverageTokPerSec}else{0}
    $agentAvg = if($agent){[double]$agent.AverageTokPerSec}else{0}
    $combined = if($freshAvg -gt 0 -and $agentAvg -gt 0){($freshAvg+$agentAvg)/2}else{0}
    $summary += [pscustomobject]@{
        Backend=$m.Backend
        Mode=$m.Mode
        FreshTokPerSec=[math]::Round($freshAvg,2)
        RepetitiveAgentTokPerSec=[math]::Round($agentAvg,2)
        BalancedAverage=[math]::Round($combined,2)
        VramMiB=[math]::Max($(if($fresh){$fresh.VramMiB}else{0}),$(if($agent){$agent.VramMiB}else{0}))
    }
}

Write-Host ''
Write-Host '================ REAL-WORLD BENCHMARK RESULTS ================' -ForegroundColor Cyan
$summary | Sort-Object BalancedAverage -Descending | Format-Table -AutoSize

$freshWinner = $summary | Where-Object FreshTokPerSec -gt 0 | Sort-Object FreshTokPerSec -Descending | Select-Object -First 1
$agentWinner = $summary | Where-Object RepetitiveAgentTokPerSec -gt 0 | Sort-Object RepetitiveAgentTokPerSec -Descending | Select-Object -First 1
$balancedWinner = $summary | Where-Object BalancedAverage -gt 0 | Sort-Object BalancedAverage -Descending | Select-Object -First 1
if($freshWinner){ Write-Host ('FRESH WINNER:      {0} / {1} at {2:N2} tok/s' -f $freshWinner.Backend,$freshWinner.Mode,$freshWinner.FreshTokPerSec) -ForegroundColor Green }
if($agentWinner){ Write-Host ('AGENT WINNER:      {0} / {1} at {2:N2} tok/s' -f $agentWinner.Backend,$agentWinner.Mode,$agentWinner.RepetitiveAgentTokPerSec) -ForegroundColor Green }
if($balancedWinner){ Write-Host ('BALANCED WINNER:   {0} / {1} at {2:N2} tok/s' -f $balancedWinner.Backend,$balancedWinner.Mode,$balancedWinner.BalancedAverage) -ForegroundColor Green }

if(-not $ninferReady -and -not $SkipNInfer){
    Write-Host ''
    Write-Host 'NInfer was not installed, so it was not benchmarked. Run Install-NInfer4080.cmd, then run this benchmark again.' -ForegroundColor Magenta
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = $PSScriptRoot
$summaryCsv = Join-Path $outDir ("AgentPort4080-Benchmark-Summary-$stamp.csv")
$detailCsv = Join-Path $outDir ("AgentPort4080-Benchmark-Detail-$stamp.csv")
$summary | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $summaryCsv
$results | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $detailCsv
Write-Host ''
Write-Host ('Saved summary: {0}' -f $summaryCsv) -ForegroundColor DarkGray
Write-Host ('Saved detail:  {0}' -f $detailCsv) -ForegroundColor DarkGray
