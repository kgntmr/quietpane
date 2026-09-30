#Requires -Version 5.1
<#
    Quietpane's safety checks, checked.

        powershell -ExecutionPolicy Bypass -File tests\Run-QuietpaneTests.ps1
        powershell -ExecutionPolicy Bypass -File tests\Run-QuietpaneTests.ps1 -Live   (adds the EICAR test)

    The quarantine tests need administrator rights, and -ExecutionPolicy Bypass does not grant them:
    without an elevated window those six are skipped. The reliable way to get one is to paste this into
    an ordinary PowerShell window, from the repository folder, and answer Yes to the prompt Windows shows:

        Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass',
            '-File',"$PWD\tests\Run-QuietpaneTests.ps1",'-Live'

    (all on one line). An elevated window says "Administrator:" in its title bar and starts in
    C:\WINDOWS\system32; an ordinary one starts in your own user folder. Elevated with -Live: 171 checks run.

    No real malware is ever used. The only live test writes the EICAR string - the harmless standard file
    the antivirus industry publishes so people can check their protection works - into a temporary folder,
    and it is built at runtime so the string is never stored in this repository.

    Nothing here changes a setting. The one test that asks Defender to act needs -Live and administrator
    rights, and it acts only on the EICAR file it created itself.
#>
param([switch]$Live)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src\Quietpane.psm1') -Force

$script:Pass = 0; $script:Fail = 0; $script:Skip = 0
function Test-Case([string]$Name, [scriptblock]$Body) {
    try {
        $r = & $Body
        # note: ($true -eq 'skip') is true in PowerShell, so the type has to be checked as well
        if ($r -is [string] -and $r -eq 'skip') { $script:Skip++; Write-Host ("  SKIP  {0}" -f $Name) -ForegroundColor DarkGray; return }
        if ($r) { $script:Pass++; Write-Host ("  ok    {0}" -f $Name) -ForegroundColor Green }
        else { $script:Fail++; Write-Host ("  FAIL  {0}" -f $Name) -ForegroundColor Red }
    } catch {
        $script:Fail++; Write-Host ("  FAIL  {0} - {1}" -f $Name, $_.Exception.Message) -ForegroundColor Red
    }
}
function Section([string]$Name) { Write-Host "`n$Name" -ForegroundColor Cyan }

$colours = @{ Critical = '#7b1d1d'; High = '#a83232'; Medium = '#9a6700'; Low = '#6e695c'; Info = '#117a68' }

Section 'Threat names to plain language'
Test-Case 'ransomware becomes Critical' { (Resolve-QpThreatInfo -ThreatName 'Ransom:Win32/WannaCrypt.A!ml').Tier -eq 'Critical' }
Test-Case 'the family name is recognised' { (Resolve-QpThreatInfo -ThreatName 'Ransom:Win32/LockBit').Family -eq 'LockBit' }
Test-Case 'a stealer becomes High' { (Resolve-QpThreatInfo -ThreatName 'PWS:Win32/RedLineStealer').Tier -eq 'High' }
Test-Case 'unwanted software becomes Low' { (Resolve-QpThreatInfo -ThreatName 'PUA:Win32/CandyOpen').Tier -eq 'Low' }
Test-Case 'the EICAR test file is only Info' { (Resolve-QpThreatInfo -ThreatName 'Virus:DOS/EICAR_Test_File').Tier -eq 'Info' }
Test-Case 'an unknown name still lands somewhere sensible' {
    $i = Resolve-QpThreatInfo -ThreatName 'Trojan:Win32/NeverSeenBefore' -VendorSeverity 4
    $i.Tier -eq 'High' -and $i.MatchedBy -eq 'category'
}
Test-Case 'a name with no category at all falls back to Defender severity' {
    (Resolve-QpThreatInfo -ThreatName 'CompletelyUnknownShape' -VendorSeverity 5).Tier -eq 'Critical'
}
Test-Case 'an unknown family is never given a family name' {
    (Resolve-QpThreatInfo -ThreatName 'Trojan:Win32/NeverSeenBefore' -VendorSeverity 4).Family -eq ''
}

Section 'The shape every finding has'
Test-Case 'a finding carries the facts the card needs' {
    $f = New-QpFinding -Severity High -ThreatName 'Trojan:Win32/Example' -Source 'Microsoft Defender' -Path 'C:\x\y.exe' -Confidence Confirmed
    $f.Id -and $f.Severity -eq 'High' -and $f.Source -eq 'Microsoft Defender' -and $f.Status -eq 'Detected' -and $f.FirstSeen
}
Test-Case 'the same thing always gets the same id' {
    $a = New-QpFinding -ThreatName 'T' -Source 'Microsoft Defender' -Path 'C:\a.exe'
    $b = New-QpFinding -ThreatName 'T' -Source 'Microsoft Defender' -Path 'C:\a.exe'
    $a.Id -eq $b.Id
}
Test-Case 'different things get different ids' {
    (New-QpFinding -ThreatName 'T' -Path 'C:\a.exe').Id -ne (New-QpFinding -ThreatName 'T' -Path 'C:\b.exe').Id
}
Test-Case 'severity outside the five tiers is refused' {
    try { New-QpFinding -Severity 'Catastrophic' | Out-Null; $false } catch { $true }
}

Section 'Hashing'
Test-Case 'a readable file is hashed' {
    $p = Join-Path $env:TEMP ('qp-hash-' + [guid]::NewGuid().ToString('N') + '.txt')
    'hello' | Set-Content -LiteralPath $p
    $h = Get-QpFileHash $p
    Remove-Item $p -Force
    $h.Length -eq 64
}
Test-Case 'a missing file returns nothing instead of throwing' { (Get-QpFileHash 'C:\nope\missing.exe') -eq '' }
Test-Case 'a locked file does not break the scan' {
    $p = Join-Path $env:TEMP ('qp-lock-' + [guid]::NewGuid().ToString('N') + '.bin')
    'x' | Set-Content -LiteralPath $p
    $fs = [IO.File]::Open($p, 'Open', 'Read', 'None')   # deny everyone, including us
    try { $h = Get-QpFileHash $p; $ok = ($h -eq '' -or $h.Length -eq 64) } finally { $fs.Close(); Remove-Item $p -Force }
    $ok
}

Section 'The doughnut'
Test-Case 'counts add up to the number in the middle' {
    $svg = New-QpDonutSvg -Counts @{ Critical = 1; High = 2; Medium = 2; Low = 1; Info = 2 } -Colours $colours
    [int]([regex]::Match($svg, '>(\d+)<').Groups[1].Value) -eq 8
}
Test-Case 'one slice per severity that has findings' {
    $svg = New-QpDonutSvg -Counts @{ Critical = 1; High = 2; Medium = 2; Low = 1; Info = 2 } -Colours $colours
    [regex]::Matches($svg, '<path').Count -eq 5
}
Test-Case 'empty severities draw no slice' {
    $svg = New-QpDonutSvg -Counts @{ Critical = 0; High = 3; Medium = 0; Low = 0; Info = 0 } -Colours $colours
    [regex]::Matches($svg, '<path').Count -eq 0 -and [regex]::Matches($svg, '<circle').Count -eq 2
}
Test-Case 'no findings at all still renders' {
    $svg = New-QpDonutSvg -Counts @{ Critical = 0; High = 0; Medium = 0; Low = 0; Info = 0 } -Colours $colours
    $svg -match '>0<' -and [regex]::Matches($svg, '<path').Count -eq 0
}
Test-Case 'the chart describes itself for screen readers' {
    (New-QpDonutSvg -Counts @{ Critical = 1; High = 0; Medium = 0; Low = 0; Info = 0 } -Colours $colours) -match 'role="img"'
}

Section 'The report'
$mock = @(
    (New-QpFinding -Section Threats -Severity Critical -ThreatName 'Ransom:Win32/LockBit' -Family 'LockBit' -Category 'Ransomware' -Source 'Microsoft Defender' -Path 'C:\Users\T\Downloads\a.exe' -Confidence Confirmed -Status Detected -What 'w' -Why 'y' -Recommended 'r' -Title 'LockBit'),
    (New-QpFinding -Section Threats -Severity Low -ThreatName 'PUA:Win32/CandyOpen' -Family 'CandyOpen' -Source 'Microsoft Defender' -Path 'C:\b.exe' -Confidence Confirmed -Title 'CandyOpen'),
    (New-QpFinding -Section Files -Severity Medium -Title 'unsigned thing' -Detail 'detail' -Source 'Quietpane check' -Confidence Heuristic)
)
$counts = [ordered]@{ Critical = 1; High = 0; Medium = 1; Low = 1; Info = 0 }
Test-Case 'the report is built and contains the chart' {
    $html = New-QpReportHtml -Findings $mock -Counts $counts -IsAdmin $true
    $html -match '<svg' -and $html -match 'LockBit'
}
Test-Case 'the report runs no scripts and fetches nothing' {
    $html = New-QpReportHtml -Findings $mock -Counts $counts -IsAdmin $true
    [regex]::Matches($html, '<script').Count -eq 0 -and [regex]::Matches($html, 'src="http').Count -eq 0
}
Test-Case 'every severity appears in the legend, even the empty ones' {
    $html = New-QpReportHtml -Findings $mock -Counts $counts -IsAdmin $true
    [regex]::Matches($html, '<li').Count -eq 5
}
Test-Case 'Defender findings show their source and confidence' {
    $html = New-QpReportHtml -Findings $mock -Counts $counts -IsAdmin $true
    $html -match 'Microsoft Defender' -and $html -match 'Confirmed'
}
Test-Case 'a report with nothing in it still renders' {
    $html = New-QpReportHtml -Findings @() -Counts ([ordered]@{ Critical = 0; High = 0; Medium = 0; Low = 0; Info = 0 }) -IsAdmin $true
    $html -match '<svg' -and $html.Length -gt 500
}

Section 'Filtering, the way the window does it'
Test-Case 'filtering by severity returns only that severity' {
    @($mock | Where-Object { $_.Severity -eq 'Critical' }).Count -eq 1
}
Test-Case 'filtering an empty severity returns nothing, not everything' {
    @($mock | Where-Object { $_.Severity -eq 'High' }).Count -eq 0
}
Test-Case 'the same threat found twice is counted once' {
    $dupes = @(
        (New-QpFinding -ThreatName 'Trojan:Win32/X' -Source 'Microsoft Defender' -Path 'C:\same.exe'),
        (New-QpFinding -ThreatName 'Trojan:Win32/X' -Source 'Microsoft Defender' -Path 'C:\same.exe')
    )
    @($dupes | Group-Object Id).Count -eq 1
}

Section 'Talking to Defender'
Test-Case 'Defender state can always be read, even when Defender is missing' {
    $s = Get-QpDefenderState
    $null -ne $s -and $s.PSObject.Properties['Available'] -and $s.PSObject.Properties['Note']
}
Test-Case 'when Defender is unavailable the scan says so instead of pretending' {
    $s = Get-QpDefenderState
    if ($s.Available) { 'skip' } else { $s.Note -match 'Defender' }
}
Test-Case 'reading detections never throws' { $null -ne @(Get-QpDefenderFindings) }
Test-Case 'a Quietpane heuristic can never be sent to Defender for removal' {
    $h = New-QpFinding -Source 'Quietpane check' -ThreatName '' -Title 'heuristic thing' -Confidence Heuristic
    (Invoke-QpRemediate -Finding $h -Action Defender).Ok -eq $false
}

Section 'Leaving something alone'
Test-Case 'allowing an item never creates a Defender exclusion' {
    $before = @((Get-MpPreference -ErrorAction SilentlyContinue).ExclusionPath).Count
    $f = New-QpFinding -ThreatName 'Test:Win32/AllowMe' -Source 'Microsoft Defender' -Path 'C:\allow-test.exe'
    Invoke-QpRemediate -Finding $f -Action Allow | Out-Null
    $after = @((Get-MpPreference -ErrorAction SilentlyContinue).ExclusionPath).Count
    $listed = @(Get-QpAllowList | Where-Object { $_.ThreatName -eq 'Test:Win32/AllowMe' }).Count -eq 1
    $before -eq $after -and $listed
}
Test-Case 'every action is written to the audit log' {
    $log = Join-Path $env:ProgramData 'Quietpane\audit.log'
    (Test-Path $log) -and ((Get-Content $log -Tail 5) -join "`n") -match 'Allow'
}

