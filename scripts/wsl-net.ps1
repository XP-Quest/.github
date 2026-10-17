# wsl-net.ps1: switch this machine's WSL networking between mirrored, tailscale and nat.
# Run elevated (the skill launches it via UAC). Idempotent; backs up .wslconfig first.
#   -Mode status    read-only report
#   -Mode mirrored  .wslconfig networkingMode=mirrored + inbound allow rules for $Ports
#   -Mode tailscale remove mirrored + rules (Tailscale runs inside WSL, NAT underneath)
#   -Mode nat       remove mirrored + rules (plain NAT)
# In every mode except status the legacy portproxy entries and the "WSL Port Forward 8080"
# task are removed; neither is wanted with mirrored, tailscale or a deliberate NAT setup.
param(
  [Parameter(Mandatory)][ValidateSet('status','mirrored','tailscale','nat')][string]$Mode,
  [int[]]$Ports = @(22),
  [string]$LanCidr = ''
)
$ErrorActionPreference = 'Continue'
$cfg     = Join-Path $env:USERPROFILE '.wslconfig'
$creator = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'   # WSL's Hyper-V VM creator id
$prefix  = 'XPQ WSL inbound'

function Get-LanCidr {
  $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1
  $ip = Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 | Select-Object -First 1
  $b = [Net.IPAddress]::Parse($ip.IPAddress).GetAddressBytes()
  $net = for ($i = 0; $i -lt 4; $i++) {
    $bits = [math]::Max(0, [math]::Min(8, $ip.PrefixLength - 8 * $i))
    $b[$i] -band ((0xFF -shl (8 - $bits)) -band 0xFF)
  }
  "$($net -join '.')/$($ip.PrefixLength)"
}

function Set-WslConfigKey([string]$Key, [string]$Value) {
  $lines = if (Test-Path $cfg) { @(Get-Content $cfg) } else { @() }
  if ($lines.Count) { Copy-Item $cfg "$cfg.bak-$(Get-Date -Format yyyyMMdd-HHmmss)" }
  $out = New-Object System.Collections.Generic.List[string]
  $in = $false; $done = $false; $hasSection = $false
  foreach ($l in $lines) {
    if ($l -match '^\s*\[(.+)\]\s*$') {
      if ($in -and -not $done -and $Value) { $out.Add("$Key=$Value"); $done = $true }
      $in = ($Matches[1] -eq 'wsl2'); if ($in) { $hasSection = $true }
    }
    if ($in -and $l -match "^\s*$Key\s*=") {
      if ($Value -and -not $done) { $out.Add("$Key=$Value"); $done = $true }
      continue
    }
    $out.Add($l)
  }
  if ($Value -and -not $done) {
    if (-not $hasSection) { $out.Add('[wsl2]') }
    $out.Add("$Key=$Value")
  }
  Set-Content -Path $cfg -Value $out
}

function Remove-XpqRules {
  Get-NetFirewallHyperVRule -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "$prefix*" } | Remove-NetFirewallHyperVRule
  Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "$prefix*" } | Remove-NetFirewallRule
}

function Remove-LegacyProxy {
  Unregister-ScheduledTask -TaskName 'WSL Port Forward 8080' -Confirm:$false -ErrorAction SilentlyContinue
  netsh interface portproxy reset | Out-Null
}

function Show-Status {
  "host: $env:COMPUTERNAME"
  "--- .wslconfig"; if (Test-Path $cfg) { Get-Content $cfg } else { '(none)' }
  "--- portproxy"; netsh interface portproxy show all
  "--- legacy task"; Get-ScheduledTask -TaskName 'WSL Port Forward 8080' -ErrorAction SilentlyContinue | Select-Object TaskName,State | Out-String
  "--- hyper-v fw"; Get-NetFirewallHyperVVMSetting -PolicyStore ActiveStore -ErrorAction SilentlyContinue | Format-List Name,Enabled,DefaultInboundAction | Out-String
  "--- XPQ hyper-v rules"; Get-NetFirewallHyperVRule -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "$prefix*" } | Format-Table Name,Enabled,Action,LocalPorts,RemoteAddresses -Auto | Out-String
  "--- XPQ windows rules"; Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "$prefix*" } | Format-Table Name,Enabled,Profile -Auto | Out-String
  "--- lan cidr"; Get-LanCidr
}

if ($Mode -eq 'status') { Show-Status; return }

Remove-LegacyProxy
Remove-XpqRules

switch ($Mode) {
  'mirrored' {
    if (-not $LanCidr) { $LanCidr = Get-LanCidr }
    Set-WslConfigKey 'networkingMode' 'mirrored'
    foreach ($p in $Ports) {
      New-NetFirewallHyperVRule -Name "$prefix $p" -DisplayName "$prefix $p" -Direction Inbound -VMCreatorId $creator `
        -Protocol TCP -LocalPorts $p -RemoteAddresses $LanCidr -Action Allow | Out-Null
      New-NetFirewallRule -Name "$prefix $p" -DisplayName "$prefix $p" -Direction Inbound -Protocol TCP -LocalPort $p `
        -RemoteAddress $LanCidr -Profile Private -Action Allow | Out-Null
    }
    "mirrored configured; allowed from $LanCidr on ports $($Ports -join ',')"
  }
  default {
    Set-WslConfigKey 'networkingMode' ''
    "$Mode configured; networkingMode removed from .wslconfig"
  }
}
"Run 'wsl --shutdown' (from Windows) for the change to take effect."
