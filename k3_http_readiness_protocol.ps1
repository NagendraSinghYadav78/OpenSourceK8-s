<#
.SYNOPSIS
    HTTP-READINESS EXTENSION to the K3 (Rancher Desktop) deployment study.
    Measures apply-to-first-successful-HTTP-response latency alongside the
    existing apply-to-Pod-Ready latency, in the SAME trial, so the two can
    be directly compared. This is the construct-validity enhancement
    identified in Threats to Validity: Pod Ready does not guarantee the
    application is actually answering HTTP requests yet.

.NOTES
    Run this from the same machine/session used for the original experiments,
    with Rancher Desktop running and kubectl pointed at its cluster.

    Requires the repo's YAML files:
        Namespace/namespace.yaml
        YAML File/deployment.yaml

    $localPort defaults to 9001 (not 9000) to avoid colliding with any
    manual port-forward you may still have open from earlier verification.

    Writes to .\results-http\http_readiness_timing.csv so it does not
    overwrite any existing results.
#>

param(
    [string]$repoPath = ".",
    [int]$trials = 15,
    [string]$namespace = "mastermain",
    [string]$deploymentName = "mywebapplication",
    [int]$localPort = 9001,
    [int]$containerPort = 9000
)

$deploymentFile = Join-Path $repoPath "YAML File\deployment.yaml"
$namespaceFile  = Join-Path $repoPath "Namespace\namespace.yaml"
$resultsDir = ".\results-http"
New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null

function Get-Timestamp { return (Get-Date).ToString("o") }

