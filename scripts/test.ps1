#!/usr/bin/env pwsh
param([switch]$NoBuild)

$ErrorActionPreference = 'Continue'
$root = Resolve-Path (Join-Path $PSScriptRoot '..')
Set-Location $root
$composeFile = 'docker/docker-compose.test.yml'

function Compose { docker compose -f $composeFile @args }

$tests = @(
  'test-model','test-m3-lsn','test-m4-fence','test-m4-watchdog','test-m4-partition',
  'test-m5-rejoin','test-m5-walgone','test-m5-wipe','test-compaction','test-m6-routing','test-m7-sync',
  'test-quorum-consistency','test-perf','test-genesis-coldstart','test-chaos'
)

$envMap = @{
  'test-compaction'         = @{ COMPACT_THRESHOLD = '8' }
  'test-m5-walgone'         = @{ WAL_KEEP = '8MB'; MAX_WAL = '64MB' }
  'test-m7-sync'            = @{ SYNCHRONOUS = 'on' }
  'test-quorum-consistency' = @{ SYNCHRONOUS = 'on' }
  'test-chaos'              = @{ SYNCHRONOUS = 'on' }
}
$tunables = @('COMPACT_THRESHOLD','WAL_KEEP','MAX_WAL','SYNCHRONOUS')

function Clear-Tunables { foreach ($k in $tunables) { Remove-Item "env:$k" -ErrorAction SilentlyContinue } }

function Wait-Ready {
  for ($i = 0; $i -lt 120; $i++) {
    docker exec -u postgres -e PGPASSFILE=/var/lib/postgresql/.pgpass pgr-node1 `
      psql -h 127.0.0.1 -U postgres -tAc 'SELECT 1' 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { return $true }
    Start-Sleep -Seconds 1
  }
  return $false
}

if (-not $NoBuild) {
  Write-Host '== building node + runner images =='
  Compose build
  if ($LASTEXITCODE -ne 0) { Write-Host 'build FAILED'; exit 1 }
}

$pass = 0; $other = 0; $summary = @()
foreach ($t in $tests) {
  Compose down -v 2>$null | Out-Null
  Write-Host "================ $t ================"
  Clear-Tunables
  if ($t -eq 'test-model') {
    $out = Compose run --rm runner bash "scripts/$t.sh" 2>&1 | Out-String
  } else {
    if ($envMap.ContainsKey($t)) { foreach ($kv in $envMap[$t].GetEnumerator()) { Set-Item "env:$($kv.Key)" $kv.Value } }
    Compose up -d node1 node2 node3 2>$null | Out-Null
    if (-not (Wait-Ready)) { Write-Host '  (warning: node1 not ready in time; running test anyway)' }
    $out = Compose run --rm runner bash "scripts/$t.sh" 2>&1 | Out-String
  }
  $lines = @($out -split "`n" | Where-Object { $_ -cmatch '^\s+(PASS|FAIL|CHECK)' })
  $lines | ForEach-Object { Write-Host $_.TrimEnd() }
  if ($lines.Count -gt 0 -and $lines[0] -cmatch '\bPASS\b') {
    $pass++; $mark = 'PASS'
  } else {
    $other++; $mark = 'CHECK'
    Write-Host "  ---- full output for $t (did not PASS) ----"
    ($out -split "`n" | Where-Object { $_ -notmatch 'screen size|FTS index' }) | ForEach-Object { Write-Host ('  | ' + $_.TrimEnd()) }
    Write-Host "  ---- end output for $t ----"
  }
  $summary += ('{0,-24} {1}' -f $t, $mark)
}
Clear-Tunables
Compose down -v 2>$null | Out-Null

Write-Host ''
Write-Host '==================== SUMMARY ===================='
$summary | ForEach-Object { Write-Host $_ }
Write-Host '------------------------------------------------'
Write-Host "$pass passed, $other need-attention, of $($tests.Count) tests"
if ($other -ne 0) { exit 1 }