Section 'Quarantine, restore and delete'
function New-TestFile([string]$Content = 'harmless test content') {
    $p = Join-Path $env:TEMP ('qp-quar-' + [guid]::NewGuid().ToString('N') + '.txt')
    [IO.File]::WriteAllText($p, $Content)
    return $p
}
function New-TestFinding([string]$Path) {
    New-QpFinding -Severity Medium -ThreatName 'Test:Win32/Harmless' -Source 'Quietpane check' -Confidence Heuristic `
        -Object (Split-Path $Path -Leaf) -Path $Path -Sha256 (Get-QpFileHash $Path) -Title 'test item'
}
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Test-Case 'protected Windows folders are refused' {
    (Test-QpProtectedPath (Join-Path $env:WINDIR 'System32\kernel32.dll')) -and
    (Test-QpProtectedPath (Join-Path $env:ProgramFiles 'anything.exe')) -and
    -not (Test-QpProtectedPath (Join-Path $env:TEMP 'something.exe'))
}
Test-Case 'a folder is never treated as a file to remove' { Test-QpProtectedPath $env:TEMP }
Test-Case 'a drive root is refused' { Test-QpProtectedPath 'C:\' }
Test-Case 'a finding whose file has changed is refused' {
    $p = New-TestFile
    $f = New-TestFinding $p
    [IO.File]::WriteAllText($p, 'something else entirely')
    $r = Test-QpFindingStillTrue $f
    Remove-Item $p -Force
    -not $r.Ok -and $r.Why -match 'changed'
}
Test-Case 'a finding whose file is gone is refused' {
    $p = New-TestFile
    $f = New-TestFinding $p
    Remove-Item $p -Force
    -not (Test-QpFindingStillTrue $f).Ok
}
Test-Case 'quarantine round trip puts back a byte-identical file' {
    if (-not $admin) { return 'skip' }
    $p = New-TestFile 'round trip content'
    $before = Get-QpFileHash $p
    $f = New-TestFinding $p
    $q = Invoke-QpRemediate -Finding $f -Action Quarantine
    $gone = -not (Test-Path -LiteralPath $p)
    $item = @(Get-QpQuarantineItems | Where-Object { $_.OriginalPath -eq $p }) | Select-Object -First 1
    $stored = $item -and (Test-Path (Join-Path $item.Folder 'payload.bin')) -and -not (Test-Path (Join-Path $item.Folder $item.FileName))
    $r = Restore-QpQuarantineItem -Id $item.Id
    $after = Get-QpFileHash $p
    Remove-Item $p -Force -ErrorAction SilentlyContinue
    $q.Ok -and $gone -and $stored -and $r.Ok -and $before -eq $after
}
Test-Case 'quarantined files are stored where they cannot run' {
    if (-not $admin) { return 'skip' }
    $p = New-TestFile
    $f = New-TestFinding $p
    Invoke-QpRemediate -Finding $f -Action Quarantine | Out-Null
    $item = @(Get-QpQuarantineItems | Where-Object { $_.OriginalPath -eq $p }) | Select-Object -First 1
    $ok = $item -and $item.FileName -like '*.txt' -and (Get-ChildItem $item.Folder | Where-Object { $_.Name -eq 'payload.bin' })
    Remove-QpQuarantineItem -Id $item.Id -Force | Out-Null
    $ok
}
Test-Case 'permanent deletion refuses without an explicit confirmation' {
    if (-not $admin) { return 'skip' }
    $p = New-TestFile
    $f = New-TestFinding $p
    $r = Invoke-QpRemediate -Finding $f -Action Delete      # no -Force
    $stillThere = Test-Path -LiteralPath $p
    Remove-Item $p -Force -ErrorAction SilentlyContinue
    -not $r.Ok -and $stillThere
}
Test-Case 'permanent deletion works when it is confirmed' {
    if (-not $admin) { return 'skip' }
    $p = New-TestFile
    $f = New-TestFinding $p
    $r = Invoke-QpRemediate -Finding $f -Action Delete -Force
    $r.Ok -and -not (Test-Path -LiteralPath $p)
}
Test-Case 'the Recycle Bin keeps the file rather than destroying it' {
    if (-not $admin) { return 'skip' }
    $p = New-TestFile
    $f = New-TestFinding $p
    $r = Invoke-QpRemediate -Finding $f -Action RecycleBin
    $r.Ok -and -not (Test-Path -LiteralPath $p) -and $r.Note -match 'Recycle Bin'
}
Test-Case 'a file in a protected folder is refused, not deleted' {
    $f = New-QpFinding -Path (Join-Path $env:WINDIR 'System32\notepad.exe') -ThreatName 'Test:Win32/NotReally' -Source 'Quietpane check'
    $r = Invoke-QpRemediate -Finding $f -Action Delete -Force
    -not $r.Ok -and (Test-Path (Join-Path $env:WINDIR 'System32\notepad.exe'))
}
Test-Case 'restoring something that is no longer quarantined fails cleanly' {
    (Restore-QpQuarantineItem -Id 'nothing-like-this').Ok -eq $false
}
Test-Case 'quarantine actions are all written to the audit log' {
    if (-not $admin) { return 'skip' }
    $log = Get-Content (Join-Path $env:ProgramData 'Quietpane\audit.log') -Tail 30 -ErrorAction SilentlyContinue
    ($log -join "`n") -match 'Quarantine' -and ($log -join "`n") -match 'DeletePermanently'
}

Section 'Stopping a check, and saying where it has got to'
Test-Case 'nothing is treated as stopped when nobody is asking' {
    Set-QpCancelCheck $null
    -not (Test-QpCancelled)
}
Test-Case 'the engine sees Stop the moment the window sets it' {
    $box = @{ Stop = $false }
    Set-QpCancelCheck { $box.Stop }
    $before = Test-QpCancelled
    $box.Stop = $true
    $after = Test-QpCancelled
    Set-QpCancelCheck $null
    -not $before -and $after
}
Test-Case 'a progress update can never break a check' {
    Set-QpProgressSink { throw 'the window fell over' }
    try { Write-QpProgress -Stage 'x' -Step 1 -Of 14; $true } catch { $false } finally { Set-QpProgressSink $null }
}

# One stopped check, looked at from several angles below.
$seen = New-Object System.Collections.ArrayList
$stoppedReport = Join-Path $env:TEMP ('qp-stopped-' + [guid]::NewGuid().ToString('N') + '.html')
Set-QpProgressSink { param($p) [void]$seen.Add($p) }
Set-QpCancelCheck { $true }
$stopped = Invoke-QpAudit -OutFile $stoppedReport
Set-QpCancelCheck $null
Set-QpProgressSink $null

Test-Case 'a stopped check says it was stopped' { [bool]$stopped.Cancelled }
Test-Case 'a stopped check reports nothing rather than half a picture' { @($stopped.Findings).Count -eq 0 -and $stopped.Total -eq 0 }
Test-Case 'a stopped check writes no report' { -not (Test-Path -LiteralPath $stoppedReport) }
Test-Case 'a stopped check still says how long it ran and how much it saw' {
    $stopped.PSObject.Properties['Seconds'] -and $stopped.PSObject.Properties['Scanned'] -and [int]$stopped.Scanned -ge 0
}
Test-Case 'progress says which step of how many, and what it is doing' {
    $first = @($seen)[0]
    $null -ne $first -and $first.Of -eq 14 -and $first.Step -ge 1 -and [string]$first.Stage -ne ''
}

Section 'The summary at the end of a check'
$sumCounts = [ordered]@{ Critical = 1; High = 2; Medium = 0; Low = 0; Info = 5 }
Test-Case 'it says how much was looked at, in words a person reads' {
    $s = New-QpScanSummary -Counts $sumCounts -Tally @{} -Scanned 1234 -Seconds 75 -Outstanding 3
    $s.Lines[0] -match '1,234' -and $s.Lines[0] -match '1 min 15 sec'
}
Test-Case 'every severity is named, including the empty ones' {
    $s = New-QpScanSummary -Counts $sumCounts -Tally @{} -Scanned 10 -Seconds 5 -Outstanding 3
    ($s.Lines -join ' ') -match 'critical' -and ($s.Lines -join ' ') -match '0 medium' -and ($s.Lines -join ' ') -match '0 low'
}
Test-Case 'what was done about it is counted' {
    $s = New-QpScanSummary -Counts $sumCounts -Tally @{ Removed = 1; Quarantined = 2; Recycled = 1; Deleted = 1; Allowed = 1; Failed = 1 } -Scanned 10 -Seconds 5 -Outstanding 0
    $dealt = @($s.Lines | Where-Object { $_ -match '^Dealt with' })[0]
    $dealt -match '1 removed by Defender' -and $dealt -match '2 in Quietpane' -and $dealt -match '1 in the Recycle Bin' -and $dealt -match '1 deleted for good' -and $dealt -match '1 left alone' -and $dealt -match 'did not work'
}
Test-Case 'nothing done means no "dealt with" line at all' {
    $s = New-QpScanSummary -Counts $sumCounts -Tally @{} -Scanned 10 -Seconds 5 -Outstanding 3
    @($s.Lines | Where-Object { $_ -match 'Dealt with' }).Count -eq 0
}
Test-Case 'serious findings get a next step that points at them' {
    (New-QpScanSummary -Counts $sumCounts -Tally @{} -Scanned 10 -Seconds 5 -Outstanding 3).NextStep -match '3 serious item'
}
Test-Case 'a failed action without admin rights explains why' {
    $s = New-QpScanSummary -Counts $sumCounts -Tally @{ Failed = 1 } -Scanned 10 -Seconds 5 -Outstanding 1 -IsAdmin $false
    $s.NextStep -match 'administrator'
}
Test-Case 'a clean check ends calmly rather than inventing work' {
    $clean = [ordered]@{ Critical = 0; High = 0; Medium = 0; Low = 0; Info = 12 }
    $s = New-QpScanSummary -Counts $clean -Tally @{} -Scanned 900 -Seconds 40 -Outstanding 0
    $s.NextStep -match 'nothing needs doing'
}
Test-Case 'a stopped check is never dressed up as a finished one' {
    $s = New-QpScanSummary -Counts $null -Tally @{} -Scanned 120 -Seconds 9 -Outstanding 0 -Cancelled $true
    $s.Lines[0] -match 'Stopped' -and $s.Lines[0] -match 'Nothing on this PC was changed' -and $s.NextStep -match 'run the check again'
}

Section 'What starts when you sign in'
# Everything below runs against a throwaway registry area, never the real sign-in settings.
$testRoot = 'HKCU:\Software\QuietpaneTest'
function Reset-StartupTestArea {
    Remove-Item -Path $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -Path "$testRoot\Run" -Force | Out-Null
    New-Item -Path "$testRoot\Approved" -Force | Out-Null
    New-Item -Path "$testRoot\Apps\Test.StartupApp_abc123\StartIt" -Force | Out-Null
    New-Item -Path "$testRoot\Apps\Test.PolicyApp_abc123\StartIt" -Force | Out-Null
    Set-ItemProperty -Path "$testRoot\Run" -Name 'QpTestApp' -Value ('"' + (Join-Path $env:WINDIR 'notepad.exe') + '" /quiet')
    Set-ItemProperty -Path "$testRoot\Run" -Name 'SecurityHealth' -Value (Join-Path $env:WINDIR 'system32\SecurityHealthSystray.exe')
    Set-ItemProperty -Path "$testRoot\Apps\Test.StartupApp_abc123\StartIt" -Name State -Value 2 -Type DWord
    Set-ItemProperty -Path "$testRoot\Apps\Test.PolicyApp_abc123\StartIt" -Name State -Value 4 -Type DWord
}
function Get-TestRegValue([string]$Name) {
    # The module keeps its registry helper private, so the tests have their own.
    [pscustomobject]@{ Exists = $null -ne (Get-ItemProperty -Path "$testRoot\Approved" -Name $Name -ErrorAction SilentlyContinue) }
}
function Get-TestStartupItems {
    Get-QpStartupItems -RunSources @(@{ Key = "$testRoot\Run"; Approved = "$testRoot\Approved"; Everyone = $false }) -FolderSources @() -AppRoot "$testRoot\Apps"
}
function Get-NewestRestorePoint([datetime]$Since) {
    Get-ChildItem (Join-Path $env:ProgramData 'Quietpane\restore') -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '*-startup' -and $_.CreationTime -ge $Since } | Sort-Object CreationTime -Descending | Select-Object -First 1
}

Test-Case 'what Windows and drivers need is always kept on' {
    (Get-QpStartupAdvice 'SecurityHealth C:\Windows\system32\SecurityHealthSystray.exe').Keep -and
    (Get-QpStartupAdvice 'RtkAudUService "C:\Windows\System32\RtkAudUService64.exe"').Keep -and
    -not (Get-QpStartupAdvice 'Discord C:\Users\x\Discord\Update.exe').Keep
}
Test-Case 'common items get a plain-language note' {
    (Get-QpStartupAdvice 'MicrosoftEdgeAutoLaunch_1 msedge.exe --no-startup-window').Note -match 'startup boost' -and
    (Get-QpStartupAdvice 'Steam steam.exe -silent').Note -match 'game launcher' -and
    (Get-QpStartupAdvice 'SomethingNobodyHasHeardOf x.exe').Note -eq ''
}
Test-Case 'switching off writes exactly what Task Manager writes' {
    Reset-StartupTestArea
    Set-QpStartupApproved -Path "$testRoot\Approved" -Name 'X' -On $false
    $b = (Get-ItemProperty -Path "$testRoot\Approved" -Name 'X').X
    $when = [DateTime]::FromFileTimeUtc([BitConverter]::ToInt64($b, 4))
    Set-QpStartupApproved -Path "$testRoot\Approved" -Name 'Y' -On $true
    $y = (Get-ItemProperty -Path "$testRoot\Approved" -Name 'Y').Y
    $b.Length -eq 12 -and $b[0] -eq 3 -and [math]::Abs(([DateTime]::UtcNow - $when).TotalMinutes) -lt 5 -and $y[0] -eq 2
}
Test-Case 'on and off are read the way Task Manager records them' {
    Reset-StartupTestArea
    $before = @(Get-TestStartupItems | Where-Object { $_.ApprovedName -eq 'QpTestApp' })[0].On
    Set-QpStartupApproved -Path "$testRoot\Approved" -Name 'QpTestApp' -On $false
    $after = @(Get-TestStartupItems | Where-Object { $_.ApprovedName -eq 'QpTestApp' })[0].On
    $before -and -not $after
}
Test-Case 'Store apps are read, and policy-set ones are locked' {
    Reset-StartupTestArea
    $items = @(Get-TestStartupItems)
    $app = @($items | Where-Object { $_.Kind -eq 'App' -and $_.Command -like 'Test.StartupApp*' })[0]
    $pol = @($items | Where-Object { $_.Kind -eq 'App' -and $_.Command -like 'Test.PolicyApp*' })[0]
    $app.On -and -not $app.Locked -and $pol.On -and $pol.Locked -and $app.Name -eq 'Startup App'
}
Test-Case 'a kept item is refused, whatever is ticked' {
    Reset-StartupTestArea
    $items = @(Get-TestStartupItems)
    $keep = @($items | Where-Object { $_.ApprovedName -eq 'SecurityHealth' })[0]
    Invoke-QpStartup -Ids $keep.Id -Items $items -Preview:$false | Out-Null
    $keep.Keep -and -not (Get-TestRegValue -Name 'SecurityHealth').Exists
}
Test-Case 'a policy-set item is refused' {
    Reset-StartupTestArea
    $items = @(Get-TestStartupItems)
    $pol = @($items | Where-Object { $_.Command -like 'Test.PolicyApp*' })[0]
    Invoke-QpStartup -Ids $pol.Id -Items $items | Out-Null
    (Get-ItemProperty -Path "$testRoot\Apps\Test.PolicyApp_abc123\StartIt").State -eq 4
}
Test-Case 'refusing everything leaves no empty restore point behind' {
    Reset-StartupTestArea
    $since = (Get-Date).AddSeconds(-1)
    $items = @(Get-TestStartupItems)
    $refused = @($items | Where-Object { $_.Keep -or $_.Locked } | ForEach-Object { $_.Id })
    Invoke-QpStartup -Ids $refused -Items $items | Out-Null
    $null -eq (Get-NewestRestorePoint $since)
}
Test-Case 'preview changes nothing' {
    Reset-StartupTestArea
    $items = @(Get-TestStartupItems)
    Invoke-QpStartup -Ids @($items.Id) -Items $items -Preview | Out-Null
    -not (Get-TestRegValue -Name 'QpTestApp').Exists -and
    (Get-ItemProperty -Path "$testRoot\Apps\Test.StartupApp_abc123\StartIt").State -eq 2
}
Test-Case 'switching off and Undo round-trip, for a Run entry and a Store app' {
    Reset-StartupTestArea
    $since = (Get-Date).AddSeconds(-2)
    $items = @(Get-TestStartupItems)
    $ids = @($items | Where-Object { $_.ApprovedName -eq 'QpTestApp' -or $_.Command -like 'Test.StartupApp*' } | ForEach-Object { $_.Id })
    Invoke-QpStartup -Ids $ids -Items $items | Out-Null
    $offRun = ((Get-ItemProperty -Path "$testRoot\Approved" -Name 'QpTestApp').QpTestApp)[0] -eq 3
    $offApp = (Get-ItemProperty -Path "$testRoot\Apps\Test.StartupApp_abc123\StartIt").State -eq 1
    $rp = Get-NewestRestorePoint $since
    if (-not $rp) { return $false }
    Invoke-QpUndo -Path $rp.FullName | Out-Null
    $backRun = -not (Get-TestRegValue -Name 'QpTestApp').Exists     # it wasn't set before, so it's gone again
    $backApp = (Get-ItemProperty -Path "$testRoot\Apps\Test.StartupApp_abc123\StartIt").State -eq 2
    Remove-Item -LiteralPath $rp.FullName -Recurse -Force   # the test's own restore point, not the user's
    $offRun -and $offApp -and $backRun -and $backApp
}
Test-Case 'Undo puts back exactly the bytes that were there before' {
    Reset-StartupTestArea
    $original = [byte[]](2, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8)
    Set-ItemProperty -Path "$testRoot\Approved" -Name 'QpTestApp' -Value $original -Type Binary
    $since = (Get-Date).AddSeconds(-2)
    $items = @(Get-TestStartupItems)
    Invoke-QpStartup -Ids @($items | Where-Object { $_.ApprovedName -eq 'QpTestApp' } | ForEach-Object { $_.Id }) -Items $items | Out-Null
    $rp = Get-NewestRestorePoint $since
    if (-not $rp) { return $false }
    Invoke-QpUndo -Path $rp.FullName | Out-Null
    $now = (Get-ItemProperty -Path "$testRoot\Approved" -Name 'QpTestApp').QpTestApp
    Remove-Item -LiteralPath $rp.FullName -Recurse -Force
    (@(Compare-Object $original $now -SyncWindow 0)).Count -eq 0
}
Test-Case 'reading the real sign-in list never throws' { $null -ne @(Get-QpStartupItems) }
Remove-Item -Path $testRoot -Recurse -Force -ErrorAction SilentlyContinue

Section 'Who used your camera, microphone and location'
# A throwaway copy of Windows' record, so the tests never touch the real permissions.
$devRoot = 'HKCU:\Software\QuietpaneTest\Consent'
$devMachine = 'HKCU:\Software\QuietpaneTest\MachineConsent'
function Set-TestUse([string]$Key, $Start, $Stop) {
    Set-ItemProperty -LiteralPath $Key -Name LastUsedTimeStart -Value ([int64]$Start.ToFileTime()) -Type QWord
    Set-ItemProperty -LiteralPath $Key -Name LastUsedTimeStop -Value ([int64]$(if ($Stop) { $Stop.ToFileTime() } else { 0 })) -Type QWord
}
function Reset-DeviceTestArea {
    Remove-Item -Path 'HKCU:\Software\QuietpaneTest' -Recurse -Force -ErrorAction SilentlyContinue
    $now = Get-Date
    foreach ($k in 'webcam', 'microphone', 'location') {
        New-Item -Path "$devRoot\$k\NonPackaged" -Force | Out-Null
        New-Item -Path "$devMachine\$k" -Force | Out-Null
        Set-ItemProperty -Path "$devRoot\$k" -Name Value -Value 'Allow' -Type String
        Set-ItemProperty -Path "$devRoot\$k\NonPackaged" -Name Value -Value 'Allow' -Type String
        Set-ItemProperty -Path "$devMachine\$k" -Name Value -Value $(if ($k -eq 'location') { 'Deny' } else { 'Allow' }) -Type String
    }
    $cam = "$devRoot\webcam"
    foreach ($a in @{ N = 'Test.VideoCaller_1234567890abc'; V = 'Allow' }, @{ N = 'Test.NeverUsed_1234567890abc'; V = 'Allow' },
                   @{ N = 'Test.AlreadyOff_1234567890abc'; V = 'Deny' }, @{ N = 'Test.AsksFirst_1234567890abc'; V = 'Prompt' },
                   @{ N = 'Test.SystemApp_1234567890abc'; V = $null }) {
        New-Item -Path "$cam\$($a.N)" -Force | Out-Null
        if ($a.V) { Set-ItemProperty -Path "$cam\$($a.N)" -Name Value -Value $a.V -Type String }
    }
    Set-TestUse "$cam\Test.VideoCaller_1234567890abc" $now.AddHours(-2) $now.AddHours(-2).AddMinutes(5)
    Set-TestUse "$cam\Test.SystemApp_1234567890abc" $now.AddDays(-1) $now.AddDays(-1).AddMinutes(1)
    # A program using the camera right now, and one program that Windows noted in two places.
    foreach ($p in 'C:#QpTest#caller.exe', 'C:#Program Files#QpTest Studio#old#studio.exe', 'C:#Program Files#QpTest Studio#new#studio.exe') { New-Item -Path "$cam\NonPackaged\$p" -Force | Out-Null }
    Set-TestUse "$cam\NonPackaged\C:#QpTest#caller.exe" $now.AddMinutes(-1) $null
    Set-TestUse "$cam\NonPackaged\C:#Program Files#QpTest Studio#old#studio.exe" $now.AddDays(-30) $now.AddDays(-30)
    Set-TestUse "$cam\NonPackaged\C:#Program Files#QpTest Studio#new#studio.exe" $now.AddDays(-3) $now.AddDays(-3)
}
function Get-TestDeviceUse { Get-QpDeviceUse -UserRoot $devRoot -MachineRoot $devMachine -BootTime (Get-Date).AddDays(-1).AddHours(-1) }
function Get-TestConsent([string]$Key) { (Get-ItemProperty -LiteralPath $Key -Name Value -ErrorAction SilentlyContinue).Value }
function Get-NewestDeviceRestorePoint([datetime]$Since) {
    Get-ChildItem (Join-Path $env:ProgramData 'Quietpane\restore') -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '*-devices' -and $_.CreationTime -ge $Since } | Sort-Object CreationTime -Descending | Select-Object -First 1
}

Test-Case 'times are put in plain words' {
    $now = [datetime]'2026-09-21 15:00'
    (Format-QpWhen $null $now) -eq 'never' -and (Format-QpWhen $now.AddSeconds(-30) $now) -eq 'a moment ago' -and
    (Format-QpWhen $now.AddMinutes(-20) $now) -eq '20 minutes ago' -and (Format-QpWhen $now.AddMinutes(-70) $now) -eq 'an hour ago' -and
    (Format-QpWhen $now.AddHours(-5) $now) -eq '5 hours ago' -and (Format-QpWhen ([datetime]'2026-09-21 01:00') $now) -eq 'earlier today' -and
    (Format-QpWhen $now.AddDays(-1) $now) -eq 'yesterday' -and (Format-QpWhen $now.AddDays(-4) $now) -eq '4 days ago' -and
    (Format-QpWhen ([datetime]'2026-03-16 12:00') $now) -eq '16 March' -and (Format-QpWhen ([datetime]'2025-12-27 12:00') $now) -eq '27 December 2025'
}
Test-Case 'who used the camera is read, in use first, then newest' {
    Reset-DeviceTestArea
    $cam = @(Get-TestDeviceUse | Where-Object { $_.Kind -eq 'webcam' })[0]
    $first = $cam.Apps[0]
    $caller = @($cam.Apps | Where-Object { $_.Name -eq 'Video Caller' })[0]
    $first.Type -eq 'Desktop' -and $first.InUse -and $first.Name -eq 'caller' -and
    $caller.Type -eq 'App' -and -not $caller.InUse -and (Format-QpWhen $caller.LastUsed) -eq 'an hour ago' -and $caller.Allowed
}
Test-Case 'each app''s own setting is read: allowed, off, asks first, or managed by Windows' {
    Reset-DeviceTestArea
    $apps = @(Get-TestDeviceUse | Where-Object { $_.Kind -eq 'webcam' })[0].Apps
    $by = @{}; foreach ($a in $apps) { $by[$a.Name] = $a }
    $by['Never Used'].Allowed -and $null -eq $by['Never Used'].LastUsed -and
    -not $by['Already Off'].Allowed -and $by['Asks First'].Asks -and $by['System App'].Locked -and -not $by['Video Caller'].Locked
}
Test-Case 'one line per program, however many copies of it Windows noted' {
    Reset-DeviceTestArea
    $studio = @(@(Get-TestDeviceUse | Where-Object { $_.Kind -eq 'webcam' })[0].Apps | Where-Object { $_.Name -eq 'QpTest Studio' })
    $studio.Count -eq 1 -and (Format-QpWhen $studio[0].LastUsed) -eq '3 days ago' -and $studio[0].Missing
}
Test-Case 'a device switched off for the whole PC says so' {
    Reset-DeviceTestArea
    $u = @(Get-TestDeviceUse)
    -not @($u | Where-Object { $_.Kind -eq 'location' })[0].PcOn -and @($u | Where-Object { $_.Kind -eq 'webcam' })[0].PcOn
}
Test-Case 'preview changes nothing' {
    Reset-DeviceTestArea
    $u = @(Get-TestDeviceUse)
    Invoke-QpDeviceAccess -Ids 'webcam|App|Test.VideoCaller_1234567890abc', 'webcam|AllDesktop' -Use $u -Preview | Out-Null
    (Get-TestConsent "$devRoot\webcam\Test.VideoCaller_1234567890abc") -eq 'Allow' -and (Get-TestConsent "$devRoot\webcam\NonPackaged") -eq 'Allow'
}
Test-Case 'Windows'' own apps and single desktop programs are refused, with no empty restore point' {
    Reset-DeviceTestArea
    $since = (Get-Date).AddSeconds(-1)
    $u = @(Get-TestDeviceUse)
    Invoke-QpDeviceAccess -Ids 'webcam|App|Test.SystemApp_1234567890abc', 'webcam|Desktop|C:\QpTest\caller.exe' -Use $u | Out-Null
    $null -eq (Get-TestConsent "$devRoot\webcam\Test.SystemApp_1234567890abc") -and $null -eq (Get-NewestDeviceRestorePoint $since)
}
Test-Case 'switching an app off writes what Settings writes, and Undo puts it back' {
    Reset-DeviceTestArea
    $since = (Get-Date).AddSeconds(-2)
    $u = @(Get-TestDeviceUse)
    Invoke-QpDeviceAccess -Ids 'webcam|App|Test.VideoCaller_1234567890abc' -Use $u | Out-Null
    $off = (Get-TestConsent "$devRoot\webcam\Test.VideoCaller_1234567890abc") -eq 'Deny'
    $rp = Get-NewestDeviceRestorePoint $since
    if (-not $rp) { return $false }
    Invoke-QpUndo -Path $rp.FullName | Out-Null
    $back = (Get-TestConsent "$devRoot\webcam\Test.VideoCaller_1234567890abc") -eq 'Allow'
    Remove-Item -LiteralPath $rp.FullName -Recurse -Force   # the test's own restore point, not the user's
    $off -and $back
}
Test-Case 'the one switch for all desktop programs, and Undo, work too' {
    Reset-DeviceTestArea
    $since = (Get-Date).AddSeconds(-2)
    $u = @(Get-TestDeviceUse)
    Invoke-QpDeviceAccess -Ids 'webcam|AllDesktop' -Use $u | Out-Null
    $off = (Get-TestConsent "$devRoot\webcam\NonPackaged") -eq 'Deny'
    $offRead = -not @(Get-TestDeviceUse | Where-Object { $_.Kind -eq 'webcam' })[0].DesktopOn
    $rp = Get-NewestDeviceRestorePoint $since
    if (-not $rp) { return $false }
    Invoke-QpUndo -Path $rp.FullName | Out-Null
    $back = (Get-TestConsent "$devRoot\webcam\NonPackaged") -eq 'Allow'
    Remove-Item -LiteralPath $rp.FullName -Recurse -Force
    $off -and $offRead -and $back
}
Test-Case 'reading the real record never throws, and covers all three' {
    @(Get-QpDeviceUse | ForEach-Object { $_.Kind }) -join ',' -eq 'webcam,microphone,location'
}
Remove-Item -Path 'HKCU:\Software\QuietpaneTest' -Recurse -Force -ErrorAction SilentlyContinue

Section 'Your browser add-ons'
# A browser of our own making, in Temp: real files in the real shape, so nothing here touches the
# browsers you actually use. The policy it reads is under HKCU:\Software\QuietpaneTest.
$addonRoot = Join-Path $env:TEMP 'QuietpaneTestBrowser'
$addonProfile = Join-Path $addonRoot 'Fake\User Data\Default'
$addonFamily = @{ Key = 'test'; Name = 'TestBrowser'; Data = 'Fake\User Data'; Roaming = $false; Policy = 'Software\QuietpaneTest\Policies\TestBrowser' }
$addonPolicy = 'HKCU:\Software\QuietpaneTest\Policies\TestBrowser'
$addonBlockList = Join-Path $addonPolicy 'ExtensionInstallBlocklist'
$addonIds = @{ Coupon = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; Docs = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
               Part = 'cccccccccccccccccccccccccccccccc'; Work = 'dddddddddddddddddddddddddddddddd'
               Many = 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' }
$addonInstalled = [datetime]'2024-03-01 12:00'

function New-TestAddonFiles([string]$Id, $Manifest, $Messages) {
    $dir = Join-Path $addonProfile "Extensions\$Id\1.0_0"
    [void][IO.Directory]::CreateDirectory($dir)
    [IO.File]::WriteAllText((Join-Path $dir 'manifest.json'), ($Manifest | ConvertTo-Json -Depth 8))
    if ($Messages) {
        $loc = Join-Path $dir '_locales\en'
        [void][IO.Directory]::CreateDirectory($loc)
        [IO.File]::WriteAllText((Join-Path $loc 'messages.json'), ($Messages | ConvertTo-Json -Depth 8))
    }
}
function Reset-AddonTestArea {
    if (Test-Path -LiteralPath $addonRoot) { [IO.Directory]::Delete($addonRoot, $true) }
    [void][IO.Directory]::CreateDirectory($addonProfile)
    Remove-Item -Path $addonPolicy -Recurse -Force -ErrorAction SilentlyContinue
    New-TestAddonFiles $addonIds.Coupon @{ name = 'Coupon Saver'; version = '1.0'; permissions = @('webRequest', 'history', 'storage', 'somethingNew'); host_permissions = @('<all_urls>') } $null
    New-TestAddonFiles $addonIds.Docs @{ name = 'Docs Helper'; version = '1.0'; permissions = @('storage'); host_permissions = @('https://docs.google.com/*', 'edge://settings/*') } $null
    New-TestAddonFiles $addonIds.Part @{ name = 'PDF Viewer'; version = '1.0'; permissions = @('tabs') } $null
    New-TestAddonFiles $addonIds.Work @{ name = 'Work Add-on'; version = '1.0'; host_permissions = @('<all_urls>') } $null
    New-TestAddonFiles $addonIds.Many @{ name = '__MSG_extName__'; version = '1.0'; permissions = @('cookies') } @{ extName = @{ message = 'Page Translator' } }
    # The browser's own settings file: where each add-on came from, and whether it is switched on.
    $chromeTime = "$([int64]($addonInstalled.ToFileTimeUtc() / 10))"
    $settings = [ordered]@{}
    $settings[$addonIds.Coupon] = @{ location = 3; state = 1; first_install_time = $chromeTime }
    $settings[$addonIds.Docs]   = @{ location = 1; disable_reasons = @(134217728); first_install_time = $chromeTime }
    $settings[$addonIds.Part]   = @{ location = 5; state = 1 }
    $settings[$addonIds.Work]   = @{ location = 9; state = 1 }
    $settings[$addonIds.Many]   = @{ location = 1; state = 0 }
    # An id the browser remembers but never installed: no manifest, no folder, so it must not be listed.
    $settings['ffffffffffffffffffffffffffffffff'] = @{ state = 0 }
    $json = @{ extensions = @{ settings = $settings } } | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText((Join-Path $addonProfile 'Secure Preferences'), $json)
}
function Get-TestAddons { @(Get-QpBrowserExtensions -Families @($addonFamily) -LocalRoot $addonRoot -NoFirefox) }
function Get-TestAddon([string]$Name) { @(Get-TestAddons | Where-Object { $_.Name -eq $Name })[0] }
function Get-NewestAddonRestorePoint([datetime]$Since) {
    Get-ChildItem (Join-Path $env:ProgramData 'Quietpane\restore') -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '*-browser-add-ons' -and $_.CreationTime -ge $Since } | Sort-Object CreationTime -Descending | Select-Object -First 1
}

Test-Case 'what an add-on may do turns into plain words, and anything unknown is counted, not guessed' {
    $r = Get-QpExtensionReach -Permissions @('<all_urls>', 'webRequest', 'history', 'storage', 'somethingNew')
    $r.Everywhere -and $r.Level -eq 'Everything' -and $r.Unnamed -eq 1 -and
    $r.Can[0] -eq 'can watch every request your browser makes' -and $r.Can -contains 'can read your browsing history'
}
Test-Case 'the sites it can reach are read from its manifest, and the browser''s own pages are not sites' {
    $r = Get-QpExtensionReach -Permissions @('https://docs.google.com/*', 'https://*.drive.google.com/*', 'edge://settings/*', 'chrome://resources/')
    (@($r.Sites) -join ',') -eq 'docs.google.com,drive.google.com' -and -not $r.Everywhere
}
Test-Case 'one line says how far it reaches, whether it is on, and when it arrived' {
    Reset-AddonTestArea
    $coupon = Format-QpExtensionUse (Get-TestAddon 'Coupon Saver')
    $docs = Format-QpExtensionUse (Get-TestAddon 'Docs Helper')
    $coupon -match '^Reads and changes everything on every site you visit\. It can watch every request your browser makes\. Added ' -and
    $docs -match '^Only works on docs\.google\.com\. Switched off in the browser at the moment\. Added '
}
Test-Case 'the browser''s own install date is read the way the browser writes it' {
    $back = ConvertFrom-QpChromeTime "$([int64]($addonInstalled.ToFileTimeUtc() / 10))"
    $null -ne $back -and [math]::Abs(($back - $addonInstalled).TotalSeconds) -lt 1
}
Test-Case 'every add-on in a profile is read, with where it came from' {
    Reset-AddonTestArea
    $all = Get-TestAddons
    $by = @{}; foreach ($a in $all) { $by[$a.Name] = $a }
    # Six entries are recorded, but one was never installed, so five are real.
    $all.Count -eq 5 -and $by['Coupon Saver'].Source -eq 'Another program on this PC put it there' -and
    $by['Coupon Saver'].On -and $by['PDF Viewer'].BuiltIn -and $by['Work Add-on'].Locked -and
    $by['Coupon Saver'].Browser -eq 'TestBrowser' -and $by['Coupon Saver'].ExtId -eq $addonIds.Coupon
}
Test-Case 'an add-on the browser has switched off says so, however the browser wrote it down' {
    Reset-AddonTestArea
    # One is off by a plain state of 0, the other by a list of reasons, which is how newer browsers write it.
    -not (Get-TestAddon 'Page Translator').On -and -not (Get-TestAddon 'Docs Helper').On -and (Get-TestAddon 'Coupon Saver').On
}
Test-Case 'a name written for several languages is read from the add-on''s own message file' {
    Reset-AddonTestArea
    $null -ne (Get-TestAddon 'Page Translator')
}
Test-Case 'preview changes nothing' {
    Reset-AddonTestArea
    Invoke-QpExtension -Ids "test|Default|$($addonIds.Coupon)" -Extensions (Get-TestAddons) -Preview | Out-Null
    -not (Test-Path -Path $addonBlockList)
}
Test-Case 'the browser''s own parts, and anything a policy controls, are refused - with no empty restore point' {
    Reset-AddonTestArea
    $since = (Get-Date).AddSeconds(-1)
    Invoke-QpExtension -Ids "test|Default|$($addonIds.Part)", "test|Default|$($addonIds.Work)" -Extensions (Get-TestAddons) | Out-Null
    -not (Test-Path -Path $addonBlockList) -and $null -eq (Get-NewestAddonRestorePoint $since)
}
Test-Case 'switching one off writes the policy the browser reads, and Undo takes it away again' {
    Reset-AddonTestArea
    $since = (Get-Date).AddSeconds(-2)
    Invoke-QpExtension -Ids "test|Default|$($addonIds.Coupon)" -Extensions (Get-TestAddons) | Out-Null
    $written = (Get-QpRegValue -Path $addonBlockList -Name '1').Value -eq $addonIds.Coupon
    $seen = (Get-TestAddon 'Coupon Saver').Blocked -and -not (Get-TestAddon 'Coupon Saver').On
    $rp = Get-NewestAddonRestorePoint $since
    if (-not $rp) { return $false }
    Invoke-QpUndo -Path $rp.FullName | Out-Null
    # The list Quietpane made goes with it, so the browser is left exactly as it was.
    $gone = -not (Test-Path -Path $addonBlockList)
    Remove-Item -LiteralPath $rp.FullName -Recurse -Force   # the test's own restore point, not the user's
    $written -and $seen -and $gone
}
Test-Case 'a blocklist that is already there keeps its entries' {
    Reset-AddonTestArea
    New-Item -Path $addonBlockList -Force | Out-Null
    Set-ItemProperty -Path $addonBlockList -Name '1' -Value 'someoneelseextensionidhere00000a' -Type String
    Set-ItemProperty -Path $addonBlockList -Name '2' -Value 'someoneelseextensionidhere00000b' -Type String
    $since = (Get-Date).AddSeconds(-2)
    Invoke-QpExtension -Ids "test|Default|$($addonIds.Coupon)" -Extensions (Get-TestAddons) | Out-Null
    $slot = (Get-QpRegValue -Path $addonBlockList -Name '3').Value -eq $addonIds.Coupon
    $kept = (Get-QpRegValue -Path $addonBlockList -Name '1').Value -eq 'someoneelseextensionidhere00000a'
    $rp = Get-NewestAddonRestorePoint $since
    if (-not $rp) { return $false }
    Invoke-QpUndo -Path $rp.FullName | Out-Null
    $stillThere = (Get-QpRegValue -Path $addonBlockList -Name '2').Value -eq 'someoneelseextensionidhere00000b'
    $undone = -not (Get-QpRegValue -Path $addonBlockList -Name '3').Exists
    Remove-Item -LiteralPath $rp.FullName -Recurse -Force
    Remove-Item -Path $addonPolicy -Recurse -Force -ErrorAction SilentlyContinue
    $slot -and $kept -and $stillThere -and $undone
}
Test-Case 'one that is already blocked is left alone rather than listed twice' {
    Reset-AddonTestArea
    New-Item -Path $addonBlockList -Force | Out-Null
    Set-ItemProperty -Path $addonBlockList -Name '1' -Value $addonIds.Coupon -Type String
    $since = (Get-Date).AddSeconds(-1)
    Invoke-QpExtension -Ids "test|Default|$($addonIds.Coupon)" -Extensions (Get-TestAddons) | Out-Null
    $one = @((Get-Item -Path $addonBlockList).GetValueNames()).Count -eq 1
    $none = $null -eq (Get-NewestAddonRestorePoint $since)
    Remove-Item -Path $addonPolicy -Recurse -Force -ErrorAction SilentlyContinue
    $one -and $none
}
Test-Case 'Firefox add-ons are read too, and Quietpane says it cannot switch those off' {
    $dir = Join-Path $addonRoot 'FirefoxProfiles\test.default'
    [void][IO.Directory]::CreateDirectory($dir)
    $addons = @{ addons = @(
        @{ id = 'toolbar@example.com'; type = 'extension'; version = '2.0'; active = $true; location = 'app-profile'
           installDate = 1709294400000; defaultLocale = @{ name = 'Old Toolbar' }
           userPermissions = @{ permissions = @('history'); origins = @('<all_urls>') } },
        @{ id = 'builtin@mozilla.org'; type = 'extension'; version = '1.0'; active = $true; location = 'app-system-defaults'
           defaultLocale = @{ name = 'Firefox Built-in' }; userPermissions = $null },
        @{ id = 'theme@example.com'; type = 'theme'; version = '1.0'; active = $true; location = 'app-profile'; defaultLocale = @{ name = 'A Theme' } }
    ) }
    [IO.File]::WriteAllText((Join-Path $dir 'extensions.json'), ($addons | ConvertTo-Json -Depth 10))
    $ff = @(Get-QpFirefoxAddons -Root (Join-Path $addonRoot 'FirefoxProfiles'))
    $old = @($ff | Where-Object { $_.Name -eq 'Old Toolbar' })[0]
    # Themes are not add-ons that can read your browsing, so they are not listed.
    $ff.Count -eq 2 -and $old.Reach.Everywhere -and $old.PolicyRoot -eq '' -and $old.Browser -eq 'Firefox' -and
    @($ff | Where-Object { $_.Name -eq 'Firefox Built-in' })[0].BuiltIn
}
Test-Case 'reading the real browsers on this PC never throws' {
    $real = @(Get-QpBrowserExtensions)
    # Every one has to carry the same shape, whatever browser it came from.
    $shapeOk = $true
    foreach ($e in $real) { if ($null -eq $e.Name -or $null -eq $e.Reach -or $null -eq $e.Browser) { $shapeOk = $false } }
    $shapeOk
}
if (Test-Path -LiteralPath $addonRoot) { [IO.Directory]::Delete($addonRoot, $true) }
Remove-Item -Path 'HKCU:\Software\QuietpaneTest' -Recurse -Force -ErrorAction SilentlyContinue

Section 'Live readings on Home'
Test-Case 'heat is always put into words, not left to colour' {
    (Get-QpHeatWord 40).Word -eq 'cool' -and (Get-QpHeatWord 60).Word -eq 'comfortable' -and (Get-QpHeatWord 75).Word -eq 'warm' -and
    (Get-QpHeatWord 88).Word -eq 'hot' -and (Get-QpHeatWord 97).Word -eq 'very hot'
}
Test-Case 'a driver''s own limit brings "very hot" forward' { (Get-QpHeatWord 82 -MaxC 90).Word -eq 'very hot' }
Test-Case 'a missing temperature says "not shared", never zero' {
    $h = Get-QpHeatWord $null
    $h.Word -eq 'not shared' -and $h.Level -eq 'none'
}
Test-Case 'setting up the readers never throws' { $null -ne (New-QpLiveMonitor) }
Test-Case 'a reading stays within believable ranges' {
    $m = New-QpLiveMonitor
    Start-Sleep -Milliseconds 1000
    $r = Get-QpLiveReading -Monitor $m
    $cpuOk = ($null -eq $r.CpuUsage) -or ($r.CpuUsage -ge 0 -and $r.CpuUsage -le 100)
    $tempOk = ($null -eq $r.CpuTempC) -or ($r.CpuTempC -gt 5 -and $r.CpuTempC -lt 130)
    $memOk = ($null -eq $r.MemUsed) -or ($r.MemUsed -ge 0 -and $r.MemUsed -le $r.MemTotal)
    $gpuOk = @($r.Gpus | Where-Object { $_.Usage -lt 0 -or $_.Usage -gt 100 -or ($null -ne $_.TempC -and ($_.TempC -le 0 -or $_.TempC -ge 130)) }).Count -eq 0
    $cpuOk -and $tempOk -and $memOk -and $gpuOk
}
Test-Case 'a thermal sensor that never moves is flagged rather than shown as live' {
    function New-FakeMonitor([scriptblock]$Kelvin) {
        $zone = [pscustomobject]@{}
        $zone | Add-Member -MemberType ScriptMethod -Name NextValue -Value $Kelvin
        [pscustomobject]@{ Cpu = $null; CpuName = ''; Zone = $zone; ZoneName = '\_TZ.TEST'; Limits = @(); Available = $null; MemTotal = [double]0
            Engines = $null; EnginePrev = $null; GpuMemory = $null; GpuSensors = $false; ZoneSeen = New-Object System.Collections.Generic.List[double] }
    }
    $stuck = New-FakeMonitor { 3252 }
    $moving = New-FakeMonitor { 3200 + (Get-Random -Minimum 0 -Maximum 100) }
    1..24 | ForEach-Object { $a = Get-QpLiveReading -Monitor $stuck; $b = Get-QpLiveReading -Monitor $moving }
    $a.CpuTempStuck -and -not $b.CpuTempStuck -and [math]::Abs($a.CpuTempC - 52.05) -lt 0.1
}
Test-Case 'Windows slowing the processor to cool it is noticed, and only then' {
    function New-LimitMonitor([double[]]$Values) {
        $limits = foreach ($v in $Values) {
            $c = [pscustomobject]@{ V = $v }
            $c | Add-Member -MemberType ScriptMethod -Name NextValue -Value { $this.V }
            $c
        }
        [pscustomobject]@{ Cpu = $null; CpuName = ''; Zone = $null; ZoneName = ''; Limits = @($limits); Available = $null; MemTotal = [double]0
            Engines = $null; EnginePrev = $null; GpuMemory = $null; GpuSensors = $false; ZoneSeen = New-Object System.Collections.Generic.List[double] }
    }
    $slowed = Get-QpLiveReading -Monitor (New-LimitMonitor 100, 80)     # two zones: the lower one counts
    $full = Get-QpLiveReading -Monitor (New-LimitMonitor 100)
    $unknown = Get-QpLiveReading -Monitor (New-LimitMonitor 0)          # 0 means "not reported", not "stopped"
    $none = Get-QpLiveReading -Monitor (New-LimitMonitor)
    $slowed.CpuThrottled -and $slowed.CpuLimitPct -eq 80 -and
    -not $full.CpuThrottled -and -not $unknown.CpuThrottled -and $null -eq $unknown.CpuLimitPct -and -not $none.CpuThrottled
}
Test-Case 'the graphics-driver code only asks questions' {
    # Only enumerate, query and close. Nothing that sets, escapes to the driver, or changes anything.
    $src = Get-Content (Join-Path $root 'src\Quietpane.psm1') -Raw
    $calls = @([regex]::Matches($src, 'DllImport\("gdi32\.dll"\)\]\s*static extern int (\w+)') | ForEach-Object { $_.Groups[1].Value })
    $calls.Count -eq 3 -and @($calls | Where-Object { $_ -notin 'D3DKMTEnumAdapters2', 'D3DKMTQueryAdapterInfo', 'D3DKMTCloseAdapter' }).Count -eq 0
}
Test-Case 'live readings write nothing to disk' {
    # Every file with its date, plus every folder by name. Folder dates are left out on purpose: Windows
    # updates a folder's date a moment late after something inside it is removed (an earlier test does that).
    $data = Join-Path $env:ProgramData 'Quietpane'
    $snap = {
        (@(Get-ChildItem $data -Recurse -Force -File -ErrorAction SilentlyContinue | ForEach-Object { "$($_.FullName)|$($_.LastWriteTimeUtc.Ticks)" }) +
         @(Get-ChildItem $data -Recurse -Force -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })) -join "`n"
    }
    $before = & $snap
    $m = New-QpLiveMonitor
    1..2 | ForEach-Object { Get-QpLiveReading -Monitor $m | Out-Null }
    $after = & $snap
    $before -eq $after
}