function Wait-PodReadyFrom {
    # Polls until Pod Ready, returning elapsed time measured from the
    # EXTERNAL stopwatch passed in (so both Pod-Ready and HTTP-Ready are
    # timed from the exact same zero point: immediately before kubectl
    # apply invocation, matching the original study's Methodology).
    param([System.Diagnostics.Stopwatch]$swatch, [string]$labelSelector, [int]$timeoutSec = 180)
    while ($swatch.Elapsed.TotalSeconds -lt $timeoutSec) {
        $status = kubectl get pods -n $namespace -l $labelSelector `
            -o jsonpath="{.items[0].status.conditions[?(@.type=='Ready')].status}" 2>$null
        if ($status -eq "True") {
            return $swatch.Elapsed
        }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

function Wait-HttpReadyFrom {
    # Polls http://localhost:$localPort/ until a successful (2xx-4xx, i.e.
    # "the server answered at all") response is received, or timeout, using
    # the SAME shared external stopwatch as Wait-PodReadyFrom. 4xx is
    # accepted as "answering" because some apps redirect/require auth on
    # "/"; adjust -expectedStatusMax if you want to require strictly 2xx.
    #
    # RESILIENCE NOTE: kubectl port-forward is not self-healing — if it hits
    # a transient "connection refused" (e.g. the container process is Ready
    # per Kubernetes but hasn't started listening on its port yet), it exits
    # entirely rather than retrying. This function detects that (job State
    # goes from Running to Completed/Failed) and transparently restarts the
    # port-forward, so a single dead attempt doesn't fail the whole trial.
    param(
        [System.Diagnostics.Stopwatch]$swatch,
        [int]$timeoutSec = 180,
        [int]$expectedStatusMax = 499,
        [string]$ns,
        [string]$dep,
        [int]$lp,
        [int]$cp
    )
    $url = "http://localhost:$lp/"
    $restartCount = 0
    while ($swatch.Elapsed.TotalSeconds -lt $timeoutSec) {
        $currentJob = Get-Job -Name "portfwd" -ErrorAction SilentlyContinue
        if ($null -eq $currentJob -or $currentJob.State -ne "Running") {
            # Port-forward died (or was never running) — restart it.
            if ($null -ne $currentJob) {
                Stop-Job -Job $currentJob -ErrorAction SilentlyContinue
                Remove-Job -Job $currentJob -ErrorAction SilentlyContinue
            }
            $restartCount++
            Start-Job -Name "portfwd" -ScriptBlock {
                param($ns, $dep, $lp, $cp)
                kubectl port-forward -n $ns "deployment/$dep" "${lp}:${cp}"
            } -ArgumentList $ns, $dep, $lp, $cp | Out-Null
            Start-Sleep -Milliseconds 750
        }
        try {
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
            if ($resp.StatusCode -le $expectedStatusMax) {
                if ($restartCount -gt 0) {
                    Write-Host "  (port-forward restarted $restartCount time(s) this trial)"
                }
                return $swatch.Elapsed
            }
        } catch {
            # Connection refused / not ready yet / timeout: keep polling.
        }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

function Ensure-Namespace {
    kubectl apply -f $namespaceFile | Out-Null
}

Write-Host "=== HTTP Readiness Experiment ($trials trials) ==="
Write-Host "Measuring apply-to-Pod-Ready AND apply-to-first-successful-HTTP-response in the same trial."
$csv = Join-Path $resultsDir "http_readiness_timing.csv"
"trial,cold_or_warm,pod_ready_seconds,http_ready_seconds,http_minus_pod_seconds" | Out-File $csv -Encoding utf8

Ensure-Namespace

for ($i = 1; $i -le $trials; $i++) {
    # Clean slate each trial: remove Deployment and any leftover port-forward
    Get-Job -Name "portfwd" -ErrorAction SilentlyContinue | Stop-Job -PassThru | Remove-Job -ErrorAction SilentlyContinue
    kubectl delete deployment $deploymentName -n $namespace --ignore-not-found | Out-Null
    Start-Sleep -Seconds 2

    $coldOrWarm = if ($i -eq 1) { "cold" } else { "warm" }

    $swatch = [System.Diagnostics.Stopwatch]::StartNew()
    kubectl apply -f $deploymentFile | Out-Null

    # --- Measurement 1: apply-to-Pod-Ready (same definition/timer as the original study) ---
    $podReadyElapsed = Wait-PodReadyFrom -swatch $swatch -labelSelector "app=$deploymentName" -timeoutSec 180
    if ($null -eq $podReadyElapsed) {
        Write-Warning "Trial $i : Pod never became Ready, skipping HTTP check"
        "$i,$coldOrWarm,TIMEOUT,TIMEOUT,TIMEOUT" | Out-File $csv -Append -Encoding utf8
        continue
    }
    $podReadySeconds = [math]::Round($podReadyElapsed.TotalSeconds, 2)

    # --- Measurement 2: apply-to-first-successful-HTTP-response (same stopwatch, same zero point) ---
    # Wait-HttpReadyFrom starts and, if needed, auto-restarts the port-forward job itself.
    $httpReadyElapsed = Wait-HttpReadyFrom -swatch $swatch -timeoutSec 180 -ns $namespace -dep $deploymentName -lp $localPort -cp $containerPort
    $swatch.Stop()

    Get-Job -Name "portfwd" -ErrorAction SilentlyContinue | Stop-Job -PassThru | Remove-Job -ErrorAction SilentlyContinue

    if ($null -eq $httpReadyElapsed) {
        Write-Warning "Trial $i : HTTP never became ready (Pod Ready at $podReadySeconds s)"
        "$i,$coldOrWarm,$podReadySeconds,TIMEOUT,TIMEOUT" | Out-File $csv -Append -Encoding utf8
    } else {
        $httpReadySeconds = [math]::Round($httpReadyElapsed.TotalSeconds, 2)
        $diff = [math]::Round($httpReadySeconds - $podReadySeconds, 2)
        Write-Host "Trial $i ($coldOrWarm): Pod Ready = $podReadySeconds s, HTTP Ready = $httpReadySeconds s, diff = $diff s"
        "$i,$coldOrWarm,$podReadySeconds,$httpReadySeconds,$diff" | Out-File $csv -Append -Encoding utf8
    }
}

Write-Host "`nAll trials complete. CSV written to $csv"
Write-Host "This measures the SAME deployment event twice: once against Kubernetes' Pod Ready"
Write-Host "condition (as in the original study), and once against the first successful HTTP"
Write-Host "response from the application itself, directly quantifying the gap between them."
