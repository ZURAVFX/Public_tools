[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InputPath,
    [Parameter(Mandatory)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$src = [IO.File]::ReadAllText((Resolve-Path $InputPath))

function Replace-Required([string]$Needle,[string]$Replacement,[string]$Label) {
    if (-not $script:src.Contains($Needle)) { throw "Patch anchor not found: $Label" }
    $script:src = $script:src.Replace($Needle,$Replacement)
}

# Surface the RTX 4080 tuned build without maintaining a second 270 KB source copy.
$src = $src.Replace('1.6.2','1.7.2-4080')

# Physical RTX 4080 measurements on Qwen3.8-27B Ridge at 49k context showed plain decode at
# ~79.6 tok/s, MTP2 at ~74.2, MTP4 at ~16.4 and MTP6 at ~6.0. Therefore this build
# defaults to speculative decoding OFF. Conservative/Medium/Aggressive remain available
# as the existing lightweight ngram-mod choices for explicit testing/use.
$src = $src.Replace('draft_mtp = $true','draft_mtp = $false')
$src = $src.Replace("speculative_mode = 'Medium'","speculative_mode = 'Off'")
$src = $src.Replace("if(`$SpecCombo.SelectedIndex -lt 0){`$SpecCombo.SelectedItem='Medium'}","if(`$SpecCombo.SelectedIndex -lt 0){`$SpecCombo.SelectedItem='Off'}")

# Existing AgentPort installs keep launcher_config.json across EXE upgrades. Apply the known-good
# 4080 profile once for this revision, then preserve user changes from that point on.
$migration = @'
$script:Config = Load-Config
try {
    $tuningRevision = '4080-ridge-visioncpu-v3'
    $currentRevision = ''
    if($script:Config.Contains('agentport_4080_tuning_revision')){
        $currentRevision = [string]$script:Config['agentport_4080_tuning_revision']
    }
    if($currentRevision -ne $tuningRevision){
        $script:Config['last_context'] = '48k (49,152 tokens)'
        $script:Config['cache_type'] = 'q4_0'
        $script:Config['offload_mode'] = 'Auto Fit (Recommended)'
        $script:Config['draft_mtp'] = $false
        $script:Config['speculative_mode'] = 'Off'
        $script:Config['runtime_backend'] = 'TextGen'
        $script:Config['agentport_4080_tuning_revision'] = $tuningRevision
        Save-Config
    }
}catch{}
'@
Replace-Required '$script:Config = Load-Config' $migration '4080 tuning migration'

# Keep full multimodal support for DeepSeek Harness, but keep the ~931 MB Qwen projector out of
# scarce 16 GB VRAM. TextGen exposes llama-server extra flags, so pass --no-mmproj-offload while
# still auto-attaching the matching mmproj. Text-only generation keeps GPU headroom; image requests
# still work and pay the projector CPU cost only when vision is actually used.
$oldMmproj = @'
    if([IO.Path]::IsPathRooted($Model)){
        $helper = @(Find-RelatedMmproj $Model) | Select-Object -First 1
        if($helper){ $lines += ('--mmproj "{0}"' -f $helper) }
    } else {
        $abs = Join-Path ([string]$script:Config.models_root) ($Model -replace '/','\')
        $helper = @(Find-RelatedMmproj $abs) | Select-Object -First 1
        if($helper){ $lines += ('--mmproj "{0}"' -f $helper) }
    }
'@
$newMmproj = @'
    if([IO.Path]::IsPathRooted($Model)){
        $helper = @(Find-RelatedMmproj $Model) | Select-Object -First 1
        if($helper){
            $lines += ('--mmproj "{0}"' -f $helper)
            $lines += '--extra-flags "--no-mmproj-offload"'
        }
    } else {
        $abs = Join-Path ([string]$script:Config.models_root) ($Model -replace '/','\')
        $helper = @(Find-RelatedMmproj $abs) | Select-Object -First 1
        if($helper){
            $lines += ('--mmproj "{0}"' -f $helper)
            $lines += '--extra-flags "--no-mmproj-offload"'
        }
    }
'@
Replace-Required $oldMmproj $newMmproj 'CPU-offload multimodal projector'

$helpers = @'
# --- AgentPort RTX 4080/NInfer backend ---------------------------------------
function Get-AgentPortRuntimeBackend {
    if($script:Config -and $script:Config.PSObject.Properties.Name -contains 'runtime_backend'){
        $v=[string]$script:Config.runtime_backend
        if($v){ return $v }
    }
    return 'TextGen'
}

function Get-AgentPortNInferDistro {
    if($script:Config -and $script:Config.PSObject.Properties.Name -contains 'ninfer_wsl_distro'){
        $v=[string]$script:Config.ninfer_wsl_distro
        if($v){ return $v }
    }
    return 'Ubuntu-24.04'
}

function Test-AgentPortRtx4080 {
    try{
        $name = (& nvidia-smi --query-gpu=name --format=csv,noheader 2>$null | Select-Object -First 1)
        return ([string]$name -match 'RTX 4080')
    }catch{ return $false }
}

function Test-AgentPortNInferWslReady {
    param([string]$Distro)
    try{
        & wsl.exe -d $Distro -- bash -lc "test -x ~/.agentport/ninfer-src/build-sm89/apps/ninfer-serve -a -s ~/.agentport/models/qwen3_8_27b_minq4.ninfer" 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    }catch{ return $false }
}

function Start-AgentPortNInfer4080IfEligible {
    param([string]$Model,[int]$Context)
    $backend = Get-AgentPortRuntimeBackend
    if($backend -ne 'NInfer4080'){ return $false }

    # NInfer is explicit/experimental until the physical 4080 benchmark proves it wins.
    $eligible = ([string]$Model -match '(?i)Qwen3\.8-27B-Ridge-3\.7bpw\.gguf$')
    if(-not $eligible){
        Set-Log 'NInfer4080 currently supports Qwen3.8-27B-Ridge-3.7bpw.gguf only; using TextGen for the selected model.' 'warn'
        return $false
    }

    if(-not (Test-AgentPortRtx4080)){
        Set-Log 'NInfer4080 requested but no RTX 4080-class GPU was detected; falling back to TextGen.' 'warn'
        return $false
    }

    $distro = Get-AgentPortNInferDistro
    if(-not (Test-AgentPortNInferWslReady $distro)){
        Set-Log ('NInfer4080 requested but the WSL engine/model is not installed in '+$distro+'; falling back to TextGen.') 'warn'
        return $false
    }

    $ctx = [Math]::Max(8192,[Math]::Min([int]$Context,98304))
    $modelId = ([string]$Model).Replace("'",'')
    $cmd = "pkill -f 'ninfer-serve.*--port 5100' >/dev/null 2>&1 || true; mkdir -p ~/.agentport/logs; nohup ~/.agentport/ninfer-src/build-sm89/apps/ninfer-serve ~/.agentport/models/qwen3_8_27b_minq4.ninfer --host 0.0.0.0 --port 5100 --api-key local-textgen --model-id '$modelId' --max-context $ctx --kv-capacity $ctx --max-concurrency 1 --prefill-chunk 64 --kv-dtype i4 --spec mtp --draft-tokens 3 --lm-head-draft --preserve-thinking > ~/.agentport/logs/ninfer-serve.log 2>&1 < /dev/null &"
    try{
        & wsl.exe -d $distro -- bash -lc $cmd | Out-Null
        if($LASTEXITCODE -ne 0){ throw "wsl exit $LASTEXITCODE" }
        Set-Log ('Starting experimental NInfer RTX 4080 backend: '+$ctx+' ctx, INT4 KV, native MTP3.') 'ok'
        $script:TextGenProcess = $null
        return $true
    }catch{
        Set-Log ('NInfer4080 launch failed; falling back to TextGen. '+$_.Exception.Message) 'warn'
        return $false
    }
}
# -----------------------------------------------------------------------------

'@

Replace-Required "function Start-TextGen {" ($helpers + "function Start-TextGen {`r`n    if(Start-AgentPortNInfer4080IfEligible -Model ([string]`$script:PendingModel) -Context ([int]`$script:PendingContext)){ return }") 'Start-TextGen injection'

$outDir = Split-Path -Parent $OutputPath
if($outDir -and -not (Test-Path $outDir)){ New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
[IO.File]::WriteAllText($OutputPath,$src,([Text.UTF8Encoding]::new($false)))

$tokens=$null; $errors=$null
[System.Management.Automation.Language.Parser]::ParseFile($OutputPath,[ref]$tokens,[ref]$errors) | Out-Null
if($errors.Count -gt 0){
    $msg=($errors | ForEach-Object { "Line $($_.Extent.StartLineNumber): $($_.Message)" }) -join "`n"
    throw "Generated AgentPort runtime is not valid PowerShell:`n$msg"
}
Write-Host "Patched runtime written to $OutputPath"