Section 'Watching a whole session'
# Made-up readings, so a hot, throttled, sleeping PC can be checked without owning one.
$sessionStart = [datetime]'2026-09-28 09:00:00'
function New-TestReading {
    param([double]$Minutes, [double]$Cpu = 10, $TempC = 50, $GpuTempC = $null, [bool]$Throttled = $false,
          $SpeedPct = 100, $CommitPct = 40, [double]$MemUsed = 3GB, [string]$Top = 'Windows Explorer', $BatteryPct = $null, $Watts = $null)
    [pscustomobject]@{
        At = $sessionStart.AddMinutes($Minutes); CpuUsage = $Cpu; CpuTempC = $TempC; CpuThrottled = $Throttled
        SpeedPct = $SpeedPct; SpeedMhz = 2400; CommitPct = $CommitPct; CommitUsed = [double]24GB; CommitLimit = [double]27GB
        MemUsed = $MemUsed; MemTotal = [double]16GB; DiskBusyPct = 26; DiskQueue = 0.8
        CpuTop = @([pscustomobject]@{ Name = $Top; Percent = $Cpu })
        Gpus = @(if ($null -ne $GpuTempC) { [pscustomobject]@{ Name = 'Test card'; Usage = 55; TempC = $GpuTempC } })
        Battery = $(if ($null -ne $BatteryPct) { [pscustomobject]@{ Percent = $BatteryPct; PluggedIn = $false; Charging = $false; Watts = $Watts; Direction = 'draining'; MinutesLeft = 70 } })
    }
}
function New-TestSession {
    # A minute of quiet, a minute very hot and held back, then the PC sleeps for half an hour.
    $w = New-QpSessionWatch -IntervalSeconds 10 -Now $sessionStart
    $w = Add-QpSessionSample $w (New-TestReading -Minutes 0 -Cpu 12 -TempC 55 -GpuTempC 45 -BatteryPct 100 -Watts 12.0)
    foreach ($i in 1..6) {
        $w = Add-QpSessionSample $w (New-TestReading -Minutes (0.1667 * $i) -Cpu 96 -TempC 97 -GpuTempC 80 -Throttled $true -SpeedPct 61 -CommitPct 91 -MemUsed 14GB -Top 'A game' -BatteryPct (100 - $i) -Watts 42.5)
    }
    $w = Add-QpSessionSample $w (New-TestReading -Minutes 31 -Cpu 20 -TempC 60 -GpuTempC 50 -Top 'A game' -BatteryPct 80 -Watts 11.0)
    return $w
}

