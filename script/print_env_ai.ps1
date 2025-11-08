[CmdletBinding()]
param(
  [switch]$Reveal = $false,
  [switch]$AsJson = $false
)

$ErrorActionPreference = 'Stop'

function Mask([string]$s){
  if ([string]::IsNullOrEmpty($s)) { return '' }
  if ($Reveal) { return $s }
  $len = $s.Length
  $head = [Math]::Min(4, $len)
  $tail = [Math]::Min(2, [Math]::Max(0, $len - $head))
  $prefix = $s.Substring(0, $head)
  $suffix = if ($tail -gt 0) { $s.Substring($len - $tail) } else { '' }
  return "$prefix***$suffix"
}

$data = [ordered]@{
  AZURE_SPEECH_KEY    = @{ set = [bool]$env:AZURE_SPEECH_KEY;    value = (Mask $env:AZURE_SPEECH_KEY) }
  AZURE_SPEECH_REGION = @{ set = [bool]$env:AZURE_SPEECH_REGION; value = $env:AZURE_SPEECH_REGION }
  GEMINI_API_KEY      = @{ set = [bool]$env:GEMINI_API_KEY;      value = (Mask $env:GEMINI_API_KEY) }
  GEMINI_MODEL        = @{ set = [bool]$env:GEMINI_MODEL;        value = $env:GEMINI_MODEL }
}

if ($AsJson) {
  $data | ConvertTo-Json -Depth 3
  exit 0
}

Write-Host "=== AI Environment Variables ===" -ForegroundColor Cyan
foreach ($k in $data.Keys) {
  $row = $data[$k]
  $status = if ($row.set) { 'SET' } else { 'MISSING' }
  $color = if ($row.set) { 'Green' } else { 'Yellow' }
  Write-Host ("{0,-22} : {1,-8} {2}" -f $k, $status, $row.value) -ForegroundColor $color
}

Write-Host "" 
Write-Host "Hints (PowerShell):" -ForegroundColor DarkCyan
Write-Host "  # Set for current session" -ForegroundColor DarkGray
Write-Host "  $env:AZURE_SPEECH_KEY='your-azure-key'" -ForegroundColor DarkGray
Write-Host "  $env:AZURE_SPEECH_REGION='your-region'" -ForegroundColor DarkGray
Write-Host "  $env:GEMINI_API_KEY='your-gemini-key'" -ForegroundColor DarkGray
Write-Host "  $env:GEMINI_MODEL='gemini-2.5-pro'" -ForegroundColor DarkGray

Write-Host "" 
Write-Host "Options:" -ForegroundColor DarkCyan
Write-Host "  -Reveal   Show full values (use with caution)" -ForegroundColor DarkGray
Write-Host "  -AsJson   Output JSON (machine-readable)" -ForegroundColor DarkGray

