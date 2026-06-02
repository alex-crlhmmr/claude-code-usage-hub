# join-fleet.ps1 — point this Windows device's Claude Code telemetry at the hub.
# Usage (PowerShell):
#   .\join-fleet.ps1 -Hub YOUR-HUB.tailNNNN.ts.net
#   .\join-fleet.ps1 -DryRun          # preview the settings.json change, write nothing
# NOTE: tested logic, but run with -DryRun first to confirm the merge on your machine.
#       If anything looks off, use the manual settings.json block from the README instead.
param(
  [string]$Name    = $env:COMPUTERNAME,
  [string]$Hub     = "YOUR-HUB.tailNNNN.ts.net",
  [switch]$DryRun,
  [switch]$NoVerify
)
$ErrorActionPreference = "Stop"
$grpc = 4317; $http = 4318
$settings = Join-Path $env:USERPROFILE ".claude\settings.json"
$osuser   = $env:USERNAME
$endpoint = "http://${Hub}:${grpc}"

Write-Host "Device : $Name"
Write-Host "OS user: $osuser"
Write-Host "Hub    : $endpoint"
Write-Host "Target : $settings"

if (-not $NoVerify -and -not $DryRun) {
  try {
    $r = Invoke-WebRequest -Uri "http://${Hub}:${http}/v1/metrics" -Method POST -Body "{}" -ContentType "application/json" -TimeoutSec 6 -UseBasicParsing
    Write-Host "Hub reachable (HTTP $($r.StatusCode))."
  } catch {
    if ($_.Exception.Response) {
      Write-Host "Hub reachable (HTTP $($_.Exception.Response.StatusCode.value__))."
    } else {
      Write-Error "Hub unreachable at ${Hub}:${http} - is Tailscale up? (tailscale status). Re-run with -NoVerify to skip."
      exit 1
    }
  }
}

if (Test-Path $settings) {
  $json = Get-Content -Raw $settings | ConvertFrom-Json
  if (-not $DryRun) { Copy-Item $settings ("$settings.bak." + (Get-Date -Format "yyyyMMddHHmmss")) }
} else {
  New-Item -ItemType Directory -Force -Path (Split-Path $settings) | Out-Null
  $json = [pscustomobject]@{}
}

if (-not ($json.PSObject.Properties.Name -contains "env")) {
  $json | Add-Member -NotePropertyName env -NotePropertyValue ([pscustomobject]@{})
}
$vars = [ordered]@{
  CLAUDE_CODE_ENABLE_TELEMETRY = "1"
  OTEL_METRICS_EXPORTER        = "otlp"
  OTEL_LOGS_EXPORTER           = "otlp"
  OTEL_EXPORTER_OTLP_PROTOCOL  = "grpc"
  OTEL_EXPORTER_OTLP_ENDPOINT  = $endpoint
  OTEL_RESOURCE_ATTRIBUTES     = "device.name=$Name,os.user=$osuser"
}
foreach ($k in $vars.Keys) {
  if ($json.env.PSObject.Properties.Name -contains $k) { $json.env.$k = $vars[$k] }
  else { $json.env | Add-Member -NotePropertyName $k -NotePropertyValue $vars[$k] }
}

$out = $json | ConvertTo-Json -Depth 30
if ($DryRun) { Write-Output $out; exit 0 }
Set-Content -Path $settings -Value $out -Encoding UTF8
Write-Host "Wrote telemetry env -> $settings"
Write-Host "Now RESTART Claude Code (new session). Run it under YOUR OWN login."
