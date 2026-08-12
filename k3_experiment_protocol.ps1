<#
.SYNOPSIS
    Experimental measurement protocol for the K3 (Rancher Desktop / Kubernetes)
    deployment study. Produces repeated-trial timing data as CSV files so the
    manuscript's Analysis section can report n, mean, median, SD, min/max
    instead of single-run screenshots.

.NOTES
    Run this from PowerShell on the same machine used in the manuscript
    (Windows 10 Pro 22H2, i7-8550U, 20GB RAM) with Rancher Desktop running
    and kubectl pointed at its cluster. Requires the repo's YAML files:
        Namespace/namespace.yaml
        YAML File/deployment.yaml

    Before running: adjust $repoPath below to point at your local clone
    of OpenSourceK8-s.

    Each experiment writes its own CSV into .\results\ so raw per-trial
    data is preserved (needed for reproducibility / supplementary material —
    see review item 54/55).
#>

param(
    [string]$repoPath = ".",
    [int]$trials = 15,
    [string]$namespace = "mastermain",
    [string]$deploymentName = "mywebapplication"
)

$deploymentFile = Join-Path $repoPath "YAML File\deployment.yaml"
$namespaceFile  = Join-Path $repoPath "Namespace\namespace.yaml"
$resultsDir = ".\results"
New-Item -ItemType Directory -Force -Path $resultsDir | Out-Null

function Get-Timestamp { return (Get-Date).ToString("o") }

function Wait-PodReady {
    param([string]$labelSelector, [int]$timeoutSec = 120)
    $start = Get-Date
    while ((Get-Date) -lt $start.AddSeconds($timeoutSec)) {
        $status = kubectl get pods -n $namespace -l $labelSelector `
            -o jsonpath="{.items[0].status.conditions[?(@.type=='Ready')].status}" 2>$null
        if ($status -eq "True") {
            return (Get-Date) - $start
        }
        Start-Sleep -Milliseconds 500
    }
    return $null   # timeout
}

function Ensure-Namespace {
    kubectl apply -f $namespaceFile | Out-Null
}

# ---------------------------------------------------------------------------
# EXPERIMENT 1: Deployment provisioning time (apply -> Ready)
# Distinguishes cold (first pull) from warm (image cached) trials.
# ---------------------------------------------------------------------------
function Run-DeploymentTimingExperiment {
    Write-Host "=== Experiment 1: Deployment provisioning time ($trials trials) ==="
    $csv = Join-Path $resultsDir "deployment_timing.csv"
    "trial,cold_or_warm,start_ts,end_ts,elapsed_seconds" | Out-File $csv -Encoding utf8

    Ensure-Namespace

    for ($i = 1; $i -le $trials; $i++) {
        # Clean slate each trial
        kubectl delete deployment $deploymentName -n $namespace --ignore-not-found | Out-Null
        Start-Sleep -Seconds 2

        # First trial is "cold" (image may not be cached); force-remove image
        # before trial 1 only if you want a true cold-pull measurement.
        $coldOrWarm = if ($i -eq 1) { "cold" } else { "warm" }

        $startTs = Get-Timestamp
        $swatch = [System.Diagnostics.Stopwatch]::StartNew()
        kubectl apply -f $deploymentFile | Out-Null

        $elapsed = Wait-PodReady -labelSelector "app=$deploymentName" -timeoutSec 180
        $swatch.Stop()
        $endTs = Get-Timestamp

        if ($null -eq $elapsed) {
            Write-Warning "Trial $i timed out"
            "$i,$coldOrWarm,$startTs,$endTs,TIMEOUT" | Out-File $csv -Append -Encoding utf8
        } else {
            $seconds = [math]::Round($elapsed.TotalSeconds, 2)
            Write-Host "Trial $i ($coldOrWarm): $seconds s"
            "$i,$coldOrWarm,$startTs,$endTs,$seconds" | Out-File $csv -Append -Encoding utf8
        }
    }
}

# ---------------------------------------------------------------------------
# EXPERIMENT 2: Failure recovery time
# Deletes the running pod and measures time until a replacement is Ready.
# ---------------------------------------------------------------------------
function Run-RecoveryExperiment {
    Write-Host "=== Experiment 2: Failure recovery time ($trials trials) ==="
    $csv = Join-Path $resultsDir "recovery_timing.csv"
    "trial,start_ts,end_ts,elapsed_seconds" | Out-File $csv -Encoding utf8

    # Ensure a stable running deployment exists first
    kubectl apply -f $deploymentFile | Out-Null
    Wait-PodReady -labelSelector "app=$deploymentName" -timeoutSec 180 | Out-Null

    for ($i = 1; $i -le $trials; $i++) {
        $podName = kubectl get pods -n $namespace -l "app=$deploymentName" `
            -o jsonpath="{.items[0].metadata.name}"

        $startTs = Get-Timestamp
        $swatch = [System.Diagnostics.Stopwatch]::StartNew()
        kubectl delete pod $podName -n $namespace | Out-Null

        $elapsed = Wait-PodReady -labelSelector "app=$deploymentName" -timeoutSec 120
        $swatch.Stop()
        $endTs = Get-Timestamp

        if ($null -eq $elapsed) {
            Write-Warning "Trial $i recovery timed out"
            "$i,$startTs,$endTs,TIMEOUT" | Out-File $csv -Append -Encoding utf8
        } else {
            $seconds = [math]::Round($elapsed.TotalSeconds, 2)
            Write-Host "Trial $i recovery: $seconds s"
            "$i,$startTs,$endTs,$seconds" | Out-File $csv -Append -Encoding utf8
        }
        Start-Sleep -Seconds 3
    }
}