Test-Case 'a session keeps the peaks, because an average hides the moment it choked' {
    $w = New-TestSession
    $w.PeakCpu -eq 96 -and $w.PeakCpuTempC -eq 97 -and $w.PeakGpuTempC -eq 80 -and $w.PeakCommitPct -eq 91 -and
    $w.PeakMemUsed -eq 14GB -and $w.PeakWatts -eq 42.5 -and $w.Samples -eq 8
}
Test-Case 'minutes hot and minutes held back are counted, and spells are counted separately' {
    $w = New-TestSession
    # Six stretches of ten seconds at 97C, which is past "very hot", and all of them held back at once.
    [math]::Round($w.VeryHotSeconds) -eq 60 -and [math]::Round($w.HotSeconds) -eq 60 -and
    [math]::Round($w.HeldBackSeconds) -eq 60 -and $w.HeldBackSpells -eq 1 -and $w.SlowestWhenBusyPct -eq 61
}
Test-Case 'a stretch with no readings is a gap, never drawn through' {
    $w = New-TestSession
    $s = Get-QpSessionSummary -Watch (Stop-QpSessionWatch $w -Now $sessionStart.AddMinutes(31)) -Now $sessionStart.AddMinutes(31)
    # The half-hour asleep is not counted as time spent hot, and the summary owns up to it.
    $w.Gaps -eq 1 -and [math]::Round($w.GapSeconds) -eq 1790 -and [math]::Round($w.WatchedSeconds) -eq 70 -and
    @($s.Lines | Where-Object { $_ -match 'One stretch went unwatched, 30 minutes in all' }).Count -eq 1
}
Test-Case 'a processor idling at a low clock is never called throttling' {
    # Quiet PC, clock down to a third to save power, no cooling brake on: that is being sensible.
    $w = New-QpSessionWatch -IntervalSeconds 10 -Now $sessionStart
    foreach ($i in 0..3) { $w = Add-QpSessionSample $w (New-TestReading -Minutes (0.1667 * $i) -Cpu 4 -SpeedPct 32) }
    $s = Get-QpSessionSummary -Watch $w -Now $sessionStart.AddMinutes(1)
    $w.HeldBackSeconds -eq 0 -and $w.HeldBackSpells -eq 0 -and $null -eq $w.SlowestWhenBusyPct -and
    @($s.Lines | Where-Object { $_ -match 'held back|of its speed' }).Count -eq 0
}
Test-Case 'the summary says nothing this PC did not report' {
    # A desktop with no temperature sensor and no battery: no heat line, no battery line, no zeroes.
    $w = New-QpSessionWatch -IntervalSeconds 10 -Now $sessionStart
    foreach ($i in 0..3) { $w = Add-QpSessionSample $w (New-TestReading -Minutes (0.1667 * $i) -Cpu 30 -TempC $null -CommitPct $null) }
    $s = Get-QpSessionSummary -Watch $w -Now $sessionStart.AddMinutes(1)
    $all = $s.Lines -join ' | '
    $null -eq $w.PeakCpuTempC -and $all -notmatch 'hottest|C\.|battery|promised' -and $all -match 'The processor peaked at 30%'
}
Test-Case 'the headline is the worst thing that happened, or plainly nothing' {
    $hot = Get-QpSessionSummary -Watch (New-TestSession) -Now $sessionStart.AddMinutes(31)
    $w = New-QpSessionWatch -IntervalSeconds 10 -Now $sessionStart
    foreach ($i in 0..3) { $w = Add-QpSessionSample $w (New-TestReading -Minutes (0.1667 * $i)) }
    $calm = Get-QpSessionSummary -Watch $w -Now $sessionStart.AddMinutes(1)
    $hot.Headline -match 'very hot' -and $calm.Headline -match 'stayed comfortable'
}
Test-Case 'a length of time is put in plain words' {
    (Format-QpSpan 0.5) -eq 'no time at all' -and (Format-QpSpan 45) -eq '45 seconds' -and (Format-QpSpan 60) -eq '60 seconds' -and
    (Format-QpSpan 120) -eq '2 minutes' -and (Format-QpSpan 3600) -eq '1 hour' -and (Format-QpSpan 12000) -eq '3 h 20 min'
}
Test-Case 'an alert is raised when it is worth interrupting for, and never twice' {
    $w = New-QpSessionWatch -IntervalSeconds 10 -Now $sessionStart
    # Six minutes very hot and held back, which is past both marks.
    foreach ($i in 0..36) { $w = Add-QpSessionSample $w (New-TestReading -Minutes (0.1667 * $i) -Cpu 96 -TempC 97 -Throttled $true -SpeedPct 61 -CommitPct 91 -Top 'A game') }
    $first = @(Update-QpSessionAlerts -Watch $w -Reading (New-TestReading -Minutes 6 -CommitPct 91) -FreePct 4 -Now $sessionStart.AddMinutes(6))
    $again = @(Update-QpSessionAlerts -Watch $w -Reading (New-TestReading -Minutes 6 -CommitPct 91) -FreePct 4 -Now $sessionStart.AddMinutes(7))
    (@($first | ForEach-Object { $_.Id }) -join ',') -eq 'veryhot,heldback,memory,drive' -and $again.Count -eq 0 -and
    @($w.Alerts).Count -eq 4 -and @($first | Where-Object { $_.Id -eq 'veryhot' })[0].Level -eq 'high'
}
Test-Case 'nothing is raised below the mark, or about a number this PC does not report' {
    $w = New-QpSessionWatch -IntervalSeconds 10 -Now $sessionStart
    # A minute hot - real, but not worth interrupting for - and a PC that reports no commit and no battery.
    foreach ($i in 0..6) { $w = Add-QpSessionSample $w (New-TestReading -Minutes (0.1667 * $i) -Cpu 96 -TempC 97 -Throttled $true -CommitPct $null) }
    $raised = @(Update-QpSessionAlerts -Watch $w -Reading (New-TestReading -Minutes 1 -CommitPct $null) -Now $sessionStart.AddMinutes(1))
    $raised.Count -eq 0
}
Test-Case 'a battery running out is worth saying, once it really is running out' {
    $w = New-QpSessionWatch -IntervalSeconds 10 -Now $sessionStart
    $plenty = New-TestReading -Minutes 1 -BatteryPct 60 -Watts 20
    $plenty.Battery.MinutesLeft = 90
    $nearly = New-TestReading -Minutes 2 -BatteryPct 8 -Watts 20
    $nearly.Battery.MinutesLeft = 12
    $none = @(Update-QpSessionAlerts -Watch $w -Reading $plenty -Now $sessionStart)
    $low = @(Update-QpSessionAlerts -Watch $w -Reading $nearly -Now $sessionStart.AddMinutes(1))
    $none.Count -eq 0 -and $low.Count -eq 1 -and $low[0].Id -eq 'battery' -and $low[0].Text -match '12 minutes left'
}
Test-Case 'the session draws as a timeline: worst wins a column, and a gap stays a gap' {
    $w = New-TestSession
    $bands = @(Get-QpSessionBands -Watch (Stop-QpSessionWatch $w -Now $sessionStart.AddMinutes(31)) -Columns 60 -Now $sessionStart.AddMinutes(31))
    $shape = ($bands | ForEach-Object { switch ($_.Heat) { 'quiet' { '.' } 'hot' { 'h' } 'veryhot' { 'V' } 'gap' { ' ' } } }) -join ''
    # A minute quiet, a minute very hot and held back, then half an hour asleep, then a moment back.
    $bands.Count -eq 60 -and $shape -match '^V+ +\.$' -and
    @($bands | Where-Object { $_.Heat -eq 'gap' }).Count -gt 50 -and
    # Held back rides its own row, so it never hides how hot it was.
    @($bands | Where-Object { $_.Held }).Count -ge 1 -and
    @($bands | Where-Object { $_.Held -and $_.Heat -eq 'veryhot' }).Count -ge 1
}
Test-Case 'a column takes the worst of what it covers, never the average' {
    # One very hot moment inside a run of comfortable ones must still show as very hot.
    $w = New-QpSessionWatch -IntervalSeconds 10 -Now $sessionStart
    foreach ($i in 0..9) { $w = Add-QpSessionSample $w (New-TestReading -Minutes (0.1667 * $i) -TempC 50) }
    $w = Add-QpSessionSample $w (New-TestReading -Minutes (0.1667 * 10) -TempC 98)
    foreach ($i in 11..20) { $w = Add-QpSessionSample $w (New-TestReading -Minutes (0.1667 * $i) -TempC 50) }
    $bands = @(Get-QpSessionBands -Watch $w -Columns 4 -Now $sessionStart.AddMinutes(3.5))
    @($bands | Where-Object { $_.Heat -eq 'veryhot' }).Count -ge 1
}
Test-Case 'a session can be written up as a page, with nothing in it that was not measured' {
    $w = New-TestSession
    $null = Update-QpSessionAlerts -Watch $w -Reading (New-TestReading -Minutes 6 -CommitPct 95) -Now $sessionStart.AddMinutes(6)
    $html = New-QpSessionReportHtml -Watch (Stop-QpSessionWatch $w -Now $sessionStart.AddMinutes(31)) -Now $sessionStart.AddMinutes(31)
    # The same promise the scan report makes: no scripts, and nothing fetched from the internet.
    [regex]::Matches($html, '<script').Count -eq 0 -and [regex]::Matches($html, 'src="http').Count -eq 0 -and
    $html -match '97&#176;C' -and $html -match 'hottest the processor got' -and
    $html -match 'What it spoke up about' -and $html -match 'Windows has promised 95%' -and
    $html -match 'Where the time went' -and $html -match 'asleep, or Quietpane was busy' -and
    $html -match '<title>Quietpane session</title>'
}
Test-Case 'a report leaves out what the PC never reported' {
    # A desktop: no temperature, no battery, no promised-memory figure.
    $w = New-QpSessionWatch -IntervalSeconds 10 -Now $sessionStart
    foreach ($i in 0..3) { $w = Add-QpSessionSample $w (New-TestReading -Minutes (0.1667 * $i) -Cpu 30 -TempC $null -CommitPct $null) }
    $html = New-QpSessionReportHtml -Watch $w -Now $sessionStart.AddMinutes(1)
    $html -notmatch 'hottest the processor got' -and $html -notmatch 'most memory promised' -and
    $html -notmatch 'Battery' -and $html -match 'busiest the processor got' -and $html.Length -gt 1500
}
Test-Case 'saving a report writes one file and nothing else' {
    $dir = Join-Path $env:TEMP ('qp-report-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void][IO.Directory]::CreateDirectory($dir)
    try {
        $out = Join-Path $dir 'session.html'
        $path = Save-QpSessionReport -Watch (New-TestSession) -OutFile $out
        $files = @(Get-ChildItem $dir -Recurse -File)
        $path -eq $out -and $files.Count -eq 1 -and (Get-Item $out).Length -gt 1500
    } finally { [IO.Directory]::Delete($dir, $true) }
}
Test-Case 'Windows'' own steadiness record is read, and an update that installed is not a problem' {
    $r = Get-QpReliability -Days 30
    # Whatever this PC says, the shape has to hold and the counts have to be countable.
    $shape = @('Score', 'Word', 'Days', 'Crashes', 'Hangs', 'BlueScreens', 'SuddenStops', 'Programs', 'Uptime', 'Available' |
        Where-Object { -not $r.PSObject.Properties.Name.Contains($_) }).Count -eq 0
    $sane = $r.Crashes -ge 0 -and $r.Hangs -ge 0 -and $r.SuddenStops -ge 0 -and $r.Days -eq 30 -and
        ($null -eq $r.Score -or ($r.Score -ge 0 -and $r.Score -le 10)) -and
        $r.Word -in 'steady', 'mostly steady', 'bumpy', 'not scored'
    # Every program named has to have failed at least once, and nothing here counts Windows Update.
    $named = @($r.Programs | Where-Object { $_.Count -lt 1 -or $_.Name -match 'WindowsUpdateClient|MsiInstaller' }).Count -eq 0
    $shape -and $sane -and $named
}
Test-Case 'the four new vitals are read, and a PC that reports none of them still gives a whole reading' {
    $m = New-QpLiveMonitor
    Start-Sleep -Milliseconds 1100
    $full = Get-QpLiveReading -Monitor $m
    # Then the same monitor with every new reader taken away, as on a PC that has no such counters.
    foreach ($f in 'Commit', 'CommitLimit', 'Speed', 'SpeedMhz', 'DiskIdle', 'DiskQueue', 'BatteryRate') { $m.$f = $null }
    $bare = Get-QpLiveReading -Monitor $m
    $gotSome = @($full.CommitPct, $full.SpeedPct, $full.DiskBusyPct | Where-Object { $null -ne $_ }).Count -ge 1
    $gotSome -and $null -eq $bare.CommitPct -and $null -eq $bare.SpeedPct -and $null -eq $bare.DiskBusyPct -and
    $null -ne $bare.CpuUsage -and $bare.PSObject.Properties.Name -contains 'CommitUsed'
}
Test-Case 'counters are asked for in English, whatever language the PC is set to' {
    # .NET looks a counter's name up in the table for the language it is running under, and only the
    # English table is on every Windows - so the lookup has to be made under the invariant culture.
    $src = Get-Content (Join-Path $root 'src\Quietpane.psm1') -Raw
    $wired = ([regex]::Matches($src, 'New-QpCounter(Group)?\s')).Count
    # Exactly two counters are made the raw way: the two lines inside the helpers that do the forcing.
    $raw = ([regex]::Matches($src, 'New-Object Diagnostics\.PerformanceCounter')).Count
    $src -match 'InvariantCulture' -and $wired -ge 10 -and $raw -eq 2
}

Section 'What''s using it'
$liveM = New-QpLiveMonitor
Start-Sleep -Milliseconds 1200
$liveR = Get-QpLiveReading -Monitor $liveM
Test-Case 'the busiest programs come with a name and a believable share' {
    @($liveR.CpuTop | Where-Object { -not $_.Name -or $_.Pct -lt 1 -or $_.Pct -gt 100 }).Count -eq 0 -and @($liveR.CpuTop).Count -le 3
}
Test-Case 'every graphics card says what is using it (possibly nothing)' {
    @($liveR.Gpus | Where-Object { -not $_.PSObject.Properties['Top'] }).Count -eq 0 -and
    @($liveR.Gpus | ForEach-Object { @($_.Top) } | Where-Object { $_ -and ($_.Pct -lt 1 -or $_.Pct -gt 100) }).Count -eq 0
}
Test-Case 'Quietpane names itself honestly' { (Get-QpProgramName -Monitor $liveM -Instance 'powershell' -ProcessId $PID) -eq 'Quietpane (this app)' }
Test-Case 'Windows'' own processes get plain names' {
    (Get-QpProgramName -Monitor $liveM -Instance 'dwm' -ProcessId 0) -eq 'Windows desktop' -and
    (Get-QpProgramName -Monitor $liveM -Instance 'MsMpEng' -ProcessId 0) -eq 'Microsoft Defender'
}
Test-Case 'the battery reading is a real percentage, or absent on a desktop' {
    $b = $liveR.Battery
    ($null -eq $b) -or ($b.Percent -ge 0 -and $b.Percent -le 100 -and $b.PluggedIn -is [bool])
}

Section 'Battery and drive health'
Test-Case 'battery health is a share of what it held new, or nothing' {
    $h = Get-QpBatteryHealth
    ($null -eq $h) -or ($h.Percent -ge 1 -and $h.Percent -le 100 -and $h.DesignWh -gt 0 -and $h.FullWh -gt 0)
}
Test-Case 'the battery report file is always deleted afterwards' {
    Get-QpBatteryHealth | Out-Null
    @(Get-ChildItem $env:TEMP -Filter 'Quietpane-battery-*.xml' -ErrorAction SilentlyContinue).Count -eq 0
}
Test-Case 'drive health uses Windows'' own verdict, and never throws' {
    $d = Get-QpDriveHealth
    ($null -eq $d) -or ($d.Health -in 'Healthy', 'Warning', 'Unhealthy', 'Unknown' -and $d.Media)
}
Test-Case 'drives have their own, cooler idea of hot' {
    (Get-QpHeatWord 55 -Kind Drive).Word -eq 'warm' -and (Get-QpHeatWord 72 -Kind Drive).Word -eq 'very hot' -and (Get-QpHeatWord 72).Word -eq 'warm'
}
Test-Case 'the drive is asked about itself, and answers something possible' {
    # Windows' own storage figures are invented on a good many PCs - a temperature stuck at exactly 60
    # whatever is happening, no wear and no hours. Where the drive can be asked directly it is, and what
    # it says has to be within the bounds of physics. A PC that will not allow the question says nothing.
    $d = Get-QpDriveHealth
    if (-not $d -or -not $d.FromDrive) { return $true }
    ($null -eq $d.TempC -or ($d.TempC -gt 0 -and $d.TempC -lt 120)) -and
    ($null -eq $d.WearPct -or ($d.WearPct -ge 0 -and $d.WearPct -le 100)) -and
    ($null -eq $d.PowerOnHours -or $d.PowerOnHours -gt 0) -and
    ($null -eq $d.WarnAtC -or ($d.WarnAtC -gt 30 -and $d.WarnAtC -lt 150))
}
Test-Case 'asking the drive twice does not change it' {
    # Read-only, and opened with no access rights at all: two reads a moment apart must agree on the
    # things that cannot move, whatever the temperature has done in between.
    $a = Get-QpDriveHealth; $b = Get-QpDriveHealth
    ($null -eq $a -and $null -eq $b) -or ($a.Name -eq $b.Name -and $a.WearPct -eq $b.WearPct -and $a.Health -eq $b.Health)
}

Section 'One sentence for the whole tab'
function New-VerdictReading {
    param([double]$Cpu = 10, $TempC = 45, [bool]$Throttled = $false, $CommitPct = 40, $MemUsed = 4GB,
        $DiskBusy = 5, $GpuTempC = $null, $GpuUsage = 10)
    [pscustomobject]@{
        CpuUsage = $Cpu; CpuTempC = $TempC; CpuTempStuck = $false; CpuThrottled = $Throttled; CpuLimitPct = $(if ($Throttled) { 61 } else { 100 })
        MemUsed = [double]$MemUsed; MemTotal = [double]16GB; CommitPct = $CommitPct; DiskBusyPct = $DiskBusy
        Gpus = @([pscustomobject]@{ Name = 'Test card'; Usage = $GpuUsage; TempC = $GpuTempC; TempMaxC = 95 })
    }
}
Test-Case 'a PC with nothing wrong is told so, not left silent' {
    $v = Get-QpLiveVerdict -Reading (New-VerdictReading)
    $v.Level -eq 'ok' -and $v.Text -match 'calm' -and $v.Why
}
Test-Case 'being held back to cool off outranks everything else' {
    # Hot, nearly out of memory and held back all at once: the one that spoils the afternoon wins.
    $v = Get-QpLiveVerdict -Reading (New-VerdictReading -Cpu 99 -TempC 97 -Throttled $true -CommitPct 95)
    $v.Level -eq 'high' -and $v.Text -match 'held back to cool off'
}
Test-Case 'running out of memory beats merely being busy' {
    $v = Get-QpLiveVerdict -Reading (New-VerdictReading -Cpu 95 -CommitPct 94)
    $v.Level -eq 'high' -and $v.Text -match 'run out of memory'
}
Test-Case 'promised memory counts even when the chips look half empty' {
    # The case the old tab could not tell you about: memory at 25%, and the PC crawling anyway.
    $v = Get-QpLiveVerdict -Reading (New-VerdictReading -MemUsed 4GB -CommitPct 93)
    $v.Level -eq 'high' -and $v.Text -match 'run out of memory'
}
Test-Case 'a drive flat out while the processor idles is named as such' {
    $v = Get-QpLiveVerdict -Reading (New-VerdictReading -Cpu 4 -GpuUsage 2 -DiskBusy 97)
    $v.Level -eq 'warn' -and $v.Text -match 'waiting on its drive'
}
Test-Case 'a busy PC is told it is busy, and that nothing is wrong' {
    $v = Get-QpLiveVerdict -Reading (New-VerdictReading -Cpu 88)
    $v.Level -eq 'warn' -and $v.Text -match 'working hard' -and $v.Why -match 'Nothing is wrong'
}
Test-Case 'the graphics card being very hot counts as much as the processor' {
    $v = Get-QpLiveVerdict -Reading (New-VerdictReading -Cpu 40 -TempC 50 -GpuTempC 92)
    $v.Level -eq 'high' -and $v.Text -match 'very hot'
}
Test-Case 'a sensor that has stopped moving is not treated as a reading' {
    $r = New-VerdictReading -TempC 97
    $r.CpuTempStuck = $true
    (Get-QpLiveVerdict -Reading $r).Text -notmatch 'very hot'
}
Test-Case 'half a PC in use is not called calm' {
    # If "calm" covered everything under four-fifths it would stop meaning anything at all.
    $mid = Get-QpLiveVerdict -Reading (New-VerdictReading -Cpu 65)
    $idle = Get-QpLiveVerdict -Reading (New-VerdictReading -Cpu 8)
    $mid.Level -eq 'ok' -and $mid.Text -match 'busy, and coping' -and $idle.Text -match 'calm'
}
Test-Case 'a PC that shares nothing gets no invented verdict' {
    $bare = [pscustomobject]@{ CpuUsage = $null; CpuTempC = $null; CpuThrottled = $false; MemUsed = $null; MemTotal = 0
        CommitPct = $null; DiskBusyPct = $null; Gpus = @() }
    $v = Get-QpLiveVerdict -Reading $bare
    $v.Level -eq 'none' -and $v.Text -notmatch '\d'
}
Test-Case 'no reading at all still comes back with something to show' {
    $v = Get-QpLiveVerdict -Reading $null
    $v -and $v.Text -and $v.Level -eq 'none'
}

Section 'What came back since last time'
$notePath = Join-Path $env:TEMP ('qp-note-' + [guid]::NewGuid().ToString('N') + '.json')
$pIds = @((Get-QpCatalog privacy).Items | Select-Object -First 4 | ForEach-Object { $_.Id })
function New-FakeState([string[]]$Applied = @(), [string[]]$Apps = @(), $Startup = @()) {
    $priv = @{}
    foreach ($i in (Get-QpCatalog privacy).Items) { $priv[$i.Id] = $(if ($Applied -contains $i.Id) { 'Applied' } else { 'NotApplied' }) }
    @{ Privacy = $priv; Vendors = @(); Startup = @($Startup)
       Apps = @($Apps | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Name = $_; Title = "App $_" } }) }
}
function New-FakeStartup([string]$Id, [bool]$On) { [pscustomobject]@{ Id = $Id; Name = "Item $Id"; On = $On; Keep = $false } }
Test-Case 'the first look just takes a note and reports nothing' {
    Remove-Item -LiteralPath $notePath -Force -ErrorAction SilentlyContinue
    $d = Update-QpQuietNote -State (New-FakeState $pIds[0..2]) -Path $notePath
    $d.Count -eq 0 -and (Test-Path -LiteralPath $notePath)
}
Test-Case 'a setting that switched itself back on is reported, by name' {
    Update-QpQuietNote -State (New-FakeState $pIds[0..2]) -Path $notePath -Accept | Out-Null
    $d = Update-QpQuietNote -State (New-FakeState $pIds[1..2]) -Path $notePath
    $d.Count -eq 1 -and $d.Privacy[0].Id -eq $pIds[0] -and $d.Privacy[0].Title
}
Test-Case 'it keeps being reported until it is dealt with' {
    (Update-QpQuietNote -State (New-FakeState $pIds[1..2]) -Path $notePath).Count -eq 1
}
Test-Case 'things that got quieter are never reported, only noted' {
    $d = Update-QpQuietNote -State (New-FakeState $pIds[0..3]) -Path $notePath
    $again = Update-QpQuietNote -State (New-FakeState $pIds[0..2]) -Path $notePath   # the newly quiet one counts from now on
    $d.Count -eq 0 -and $again.Count -eq 1 -and $again.Privacy[0].Id -eq $pIds[3]
}
Test-Case '"That was me" clears it, and it stays cleared' {
    Update-QpQuietNote -State (New-FakeState $pIds[0..2]) -Path $notePath -Accept | Out-Null
    (Update-QpQuietNote -State (New-FakeState $pIds[0..2]) -Path $notePath).Count -eq 0
}
Test-Case 'an app that came back is reported; one that went is not' {
    Update-QpQuietNote -State (New-FakeState -Apps 'Kept') -Path $notePath -Accept | Out-Null
    $back = Update-QpQuietNote -State (New-FakeState -Apps 'Kept', 'Returned') -Path $notePath
    Update-QpQuietNote -State (New-FakeState -Apps 'Kept') -Path $notePath -Accept | Out-Null
    $gone = Update-QpQuietNote -State (New-FakeState -Apps @()) -Path $notePath
    $back.Count -eq 1 -and $back.Apps[0].Id -eq 'Returned' -and $back.Apps[0].Title -eq 'App Returned' -and $gone.Count -eq 0
}
Test-Case 'a setting this PC no longer has, or Quietpane no longer lists, is never reported as back' {
    Update-QpQuietNote -State (New-FakeState $pIds[0..2]) -Path $notePath -Accept | Out-Null
    # One setting is no longer on this PC at all, and the note also names one a newer catalog dropped.
    $note = Get-Content -LiteralPath $notePath -Raw | ConvertFrom-Json
    $note.Privacy = @(@($note.Privacy) + 'retired.setting')
    $note | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $notePath -Encoding UTF8
    $s = New-FakeState $pIds[1..2]; $s.Privacy[$pIds[0]] = 'NotApplicable'
    (Update-QpQuietNote -State $s -Path $notePath).Count -eq 0
}
Test-Case 'a brand extra is reported when it is back on, not when its app was uninstalled' {
    function New-VendorState([string]$Status) {
        $s = New-FakeState $pIds[0..2]
        if ($Status) { $s.Vendors = @([pscustomobject]@{ Name = 'Brand'; Items = @([pscustomobject]@{ Id = 'brand.helper'; Title = 'Brand helper'; Status = $Status }) }) }
        $s
    }
    Update-QpQuietNote -State (New-VendorState 'Applied') -Path $notePath -Accept | Out-Null
    $uninstalled = Update-QpQuietNote -State (New-VendorState '') -Path $notePath
    $backOn = Update-QpQuietNote -State (New-VendorState 'NotApplied') -Path $notePath
    $uninstalled.Count -eq 0 -and $backOn.Count -eq 1 -and $backOn.Vendors[0].Title -eq 'Brand helper'
}
Test-Case 'a startup item back on is reported; an uninstalled one is not' {
    Update-QpQuietNote -State (New-FakeState -Startup @((New-FakeStartup 's1' $false), (New-FakeStartup 's2' $false))) -Path $notePath -Accept | Out-Null
    $d = Update-QpQuietNote -State (New-FakeState -Startup @((New-FakeStartup 's1' $true))) -Path $notePath   # s1 back on, s2 gone
    $d.Count -eq 1 -and $d.Startup[0].Id -eq 's1' -and $d.Startup[0].Title -eq 'Item s1'
}
Test-Case 'a Windows update in between is named as the likely reason' {
    Update-QpQuietNote -State (New-FakeState $pIds[0..2]) -Path $notePath -Accept | Out-Null
    $note = Get-Content -LiteralPath $notePath -Raw | ConvertFrom-Json
    $note.Windows = [pscustomobject]@{ Display = '21H2'; Build = '1.1' }
    $note | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $notePath -Encoding UTF8
    $d = Update-QpQuietNote -State (New-FakeState $pIds[1..2]) -Path $notePath
    $d.WindowsUpdated -and $d.WindowsChange -match '^from 21H2 to '
}
Test-Case 'switching off what came back, when nothing did, changes nothing and saves nothing' {
    $since = (Get-Date).AddSeconds(-1)
    Invoke-QpPutBack | Out-Null
    @(Get-ChildItem (Join-Path $env:ProgramData 'Quietpane\restore') -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like '*-came-back' -and $_.CreationTime -ge $since }).Count -eq 0
}
Remove-Item -LiteralPath $notePath -Force -ErrorAction SilentlyContinue

