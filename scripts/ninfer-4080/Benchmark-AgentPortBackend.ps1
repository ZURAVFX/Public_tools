[CmdletBinding()]
param(
    [string]$BaseUrl = 'http://127.0.0.1:5100/v1',
    [string]$ApiKey = 'local-textgen',
    [string]$Model = 'Qwen3.8-27B-Ridge-3.7bpw.gguf',
    [int]$MaxTokens = 512,
    [int]$Runs = 3,
    [string]$Prompt = 'Write a compact but complete Python implementation of an LRU cache with type hints, then explain its time complexity.'
)

$ErrorActionPreference = 'Stop'
$headers = @{ Authorization = "Bearer $ApiKey"; 'Content-Type' = 'application/json' }
$rows = @()

for($i=1; $i -le $Runs; $i++){
    $body = @{
        model = $Model
        messages = @(@{ role='user'; content=$Prompt })
        max_tokens = $MaxTokens
        temperature = 0
        stream = $false
    } | ConvertTo-Json -Depth 8

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $response = Invoke-RestMethod -Method Post -Uri ($BaseUrl.TrimEnd('/') + '/chat/completions') -Headers $headers -Body $body -TimeoutSec 600
    $sw.Stop()

    $completion = 0
    $promptTokens = 0
    if($response.usage){
        if($response.usage.completion_tokens){ $completion = [int]$response.usage.completion_tokens }
        if($response.usage.prompt_tokens){ $promptTokens = [int]$response.usage.prompt_tokens }
    }
    $tps = if($completion -gt 0 -and $sw.Elapsed.TotalSeconds -gt 0){ $completion / $sw.Elapsed.TotalSeconds }else{ 0 }
    $rows += [pscustomobject]@{
        Run = $i
        PromptTokens = $promptTokens
        CompletionTokens = $completion
        WallSeconds = [math]::Round($sw.Elapsed.TotalSeconds,3)
        EndToEndTokPerSec = [math]::Round($tps,2)
    }
}

$rows | Format-Table -AutoSize
$valid = @($rows | Where-Object CompletionTokens -gt 0)
if($valid.Count){
    $avg = ($valid | Measure-Object EndToEndTokPerSec -Average).Average
    Write-Host ('Average end-to-end completion throughput: {0:N2} tok/s' -f $avg) -ForegroundColor Green
}else{
    Write-Warning 'The server response did not expose completion_tokens, so only wall-clock timings are available.'
}

Write-Host ''
Write-Host 'Use the same prompt/max tokens for both backends. For TextGen, start AgentPort normally. For NInfer, run Start-NInfer4080.ps1 first.'
