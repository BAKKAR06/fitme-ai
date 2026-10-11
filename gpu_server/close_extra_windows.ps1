# Closes leftover FitMe terminal windows:
#  - finished helper scripts (INSTALL_ON_PHONE, CHECK_PROJECT, GIT_PUSH...) waiting on "press any key";
#  - old copies of the GPU server / backend / tunnel windows.
# Keeps the newest running window of each server. Usage: -StopAll closes the servers too.
param([switch]$StopAll)

$all = Get-CimInstance Win32_Process
$byParent = $all | Group-Object ParentProcessId -AsHashTable -AsString
function Get-Descendants($id) {
  $out = @()
  $kids = $byParent["$id"]
  foreach ($k in $kids) { $out += $k; $out += Get-Descendants $k.ProcessId }
  return $out
}

$kinds = @{ gpu = 'fashn_server\.py'; backend = 'uvicorn app\.main'; tunnel = 'tunnel\.py' }
$cmds = $all | Where-Object { $_.Name -eq 'cmd.exe' }

$keep = @{}
if (-not $StopAll) {
  foreach ($kind in $kinds.Keys) {
    $alive = $cmds | Where-Object {
      $_.CommandLine -match '/k' -and $_.CommandLine -match $kinds[$kind] -and
      ((Get-Descendants $_.ProcessId) | Where-Object { $_.Name -eq 'python.exe' })
    } | Sort-Object CreationDate -Descending | Select-Object -First 1
    if ($alive) { $keep[[string]$alive.ProcessId] = $kind }
  }
}

# never touch this script's own window
$self = $all | Where-Object { $_.ProcessId -eq $PID }
$protect = @{ "$($self.ParentProcessId)" = 1 }

$closed = 0
foreach ($c in $cmds) {
  $id = [string]$c.ProcessId
  if ($keep.ContainsKey($id) -or $protect.ContainsKey($id)) { continue }
  $isFitMe = ($c.CommandLine -match 'fitme-ai\\[^"]+\.bat') -or
             ($c.CommandLine -match '/k' -and $c.CommandLine -match 'fashn_server\.py|uvicorn app\.main|tunnel\.py')
  if (-not $isFitMe) { continue }
  $desc = Get-Descendants $c.ProcessId
  if ($desc | Where-Object { $keep.ContainsKey([string]$_.ProcessId) -or $protect.ContainsKey([string]$_.ProcessId) }) { continue }
  taskkill /PID $c.ProcessId /T /F *> $null
  $closed++
}
Write-Output "closed $closed old FitMe windows; kept: $(($keep.Values | Sort-Object) -join ', ')"
