[CmdletBinding()]
param(
    [int]$Context = 49152,
    [int]$MaxTokens = 256,
    [string]$Distro = 'Ubuntu-24.04',
    [switch]$SkipNInfer
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
    throw 'Could not determine selected model.'
}
$model = Get-SelectedModel $originalFlags

$FreshPrompts = @(
    'Write a concise Python implementation of an async retry helper with exponential backoff, jitter, cancellation support, type hints, and one short usage example.',
    'Write a TypeScript function that merges two arrays of records by id, keeps the newest updatedAt value, preserves stable ordering, and explain the complexity briefly.',
    'Write a PowerShell function that checks whether a TCP port is listening, returns the owning process name when available, and handles access errors cleanly.'
)
$RepetitivePrompts = @(
    'Return exactly 12 JSON objects for a coding-agent file plan. Keys: action,path,operation,reason,verify. Use a Python REST API project. No prose outside the JSON array.',
    'Return exactly 12 JSON objects for a coding-agent file plan. Keys: action,path,operation,reason,verify. Use a TypeScript desktop app project. No prose outside the JSON array.',
    'Return exactly 12 JSON objects for a coding-agent file plan. Keys: action,path,operation,reason,verify. Use a Windows PowerShell launcher project. No prose outside the JSON array.'
)

function Stop-LocalBackend {
    Get-NetTCPConnection -State Listen -LocalPort 5100 -ErrorAction SilentlyContinue |
        ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.CommandLine -like '*llama-server.exe*' -or
        ($_.CommandLine -like '*installer_files\env\python.exe*server.py*' -and $_.CommandLine -like ('*'+$textgenRoot+'*'))
    } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    try { & wsl.exe -d $Distro -- bash -lc "pkill -f 'ninfer-serve.*--port 5100' >/dev/null 2>&1 || true" 2>$null | Out-Null } catch {}
    Start-Sleep -Milliseconds 800
}

function Wait-Api([int]$TimeoutSec=240){
    $deadline=(Get-Date).AddSeconds($TimeoutSec)
    while((Get-Date) -lt $deadline){
        try{ $r=Invoke-RestMethod -Uri ($baseUrl+'/models') -Headers $headers -TimeoutSec 2; if($r){ return $r } }catch{}
        Start-Sleep -Milliseconds 750
    }
    throw "API did not become ready at $baseUrl within $TimeoutSec seconds."
}

function Start-TextGenBackend {
    $logDir=Join-Path $textgenRoot 'logs'; New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    $out=Join-Path $logDir 'benchmark-v2.out.log'; $err=Join-Path $logDir 'benchmark-v2.err.log'
    Remove-Item -LiteralPath $out,$err -Force -ErrorAction SilentlyContinue
    $envDir=Join-Path $textgenRoot 'installer_files\env'
    $cmd='set "PYTHONNOUSERSITE=1"&& set "PYTHONPATH="&& set "PYTHONHOME="&& set "PYTHONUTF8=1"&& set "CUDA_PATH={0}"&& set "CUDA_HOME={0}"&& call "{1}" activate "{0}" && "{2}" server.py > "{3}" 2> "{4}"' -f $envDir,$conda,$python,$out,$err
    Start-Process -FilePath 'cmd.exe' -ArgumentList '/d','/s','/c',$cmd -WorkingDirectory $textgenRoot -WindowStyle Hidden | Out-Null
    try{ Wait-Api 240 | Out-Null }catch{
        $tail=if(Test-Path $err){(Get-Content $err -Tail 100)-join "`n"}else{'No TextGen error log.'}
        throw "TextGen failed to start.`n$tail"
    }
}

function Set-TextGenMode([string]$Name){
    $lines=@($originalFlags -split "`r?`n" | Where-Object { $_.Trim() })
    $lines=@($lines | Where-Object {
        $_ -notmatch '^--spec-type\b' -and $_ -notmatch '^--spec-ngram-size-n\b' -and $_ -notmatch '^--spec-ngram-size-m\b' -and
        $_ -notmatch '^--draft-max\b' -and $_ -notmatch '^--spec-draft-n-max\b' -and
        $_ -notmatch '^--ctx-size\b' -and $_ -notmatch '^--cache-type\b' -and $_ -notmatch '^--gpu-layers\b' -and $_ -notmatch '^--fit-target\b' -and $_ -notmatch '^--parallel\b' -and
        $_ -notmatch '(?i)^--(?:mmproj|multimodal-projector)\b'
    })
    $lines += '--ctx-size '+$Context
    $lines += '--cache-type q4_0'
    $lines += '--gpu-layers -1'
    $lines += '--fit-target 768'
    $lines += '--parallel 1'
    switch($Name){
        'Off' {}
        'NGram Conservative' { $lines += '--spec-type ngram-mod'; $lines += '--spec-ngram-size-n 16'; $lines += '--spec-ngram-size-m 32' }
        'NGram Medium'       { $lines += '--spec-type ngram-mod'; $lines += '--spec-ngram-size-n 24'; $lines += '--spec-ngram-size-m 48' }
        'NGram Aggressive'   { $lines += '--spec-type ngram-mod'; $lines += '--spec-ngram-size-n 32'; $lines += '--spec-ngram-size-m 64' }
        default { throw "Unknown TextGen mode: $Name" }
    }
    [IO.File]::WriteAllLines($flagsFile,$lines,([Text.UTF8Encoding]::new($false)))
}