# ---------------------------------------------------------------------------
# EXPERIMENT 3: Scale-out / scale-in stabilization time
# 1 -> 3 replicas, then back to 1. Measures time to reach desired ready count.
# ---------------------------------------------------------------------------
function Wait-ReplicasReady {
    param([int]$desiredCount, [int]$timeoutSec = 120)
    $start = Get-Date
    while ((Get-Date) -lt $start.AddSeconds($timeoutSec)) {
        $ready = kubectl get deployment $deploymentName -n $namespace `
            -o jsonpath="{.status.readyReplicas}" 2>$null
        if ($ready -eq $desiredCount) {
            return (Get-Date) - $start
        }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

function Run-ScalingExperiment {
    Write-Host "=== Experiment 3: Scale-out/in timing ($trials trials) ==="
    $csv = Join-Path $resultsDir "scaling_timing.csv"
    "trial,direction,from_replicas,to_replicas,start_ts,end_ts,elapsed_seconds" | Out-File $csv -Encoding utf8

    kubectl apply -f $deploymentFile | Out-Null
    Wait-ReplicasReady -desiredCount 1 -timeoutSec 180 | Out-Null

    for ($i = 1; $i -le $trials; $i++) {
        # Scale out 1 -> 3
        $startTs = Get-Timestamp
        $swatch = [System.Diagnostics.Stopwatch]::StartNew()
        kubectl scale deployment $deploymentName -n $namespace --replicas=3 | Out-Null
        $elapsedOut = Wait-ReplicasReady -desiredCount 3 -timeoutSec 120
        $swatch.Stop()
        $endTs = Get-Timestamp
        $secOut = if ($elapsedOut) { [math]::Round($elapsedOut.TotalSeconds, 2) } else { "TIMEOUT" }
        "$i,scale_out,1,3,$startTs,$endTs,$secOut" | Out-File $csv -Append -Encoding utf8
        Write-Host "Trial $i scale-out (1->3): $secOut s"

        # Scale in 3 -> 1
        $startTs2 = Get-Timestamp
        $swatch2 = [System.Diagnostics.Stopwatch]::StartNew()
        kubectl scale deployment $deploymentName -n $namespace --replicas=1 | Out-Null
        $elapsedIn = Wait-ReplicasReady -desiredCount 1 -timeoutSec 120
        $swatch2.Stop()
        $endTs2 = Get-Timestamp
        $secIn = if ($elapsedIn) { [math]::Round($elapsedIn.TotalSeconds, 2) } else { "TIMEOUT" }
        "$i,scale_in,3,1,$startTs2,$endTs2,$secIn" | Out-File $csv -Append -Encoding utf8
        Write-Host "Trial $i scale-in (3->1): $secIn s"
    }
}

# ---------------------------------------------------------------------------
# EXPERIMENT 4: Deployment success rate
# Repeats clean apply/teardown cycles and records pass/fail against a
# defined success criterion (Ready condition reached within timeout).
# ---------------------------------------------------------------------------
function Run-SuccessRateExperiment {
    Write-Host "=== Experiment 4: Deployment success rate ($trials trials) ==="
    $csv = Join-Path $resultsDir "success_rate.csv"
    "trial,success,elapsed_seconds" | Out-File $csv -Encoding utf8

    $successCount = 0
    for ($i = 1; $i -le $trials; $i++) {
        kubectl delete deployment $deploymentName -n $namespace --ignore-not-found | Out-Null
        Start-Sleep -Seconds 2
        $swatch = [System.Diagnostics.Stopwatch]::StartNew()
        kubectl apply -f $deploymentFile | Out-Null
        $elapsed = Wait-PodReady -labelSelector "app=$deploymentName" -timeoutSec 90
        $swatch.Stop()
        if ($elapsed) {
            $successCount++
            "$i,1,$([math]::Round($elapsed.TotalSeconds,2))" | Out-File $csv -Append -Encoding utf8
        } else {
            "$i,0,TIMEOUT" | Out-File $csv -Append -Encoding utf8
        }
    }
    $rate = [math]::Round(($successCount / $trials) * 100, 1)
    Write-Host "Success rate: $successCount / $trials ($rate%)"
}

# ---------------------------------------------------------------------------
# Run everything
# ---------------------------------------------------------------------------
Run-DeploymentTimingExperiment
Run-RecoveryExperiment
Run-ScalingExperiment
Run-SuccessRateExperiment

Write-Host "`nAll experiments complete. CSVs written to $resultsDir"
Write-Host "Also record (manually, once): Rancher Desktop version, Kubernetes/K3s version,"
Write-Host "container runtime (containerd/Moby), CPU/RAM allocation, Windows build, kubectl version."
