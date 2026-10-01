# Used by the tests only. Started the way Quietpane starts itself with administrator rights (but without
# asking for them), it writes down exactly what it was given - into received.json beside itself - so the
# test can compare it with what was sent. It takes the same named values the real window takes.
param([string]$ForUser, [string]$Tab, [string]$Tick, [string]$Pending, [switch]$Elevated)
$got = [ordered]@{
    Script = $PSCommandPath; ForUser = $ForUser; Tab = $Tab; Tick = $Tick; Pending = $Pending; Elevated = [bool]$Elevated
    Extra = @($args)
}
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'received.json'), ($got | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding $false))