function Test-NInferReady {
    if($SkipNInfer){ return $false }
    try{
        & wsl.exe -d $Distro -- bash -lc "test -x ~/.agentport/ninfer-src/build-sm89/apps/ninfer-serve -a -s ~/.agentport/models/qwen3_8_27b_minq4.ninfer" 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    }catch{ return $false }
}

function Start-NInferBackend {
    $safeModel=$model.Replace("'",'')
    $cmd="mkdir -p ~/.agentport/logs; nohup ~/.agentport/ninfer-src/build-sm89/apps/ninfer-serve ~/.agentport/models/qwen3_8_27b_minq4.ninfer --host 0.0.0.0 --port 5100 --api-key local-textgen --model-id '$safeModel' --max-context $Context --kv-capacity $Context --max-concurrency 1 --prefill-chunk 64 --kv-dtype i4 --spec mtp --draft-tokens 3 --lm-head-draft --preserve-thinking > ~/.agentport/logs/ninfer-benchmark-v2.log 2>&1 < /dev/null &"
    & wsl.exe -d $Distro -- bash -lc $cmd | Out-Null
    if($LASTEXITCODE -ne 0){ throw "WSL NInfer launch exited $LASTEXITCODE" }
    try{ Wait-Api 240 | Out-Null }catch{
        $tail=& wsl.exe -d $Distro -- bash -lc "tail -n 100 ~/.agentport/logs/ninfer-benchmark-v2.log 2>/dev/null || true"
        throw "NInfer failed to start.`n$($tail -join "`n")"
    }
}

function Get-ApiModelId {
    try{ $m=Invoke-RestMethod -Uri ($baseUrl+'/models') -Headers $headers -TimeoutSec 5; if($m.data -and $m.data[0].id){ return [string]$m.data[0].id } }catch{}
    return $model
}

function Invoke-OneRequest([string]$ApiModel,[string]$Prompt){
    $body=@{model=$ApiModel;messages=@(@{role='user';content=$Prompt});max_tokens=$MaxTokens;temperature=0;stream=$false}|ConvertTo-Json -Depth 8
    $sw=[Diagnostics.Stopwatch]::StartNew()
    $response=Invoke-RestMethod -Method Post -Uri ($baseUrl+'/chat/completions') -Headers $headers -Body $body -TimeoutSec 900
    $sw.Stop()
    $ct=if($response.usage -and $response.usage.completion_tokens){[int]$response.usage.completion_tokens}else{0}
    $tps=if($ct -gt 0){$ct/$sw.Elapsed.TotalSeconds}else{0}
    [pscustomobject]@{Tokens=$ct;Seconds=$sw.Elapsed.TotalSeconds;TokPerSec=$tps}
}

function Get-VramUsedMiB {
    try{ $v=(& nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>$null | Select-Object -First 1).Trim(); if($v -match '^\d+$'){return [int]$v} }catch{}
    return 0
}

function Invoke-Suite([string]$Backend,[string]$Mode,[string]$Suite,[string[]]$Prompts){
    Write-Host "`n$Backend / $Mode / $Suite" -ForegroundColor Yellow
    Stop-LocalBackend
    if($Backend -eq 'TextGen'){ Set-TextGenMode $Mode; Start-TextGenBackend }else{ Start-NInferBackend }
    $apiModel=Get-ApiModelId
    $warmBody=@{model=$apiModel;messages=@(@{role='user';content='Reply READY only.'});max_tokens=16;temperature=0;stream=$false}|ConvertTo-Json -Depth 8
    try{Invoke-RestMethod -Method Post -Uri ($baseUrl+'/chat/completions') -Headers $headers -Body $warmBody -TimeoutSec 120|Out-Null}catch{}
    $samples=@()
    for($i=0;$i -lt $Prompts.Count;$i++){
        $x=Invoke-OneRequest $apiModel $Prompts[$i]; $samples += $x
        Write-Host ('  task {0}/{1}: {2:N2} tok/s ({3} tokens, {4:N2}s)' -f ($i+1),$Prompts.Count,$x.TokPerSec,$x.Tokens,$x.Seconds)
    }
    $totalTokens=($samples|Measure-Object Tokens -Sum).Sum
    $totalSeconds=($samples|Measure-Object Seconds -Sum).Sum
    $weighted=if($totalSeconds -gt 0){$totalTokens/$totalSeconds}else{0}
    $min=($samples|Measure-Object TokPerSec -Minimum).Minimum
    $max=($samples|Measure-Object TokPerSec -Maximum).Maximum
    [pscustomobject]@{Backend=$Backend;Mode=$Mode;Suite=$Suite;WeightedTokPerSec=[math]::Round($weighted,2);MinTokPerSec=[math]::Round($min,2);MaxTokPerSec=[math]::Round($max,2);Tokens=[int]$totalTokens;Seconds=[math]::Round($totalSeconds,2);VramMiB=Get-VramUsedMiB}
}

$ninferReady=Test-NInferReady
if(-not $SkipNInfer -and -not $ninferReady){
    throw 'NInfer is not installed/ready. Run Install-NInfer4080.cmd first. This full benchmark will not silently skip NInfer. Use -SkipNInfer only for an intentional TextGen-only run.'
}

Write-Host ''
Write-Host 'AgentPort RTX 4080 benchmark v2' -ForegroundColor Cyan
Write-Host ('Model:   {0}' -f $model)
Write-Host ('Context: {0:N0} | KV: q4_0 | TextGen fit target: 768 MiB | Output cap: {1}' -f $Context,$MaxTokens)
Write-Host 'Fresh suite: 3 different tasks. Repetitive suite: 3 related agent-plan tasks.'
Write-Host 'Native llama.cpp MTP4/MTP6 are omitted because prior 4080 measurements were decisively slower.'

$modes=@(
    [pscustomobject]@{Backend='TextGen';Mode='Off'},
    [pscustomobject]@{Backend='TextGen';Mode='NGram Conservative'},
    [pscustomobject]@{Backend='TextGen';Mode='NGram Medium'},
    [pscustomobject]@{Backend='TextGen';Mode='NGram Aggressive'}
)
if($ninferReady){$modes += [pscustomobject]@{Backend='NInfer';Mode='MTP3 min-Q4'}}
$results=@()
try{
    foreach($m in $modes){
        $results += Invoke-Suite $m.Backend $m.Mode 'Fresh' $FreshPrompts
        $results += Invoke-Suite $m.Backend $m.Mode 'RepetitiveAgent' $RepetitivePrompts
    }
}finally{
    Write-Host "`nRestoring original TextGen flags/backend..." -ForegroundColor DarkGray
    try{ [IO.File]::WriteAllText($flagsFile,$originalFlags,([Text.UTF8Encoding]::new($false))); Stop-LocalBackend; Start-TextGenBackend; Write-Host 'Restored.' -ForegroundColor Green }catch{ Write-Warning 'Original flags were restored, but TextGen restart failed. Click Apply / Switch in AgentPort.' }
}

Write-Host "`n================ BENCHMARK V2 RESULTS ================" -ForegroundColor Cyan
$results | Sort-Object Suite,WeightedTokPerSec -Descending | Format-Table -AutoSize

$summary=@()
foreach($m in $modes){
    $r=@($results|Where-Object {$_.Backend -eq $m.Backend -and $_.Mode -eq $m.Mode})
    if($r.Count -eq 2){
        $balanced=($r[0].WeightedTokPerSec+$r[1].WeightedTokPerSec)/2
        $summary += [pscustomobject]@{Backend=$m.Backend;Mode=$m.Mode;BalancedTokPerSec=[math]::Round($balanced,2)}
    }
}
Write-Host "`nBalanced summary:" -ForegroundColor Cyan
$summary | Sort-Object BalancedTokPerSec -Descending | Format-Table -AutoSize
$winner=$summary|Sort-Object BalancedTokPerSec -Descending|Select-Object -First 1
if($winner){ Write-Host ('WINNER: {0} / {1} at {2:N2} tok/s balanced' -f $winner.Backend,$winner.Mode,$winner.BalancedTokPerSec) -ForegroundColor Green }

$outDir=Split-Path -Parent $MyInvocation.MyCommand.Path
$results | Export-Csv (Join-Path $outDir 'benchmark-v2-results.csv') -NoTypeInformation
$summary | Export-Csv (Join-Path $outDir 'benchmark-v2-summary.csv') -NoTypeInformation