Section 'Reading the PC quickly, without cutting corners'
Test-Case 'the shared lookups give exactly the same answers as asking one by one' {
    # Scheduled-task checks are what the shared lookup speeds up, so compare a handful both ways.
    # Picks tasks that really exist on this PC, so the comparison means something.
    $mod = Get-Module Quietpane
    $present = & $mod { Get-QpTasksByPath }
    $taskActions = @((Get-QpCatalog privacy).Items | ForEach-Object { $_.Actions } | Where-Object { $_.Type -eq 'Task' -and $present.ContainsKey($_.Path) } | Select-Object -First 4)
    if (-not $taskActions.Count) { return 'skip' }
    $oneByOne = @($taskActions | ForEach-Object { "$(& $mod { param($a) Test-QpActionApplied $a } $_)" }) -join ','
    $shared = (& $mod { param($list) Start-QpStateCache; try { @($list | ForEach-Object { "$(Test-QpActionApplied $_)" }) } finally { Stop-QpStateCache } } $taskActions) -join ','
    $oneByOne -eq $shared
}
Test-Case 'the whole state comes back in one pass, and the shared lookups are let go afterwards' {
    $s = Get-QpState
    $keysOk = @('Privacy', 'Vendors', 'Apps', 'Startup', 'Devices', 'Addons', 'Cleanup', 'Restore', 'Problems' | Where-Object { -not $s.ContainsKey($_) }).Count -eq 0
    $keysOk -and $null -eq (& (Get-Module Quietpane) { $script:StateCache })
}
Test-Case 'asking Task Scheduler directly lists exactly the tasks Get-ScheduledTask lists' {
    # Names and whether each is switched off; "running" or "ready" can change between the two reads.
    $fast = @(foreach ($kv in (Get-QpTasksByPath).GetEnumerator()) { foreach ($t in $kv.Value) { '{0}{1}|{2}' -f $t.TaskPath, $t.TaskName, ($t.State -eq 'Disabled') } }) | Sort-Object
    $slow = @(Get-ScheduledTask | ForEach-Object { '{0}{1}|{2}' -f $_.TaskPath, $_.TaskName, ("$($_.State)" -eq 'Disabled') }) | Sort-Object
    $fast.Count -gt 0 -and (($fast -join "`n") -eq ($slow -join "`n"))
}
Test-Case 'every task line in the catalogs finds the same tasks all three ways' {
    $mod = Get-Module Quietpane
    $lines = @((Get-QpCatalog privacy).Items | ForEach-Object { $_.Actions }) + @((Get-QpCatalog vendors).Vendors | ForEach-Object { $_.Items } | ForEach-Object { $_.Actions })
    $differ = @(foreach ($a in @($lines | Where-Object { $_ -and $_.Type -eq 'Task' })) {
        $slow = (@(Get-ScheduledTask -TaskPath $a.Path -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like $a.Name } | ForEach-Object { "$($_.TaskPath)$($_.TaskName)" }) | Sort-Object) -join ';'
        $fast = (@(Get-QpTasksMatching -Path $a.Path -Name $a.Name | ForEach-Object { "$($_.TaskPath)$($_.TaskName)" }) | Sort-Object) -join ';'
        $shared = (@(& $mod { param($x) Start-QpStateCache; try { Get-QpTasksMatching -Path $x.Path -Name $x.Name } finally { Stop-QpStateCache } } $a | ForEach-Object { "$($_.TaskPath)$($_.TaskName)" }) | Sort-Object) -join ';'
        if ($slow -ne $fast -or $slow -ne $shared) { "$($a.Path)$($a.Name)" }
    })
    $differ.Count -eq 0
}
Test-Case 'a task folder ending in * covers every folder under it, as Get-ScheduledTask reads it' {
    # This used to find nothing while the window read the PC, so the item always said "not on this PC".
    $found = @(& (Get-Module Quietpane) {
        Start-QpStateCache
        try {
            $list = New-Object System.Collections.ArrayList
            [void]$list.Add([pscustomobject]@{ TaskPath = '\SoftLanding\S-1-5-21-1\'; TaskName = 'SoftLandingCreativeManagementTask'; State = 'Ready' })
            $script:StateCache.Tasks = @{ '\SoftLanding\S-1-5-21-1\' = $list; '\Other\' = (New-Object System.Collections.ArrayList) }
            Get-QpTasksMatching -Path '\SoftLanding\*' -Name '*'
        } finally { Stop-QpStateCache }
    })
    $found.Count -eq 1 -and $found[0].TaskName -eq 'SoftLandingCreativeManagementTask'
}
Test-Case 'registry values are read exactly as stored, with their type, however the path is written' {
    $k = 'HKCU:\Software\QuietpaneTest-Reg'
    New-Item -Path $k -Force | Out-Null
    try {
        Set-ItemProperty -Path $k -Name 'D' -Value 7 -Type DWord
        Set-ItemProperty -Path $k -Name 'S' -Value '1' -Type String
        Set-ItemProperty -Path $k -Name 'E' -Value '%TEMP%\x' -Type ExpandString
        Set-ItemProperty -Path $k -Name 'B' -Value ([byte[]](1, 2, 3)) -Type Binary
        Set-ItemProperty -Path $k -Name 'M' -Value @('a', 'b') -Type MultiString
        $dw = Get-QpRegValue -Path $k -Name 'D'; $txt = Get-QpRegValue -Path $k -Name 'S'; $exp = Get-QpRegValue -Path $k -Name 'E'
        $bin = Get-QpRegValue -Path $k -Name 'B'; $multi = Get-QpRegValue -Path $k -Name 'M'
        $long = Get-QpRegValue -Path 'Registry::HKEY_CURRENT_USER\Software\QuietpaneTest-Reg' -Name 'D'
        $dw.Exists -and $dw.Value -eq 7 -and $dw.Kind -eq 'DWord' -and $txt.Value -eq '1' -and $txt.Kind -eq 'String' -and
        $exp.Value -eq '%TEMP%\x' -and $exp.Kind -eq 'ExpandString' -and (@($bin.Value) -join ',') -eq '1,2,3' -and $bin.Kind -eq 'Binary' -and
        (@($multi.Value) -join ',') -eq 'a,b' -and $multi.Kind -eq 'MultiString' -and $long.Exists -and $long.Value -eq 7 -and
        -not (Get-QpRegValue -Path $k -Name 'Missing').Exists -and -not (Get-QpRegValue -Path "$k\NoSuchKey" -Name 'D').Exists
    } finally { Remove-Item -Path $k -Recurse -Force -ErrorAction SilentlyContinue }
}
Test-Case 'the installed-programs list is the same as reading it the slow way' {
    $new = @(& (Get-Module Quietpane) { $script:InstalledPrograms = $null; Get-QpInstalledPrograms } | ForEach-Object { '{0}|{1}|{2}|{3}' -f $_.Name, $_.Uninstall, $_.Quiet, $_.Key }) | Sort-Object
    $old = @(foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*') {
        Get-ItemProperty -Path $k -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -and -not $_.SystemComponent } |
            ForEach-Object { '{0}|{1}|{2}|{3}' -f $_.DisplayName, $(if ($_.QuietUninstallString) { $_.QuietUninstallString } else { $_.UninstallString }), [bool]$_.QuietUninstallString, $_.PSChildName }
    }) | Sort-Object
    $new.Count -gt 0 -and (($new -join "`n") -eq ($old -join "`n"))
}

Section 'Undo tells the truth'
Test-Case 'Undo puts a setting back with its old type, not just its old value' {
    # Text stays text: a setting that was "1" as text comes back as text, even though the change wrote a number.
    $k = 'HKCU:\Software\QuietpaneTest-UndoKind'
    New-Item -Path $k -Force | Out-Null
    Set-ItemProperty -Path $k -Name 'V' -Value '1' -Type String
    $rp = $null
    try {
        $rp = & (Get-Module Quietpane) { param($key)
            Start-QpSession 'undo-kind-test'
            $p = $script:Session.Path
            try { Invoke-QpRegAction -Action @{ Type = 'Reg'; Path = $key; Name = 'V'; Value = 0; Kind = 'DWord' } } finally { Stop-QpSession }
            $p
        } $k
        $changed = Get-QpRegValue -Path $k -Name 'V'
        $r = @(Invoke-QpUndo -Path $rp)[-1]
        $back = Get-QpRegValue -Path $k -Name 'V'
        $changed.Kind -eq 'DWord' -and $changed.Value -eq 0 -and $back.Kind -eq 'String' -and $back.Value -eq '1' -and
        $r.Failed -eq 0 -and (Test-Path (Join-Path $rp 'undone.txt'))
    } finally {
        Remove-Item -Path $k -Recurse -Force -ErrorAction SilentlyContinue
        if ($rp -and (Test-Path $rp)) { Remove-Item -LiteralPath $rp -Recurse -Force }   # the test's own restore point
    }
}
Test-Case 'an Undo that cannot put everything back says so, and stays in the list to try again' {
    $rp = Join-Path $env:ProgramData ('Quietpane\restore\{0}-undo-fail-test' -f (Get-QpStamp))
    New-Item -ItemType Directory -Force -Path $rp | Out-Null
    try {
        @{ Name = 'undo-fail-test'; Started = (Get-Date).ToString('s'); Entries = @(@{ Type = 'Task'; Path = '\QuietpaneNoSuchFolder\'; Name = 'NoSuchTask' }) } |
            ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $rp 'state.json') -Encoding UTF8
        $r = @(Invoke-QpUndo -Path $rp)[-1]
        $r.Failed -eq 1 -and $r.Restored -eq 0 -and -not (Test-Path (Join-Path $rp 'undone.txt'))
    } finally { Remove-Item -LiteralPath $rp -Recurse -Force -ErrorAction SilentlyContinue }
}
Test-Case 'restore points are dated on the ordinary calendar, whatever the PC''s language' {
    # Thai Windows counts years from 543 BC, so its own date format would name a restore point "2569...".
    $was = [Threading.Thread]::CurrentThread.CurrentCulture
    try {
        [Threading.Thread]::CurrentThread.CurrentCulture = New-Object Globalization.CultureInfo 'th-TH'
        $when = New-Object DateTime 2026, 9, 22, 10, 30, 0
        $ours = Get-QpStamp 'yyyyMMdd-HHmmss' $when
        $local = $when.ToString('yyyyMMdd-HHmmss')
    } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $was }
    $ours -eq '20260922-103000' -and $local -ne $ours
}
Test-Case 'an uninstall command is split safely, and only Windows Installer''s install switch becomes remove' {
    $inno = Split-QpUninstallCommand '"C:\Program Files\Brand\unins000.exe" /SILENT'
    $msiI = Split-QpUninstallCommand 'MsiExec.exe /I{12345678-1234-1234-1234-123456789012}'
    $msiX = Split-QpUninstallCommand 'MsiExec.exe /X{12345678-1234-1234-1234-123456789012} /qn'
    $other = Split-QpUninstallCommand 'C:\Brand\uninstall.exe /INSTALLDIR=C:\Brand'
    $inno.Program -eq 'C:\Program Files\Brand\unins000.exe' -and $inno.Arguments -eq '/SILENT' -and
    $msiI.Program -eq 'MsiExec.exe' -and $msiI.Arguments -eq '/X{12345678-1234-1234-1234-123456789012} /passive /norestart' -and
    $msiX.Arguments -eq '/X{12345678-1234-1234-1234-123456789012} /qn' -and
    $other.Program -eq 'C:\Brand\uninstall.exe' -and $other.Arguments -eq '/INSTALLDIR=C:\Brand'
}
Test-Case 'catalogs are read once and remembered' {
    [object]::ReferenceEquals((Get-QpCatalog privacy), (Get-QpCatalog privacy))
}
Test-Case 'when nothing changes, no restore point is kept' {
    $since = (Get-Date).AddSeconds(-1)
    Invoke-QpRemoveApps -Names 'Quietpane.Test.NotAnApp' | Out-Null    # nothing by that name, so nothing changes
    @(Get-ChildItem (Join-Path $env:ProgramData 'Quietpane\restore') -Directory -ErrorAction SilentlyContinue | Where-Object { $_.CreationTime -ge $since }).Count -eq 0
}
Test-Case 'an empty restore point is never offered in Undo' {
    $fake = Join-Path $env:ProgramData 'Quietpane\restore\19990101-000000-quietpane-test'
    New-Item -ItemType Directory -Path $fake -Force | Out-Null
    '{ "Name": "test", "Entries": [] }' | Set-Content -LiteralPath (Join-Path $fake 'state.json') -Encoding UTF8
    $listed = @(Get-QpRestorePoints | Where-Object { $_.Name -eq '19990101-000000-quietpane-test' }).Count
    Remove-Item -LiteralPath $fake -Recurse -Force    # the test's own folder
    $listed -eq 0
}

Section 'Where your space went'
# In your own folder, not Temp: Temp lives inside AppData, which Quietpane deliberately refuses to move.
$spaceTest = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'QuietpaneSpaceTest'
function Set-TestFile([string]$Path, [int]$Bytes) { $fs = [IO.File]::Create($Path); $fs.SetLength($Bytes); $fs.Close() }
function Reset-SpaceTestArea {
    if (Test-Path $spaceTest) { Remove-Item -LiteralPath $spaceTest -Recurse -Force }
    foreach ($d in 'big', 'small', 'program', 'holder\program2') { New-Item -ItemType Directory -Path (Join-Path $spaceTest $d) -Force | Out-Null }
    Set-TestFile "$spaceTest\big\big.bin" 40000
    Set-TestFile "$spaceTest\small\tiny.bin" 100
    Set-TestFile "$spaceTest\program\app.exe" 2000        # an .exe with a .dll beside it is a program's own folder
    Set-TestFile "$spaceTest\program\app.dll" 2000
    Set-TestFile "$spaceTest\holder\program2\thing.exe" 500
    Set-TestFile "$spaceTest\holder\program2\thing.dll" 500
}
function Get-TestSpace { Get-QpSpaceUse -Root $spaceTest -KeepAbove 1000 }

Test-Case 'folder sizes add up, and the small ones are summed up in a line' {
    Reset-SpaceTestArea
    $u = Get-TestSpace
    $by = @{}; foreach ($c in $u.Tree.Children) { $by[$c.Name] = $c }
    $u.Tree.Size -eq 45100 -and $u.Tree.Files -eq 6 -and $by['big'].Size -eq 40000 -and $by['program'].Size -eq 4000 -and
    -not $by.ContainsKey('small') -and $u.Tree.OtherCount -eq 1 -and $u.Tree.OtherSize -eq 100
}
Test-Case 'a program''s own folder is spotted, and so is a folder holding one' {
    Reset-SpaceTestArea
    $by = @{}; foreach ($c in (Get-TestSpace).Tree.Children) { $by[$c.Name] = $c }
    $by['program'].HasProgram -and $by['program'].ContainsProgram -and
    -not $by['holder'].HasProgram -and $by['holder'].ContainsProgram -and -not $by['big'].ContainsProgram
}
Test-Case 'links are not followed, so nothing is counted twice' {
    Reset-SpaceTestArea
    $before = (Get-TestSpace).Tree.Size
    New-Item -ItemType Junction -Path "$spaceTest\link" -Target "$spaceTest\big" -ErrorAction Stop | Out-Null
    $after = Get-TestSpace
    $after.Tree.Size -eq $before -and @($after.Tree.Children | Where-Object { $_.Name -eq 'link' }).Count -eq 0
}
Test-Case 'Windows, programs, games and app data are explained instead of offered' {
    $win = Get-QpSpaceAdvice -Path (Join-Path $env:WINDIR 'System32')
    $prog = Get-QpSpaceAdvice -Path (Join-Path $env:ProgramFiles 'Something')
    $steam = Get-QpSpaceAdvice -Path 'C:\Program Files (x86)\Steam\steamapps\common\Rust'
    $app = Get-QpSpaceAdvice -Path (Join-Path $env:LOCALAPPDATA 'Google')
    $dot = Get-QpSpaceAdvice -Path (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex\plugins')
    $me = Get-QpSpaceAdvice -Path ([Environment]::GetFolderPath('UserProfile'))
    $downloads = Get-QpSpaceAdvice -Path (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads')
    -not ($win.CanRecycle -or $prog.CanRecycle -or $steam.CanRecycle -or $app.CanRecycle -or $dot.CanRecycle -or $me.CanRecycle -or $downloads.CanRecycle) -and
    $win.Why -match 'Windows itself' -and $steam.Why -match 'Steam' -and $downloads.Why -match 'main folders'
}
Test-Case 'your own files are yours to move, and OneDrive says what else it means' {
    $mine = Get-QpSpaceAdvice -Path (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads\holiday.mp4')
    if (-not $mine.CanRecycle -or $mine.Note -ne '') { return $false }
    # OneDrive only exists on some PCs; where it does, moving something also removes it everywhere else.
    if (-not $env:OneDrive) { return $true }
    $one = Get-QpSpaceAdvice -Path (Join-Path $env:OneDrive 'Pictures\x.jpg')
    $one.CanRecycle -and $one.Note -match 'other devices'
}
Test-Case 'a folder Windows knows a program lives in is left alone, both ways round' {
    $installed = @([pscustomobject]@{ Path = 'C:\Games\The Sims 4'; Name = 'The Sims 4' })
    $inside = Get-QpSpaceAdvice -Path 'C:\Games\The Sims 4\Data\Client' -Installed $installed
    $holder = Get-QpSpaceAdvice -Path 'C:\Games' -Installed $installed
    $near = Get-QpSpaceAdvice -Path 'C:\Games\Something' -NearProgram $true
    -not $inside.CanRecycle -and $inside.Why -match 'Part of The Sims 4' -and
    -not $holder.CanRecycle -and $holder.Why -match 'holds The Sims 4' -and
    -not $near.CanRecycle -and $near.Why -match 'stop that program working'
}
Test-Case 'installed programs are read from where Windows lists them' {
    $places = @(Get-QpInstallPlaces)
    $places.Count -ge 1 -and @($places | Where-Object { -not [IO.Path]::IsPathRooted($_.Path) }).Count -eq 0
}
Test-Case 'nothing too big for the Recycle Bin is ever sent there' {
    Reset-SpaceTestArea
    $file = "$spaceTest\big\big.bin"
    $drive = [IO.Path]::GetPathRoot($file).TrimEnd('\')
    & (Get-Module Quietpane) { param($d) $script:BinLimits[$d] = [int64]1 } $drive    # pretend the bin is tiny
    $refused = -not (Move-QpToRecycleBin -Path $file -SizeBytes 40000)
    $stillThere = Test-Path -LiteralPath $file
    $r = Invoke-QpSpaceRecycle -Path $file -SizeBytes 40000
    & (Get-Module Quietpane) { $script:BinLimits = @{} }
    $refused -and $stillThere -and -not $r.Ok -and $r.Note -match 'bigger than'
}
Test-Case 'a place that is not yours to move is refused, with what to do instead' {
    $r = Invoke-QpSpaceRecycle -Path (Join-Path $env:WINDIR 'System32') -SizeBytes 1000
    -not $r.Ok -and $r.Note -match 'Windows itself'
}
Test-Case 'a real drive comes back with its own figures' {
    $u = Get-QpSpaceUse -Root ($env:SystemDrive + '\') -KeepAbove 1GB
    $u.Total -gt 0 -and $u.Used -gt 0 -and $u.Hidden -ge 0 -and $u.BinLimit -ge 0 -and -not $u.Cancelled
}
if (Test-Path $spaceTest) { Remove-Item -LiteralPath $spaceTest -Recurse -Force }

Section 'The room worth clearing first'
# A pretend user folder with files of known ages, and a pretend scan result, so the suggestions can be
# checked without touching anything real. It sits in your own folder, because Temp is inside AppData,
# which Quietpane refuses to move from.
$winRoot = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'QuietpaneWinsTest'
$winDownloads = Join-Path $winRoot 'Downloads'
$winDesktop = Join-Path $winRoot 'Desktop'
$winNow = [datetime]'2026-09-23 12:00'
function Set-TestAged([string]$Path, [int]$Bytes, [datetime]$When) {
    $fs = [IO.File]::Create($Path); $fs.SetLength($Bytes); $fs.Close()
    (Get-Item -LiteralPath $Path).LastWriteTime = $When
}
function Reset-WinsTestArea {
    if (Test-Path $winRoot) { Remove-Item -LiteralPath $winRoot -Recurse -Force }
    foreach ($d in $winDownloads, $winDesktop) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    Set-TestAged (Join-Path $winDownloads 'setup_thing.exe') 2000 $winNow.AddDays(-200)   # an installer
    Set-TestAged (Join-Path $winDownloads 'office.msi') 1000 $winNow.AddDays(-700)        # an older installer
    Set-TestAged (Join-Path $winDownloads 'photos.zip') 5000 $winNow.AddDays(-500)        # an old download
    Set-TestAged (Join-Path $winDownloads 'notes.pdf') 100 $winNow.AddDays(-30)           # recent: left alone
    Set-TestAged (Join-Path $winDownloads 'last-year.txt') 300 $winNow.AddDays(-200)      # old, but not a year old
    Set-TestAged (Join-Path $winDesktop 'driver.exe') 700 $winNow.AddDays(-400)           # an installer on the desktop
    Set-TestAged (Join-Path $winDesktop 'shopping.txt') 50 $winNow.AddDays(-900)          # the desktop is not Downloads
}
function New-TestNode($Name, $Path, $Size, $When, $IsFile, $Children) {
    [pscustomobject]@{ Name = $Name; Path = $Path; Size = [int64]$Size; Modified = $When; IsFile = $IsFile; Children = @($Children) }
}
function New-TestSpace($Children, $BinLimit = [int64]10GB) {
    [pscustomobject]@{
        Root = ($env:SystemDrive + '\'); Installed = @(); BinLimit = [int64]$BinLimit
        Tree = (New-TestNode 'C:\' 'C:\' 0 $winNow $false $Children)
    }
}
function Get-TestWins($Space, $Cleanup = @()) {
    @(Get-QpEasyWins -Space $Space -Cleanup $Cleanup -Now $winNow -UserDir $winRoot)
}
function Get-TestWin($Wins, [string]$Id) { @($Wins | Where-Object { $_.Id -eq $Id })[0] }

Test-Case 'old files are found by the date on the file, and links are never followed' {
    Reset-WinsTestArea
    New-Item -ItemType Junction -Path (Join-Path $winRoot 'link') -Target $winDownloads -ErrorAction Stop | Out-Null
    $all = Get-QpOldFiles -Roots @($winRoot) -Before $winNow.AddDays(-100)
    $installers = Get-QpOldFiles -Roots @($winDownloads) -Before $winNow.AddDays(-100) -Extensions @('.exe', '.msi')
    $big = Get-QpOldFiles -Roots @($winDownloads) -Before $winNow.AddDays(-100) -MinSize 4000
    # 6 old files in all; notes.pdf is too recent, and the junction must not double any of them.
    $all.Files.Count -eq 6 -and -not $all.Truncated -and
    (@($installers.Files | ForEach-Object { $_.Name }) -join ',') -eq 'setup_thing.exe,office.msi' -and
    $big.Files.Count -eq 1 -and $big.Files[0].Name -eq 'photos.zip'
}
Test-Case 'installers are one suggestion and forgotten downloads another, with the desktop left out of the downloads' {
    Reset-WinsTestArea
    $wins = Get-TestWins (New-TestSpace @())
    $inst = Get-TestWin $wins 'installers'
    $old = Get-TestWin $wins 'downloads'
    $inst -and $old -and $inst.Count -eq 3 -and $inst.Bytes -eq 3700 -and $inst.CanRecycle -and
    $inst.Short -match '^3 of them, the newest from ' -and
    # Only photos.zip: the .pdf is recent, last-year.txt is not a year old, and shopping.txt is on the desktop.
    $old.Count -eq 1 -and $old.Items[0].Name -eq 'photos.zip'
}
Test-Case 'a big file nobody has changed in years is offered, and one that is part of a program is not' {
    Reset-WinsTestArea
    $mine = Join-Path $winRoot 'holiday.mov'
    Set-TestAged $mine 500 $winNow.AddYears(-3)
    $game = Join-Path $winRoot 'game.pak'
    Set-TestAged $game 500 $winNow.AddYears(-3)
    $space = New-TestSpace @(
        (New-TestNode 'holiday.mov' $mine 400MB $winNow.AddYears(-3) $true @()),
        (New-TestNode 'game.pak' $game 400MB $winNow.AddYears(-3) $true @()),
        (New-TestNode 'recent.mov' $mine 400MB $winNow.AddMonths(-2) $true @()),
        (New-TestNode 'gone.mov' (Join-Path $winRoot 'not-there.mov') 400MB $winNow.AddYears(-3) $true @())
    )
    $space.Installed = @([pscustomobject]@{ Path = $game; Name = 'A Game' })
    $win = Get-TestWin (Get-TestWins $space) 'bigold'
    # Only the one that is old, big, still there, and yours to move.
    $win -and $win.Count -eq 1 -and $win.Items[0].Name -eq 'holiday.mov' -and $win.CanRecycle
}
Test-Case 'nothing bigger than the Recycle Bin can hold is ever offered' {
    Reset-WinsTestArea
    $mine = Join-Path $winRoot 'huge.mov'
    Set-TestAged $mine 500 $winNow.AddYears(-3)
    $space = New-TestSpace @((New-TestNode 'huge.mov' $mine 400MB $winNow.AddYears(-3) $true @())) ([int64]100MB)
    $tight = Get-TestWins $space
    # With the bin switched off altogether, they become things to look at rather than things to move.
    $offSpace = New-TestSpace @() ([int64]0)
    $off = Get-TestWin (Get-TestWins $offSpace) 'installers'
    $null -eq (Get-TestWin $tight 'bigold') -and $off -and -not $off.CanRecycle -and $off.Advice -match 'switched off'
}
Test-Case 'what only Windows can clear is explained, never touched' {
    Reset-WinsTestArea
    $space = New-TestSpace @(
        (New-TestNode 'Windows.old' 'C:\Windows.old' 12GB $winNow.AddDays(-5) $false @()),
        (New-TestNode '$Recycle.Bin' 'C:\$Recycle.Bin' 800MB $winNow $false @())
    )
    $cleanup = @([pscustomobject]@{ Id = 'wu.download'; Title = 'Windows Update download cache'; SizeBytes = [int64]2GB })
    $wins = Get-TestWins $space $cleanup
    $old = Get-TestWin $wins 'windows.old'
    $bin = Get-TestWin $wins 'recyclebin'
    $wu = Get-TestWin $wins 'wu.download'
    $old -and -not $old.CanRecycle -and $old.Count -eq 0 -and $old.Advice -match 'Settings > System > Storage' -and
    $bin -and -not $bin.CanRecycle -and $bin.Advice -match 'Empty Recycle Bin' -and
    $wu -and -not $wu.CanRecycle -and $wu.Advice -match 'Apply' -and $wu.Bytes -eq 2GB
}
Test-Case 'the ones you can act on come first, biggest first' {
    Reset-WinsTestArea
    $space = New-TestSpace @((New-TestNode 'Windows.old' 'C:\Windows.old' 12GB $winNow.AddDays(-5) $false @()))
    $order = @(Get-TestWins $space | ForEach-Object { $_.Id }) -join ','
    # Windows.old is by far the biggest, and still comes last: it is not yours to move.
    $order -eq 'downloads,installers,windows.old'
}
Test-Case 'preview changes nothing at all' {
    Reset-WinsTestArea
    $win = Get-TestWin (Get-TestWins (New-TestSpace @())) 'installers'
    $r = Invoke-QpEasyWin -Win $win -Preview
    $r.Moved -eq 0 -and @(Get-ChildItem $winDownloads -File).Count -eq 5 -and (Test-Path (Join-Path $winDesktop 'driver.exe'))
}
Test-Case 'moving a suggestion sends every file to the Recycle Bin, in one restore point' {
    Reset-WinsTestArea
    $since = (Get-Date).AddSeconds(-2)
    $win = Get-TestWin (Get-TestWins (New-TestSpace @())) 'installers'
    $r = Invoke-QpEasyWin -Win $win
    $gone = -not (Test-Path (Join-Path $winDownloads 'setup_thing.exe')) -and -not (Test-Path (Join-Path $winDesktop 'driver.exe'))
    $kept = Test-Path (Join-Path $winDownloads 'photos.zip')
    $rp = Get-ChildItem (Join-Path $env:ProgramData 'Quietpane\restore') -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '*-space-tidy' -and $_.CreationTime -ge $since } | Sort-Object CreationTime -Descending | Select-Object -First 1
    if (-not $rp) { return $false }
    $entries = @((Get-Content (Join-Path $rp.FullName 'state.json') -Raw | ConvertFrom-Json).Entries)
    Remove-Item -LiteralPath $rp.FullName -Recurse -Force   # the test's own restore point, not the user's
    # The three files are in the Recycle Bin by design: that is where the app puts them.
    $r.Moved -eq 3 -and $r.Failed -eq 0 -and $r.Bytes -eq 3700 -and $gone -and $kept -and $entries.Count -eq 3
}
if (Test-Path $winRoot) { Remove-Item -LiteralPath $winRoot -Recurse -Force }

Section 'What''s talking to the internet'
Test-Case 'your own network is told apart from the internet' {
    (Test-QpPrivateAddress '192.168.1.5') -and (Test-QpPrivateAddress '10.0.0.3') -and (Test-QpPrivateAddress '172.20.1.1') -and
    (Test-QpPrivateAddress '127.0.0.1') -and (Test-QpPrivateAddress 'fe80::1') -and (Test-QpPrivateAddress '::1') -and
    -not (Test-QpPrivateAddress '4.207.247.137') -and -not (Test-QpPrivateAddress '2600:1901:1:a98::')
}
Test-Case 'who is behind an address is named, and a reporting address is only ever a hint' {
    $a = Get-QpAddressLabel -Address '1.2.3.4' -HostName 'api.anthropic.com'
    $b = Get-QpAddressLabel -Address '5.6.7.8' -HostName 'vortex.data.microsoft.com'
    $c = Get-QpAddressLabel -Address '9.9.9.9' -HostName ''
    $a.Owner -eq 'Anthropic' -and $a.Note -eq '' -and $b.Note -match 'looks like' -and
    $c.Text -eq '9.9.9.9' -and $c.Owner -eq '' -and $c.Note -eq ''
}
Test-Case 'connections are grouped by program, with the places that have names first' {
    $conns = @(
        [pscustomobject]@{ RemoteAddress = '1.1.1.1'; OwningProcess = 4242 }
        [pscustomobject]@{ RemoteAddress = '2.2.2.2'; OwningProcess = 4242 }
        [pscustomobject]@{ RemoteAddress = '192.168.0.9'; OwningProcess = 4242 }   # your own network
        [pscustomobject]@{ RemoteAddress = '127.0.0.1'; OwningProcess = 4242 }     # this PC
        [pscustomobject]@{ RemoteAddress = '3.3.3.3'; OwningProcess = 4343 }       # a second copy of the same program
        [pscustomobject]@{ RemoteAddress = '10.0.0.5'; OwningProcess = 4444 }      # only ever on your own network
    )
    $cache = @([pscustomobject]@{ Data = '2.2.2.2'; Entry = 'api.anthropic.com'; Type = 'A' })
    $procs = @(
        [pscustomobject]@{ Id = 4242; ProcessName = 'testapp'; Description = 'Test App'; Product = ''; Path = 'D:\Test\testapp.exe' }
        [pscustomobject]@{ Id = 4343; ProcessName = 'testapp'; Description = 'Test App'; Product = ''; Path = 'D:\Test\testapp.exe' }
        [pscustomobject]@{ Id = 4444; ProcessName = 'printer'; Description = ''; Product = ''; Path = '' }
    )
    $r = Get-QpConnections -Connections $conns -DnsCache $cache -Processes $procs -Services @{}
    $p = @($r.Programs)[0]
    @($r.Programs).Count -eq 1 -and $p.Name -eq 'Test App' -and $p.Processes -eq 2 -and $p.Count -eq 3 -and
    $p.Destinations[0].Text -eq 'api.anthropic.com' -and ($p.Owners -contains 'Anthropic') -and $p.LocalCount -eq 1 -and
    ($r.LocalOnly -contains 'printer')
}
Test-Case 'reading the real list never throws' {
    $r = Get-QpConnections
    $null -ne $r -and $r.Internet -ge 0 -and $null -ne $r.At
}

Section 'Start menu, desktop and sign-in'
Test-Case 'a shortcut carries the app id, so the taskbar treats it as Quietpane' {
    Initialize-QpShortcut
    $lnk = Join-Path $env:TEMP 'QuietpaneShortcutTest.lnk'
    $i = Get-QpInfo
    [QuietpaneShortcut]::Create($lnk, (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'), '-NoProfile', $root, $i.IconPath, 'Quietpane test', $i.AppId)
    $s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
    $ok = (Test-Path -LiteralPath $lnk) -and ([QuietpaneShortcut]::ReadAppId($lnk)) -eq $i.AppId -and
          $s.IconLocation -like '*quietpane.ico*' -and $s.TargetPath -like '*powershell.exe' -and $s.WorkingDirectory -eq $root
    [IO.File]::Delete($lnk)
    $ok
}
Test-Case 'shortcuts go in your own Start menu and desktop, and open Quietpane''s own copy in Program Files' {
    $p = Get-QpShortcutPaths
    $s = Test-QpShortcuts
    $pf = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
    $p.StartMenu.StartsWith($env:APPDATA, [StringComparison]::OrdinalIgnoreCase) -and
    $p.Desktop.StartsWith([Environment]::GetFolderPath('DesktopDirectory'), [StringComparison]::OrdinalIgnoreCase) -and
    $p.Script -ieq (Join-Path $pf 'Quietpane\Quietpane.ps1') -and $p.Icon -like '*\Quietpane\assets\quietpane.ico' -and
    $null -ne $s.StartMenu -and $null -ne $s.Desktop -and $null -ne $s.Pinned
}
Test-Case 'version numbers compare as numbers, not as text' {
    (Compare-QpVersion '1.10.0' '1.9.2') -eq 1 -and (Compare-QpVersion '1.9.2' '1.10.0') -eq -1 -and (Compare-QpVersion '1.11.0' '1.11.0') -eq 0
}

# A pretend Program Files, Start menu and taskbar in a temporary folder: the real ones are never touched.
$copyArea = Join-Path $env:TEMP ('QpCopyTest-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$copyTo = Join-Path $copyArea 'Program Files\Quietpane'
Test-Case 'Quietpane''s own copy has everything it needs to run, and none of the tests or tools' {
    $r = Install-QpCopy -From $root -To $copyTo
    $r.Ok -and $r.Changed -and (Get-QpAppVersion $copyTo) -eq (Get-QpInfo).Version -and
    (Test-Path (Join-Path $copyTo 'src\catalog\network.psd1')) -and (Test-Path (Join-Path $copyTo 'assets\quietpane.ico')) -and
    (Test-Path (Join-Path $copyTo 'PRIVACY.md')) -and -not (Test-Path (Join-Path $copyTo 'tests')) -and -not (Test-Path (Join-Path $copyTo 'tools')) -and
    (Test-QpCopyMatches $root $copyTo)
}
Test-Case 'opening the same version again leaves the copy alone' {
    $r = Install-QpCopy -From $root -To $copyTo
    $r.Ok -and -not $r.Changed
}
Test-Case 'a copy that was changed or only half made is put right' {
    Set-Content -LiteralPath (Join-Path $copyTo 'README.md') -Value 'changed' -Encoding ASCII
    $r = Install-QpCopy -From $root -To $copyTo
    $r.Changed -and (Test-QpCopyMatches $root $copyTo)
}
Test-Case 'an older Quietpane never replaces a newer copy' {
    $engine = Join-Path $copyTo 'src\Quietpane.psm1'
    $text = [IO.File]::ReadAllText($engine) -replace "(?m)^\`$script:AppVersion\s*=\s*'[^']+'", "`$`$script:AppVersion  = '99.0.0'"
    [IO.File]::WriteAllText($engine, $text)
    $r = Install-QpCopy -From $root -To $copyTo
    $r.Ok -and -not $r.Changed -and (Get-QpAppVersion $copyTo) -eq '99.0.0'
}
Test-Case 'a folder that isn''t Quietpane is never sent to the Recycle Bin' {
    $other = Join-Path $copyArea 'Not Quietpane'
    New-Item -ItemType Directory -Force -Path $other | Out-Null
    (Remove-QpCopy -InstallRoot $other) -eq 'Failed' -and (Test-Path $other) -and (Remove-QpCopy -InstallRoot (Join-Path $copyArea 'missing')) -eq 'None'
}
Test-Case 'shortcuts that still open a moved folder are pointed at Quietpane''s own copy, and yours are left alone' {
    Initialize-QpShortcut
    $links = Join-Path $copyArea 'links'; $pinned = Join-Path $links 'TaskBar'
    New-Item -ItemType Directory -Force -Path $pinned | Out-Null
    $fresh = Join-Path $copyArea 'Program Files 2\Quietpane'
    $p = [pscustomobject]@{
        StartMenu = Join-Path $links 'Quietpane.lnk'; Desktop = Join-Path $links 'Desktop Quietpane.lnk'; Pinned = $pinned
        AppRoot = $root; InstallRoot = $fresh; Script = Join-Path $fresh 'Quietpane.ps1'; Icon = Join-Path $fresh 'assets\quietpane.ico'; FromCopy = $false
    }
    $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $old = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "D:\Moved away\Quietpane.ps1"'
    $appId = (Get-QpInfo).AppId
    [QuietpaneShortcut]::Create($p.StartMenu, $ps, $old, $root, '', 'Quietpane', $appId)
    [QuietpaneShortcut]::Create((Join-Path $pinned 'Quietpane.lnk'), $ps, $old, $root, '', 'Quietpane', $appId)
    [QuietpaneShortcut]::Create($p.Desktop, $ps, $old, $root, '', 'Mine', '')   # someone's own, without Quietpane's app id
    $r = Sync-QpInstall -InstallRoot $fresh -Name 'Quietpane test - no such task' -Paths $p
    $want = '*-File "' + (Join-Path $fresh 'Quietpane.ps1') + '"*'
    $r.InUse -and $r.Updated -and $r.Repaired -eq 2 -and (Get-QpAppVersion $fresh) -eq (Get-QpInfo).Version -and
    ([QuietpaneShortcut]::ReadArguments($p.StartMenu) -like $want) -and
    ([QuietpaneShortcut]::ReadArguments((Join-Path $pinned 'Quietpane.lnk')) -like $want) -and
    ([QuietpaneShortcut]::ReadArguments($p.Desktop) -eq $old)
}
Test-Case 'with no shortcuts and no sign-in start, opening Quietpane changes nothing at all' {
    $empty = Join-Path $copyArea 'nothing'
    New-Item -ItemType Directory -Force -Path $empty | Out-Null
    $none = Join-Path $copyArea 'Program Files 3\Quietpane'
    $p = [pscustomobject]@{ StartMenu = Join-Path $empty 'a.lnk'; Desktop = Join-Path $empty 'b.lnk'; Pinned = $empty; AppRoot = $root; InstallRoot = $none; Script = Join-Path $none 'Quietpane.ps1'; Icon = ''; FromCopy = $false }
    $r = Sync-QpInstall -InstallRoot $none -Name 'Quietpane test - no such task' -Paths $p
    -not $r.InUse -and -not (Test-Path $none)
}
Test-Case 'starting at sign-in waits for sign-in to finish, runs on battery, and is never stopped for running too long' {
    $t = New-QpSignInTask -Script 'C:\Program Files\Quietpane\Quietpane.ps1'
    $a = @($t.Actions)[0]; $tr = @($t.Triggers)[0]
    $t.Principal.RunLevel -eq 'Highest' -and $t.Principal.LogonType -eq 'Interactive' -and
    $tr.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' -and $tr.Delay -eq 'PT20S' -and
    -not $t.Settings.DisallowStartIfOnBatteries -and -not $t.Settings.StopIfGoingOnBatteries -and $t.Settings.ExecutionTimeLimit -eq 'PT0S' -and
    $a.Execute -like '*\System32\WindowsPowerShell\v1.0\powershell.exe' -and
    $a.Arguments -like '*-File "C:\Program Files\Quietpane\Quietpane.ps1" -Minimized' -and $t.Author -eq 'KomodoWorks'
}
Test-Case 'the safety scan knows Quietpane''s own sign-in task, but not one that only borrows its name' {
    $pf = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
    $good = [pscustomobject]@{ TaskPath = '\'; TaskName = 'Quietpane (KomodoWorks)'; Actions = @(Get-QpSignInAction (Join-Path $pf 'Quietpane\Quietpane.ps1')) }
    $bad = [pscustomobject]@{ TaskPath = '\'; TaskName = 'Quietpane (KomodoWorks)'; Actions = @(Get-QpSignInAction 'C:\Users\Public\other.ps1') }
    $moved = [pscustomobject]@{ TaskPath = '\Other\'; TaskName = 'Quietpane (KomodoWorks)'; Actions = $good.Actions }
    (Test-QpOwnSignInTask $good) -and -not (Test-QpOwnSignInTask $bad) -and -not (Test-QpOwnSignInTask $moved)
}
Test-Case 'the sign-in start can also check once for things that came back, and the task itself carries that choice' {
    $plain = New-QpSignInTask -Script 'C:\Program Files\Quietpane\Quietpane.ps1'
    $watch = New-QpSignInTask -Script 'C:\Program Files\Quietpane\Quietpane.ps1' -Watch
    @($plain.Actions)[0].Arguments -like '*-Minimized' -and @($watch.Actions)[0].Arguments -like '*-Minimized -Watch' -and
    -not (Test-QpTaskWatches $plain) -and (Test-QpTaskWatches $watch) -and $watch.Description -match 'checks once'
}
Test-Case 'the safety scan knows both kinds of Quietpane sign-in task as its own, and nothing with extras' {
    $pf = if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }
    $opens = Join-Path $pf 'Quietpane\Quietpane.ps1'
    $watching = [pscustomobject]@{ TaskPath = '\'; TaskName = 'Quietpane (KomodoWorks)'; Actions = @(Get-QpSignInAction $opens -Watch) }
    $extra = [pscustomobject]@{ TaskPath = '\'; TaskName = 'Quietpane (KomodoWorks)'
        Actions = @([pscustomobject]@{ Execute = (Get-QpSignInAction $opens).Execute; Arguments = (Get-QpSignInAction $opens -Watch).Arguments + ' -Other' }) }
    (Test-QpOwnSignInTask $watching) -and -not (Test-QpOwnSignInTask $extra)
}
Test-Case 'switching the sign-in start on and off (needs administrator rights)' {
    if (-not (Test-QpAdmin)) { return 'skip' }
    $name = 'Quietpane test - safe to delete'
    $to = Join-Path $copyArea 'Program Files 4\Quietpane'
    try {
        $on = Enable-QpSignInStart -InstallRoot $to -Name $name
        $t = Get-QpSignInTask -Name $name
        $ok = $on.Ok -and $t -and (Test-QpSignInStart -Name $name) -and "$($t.Principal.RunLevel)" -eq 'Highest' -and (Get-QpAppVersion $to)
        # Ticking "also tell me" and unticking it again sets the same task up with and without -Watch.
        $ok = $ok -and -not (Test-QpSignInWatch -Name $name)
        $ok = $ok -and (Enable-QpSignInStart -InstallRoot $to -Name $name -Watch).Ok -and (Test-QpSignInWatch -Name $name)
        $ok = $ok -and (Enable-QpSignInStart -InstallRoot $to -Name $name).Ok -and -not (Test-QpSignInWatch -Name $name)
        # The copy is this test's own; it goes first, so switching off has nothing to send to your Recycle Bin.
        [IO.Directory]::Delete($to, $true)
        $off = Disable-QpSignInStart -InstallRoot $to -Name $name
        $ok -and $off.Ok -and -not (Get-QpSignInTask -Name $name) -and $off.Copy -in 'None', 'Kept'
    } finally { try { Unregister-ScheduledTask -TaskPath '\' -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue } catch { } }
}
Test-Case 'opened minimised at sign-in, the window still starts working the first time it is opened' {
    # Windows never sends ContentRendered to a window that starts minimised, so the window also listens
    # for the first time it is opened.
    $src = Get-Content (Join-Path $root 'Quietpane.ps1') -Raw
    $src -match 'Add_ContentRendered\(\{ Start-FirstShow \}\)' -and $src -match 'Add_StateChanged\(\{[^}]*Start-FirstShow'
}
try { [IO.Directory]::Delete($copyArea, $true) } catch { }

Section 'The app icon'
Add-Type -AssemblyName PresentationCore
Test-Case 'the icon has every size Windows asks for' {
    $ico = (Get-QpInfo).IconPath
    $dec = New-Object System.Windows.Media.Imaging.IconBitmapDecoder ([Uri]$ico), 'None', 'OnLoad'
    $sizes = @($dec.Frames | ForEach-Object { $_.PixelWidth } | Sort-Object)
    ($sizes -join ',') -eq '16,20,24,32,40,48,64,256'
}
Test-Case 'the icon is the KomodoWorks emblem, on a see-through background' {
    $dec = New-Object System.Windows.Media.Imaging.IconBitmapDecoder ([Uri](Get-QpInfo).IconPath), 'None', 'OnLoad'
    $big = New-Object System.Windows.Media.Imaging.FormatConvertedBitmap ($dec.Frames | Where-Object { $_.PixelWidth -eq 256 }), ([System.Windows.Media.PixelFormats]::Bgra32), $null, 0
    $px = New-Object byte[] (256 * 256 * 4)
    $big.CopyPixels($px, 256 * 4, 0)
    function Get-Px([int]$x, [int]$y) { $i = ($y * 256 + $x) * 4; '{0},{1},{2},{3}' -f $px[$i + 2], $px[$i + 1], $px[$i], $px[$i + 3] }
    # corner clear, dark square in the KomodoWorks anchor colour, teal square peeking out bottom-right
    (Get-Px 0 0).EndsWith(',0') -and (Get-Px 40 40) -eq '15,27,28,255' -and (Get-Px 240 240) -eq '23,155,131,255'
}
Test-Case 'the window''s calls into Windows only name the app, ask for a sharp picture and colour its title bar' {
    # A fixed list on purpose: anything new the window asks Windows to do has to be added here by hand.
    # The third is DwmSetWindowAttribute, used only to give a dark window a dark title bar.
    $src = Get-Content (Join-Path $root 'Quietpane.ps1') -Raw
    $calls = @([regex]::Matches($src, 'DllImport\("(\w+)\.dll"[^\]]*\)\]\s*public static extern int (\w+)') | ForEach-Object { '{0}!{1}' -f $_.Groups[1].Value, $_.Groups[2].Value })
    ($calls -join ';') -eq 'shell32!SetCurrentProcessExplicitAppUserModelID;user32!SetProcessDPIAware;dwmapi!DwmSetWindowAttribute'
}

Section 'What signing in costs'
# The window's own self-test, shared by the checks below and in the next two sections.
$cardsOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File (Join-Path $root 'Quietpane.ps1') -SelfTest 2>&1 | Out-String
Test-Case 'what a startup program costs is measured from the program itself, never guessed' {
    # PowerShell is running right now (this test is it); the made-up one is not.
    $here = (Get-Process -Id $PID).Path
    $items = @(
        [pscustomobject]@{ Id = 'running'; Name = 'PowerShell'; Target = $here },
        [pscustomobject]@{ Id = 'gone'; Name = 'Not here'; Target = 'C:\nowhere\QuietpaneNoSuchProgram.exe' }
    )
    $costs = @(Get-QpSignInCost -Items $items)
    $run = @($costs | Where-Object { $_.Id -eq 'running' })[0]
    $gone = @($costs | Where-Object { $_.Id -eq 'gone' })[0]
    $run.Running -and $run.MemoryMB -gt 0 -and -not $gone.Running -and $gone.MemoryMB -eq 0 -and $null -eq $gone.WindowsSeconds
}
Test-Case 'Windows'' own timing is used where there is one, and left out where there isn''t' {
    $here = (Get-Process -Id $PID).Path
    $exe = Split-Path $here -Leaf
    $record = [pscustomobject]@{ Boot = $null; Slow = @{ $exe.ToLowerInvariant() = [pscustomobject]@{ Name = $exe; Seconds = 4.2; When = (Get-Date) } }; Stale = $false }
    $with = @(Get-QpSignInCost -Items @([pscustomobject]@{ Id = 'x'; Name = 'PowerShell'; Target = $here }) -Record $record)[0]
    $without = @(Get-QpSignInCost -Items @([pscustomobject]@{ Id = 'x'; Name = 'PowerShell'; Target = $here }))[0]
    $with.WindowsSeconds -eq 4.2 -and $null -eq $without.WindowsSeconds
}
Test-Case 'a cost reads as plain words, and says nothing it cannot back up' {
    $running = Format-QpSignInCost ([pscustomobject]@{ Running = $true; MemoryMB = 500; Copies = 2; StartedAfterSeconds = 6.5; WindowsSeconds = 3.2 })
    $quiet = Format-QpSignInCost ([pscustomobject]@{ Running = $false; MemoryMB = 0; Copies = 0; StartedAfterSeconds = $null; WindowsSeconds = $null })
    $shy = Format-QpSignInCost ([pscustomobject]@{ Running = $true; MemoryMB = 40; Copies = 1; StartedAfterSeconds = $null; WindowsSeconds = $null })
    $running -eq 'Windows timed it at 3.2 seconds, using 500 MB in 2 copies now, started 6.5 seconds after you signed in.' -and
    $quiet -eq 'Not running at the moment.' -and $shy -eq 'Using 40 MB now.'
}
Test-Case 'Windows'' restart record is read if it is there, and simply absent if not' {
    # The log needs administrator rights, so without them there is nothing to read - and the window
    # carries on without it. With them, whatever comes back has to make sense.
    $r = Get-QpBootRecord
    if (-not $r) { return 'skip' }
    $null -ne $r.Slow -and ($null -eq $r.Boot -or ($r.Boot.Seconds -gt 0 -and $r.Boot.When -and $r.Boot.ToDesktopSeconds -ge 0))
}
Test-Case 'the heaviest comes first, with the total and Windows'' own figure' {
    $cardsOut -match 'sign-in costs: Slow starter,Heavy app,Idle helper; total line: True; restart line: True; windows timing: True; copies: True'
}

Section 'Plain words, and something to do about them'
Test-Case 'a check''s detail splits into plain words on the card and technical lines underneath' {
    $d = Split-QpFindingDetail "C:\Users\me\AppData\Local\Temp\thing.exe`nHKCU:\Software\Run = thing.exe`n2026-09-22  C:\x\y.exe`nThis launches a hidden command every time you sign in."
    $d.Why -eq 'This launches a hidden command every time you sign in.' -and
    $d.Technical -match 'thing\.exe' -and $d.Technical -match 'HKCU' -and $d.Technical -notmatch 'launches a hidden'
}
Test-Case 'every privacy setting has a plain title and a short line, with the full text kept for the tooltip' {
    $items = @((Get-QpCatalog privacy).Items)
    $longTitles = @($items | Where-Object { @("$($_.Title)" -split '\s+').Count -gt 9 })
    $longShorts = @($items | Where-Object { @("$($_.Short)" -split '\s+').Count -gt 12 })
    $jargon = @($items | Where-Object { $_.Title -match '(?i)DiagTrack|group-policy|CEIP|registry|policy value' })
    $items.Count -eq 32 -and @($items | Where-Object { -not $_.Short }).Count -eq 0 -and
    @($items | Where-Object { -not $_.Description }).Count -eq 0 -and
    $longTitles.Count -eq 0 -and $longShorts.Count -eq 0 -and $jargon.Count -eq 0
}
Test-Case 'the session card names the worst of it, counts the minutes and owns up to the gap' {
    $cardsOut -match 'session: Stop watching; very hot: True; held back: True; gap owned up to: True; busiest: True; stops: True; alerts: memory,drive; said once: True; report: Visible offered, \d{4,} characters, 0 scripts; timeline: 96 columns, 92 a gap, 3 held back, 4 legend words'
}
Test-Case 'the live tiles rank what matters, merge the busy list and never draw an invented zero' {
    # The whole Health panel drawn into the real window twice: a PC in trouble, then one that shares
    # almost nothing. A game busy on both the processor and the graphics card is one program, listed
    # once at its loudest, rather than the same name in four columns as it used to be.
    $cardsOut -match 'live tiles: verdict worst first: True; held back named: True; memory word: True; drive heat: True; video memory folded in: True; 2 rows: A game 88% of the graphics card / Windows Explorer 6% of the processor; drive life: True; calm: True; nothing invented: True'
}
Test-Case 'Health keeps two columns when there is room, and puts the list underneath when there is not' {
    # At the usual width and at the narrowest the window allows: nothing cut off, the tabs on one row.
    $cardsOut -match 'health layout: 1100: side by side, fits True, tabs on one row True; 760: list underneath, fits True, tabs on one row True'
}
Test-Case 'the Health list shows what the PC shares, and leaves out or says "not shared" for what it does not' {
    # Made-up PCs drawn into the real window: everything shared, nothing shared, offline, and Fahrenheit.
    $cardsOut -match 'health facts: cores: True; memory: True; clocks: True; fan stopped: True; no clock or fan noise: True; network: True; not connected: True; network not shared: True; power plan: True; fans not shared: True; this pc: True; drive speeds: True; fahrenheit: True'
}
Test-Case 'the live tiles cope with two graphics cards, built-in graphics, no battery and a silent drive' {
    $cardsOut -match 'two cards: True; built-in graphics quiet: True; no battery box: True; drive temperature not shared: True'
}
Test-Case 'light and dark switch live in the real window, and every colour has a dark partner' {
    # The window is built light, switched to dark and back; a card background from the XAML, a line of
    # text and a bar built in code must all follow, and no shared brush may have been frozen along the way.
    $cardsOut -match 'theme: live switch: True; back to light: True; shared: True; follows Windows: True; a fixed choice holds: True; frozen: none; every colour has a dark partner: True'
}
Test-Case 'the steadiness card shows Windows'' score, or says plainly that there isn''t one' {
    $cardsOut -match 'holding up: score: True; crashes named: True; sudden stops: True; awake: True; unscored says so: True'
}
Test-Case 'the easy wins show what they mean, and what only Windows can clear says where to go' {
    $cardsOut -match 'easy wins: rows: 2; move button: True; size: True; windows only: True; stopped looking: True; files hidden: True'
}
Test-Case 'the add-ons that see the most come first, and the browser''s own parts stay out of the way' {
    # Four add-ons drawn into the real window: two that read every site, one that does not, one Firefox.
    $cardsOut -match 'add-ons: Coupon Helper,Old Toolbar,Docs Offline; reads every site: True; count: True; parts summed up: True; firefox: True'
}
Test-Case 'files found by Quietpane''s own checks can be quarantined or removed, whatever their level' {
    # A Medium file, a Low file and two files listed on one card: four in all. A setting gets no buttons.
    $cardsOut -match 'finding quarantine buttons: 4 \(unnamed 0\)'
}
Test-Case 'the window keeps its words down' {
    $env:QP_WORDS = '1'
    try { $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File (Join-Path $root 'Quietpane.ps1') -SelfTest 2>&1 | Out-String }
    finally { Remove-Item Env:\QP_WORDS -ErrorAction SilentlyContinue }
    if ($out -notmatch 'words: ([^\r\n]+)') { return $false }   # [^\r\n], or the last tab keeps the carriage return
    $counts = @{}
    foreach ($pair in ($matches[1] -split ',\s*')) { if ($pair -match '^(.+)=(\d+)$') { $counts[$matches[1]] = [int]$matches[2] } }
    $total = ($counts.Values | Measure-Object -Sum).Sum
    # Room to grow, but not back to where it was (2,900 words, Privacy alone 1,340).
    $counts.Count -eq 9 -and $total -lt 2300 -and $counts['Privacy'] -lt 950 -and $counts['Home'] -lt 200 -and $counts['About'] -lt 210
}

Section 'What the PC is, and how fast it is going (2.0)'
# Made-up PCs for the rules, and this PC for the real thing. Every rule is the same one: what Windows
# does not say plainly is left empty - never a zero, never worked out from something else.
function New-TestFacts {
    param($Sticks = $null, $Arrays = $null, $System = $null, $Video = $null, [string]$PowerCfg = '')
    if ($null -eq $Sticks) { $Sticks = @([pscustomobject]@{ Capacity = 8GB; SMBIOSMemoryType = 34; ConfiguredClockSpeed = 5200 }, [pscustomobject]@{ Capacity = 8GB; SMBIOSMemoryType = 34; ConfiguredClockSpeed = 5200 }) }
    if ($null -eq $System) { $System = [pscustomobject]@{ Manufacturer = 'Micro-Star International Co., Ltd.'; Model = 'Cyborg 15 A13VF' } }
    ConvertTo-QpSystemFacts -Processors @([pscustomobject]@{ NumberOfCores = 10; NumberOfLogicalProcessors = 16 }) -Sticks $Sticks -Arrays $Arrays `
        -System $System -OS ([pscustomobject]@{ Caption = 'Microsoft Windows 11 Home' }) `
        -WindowsKey ([pscustomobject]@{ ProductName = 'Windows 10 Home'; DisplayVersion = '25H2'; CurrentBuild = '26200'; UBR = 9457 }) `
        -Video $Video -PowerCfg $PowerCfg
}
Test-Case 'the facts come through as Windows gives them, and Windows 11 is not called Windows 10' {
    # The registry's ProductName still says "Windows 10" on Windows 11; the operating system record does not.
    $f = New-TestFacts -Arrays @([pscustomobject]@{ Use = 3; MemoryDevices = 4 }) `
        -Video @([pscustomobject]@{ CurrentHorizontalResolution = 1920; CurrentVerticalResolution = 1080; CurrentRefreshRate = 144 }) `
        -PowerCfg 'Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Balanced)'
    $f.Cores -eq 10 -and $f.Threads -eq 16 -and $f.MemoryType -eq 'DDR5' -and $f.MemorySpeedMTs -eq 5200 -and
    $f.MemorySticks -eq 2 -and $f.MemorySlots -eq 4 -and $f.Maker -eq 'Micro-Star International' -and $f.Model -eq 'Cyborg 15 A13VF' -and
    $f.Windows -eq 'Windows 11 Home' -and $f.WindowsVersion -eq '25H2' -and $f.WindowsBuild -eq '26200.9457' -and
    @($f.Screens) -join ';' -eq '1920 x 1080, 144 Hz' -and $f.PowerPlan -eq 'Balanced'
}
Test-Case 'memory slots come from the board, never worked out from the sticks' {
    $none = New-TestFacts -Arrays @()
    $wrong = New-TestFacts -Arrays @([pscustomobject]@{ Use = 3; MemoryDevices = 1 })          # fewer slots than sticks: contradicts itself
    $flash = New-TestFacts -Arrays @([pscustomobject]@{ Use = 4; MemoryDevices = 8 })          # not system memory
    $two = New-TestFacts -Arrays @([pscustomobject]@{ Use = 3; MemoryDevices = 2 }, [pscustomobject]@{ Use = 3; MemoryDevices = 2 })
    $null -eq $none.MemorySlots -and $none.MemorySticks -eq 2 -and $null -eq $wrong.MemorySlots -and
    $null -eq $flash.MemorySlots -and $two.MemorySlots -eq 4
}
Test-Case 'sticks that disagree give no type or speed, rather than one of them' {
    $mixed = New-TestFacts -Sticks @([pscustomobject]@{ Capacity = 8GB; SMBIOSMemoryType = 34; ConfiguredClockSpeed = 4800 }, [pscustomobject]@{ Capacity = 8GB; SMBIOSMemoryType = 26; ConfiguredClockSpeed = 3200 })
    $unknown = New-TestFacts -Sticks @([pscustomobject]@{ Capacity = 8GB; SMBIOSMemoryType = 0; ConfiguredClockSpeed = 0 })
    $noSticks = New-TestFacts -Sticks @([pscustomobject]@{ Capacity = 0 })
    $null -eq $mixed.MemoryType -and $null -eq $mixed.MemorySpeedMTs -and $mixed.MemorySticks -eq 2 -and
    $null -eq $unknown.MemoryType -and $null -eq $unknown.MemorySpeedMTs -and
    $null -eq $noSticks.MemorySticks -and $null -eq $noSticks.MemoryType
}
Test-Case 'placeholder maker names, missing screens and a default refresh rate are left out' {
    $f = New-TestFacts -System ([pscustomobject]@{ Manufacturer = 'To Be Filled By O.E.M.'; Model = 'System Product Name' }) `
        -Video @([pscustomobject]@{ CurrentHorizontalResolution = $null; CurrentVerticalResolution = $null; CurrentRefreshRate = $null },
                 [pscustomobject]@{ CurrentHorizontalResolution = 2560; CurrentVerticalResolution = 1440; CurrentRefreshRate = 1 })
    $null -eq $f.Maker -and $null -eq $f.Model -and @($f.Screens) -join ';' -eq '2560 x 1440' -and $null -eq $f.PowerPlan
}
Test-Case 'the power plan is named by Windows'' own plans, whatever language powercfg speaks' {
    $de = ConvertFrom-QpPowerCfg 'GUID des Energieschemas: 381b4222-f694-41f0-9685-ff5bb260df2e  (Ausbalanciert)'
    $own = ConvertFrom-QpPowerCfg 'Power Scheme GUID: 11111111-2222-3333-4444-555555555555  (Gaming boost)'
    $de.Name -eq 'Balanced' -and $own.Name -eq 'Gaming boost' -and $null -eq (ConvertFrom-QpPowerCfg 'nothing useful here')
}
Test-Case 'this PC''s facts are read without a zero anywhere' {
    $f = Get-QpSystemFacts
    $numbers = @($f.Cores, $f.Threads, $f.MemorySpeedMTs, $f.MemorySticks, $f.MemorySlots)
    @($numbers | Where-Object { $null -ne $_ -and $_ -le 0 }).Count -eq 0 -and $f.PSObject.Properties.Name -contains 'PowerPlan'
}

function New-TestCard($Desc, $Medium, [bool]$Hardware = $true, [bool]$Virtual = $false, [string]$Status = 'Up') {
    [pscustomobject]@{ InterfaceDescription = $Desc; NdisPhysicalMedium = $Medium; HardwareInterface = $Hardware; Virtual = $Virtual; Status = $Status }
}
Test-Case 'only real Wi-Fi and wired cards are counted, so no traffic is counted twice' {
    $cards = @(
        (New-TestCard 'Intel(R) Wi-Fi 6E AX211 160MHz' 9),
        (New-TestCard 'Realtek PCIe GbE Family Controller' 14 -Status 'Disconnected'),
        (New-TestCard 'Hyper-V Virtual Ethernet Adapter' 0 $false),
        (New-TestCard 'Hyper-V Virtual Ethernet Adapter #2' 14 $false $true),     # WSL's switch, on the same traffic
        (New-TestCard 'TAP-Windows Adapter V9' 14 $true),                           # a VPN that claims to be hardware
        (New-TestCard 'WireGuard Tunnel' 14 $true),
        (New-TestCard 'Bluetooth Device (Personal Area Network)' 10),
        (New-TestCard 'Microsoft Wi-Fi Direct Virtual Adapter' 9 $false),
        (New-TestCard 'Intel(R) Ethernet I219-V #2' 14)                             # real, but the counters don't list it
    )
    $instances = @('Intel[R] Wi-Fi 6E AX211 160MHz', 'Realtek PCIe GbE Family Controller', 'Hyper-V Virtual Ethernet Adapter', 'Hyper-V Virtual Ethernet Adapter _2', 'TAP-Windows Adapter V9', 'WireGuard Tunnel')
    $picked = @(Select-QpNetworkCards -Adapters $cards -Instances $instances)
    $picked.Count -eq 2 -and ($picked | Where-Object Kind -eq 'Wi-Fi').Instance -eq 'Intel[R] Wi-Fi 6E AX211 160MHz' -and
    ($picked | Where-Object Kind -eq 'Wired').Up -eq $false -and (ConvertTo-QpCounterInstance 'Intel(R) Ethernet I219-V #2') -eq 'Intel[R] Ethernet I219-V _2'
}
Test-Case 'network speed adds up connected cards of a kind, and says nothing it was not told' {
    $fake = { param($v) $o = [pscustomobject]@{ V = $v }; $o | Add-Member -MemberType ScriptMethod -Name NextValue -Value { $this.V }; $o }
    $m = [pscustomobject]@{ NetAt = (Get-Date); Net = @(
        [pscustomobject]@{ Kind = 'Wi-Fi'; Instance = 'a'; Up = $true; Received = (& $fake 1000); Sent = (& $fake 10) },
        [pscustomobject]@{ Kind = 'Wi-Fi'; Instance = 'b'; Up = $true; Received = (& $fake 500); Sent = (& $fake 5) },
        [pscustomobject]@{ Kind = 'Wired'; Instance = 'c'; Up = $false; Received = (& $fake 99999); Sent = (& $fake 99999) }) }
    $r = @(Get-QpNetRates -Monitor $m)
    $m.Net = @(); $none = Get-QpNetRates -Monitor $m
    $m.Net = $null; $unknown = Get-QpNetRates -Monitor $m
    $r.Count -eq 1 -and $r[0].Kind -eq 'Wi-Fi' -and $r[0].DownBps -eq 1500 -and $r[0].UpBps -eq 15 -and
    $none -is [array] -and $none.Count -eq 0 -and $null -eq $unknown
}
Test-Case 'drive and network speeds are Windows'' per-second rates, never running totals' {
    $m = New-QpLiveMonitor
    $rates = @($m.DiskRead, $m.DiskWrite) + @($m.Net | ForEach-Object { $_.Received; $_.Sent }) | Where-Object { $_ }
    $types = @($rates | ForEach-Object { [string]$_.CounterType } | Select-Object -Unique)
    # A PC without the counters simply has none; one with them must have only per-second kinds.
    @($types | Where-Object { $_ -notmatch '^RateOfCountsPerSecond(32|64)$' }).Count -eq 0
}
Test-Case 'a speed never rounds a trickle down to nothing, and nothing stays nothing' {
    (Format-QpRate 541) -eq '541 B/s' -and (Format-QpRate 0) -eq '0 B/s' -and (Format-QpRate 2048) -eq '2.0 KB/s' -and
    (Format-QpRate (15.8 * 1MB)) -eq '15.8 MB/s' -and $null -eq (Format-QpRate $null)
}
Test-Case 'the graphics clock, memory clock and fan come back as the driver said, or empty - never zero' {
    $m = New-QpLiveMonitor
    Start-Sleep -Milliseconds 300
    $r = Get-QpLiveReading -Monitor $m
    $bad = @($r.Gpus | Where-Object { ($null -ne $_.EngineClockMhz -and $_.EngineClockMhz -le 0) -or ($null -ne $_.MemoryClockMhz -and $_.MemoryClockMhz -le 0) -or ($null -ne $_.FanRpm -and $_.FanRpm -lt 0) })
    $shape = @($r.Gpus | Where-Object { $_.PSObject.Properties.Name -notcontains 'EngineClockMhz' -or $_.PSObject.Properties.Name -notcontains 'FanRpm' })
    $bad.Count -eq 0 -and $shape.Count -eq 0 -and ($null -eq $r.DiskReadBps -or $r.DiskReadBps -ge 0) -and
    ($null -eq $r.Network -or $r.Network -is [array])
}
Test-Case 'the graphics driver is still only asked questions: no new native calls anywhere' {
    # Every native call in the engine, by name. A new one - of any kind, from any DLL - fails this.
    $src = Get-Content (Join-Path $root 'src\Quietpane.psm1') -Raw
    $calls = @([regex]::Matches($src, 'DllImport\("([\w.]+)"[^\]]*\]\s*(?:public\s+|internal\s+|private\s+)?static\s+extern\s+\w+\s+(\w+)') | ForEach-Object { $_.Groups[1].Value.ToLower() + '!' + $_.Groups[2].Value } | Sort-Object)
    ($calls -join ';') -eq 'gdi32.dll!D3DKMTCloseAdapter;gdi32.dll!D3DKMTEnumAdapters2;gdi32.dll!D3DKMTQueryAdapterInfo;kernel32.dll!CloseHandle;kernel32.dll!CreateFileW;kernel32.dll!DeviceIoControl' -and
    [regex]::Matches($src, 'DllImport').Count -eq 6
}
Test-Case 'a temperature is written in the unit chosen, and thresholds stay in Celsius' {
    $deg = [char]0x00B0
    (Format-QpTemp 47 -Unit C) -eq "47${deg}C" -and (Format-QpTemp 47 -Unit F) -eq "117${deg}F" -and
    (Format-QpTemp 100 -Unit F) -eq "212${deg}F" -and (Format-QpTemp 0 -Unit F) -eq "32${deg}F" -and
    (Format-QpTemp -40 -Unit F) -eq "-40${deg}F" -and $null -eq (Format-QpTemp $null -Unit F) -and
    (Get-QpHeatWord -Celsius 90).Level -eq 'warn'
}
Test-Case 'the unit is remembered in one small file, and anything odd in it means Celsius' {
    $f = Join-Path $env:TEMP ('qp-unit-' + [guid]::NewGuid().ToString('N') + '\temperature.txt')
    try {
        $missing = Get-QpTempUnit -Path $f
        $wrote = Set-QpTempUnit -Unit F -Path $f
        $f1 = Get-QpTempUnit -Path $f
        $content = [IO.File]::ReadAllText($f)
        [IO.File]::WriteAllText($f, 'Kelvin please')
        $odd = Get-QpTempUnit -Path $f
        $missing -eq 'C' -and $wrote -eq $true -and $f1 -eq 'F' -and $content -eq 'F' -and $odd -eq 'C'
    } finally { Remove-Item -LiteralPath (Split-Path $f) -Recurse -Force -ErrorAction SilentlyContinue }   # the test's own temporary folder
}
Test-Case 'a unit that cannot be saved says so, so Settings never shows a choice that did not stick' {
    # A path under a file, which cannot be a folder: the write fails and the answer is $false.
    $file = Join-Path $env:TEMP ('qp-unitfile-' + [guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($file, 'x')
    try { (Set-QpTempUnit -Unit F -Path (Join-Path $file 'temperature.txt')) -eq $false }
    finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }   # the test's own temporary file
}

Section 'Updates, without a connection'
# Made-up downloads in a temporary folder: never the real Downloads folder, never the network.
$updDir = Join-Path $env:TEMP ('qp-upd-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $updDir | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
function New-TestDownload {
    param([string]$Name, [string]$Version, [switch]$NoWindow, [switch]$Escapes, [switch]$Marked)
    $src = Join-Path $updDir ('s-' + [guid]::NewGuid().ToString('N'))
    $app = Join-Path $src 'Quietpane\App files - no need to open'
    New-Item -ItemType Directory -Path (Join-Path $app 'src') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $app 'src\Quietpane.psm1') -Value ("# engine`r`n`$script:AppVersion  = '$Version'`r`n`$script:AppReleased = '2027-01-02'")
    if (-not $NoWindow) { Set-Content -LiteralPath (Join-Path $app 'Quietpane.ps1') -Value '# window' }
    Set-Content -LiteralPath (Join-Path $src 'Quietpane\Start Quietpane.cmd') -Value '@echo off'
    $zip = Join-Path $updDir $Name
    [IO.Compression.ZipFile]::CreateFromDirectory($src, $zip)
    Remove-Item -LiteralPath $src -Recurse -Force
    if ($Escapes) {
        $a = [IO.Compression.ZipFile]::Open($zip, 'Update')
        $w = New-Object IO.StreamWriter(($a.CreateEntry('../outside.txt')).Open()); $w.Write('x'); $w.Dispose(); $a.Dispose()
    }
    if ($Marked) { Set-Content -LiteralPath $zip -Stream 'Zone.Identifier' -Value "[ZoneTransfer]`r`nZoneId=3`r`nHostUrl=https://github.com/" }
    $zip
}
$zNew = New-TestDownload 'Quietpane.zip' '99.1.0' -Marked
$zOld = New-TestDownload 'Quietpane (1).zip' '0.9.0'
$zHalf = New-TestDownload 'Quietpane (2).zip' '99.9.0' -NoWindow
$zEvil = New-TestDownload 'Quietpane (3).zip' '99.8.0' -Escapes
Test-Case 'which Quietpane is in a ZIP is read from inside it, without unpacking anything' {
    $z = Get-QpZipVersion -Path $zNew
    $z.Version -eq '99.1.0' -and $z.Released -eq '2027-01-02' -and
    @(Get-ChildItem -LiteralPath $updDir -Directory).Count -eq 0
}
Test-Case 'a ZIP without both halves of Quietpane is not taken for one' {
    $null -eq (Get-QpZipVersion -Path $zHalf)
}
Test-Case 'a ZIP that names a path outside itself is never offered' {
    $null -eq (Get-QpZipVersion -Path $zEvil)
}
Test-Case 'only the newest download newer than this one is offered, and only files named Quietpane' {
    Set-Content -LiteralPath (Join-Path $updDir 'Holiday photos.zip') -Value 'not a zip'
    $f = Find-QpDownloadedUpdate -Folder $updDir -Current '1.22.0'
    $none = Find-QpDownloadedUpdate -Folder $updDir -Current '100.0.0'
    $f.Version -eq '99.1.0' -and $f.Name -eq 'Quietpane.zip' -and $null -eq $none
}
Test-Case 'an older or same version is refused, not installed' {
    $older = try { Expand-QpUpdate -Zip $zOld -Current '1.22.0' | Out-Null; $false } catch { $_.Exception.Message -match 'not newer' }
    $same = try { Expand-QpUpdate -Zip $zNew -Current '99.1.0' | Out-Null; $false } catch { $_.Exception.Message -match 'not newer' }
    $older -and $same
}
Test-Case 'unpacking keeps Windows'' downloaded-from-the-internet mark on every file' {
    # Without it SmartScreen would no longer look at the new version before it runs.
    $x = Expand-QpUpdate -Zip $zNew -Current '1.22.0'
    $files = @(Get-ChildItem -LiteralPath $x.Folder -Recurse -File)
    $marked = @($files | Where-Object { try { (Get-Content -LiteralPath $_.FullName -Stream 'Zone.Identifier' -Raw -ErrorAction Stop) -match 'ZoneId=3' } catch { $false } })
    $x.Marked -and $files.Count -ge 3 -and $marked.Count -eq $files.Count -and (Split-Path $x.Start -Leaf) -eq 'Start Quietpane.cmd' -and
        (Split-Path $x.Folder -Leaf) -eq 'Quietpane 99.1.0'
}
Test-Case 'installing the same download twice reuses what was unpacked' {
    $x = Expand-QpUpdate -Zip $zNew -Current '1.22.0'
    $x.Reused -and @(Get-ChildItem -LiteralPath $updDir -Directory -Filter 'Quietpane 99.1.0*').Count -eq 1
}
Test-Case 'nothing is ever written outside the update''s own folder' {
    $refused = try { Expand-QpUpdate -Zip $zEvil -Current '1.22.0' | Out-Null; $false } catch { $true }
    $refused -and -not (Test-Path (Join-Path (Split-Path $updDir) 'outside.txt'))
}
Test-Case 'an old folder opens the newer installed copy - and that copy never sends itself anywhere' {
    $install = Join-Path $updDir 'Program Files copy'
    New-Item -ItemType Directory -Path (Join-Path $install 'src') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $install 'src\Quietpane.psm1') -Value "`$script:AppVersion  = '99.2.0'"
    Set-Content -LiteralPath (Join-Path $install 'Quietpane.ps1') -Value '# window'
    $fromOld = Get-QpNewerInstalledCopy -Running (Join-Path $updDir 'old folder') -InstallRoot $install -Current '1.22.0'
    $fromItself = Get-QpNewerInstalledCopy -Running $install -InstallRoot $install -Current '1.22.0'
    $fromNewer = Get-QpNewerInstalledCopy -Running (Join-Path $updDir 'old folder') -InstallRoot $install -Current '99.3.0'
    $fromOld.Version -eq '99.2.0' -and $null -eq $fromItself -and $null -eq $fromNewer
}
Remove-Item -LiteralPath $updDir -Recurse -Force -ErrorAction SilentlyContinue
Test-Case 'a downloaded update is started the way a double-click starts it, never with this window''s rights' {
    # Starting it from the elevated window would give whatever was in the ZIP administrator rights with
    # nobody asked. It must go through Open-AsUser (Explorer, as the signed-in user).
    $src = Get-Content (Join-Path $root 'Quietpane.ps1') -Raw
    $body = [regex]::Match($src, '(?s)function Install-QuietpaneUpdate.*?\n}\r?\n').Value
    $body -match 'Open-AsUser \$x\.Start' -and $body -notmatch 'Start-Process' -and $body -match 'ReleaseMutex'
}
Test-Case 'looking for a newer version says it opens the browser, and only then does' {
    $src = Get-Content (Join-Path $root 'Quietpane.ps1') -Raw
    $body = [regex]::Match($src, '(?s)function Open-ReleasePage.*?\n}\r?\n').Value
    $body -match 'Show-ChoiceDialog' -and $body -match "doesn't connect to anything" -and $body -match "if \(\`$choice -eq 'open'\) \{ Open-AsUser" -and
        $body -match '/releases/latest'
}
Test-Case 'the About line and the Home offer draw from a made-up Downloads folder' {
    $cardsOut -match 'updates: offered: True; older ignored: True; version line: True'
}
Test-Case 'every launcher explains a PC that only runs signed apps, instead of failing silently' {
    $files = @('Start Quietpane.cmd', 'Safety scan only.cmd', 'tools\release\Start Quietpane.cmd', 'tools\release\Safety scan only.cmd')
    @($files | Where-Object {
        $c = Get-Content (Join-Path $root $_) -Raw
        $c -match '\$ExecutionContext\.SessionState\.LanguageMode' -and $c -match 'if /i not "%QPMODE%"=="FullLanguage" goto restricted' -and
            $c -match "don't switch Smart App Control off" -and $c -match ':restricted'
    }).Count -eq 4
}

Section 'Keyboards and screen readers'
$selfTestOut = & powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File (Join-Path $root 'Quietpane.ps1') -SelfTest 2>&1 | Out-String
Test-Case 'every control you can reach with the keyboard has a name a screen reader can say' {
    $selfTestOut -match 'unnamed controls: 0 ' -and $selfTestOut -match 'window built OK'
}
Test-Case 'the taskbar badge for things that came back draws, and clears again' {
    $selfTestOut -match 'badge: OK'
}
Test-Case 'the newer accessibility features are switched on before the window''s code loads' {
    # Too late once WPF is loaded, so the order in the file is what matters.
    $src = Get-Content (Join-Path $root 'Quietpane.ps1') -Raw
    $switchAt = $src.IndexOf("'Switch.UseLegacyAccessibilityFeatures'")
    $switchAt -gt 0 -and $switchAt -lt $src.IndexOf('Add-Type -AssemblyName PresentationFramework') -and
    $src -match 'Switch\.UseLegacyAccessibilityFeatures\.3' -and $src -match 'AutomationProperties\.LiveSetting="Polite"'
}
Test-Case 'all text is dark enough to read (WCAG AA, 4.5 to 1)' {
    # Every colour the window uses for text on its cream background, and white on every severity badge.
    function Get-Lum([string]$Hex) {
        $c = @(1, 3, 5 | ForEach-Object { [Convert]::ToInt32($Hex.Substring($_, 2), 16) / 255.0 } |
            ForEach-Object { if ($_ -le 0.03928) { $_ / 12.92 } else { [math]::Pow(($_ + 0.055) / 1.055, 2.4) } })
        0.2126 * $c[0] + 0.7152 * $c[1] + 0.0722 * $c[2]
    }
    function Get-Contrast([string]$A, [string]$B) { $x = Get-Lum $A; $y = Get-Lum $B; ([math]::Max($x, $y) + 0.05) / ([math]::Min($x, $y) + 0.05) }
    $src = Get-Content (Join-Path $root 'Quietpane.ps1') -Raw
    $onCream = @([regex]::Matches($src, "New-Text [^\r\n]*?'(#[0-9A-Fa-f]{6})'") | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -ne '#FFFDF8' } | Sort-Object -Unique)
    $tooLight = @($onCream | Where-Object { (Get-Contrast $_ '#FAF6EC') -lt 4.5 })
    $badges = @([regex]::Match($src, 'SevColours = \[ordered\]@\{([^}]+)\}').Groups[1].Value -split ';' | ForEach-Object { if ($_ -match "'(#[0-9A-Fa-f]{6})'") { $matches[1] } })
    $weakBadges = @($badges | Where-Object { (Get-Contrast '#FFFDF8' $_) -lt 4.5 })
    $onCream.Count -gt 3 -and $badges.Count -eq 5 -and $tooLight.Count -eq 0 -and $weakBadges.Count -eq 0
}
Test-Case 'in the dark as well: every text colour and every badge still reads (WCAG AA, 4.5 to 1)' {
    # The same text colours as above, turned into their dark partners, on both dark surfaces - the window
    # and the cards - plus the heat words, and the severity badges the other way round (dark text on a
    # bright badge). And every colour the window uses must have a dark partner at all, or it would stay
    # light on a dark window.
    function Get-Lum([string]$Hex) {
        $c = @(1, 3, 5 | ForEach-Object { [Convert]::ToInt32($Hex.Substring($_, 2), 16) / 255.0 } |
            ForEach-Object { if ($_ -le 0.03928) { $_ / 12.92 } else { [math]::Pow(($_ + 0.055) / 1.055, 2.4) } })
        0.2126 * $c[0] + 0.7152 * $c[1] + 0.0722 * $c[2]
    }
    function Get-Contrast([string]$A, [string]$B) { $x = Get-Lum $A; $y = Get-Lum $B; ([math]::Max($x, $y) + 0.05) / ([math]::Min($x, $y) + 0.05) }
    $src = Get-Content (Join-Path $root 'Quietpane.ps1') -Raw
    $dark = @{}
    foreach ($m in [regex]::Matches($src, "'([^']+)' = @\{ Light = '(#[0-9A-F]{6})'; Dark = '(#[0-9A-F]{6})' \}")) { $dark[$m.Groups[1].Value.ToUpperInvariant()] = $m.Groups[3].Value }
    $window = $dark['#FAF6EC']; $card = $dark['#FFFDF8']
    $text = @([regex]::Matches($src, "New-Text [^\r\n]*?'(#[0-9A-Fa-f]{6})'") | ForEach-Object { $_.Groups[1].Value.ToUpperInvariant() } | Where-Object { $_ -ne '#FFFDF8' })
    $heat = @([regex]::Match($src, 'HeatColours = @\{([^}]+)\}').Groups[1].Value -split ';' | ForEach-Object { if ($_ -match "'(#[0-9A-Fa-f]{6})'") { $matches[1].ToUpperInvariant() } })
    $all = @($text + $heat | Sort-Object -Unique)
    $weak = @(foreach ($c in $all) { foreach ($s in $window, $card) { if (-not $dark[$c] -or (Get-Contrast $dark[$c] $s) -lt 4.5) { '{0} on {1}' -f $c, $s } } })
    $badges = @([regex]::Match($src, 'SevColours = \[ordered\]@\{([^}]+)\}').Groups[1].Value -split ';' | ForEach-Object { if ($_ -match "'(#[0-9A-Fa-f]{6})'") { $matches[1] } })
    $weakBadges = @($badges | Where-Object { (Get-Contrast $card $dark[$_.ToUpperInvariant()]) -lt 4.5 })
    $used = @($src -split "`n" | Where-Object { $_ -notmatch '= @\{ Light = ' } | ForEach-Object { [regex]::Matches($_, '#[0-9A-Fa-f]{6}\b') | ForEach-Object { $_.Value.ToUpperInvariant() } } | Sort-Object -Unique)
    $orphans = @($used | Where-Object { -not $dark.ContainsKey($_) })
    if ($weak.Count -or $weakBadges.Count -or $orphans.Count) { Write-Host ('        weak: {0} | badges: {1} | no dark partner: {2}' -f ($weak -join ', '), ($weakBadges -join ', '), ($orphans -join ', ')) }
    $window -and $card -and $all.Count -gt 5 -and $badges.Count -eq 5 -and $weak.Count -eq 0 -and $weakBadges.Count -eq 0 -and $orphans.Count -eq 0
}
Test-Case 'the choice dialog closes with Esc and starts on the safest choice' {
    $src = Get-Content (Join-Path $root 'Quietpane.ps1') -Raw
    $src -match "Key -eq 'Escape'" -and $src -match 'firstChoice\.Focus\(\)'
}

Section 'When things go wrong'
Test-Case 'the window still draws on a PC with nothing on it, and says what could not be read' {
    # Every list empty, and one part reported as unreadable: nothing may be left blank or throw, and
    # every control on the empty screens still has a name.
    $env:QP_EMPTYSTATE = '1'
    try {
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File (Join-Path $root 'Quietpane.ps1') -SelfTest 2>&1 | Out-String
    } finally { Remove-Item Env:\QP_EMPTYSTATE -ErrorAction SilentlyContinue }
    $out -match 'empty state drawn OK' -and $out -match 'could not be read' -and $out -match 'unnamed controls: 0 ' -and $out -notmatch 'Exception|ParserError'
}
Test-Case 'a part of the read that fails does not take the rest with it' {
    $s = Get-QpState
    # Problems is always there, and everything else still comes back in its usual shape.
    $null -ne $s.Problems -and $s.Privacy -is [hashtable] -and $null -ne $s.Devices
}
Test-Case 'one job at a time is enforced in the window, not left to chance' {
    $src = Get-Content (Join-Path $root 'Quietpane.ps1') -Raw
    # Every action that asks a question first has to check nothing else is running, or it would ask
    # and then quietly do nothing.
    $src -match 'function Test-Busy' -and
    @([regex]::Matches($src, 'if \(Test-Busy\) \{ return \}')).Count -ge 6 -and
    $src -match 'add_UnhandledException'
}

Section 'The checks a person has to do by hand'
Test-Case 'the manual test pages are written down, including the AMTSO ones' {
    $doc = Join-Path $root 'docs\manual-checks.md'
    if (-not (Test-Path $doc)) { return $false }
    $text = Get-Content $doc -Raw
    $text -match 'AMTSO' -and $text -match 'amtso\.org' -and $text -match 'EICAR'
}
Test-Case 'the app itself never downloads a test file' {
    # AMTSO checks are done in a browser on purpose: Quietpane makes no network requests at all.
    $lines = @(Get-Content (Join-Path $root 'src\Quietpane.psm1')) + @(Get-Content (Join-Path $root 'Quietpane.ps1')) |
        Where-Object { $_ -notmatch '\$suspicious(Cmd|Task)\s*=' }   # those two lines are what a scan looks FOR
    [regex]::Matches(($lines -join "`n"), '(?i)Invoke-WebRequest|Invoke-RestMethod|DownloadFile|DownloadString|WebClient|HttpClient').Count -eq 0
}

Section 'With the real antivirus (needs -Live and administrator rights)'
if (-not $Live) {
    Write-Host '  SKIP  EICAR detection (run with -Live to include it)' -ForegroundColor DarkGray
    $script:Skip++
} else {
    Test-Case 'Defender detects the EICAR test file and Quietpane calls it Info, not malware' {
        $dir = Join-Path $env:TEMP ('qp-eicar-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        try {
            # assembled here so the test string is never stored in the repository
            $eicar = 'X5O!P%@AP[4\PZX54(P^)7CC)7}$' + 'EICAR-STANDARD-ANTIVIRUS-TEST-FILE' + '!$H+H*'
            [IO.File]::WriteAllText((Join-Path $dir 'qp-test.com'), $eicar)
            $r = Invoke-QpThreatScan -Type Custom -Path $dir
            $hit = @($r.Findings | Where-Object { $_.Path -like "$dir*" }) | Select-Object -First 1
            $null -ne $hit -and $hit.Severity -eq 'Info' -and $hit.Source -eq 'Microsoft Defender' -and $hit.Family -eq 'EICAR test file'
        } finally {
            Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host ("`n{0} passed, {1} failed, {2} skipped" -f $script:Pass, $script:Fail, $script:Skip) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
