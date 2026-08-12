<#
.SYNOPSIS
    Minikube comparison protocol - mirrors k3_experiment_protocol.ps1 exactly,
    but targets the "minikube" kubectl context instead of "rancher-desktop",
    so results are directly comparable metric-for-metric.

.NOTES
    Run this AFTER installing and starting minikube (see accompanying steps).
    This script switches kubectl context to "minikube" at the start and
    switches back to "rancher-desktop" at the end, so it won't interfere
    with your existing Rancher Desktop cluster.

    Requires the same YAML files as before:
        Namespace/namespace.yaml
        YAML File/deployment.yaml
#>

param(
    [string]$repoPath = ".",
    [int]$trials = 15,
    [string]$namespace = "mastermain",
    [string]$deploymentName = "mywebapplication",
    [string]$targetContext = "minikube",
    [string]$originalContext = "rancher-desktop"
)

$deploymentFile = Join-Path $repoPath "YAML File\deployment.yaml"
$namespaceFile  = Join-Path $repoPath "Namespace\namespace.yaml"
$resultsDir = ".\results-minikube"
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
    return $null
}

function Ensure-Namespace {
    kubectl apply -f $namespaceFile | Out-Null
}

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

# ---------------------------------------------------------------------------
# Context switch — point kubectl at minikube for the duration of this script
# ---------------------------------------------------------------------------
Write-Host "=== Switching kubectl context to '$targetContext' ==="
$contextCheck = kubectl config get-contexts -o name
if ($contextCheck -notcontains $targetContext) {
    Write-Error "Context '$targetContext' not found. Run 'kubectl config get-contexts' to see available contexts. Aborting."
    exit 1
}
kubectl config use-context $targetContext | Out-Null
Write-Host "Now targeting: $(kubectl config current-context)"

# ---------------------------------------------------------------------------
# EXPERIMENT 1: Deployment provisioning time
# ---------------------------------------------------------------------------
function Run-DeploymentTimingExperiment {
    Write-Host "`n=== Experiment 1: Deployment provisioning time ($trials trials) ==="
    $csv = Join-Path $resultsDir "deployment_timing.csv"
    "trial,cold_or_warm,start_ts,end_ts,elapsed_seconds" | Out-File $csv -Encoding utf8

    Ensure-Namespace

    for ($i = 1; $i -le $trials; $i++) {
        kubectl delete deployment $deploymentName -n $namespace --ignore-not-found | Out-Null
        Start-Sleep -Seconds 2

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
# ---------------------------------------------------------------------------
function Run-RecoveryExperiment {
    Write-Host "`n=== Experiment 2: Failure recovery time ($trials trials) ==="
    $csv = Join-Path $resultsDir "recovery_timing.csv"
    "trial,start_ts,end_ts,elapsed_seconds" | Out-File $csv -Encoding utf8

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
# EXPERIMENT 3: Scale-out / scale-in
# ---------------------------------------------------------------------------
function Run-ScalingExperiment {
    Write-Host "`n=== Experiment 3: Scale-out/in timing ($trials trials) ==="
    $csv = Join-Path $resultsDir "scaling_timing.csv"
    "trial,direction,from_replicas,to_replicas,start_ts,end_ts,elapsed_seconds" | Out-File $csv -Encoding utf8

    kubectl apply -f $deploymentFile | Out-Null
    Wait-ReplicasReady -desiredCount 1 -timeoutSec 180 | Out-Null

    for ($i = 1; $i -le $trials; $i++) {
        $startTs = Get-Timestamp
        $swatch = [System.Diagnostics.Stopwatch]::StartNew()
        kubectl scale deployment $deploymentName -n $namespace --replicas=3 | Out-Null
        $elapsedOut = Wait-ReplicasReady -desiredCount 3 -timeoutSec 120
        $swatch.Stop()
        $endTs = Get-Timestamp
        $secOut = if ($elapsedOut) { [math]::Round($elapsedOut.TotalSeconds, 2) } else { "TIMEOUT" }
        "$i,scale_out,1,3,$startTs,$endTs,$secOut" | Out-File $csv -Append -Encoding utf8
        Write-Host "Trial $i scale-out (1->3): $secOut s"

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
# ---------------------------------------------------------------------------
function Run-SuccessRateExperiment {
    Write-Host "`n=== Experiment 4: Deployment success rate ($trials trials) ==="
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
# Run everything, then restore original context
# ---------------------------------------------------------------------------
try {
    Run-DeploymentTimingExperiment
    Run-RecoveryExperiment
    Run-ScalingExperiment
    Run-SuccessRateExperiment
}
finally {
    Write-Host "`n=== Restoring kubectl context to '$originalContext' ==="
    kubectl config use-context $originalContext | Out-Null
    Write-Host "Now targeting: $(kubectl config current-context)"
}

Write-Host "`nAll Minikube experiments complete. CSVs written to $resultsDir"
Write-Host "Also record (manually, once): minikube version, Kubernetes version used, driver (docker/hyperv/etc), CPU/memory allocation."
