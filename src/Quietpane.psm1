# ============================================================================
#  LOOKING FOR HOW TO START Quietpane?  This file is the app's code.
#  Close this window, then double-click "Start Quietpane" instead.
# ============================================================================
#Requires -Version 5.1
<#
    Quietpane - core engine.
    Developed by KomodoWorks - https://www.komodoworks.com - MIT License.

    Principles
      * Scan is read-only.
      * Every change is recorded in a restore point (%ProgramData%\Quietpane\restore\...) and can be undone.
      * Tidying up only ever moves files to the Recycle Bin. The single exception is a threat the
        user chooses to delete for good, which is confirmed twice and written to the audit log.
      * Quarantined files are moved, never altered, and can be restored byte-for-byte.
      * Other programs' scheduled tasks are disabled, never deleted. (Quietpane's own sign-in task,
        which you switch on in About, goes completely when you switch it off.)
      * Security (Defender, SmartScreen, firewall) and Windows Update are never touched.
      * No network requests, no telemetry, no data collection. Everything stays on this PC.
#>

$script:AppVersion  = '1.22.0'
$script:AppReleased = '2026-09-30'   # the day this version was published; bumped with the version
$script:Brand       = @{ Name = 'KomodoWorks'; Url = 'https://www.komodoworks.com'; Email = 'info@komodoworks.com'; Repo = 'https://github.com/kgntmr/quietpane' }
$script:AssetsRoot  = Join-Path (Split-Path $PSScriptRoot -Parent) 'assets'
$script:LogSink     = $null
$script:LogFile     = $null
$script:ProgressSink = $null      # where "where the check has got to" is sent, if anyone is listening
$script:CancelCheck = $null       # how the engine asks whether the user has pressed Stop
$script:Session     = $null
$script:CatalogRoot = Join-Path $PSScriptRoot 'catalog'
$script:DataRoot    = Join-Path $env:ProgramData 'Quietpane'
# Restore points made before the app was renamed (it used to be called Clean My PC).
# New ones go to the folder above; old ones stay readable so Undo keeps working.
$script:LegacyDataRoot = Join-Path $env:ProgramData 'CleanMyPC'
$script:HostsPath   = Join-Path $env:WINDIR 'System32\drivers\etc\hosts'
$script:ComputerMaker = $null      # filled in once, when brand software is looked for
$script:GpuNames = $null
$script:InstalledPrograms = $null

# Apps that are never removed, even if someone adds them to the catalog.
$script:ProtectedAppPattern = '^(Microsoft\.WindowsStore|Microsoft\.StorePurchaseApp|Microsoft\.DesktopAppInstaller|Microsoft\.SecHealthUI|Microsoft\.Windows\.Photos|Microsoft\.WindowsCamera|Microsoft\.WindowsCalculator|Microsoft\.WindowsNotepad|Microsoft\.Paint|Microsoft\.ScreenSketch|Microsoft\.WindowsTerminal|Microsoft\.Winget\.Source|Microsoft\.VCLibs.*|Microsoft\.NET\..*|Microsoft\.UI\.Xaml.*|Microsoft\.WindowsAppRuntime.*|MicrosoftCorporationII\.WinAppRuntime.*|Microsoft\.Services\.Store.*|Microsoft\..*Extension[s]?|Microsoft\.LanguageExperiencePack.*|NVIDIACorp\..*|RealtekSemiconductorCorp\..*|AppUp\.Intel.*|Microsoft\.MicrosoftEdge\.Stable|Microsoft\.MicrosoftEdgeDevToolsClient)$'

#region ---------------------------------------------------------------- helpers

function Get-QpInfo {
    [pscustomobject]@{
        Version    = $script:AppVersion
        Released   = $script:AppReleased
        BrandName  = $script:Brand.Name
        BrandUrl   = $script:Brand.Url
        BrandEmail = $script:Brand.Email
        RepoUrl    = $script:Brand.Repo
        LogoPath   = Join-Path $script:AssetsRoot 'komodoworks-logo.png'
        IconPath   = Join-Path $script:AssetsRoot 'quietpane.ico'
        AppId      = $script:AppUserModelId
        DataRoot   = $script:DataRoot
    }
}

function Set-QpLogSink {
    param([scriptblock]$Sink)
    $script:LogSink = $Sink
}

function Write-QpLog {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'PREVIEW', 'SKIP', 'STEP')][string]$Level = 'INFO'
    )
    $line = '[{0}] {1,-7} {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    if ($script:LogFile) { try { Add-Content -Path $script:LogFile -Value $line -Encoding UTF8 } catch { } }
    if ($script:LogSink) { & $script:LogSink $line } else { Write-Host $line }
}

function Set-QpProgressSink {
    <# Where the engine says how far along it is. Purely for show - it changes nothing. #>
    param([scriptblock]$Sink)
    $script:ProgressSink = $Sink
}

function Write-QpProgress {
    <# One update: which step, what is being looked at, how much has been looked at so far. #>
    param(
        [string]$Stage = '', [int]$Step = 0, [int]$Of = 0,
        [string]$Object = '', [int]$Scanned = 0, [int]$Found = 0
    )
    if (-not $script:ProgressSink) { return }
    # A progress update must never be able to break a check, so it is never allowed to throw.
    try {
        & $script:ProgressSink ([pscustomobject]@{
            Stage = $Stage; Step = $Step; Of = $Of; Object = $Object
            Scanned = $Scanned; Found = $Found; At = (Get-Date)
        })
    } catch { }
}

function Set-QpCancelCheck {
    <#
        Gives the engine a way to ask "has the user pressed Stop?". It is polled between steps, so a
        check always stops at a safe point - never half way through writing anything.
    #>
    param([scriptblock]$Check)
    $script:CancelCheck = $Check
}

function Test-QpCancelled {
    if (-not $script:CancelCheck) { return $false }
    try { return [bool](& $script:CancelCheck) } catch { return $false }
}

function Test-QpAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

$script:CatalogCache = @{}
function Get-QpCatalog {
    <# A catalog file, parsed once and remembered. It is read again only if the file itself changes. #>
    param([ValidateSet('privacy', 'apps', 'cleanup', 'vendors', 'threats', 'startup', 'network', 'extensions')][string]$Name)
    $path = Join-Path $script:CatalogRoot "$Name.psd1"
    $stamp = (Get-Item -LiteralPath $path).LastWriteTimeUtc.Ticks
    $hit = $script:CatalogCache[$Name]
    if ($hit -and $hit.Stamp -eq $stamp) { return $hit.Data }
    $data = Import-PowerShellDataFile -Path $path
    $script:CatalogCache[$Name] = @{ Stamp = $stamp; Data = $data }
    return $data
}

# While the window reads the PC's state, slow lookups are made once and shared, instead of once per
# setting. Outside a read (when something is actually being changed) everything is asked fresh.
$script:StateCache = $null
function Start-QpStateCache { $script:StateCache = @{} }
function Stop-QpStateCache { $script:StateCache = $null }

# Task Scheduler, asked directly. Get-ScheduledTask goes through WMI and takes about a second even for
# one task; asking Task Scheduler itself gives the same answers in a few milliseconds. Only reading
# goes this way - changes still use the ScheduledTasks cmdlets.
$script:TaskService = $null
$script:TaskStates = @{ 0 = 'Unknown'; 1 = 'Disabled'; 2 = 'Queued'; 3 = 'Ready'; 4 = 'Running' }
function Get-QpTaskService {
    if (-not $script:TaskService) {
        $svc = New-Object -ComObject Schedule.Service
        $svc.Connect()
        $script:TaskService = $svc
    }
    return $script:TaskService
}

function Get-QpTasksByPath {
    # Every scheduled task in one pass, grouped by folder the way Get-ScheduledTask names them ("\Microsoft\Windows\X\").
    if ($script:StateCache -and $script:StateCache.ContainsKey('Tasks')) { return $script:StateCache.Tasks }
    $byPath = @{}
    try {
        $folders = New-Object System.Collections.Stack
        $folders.Push((Get-QpTaskService).GetFolder('\'))
        while ($folders.Count) {
            $f = $folders.Pop()
            $path = if ($f.Path -eq '\') { '\' } else { $f.Path + '\' }
            # A folder this account may not read is skipped, as Get-ScheduledTask skips it.
            $tasks = @(); try { $tasks = @($f.GetTasks(1)) } catch { }     # 1: hidden tasks too
            foreach ($t in $tasks) {
                if (-not $byPath.ContainsKey($path)) { $byPath[$path] = New-Object System.Collections.ArrayList }
                [void]$byPath[$path].Add([pscustomobject]@{ TaskPath = $path; TaskName = [string]$t.Name; State = $script:TaskStates[[int]$t.State] })
            }
            $subs = @(); try { $subs = @($f.GetFolders(0)) } catch { }
            foreach ($s in $subs) { $folders.Push($s) }
        }
    } catch {
        # Task Scheduler can't be asked directly here, so take the slower way round.
        $byPath = @{}
        foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
            if (-not $byPath.ContainsKey($t.TaskPath)) { $byPath[$t.TaskPath] = New-Object System.Collections.ArrayList }
            [void]$byPath[$t.TaskPath].Add([pscustomobject]@{ TaskPath = $t.TaskPath; TaskName = $t.TaskName; State = [string]$t.State })
        }
    }
    if ($script:StateCache) { $script:StateCache.Tasks = $byPath }
    return $byPath
}

function Get-QpTasksMatching {
    <#
        The scheduled tasks one catalog line means: a folder - which may end in * for "every folder under
        it", as Get-ScheduledTask understands it - and a task name, which may use wildcards too. While the
        window reads the PC it uses the shared list; otherwise it asks Task Scheduler for just that folder.
    #>
    param([string]$Path, [string]$Name)
    $wild = [Management.Automation.WildcardPattern]::ContainsWildcardCharacters($Path)
    if ($script:StateCache -or $wild) {
        $byPath = Get-QpTasksByPath
        $keys = if ($wild) { @($byPath.Keys | Where-Object { $_ -like $Path }) } else { @($Path) }
        return @(foreach ($k in $keys) { foreach ($t in @($byPath[$k])) { if ($t -and $t.TaskName -like $Name) { $t } } })
    }
    try {
        $folder = (Get-QpTaskService).GetFolder($(if ($Path -eq '\') { '\' } else { $Path.TrimEnd('\') }))
        return @(foreach ($t in @($folder.GetTasks(1))) {
            if ([string]$t.Name -like $Name) { [pscustomobject]@{ TaskPath = $Path; TaskName = [string]$t.Name; State = $script:TaskStates[[int]$t.State] } }
        })
    } catch {
        $ex = $_.Exception; while ($ex.InnerException) { $ex = $ex.InnerException }
        if ($ex.HResult -in -2147024894, -2147024893) { return @() }   # no such folder on this PC
        return @(Get-ScheduledTask -TaskPath $Path -ErrorAction SilentlyContinue | Where-Object { $_.TaskName -like $Name } |
            ForEach-Object { [pscustomobject]@{ TaskPath = $_.TaskPath; TaskName = $_.TaskName; State = [string]$_.State } })
    }
}

function Get-QpAppxPackages {
    # The installed Store apps, asked for once per read.
    if ($script:StateCache -and $script:StateCache.ContainsKey('Appx')) { return $script:StateCache.Appx }
    $all = @(Get-AppxPackage -ErrorAction SilentlyContinue)
    if ($script:StateCache) { $script:StateCache.Appx = $all }
    return $all
}

function Format-QpBytes {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    return '{0:N0} KB' -f ($Bytes / 1KB)
}

function Format-QpRate {
    <# A speed, per second: small ones in bytes, so a trickle never rounds down to a zero. $null stays $null. #>
    param($BytesPerSecond)
    if ($null -eq $BytesPerSecond -or "$BytesPerSecond" -eq '') { return $null }
    $b = [math]::Max(0, [double]$BytesPerSecond)
    if ($b -lt 1KB) { return '{0:N0} B/s' -f $b }
    if ($b -lt 1MB) { return '{0:N1} KB/s' -f ($b / 1KB) }
    return (Format-QpBytes $b) + '/s'
}

function Get-QpSize {
    param([string[]]$Paths)
    $sum = 0
    foreach ($p in $Paths) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $m = Get-ChildItem -LiteralPath $p -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum
        if ($m.Sum) { $sum += $m.Sum }
    }
    return $sum
}

$script:BinLimits = @{}
function Get-QpRecycleBinLimit {
    <#
        The biggest item the Recycle Bin on that drive will take. Anything bigger, Windows deletes for
        good without asking, so Quietpane never sends it there. 0 means "don't use the bin here".
    #>
    param([string]$Path)
    try {
        $drive = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Path)).TrimEnd('\')
        if ($script:BinLimits.ContainsKey($drive)) { return $script:BinLimits[$drive] }
        $limit = [int64]0
        $policy = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer' -ErrorAction SilentlyContinue
        if (-not ($policy -and [int]$policy.NoRecycleFiles -eq 1)) {
            $vol = Get-CimInstance Win32_Volume -Filter "DriveLetter='$drive'" -ErrorAction Stop | Select-Object -First 1
            $p = $null
            if ($vol -and "$($vol.DeviceID)" -match '\{[0-9a-fA-F-]+\}') {
                $p = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\BitBucket\Volume\$($matches[0])" -ErrorAction SilentlyContinue
            }
            if ($p -and [int]$p.NukeOnDelete -eq 1) { $limit = 0 }
            elseif ($p -and $p.MaxCapacity) { $limit = [int64]$p.MaxCapacity * 1MB }
            elseif ($vol) { $limit = [int64]([double]$vol.Capacity * 0.05) }   # not set: assume a cautious 5% of the drive
        }
        $script:BinLimits[$drive] = $limit
        return $limit
    } catch { return [int64]0 }   # can't tell, so assume it can't take it
}

function Move-QpToRecycleBin {
    param([string]$Path, [int64]$SizeBytes = -1)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    Add-Type -AssemblyName Microsoft.VisualBasic
    try {
        $item = Get-Item -LiteralPath $Path -Force
        # Too big for the bin means Windows would delete it for good, silently. Leave it where it is.
        if ($SizeBytes -lt 0) { $SizeBytes = if ($item.PSIsContainer) { Get-QpSize @($item.FullName) } else { $item.Length } }
        $limit = Get-QpRecycleBinLimit $item.FullName
        if ($limit -le 0 -or $SizeBytes -gt $limit) {
            Write-QpLog ("{0} is bigger than the Recycle Bin can hold, so it was left where it is (Windows would have deleted it for good)." -f $item.Name) 'WARN'
            return $false
        }
        if ($item.PSIsContainer) {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($item.FullName, 'OnlyErrorDialogs', 'SendToRecycleBin')
        } else {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($item.FullName, 'OnlyErrorDialogs', 'SendToRecycleBin')
        }
        return $true
    } catch {
        return $false
    }
}

$script:RegHives = @{
    'HKLM' = 'LocalMachine'; 'HKEY_LOCAL_MACHINE' = 'LocalMachine'; 'HKCU' = 'CurrentUser'; 'HKEY_CURRENT_USER' = 'CurrentUser'
    'HKU' = 'Users'; 'HKEY_USERS' = 'Users'; 'HKCR' = 'ClassesRoot'; 'HKEY_CLASSES_ROOT' = 'ClassesRoot'
}
$script:RegMissing = New-Object object   # stands in for "no such value", which a real value can never be

function Get-QpRegValue {
    <#
        One registry value: whether it exists, its value exactly as stored (%TEMP% stays %TEMP%), and its
        type, so Undo can put back precisely what was there. Read through .NET, which is many times
        quicker than Get-ItemProperty over a hundred settings; anything that isn't a plain registry path
        still goes through Get-ItemProperty.
    #>
    param([string]$Path, [string]$Name)
    if ($Path -match '^(?:Microsoft\.PowerShell\.Core\\)?(?:Registry::)?(HKLM|HKCU|HKU|HKCR|HKEY_LOCAL_MACHINE|HKEY_CURRENT_USER|HKEY_USERS|HKEY_CLASSES_ROOT):?\\?(.*)$') {
        $hive = $script:RegHives[$matches[1].ToUpperInvariant()]
        $sub = $matches[2].TrimEnd('\')
        $key = $null
        try {
            $key = ([Microsoft.Win32.Registry]::$hive).OpenSubKey($sub, $false)
            if (-not $key) { return @{ Exists = $false; Value = $null; Kind = $null } }
            $valueName = if ($Name -eq '(default)') { '' } else { $Name }
            $v = $key.GetValue($valueName, $script:RegMissing, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if ([object]::ReferenceEquals($v, $script:RegMissing)) { return @{ Exists = $false; Value = $null; Kind = $null } }
            return @{ Exists = $true; Value = $v; Kind = [string]$key.GetValueKind($valueName) }
        } catch {
            return @{ Exists = $false; Value = $null; Kind = $null }
        } finally { if ($key) { $key.Close() } }
    }
    try {
        $p = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
        return @{ Exists = $true; Value = $p.$Name; Kind = $null }
    } catch {
        return @{ Exists = $false; Value = $null; Kind = $null }
    }
}

function Get-QpStamp {
    <#
        The date and time as a name for a folder or a log, always on the ordinary (Gregorian) calendar.
        Get-Date -Format follows the PC's own calendar, which on some Windows languages would date a
        restore point in another century.
    #>
    param([string]$Format = 'yyyyMMdd-HHmmss', [datetime]$When = (Get-Date))
    return $When.ToString($Format, [Globalization.CultureInfo]::InvariantCulture)
}

#endregion

function Get-QpSystemUsage {
    <# Live disk and memory figures for the Home screen. Read-only. #>
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $sysDrive = ($env:SystemDrive, 'C:')[[int][string]::IsNullOrEmpty($env:SystemDrive)]
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$sysDrive'" -ErrorAction SilentlyContinue
    $memTotal = if ($os) { [int64]$os.TotalVisibleMemorySize * 1KB } else { 0 }
    $memFree = if ($os) { [int64]$os.FreePhysicalMemory * 1KB } else { 0 }
    [pscustomobject]@{
        Drive     = $sysDrive
        DiskTotal = if ($disk) { [int64]$disk.Size } else { 0 }
        DiskFree  = if ($disk) { [int64]$disk.FreeSpace } else { 0 }
        DiskUsed  = if ($disk) { [int64]($disk.Size - $disk.FreeSpace) } else { 0 }
        MemTotal  = $memTotal
        MemFree   = $memFree
        MemUsed   = $memTotal - $memFree
    }
}

function Get-QpTotals {
    <# Running totals of what this tool has freed on this PC, so the Home screen can show progress. #>
    $file = Join-Path $script:DataRoot 'totals.json'
    $empty = [pscustomobject]@{ SpaceFreedBytes = [int64]0; MemoryFreedBytes = [int64]0; Runs = 0; LastRun = $null }
    if (-not (Test-Path $file)) { return $empty }
    try {
        $t = Get-Content $file -Raw | ConvertFrom-Json
        [pscustomobject]@{
            SpaceFreedBytes  = [int64]$t.SpaceFreedBytes
            MemoryFreedBytes = [int64]$t.MemoryFreedBytes
            Runs             = [int]$t.Runs
            LastRun          = $t.LastRun
        }
    } catch { $empty }
}

function Add-QpTotals {
    param([int64]$SpaceBytes = 0, [int64]$MemoryBytes = 0, [switch]$CountRun)
    if ($SpaceBytes -le 0 -and $MemoryBytes -le 0 -and -not $CountRun) { return }
    try {
        $t = Get-QpTotals
        $new = [pscustomobject]@{
            SpaceFreedBytes  = $t.SpaceFreedBytes + [Math]::Max(0, $SpaceBytes)
            MemoryFreedBytes = $t.MemoryFreedBytes + [Math]::Max(0, $MemoryBytes)
            Runs             = $t.Runs + [int]([bool]$CountRun)
            LastRun          = Get-QpStamp 'yyyy-MM-dd HH:mm'
        }
        if (-not (Test-Path $script:DataRoot)) { New-Item -ItemType Directory -Path $script:DataRoot -Force | Out-Null }
        $new | ConvertTo-Json | Set-Content -Path (Join-Path $script:DataRoot 'totals.json') -Encoding UTF8
    } catch { Write-QpLog "Could not record the totals: $($_.Exception.Message)" 'WARN' }
}

#region ---------------------------------------------------------------- live readings (read-only)

# Processor, graphics and memory load, plus temperatures, for the Home screen. Everything here only
# reads: Windows performance counters, Windows' own thermal sensor, and the graphics driver's own
# sensor - the same one Task Manager shows. No driver is installed, nothing is downloaded, nothing is
# written, and no reading is stored or leaves this PC.
#
# Why not the processor's own core sensors? Reading those needs a kernel driver (the kind other
# monitoring tools ship, and which Microsoft now flags as a security risk). Quietpane will not
# install one, so the processor figure comes from Windows' thermal zone and says so.

$script:GpuSensorSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

// Read-only questions to the graphics driver through gdi32.dll: the calls Task Manager uses for its
// GPU temperature and memory figures. Nothing here changes a setting or keeps a handle open.
public static class QuietpaneGpuSensors {
    [StructLayout(LayoutKind.Sequential)] struct LUID { public uint LowPart; public int HighPart; }
    [StructLayout(LayoutKind.Sequential)] struct ADAPTERINFO { public uint hAdapter; public LUID AdapterLuid; public uint NumOfSources; public int bPrecisePresentRegionsPreferred; }
    [StructLayout(LayoutKind.Sequential)] struct ENUMADAPTERS2 { public uint NumAdapters; public IntPtr pAdapters; }
    [StructLayout(LayoutKind.Sequential)] struct QUERYADAPTERINFO { public uint hAdapter; public int Type; public IntPtr pPrivateDriverData; public uint PrivateDriverDataSize; }
    [StructLayout(LayoutKind.Sequential)] struct CLOSEADAPTER { public uint hAdapter; }
    [StructLayout(LayoutKind.Sequential)] struct PERFDATA {
        public uint PhysicalAdapterIndex; public ulong MemoryFrequency; public ulong MaxMemoryFrequency; public ulong MaxMemoryFrequencyOC;
        public ulong MemoryBandwidth; public ulong PCIEBandwidth; public uint FanRPM; public uint Power; public uint Temperature; public byte PowerStateOverride; }
    [StructLayout(LayoutKind.Sequential)] struct PERFDATACAPS {
        public uint PhysicalAdapterIndex; public ulong MaxMemoryBandwidth; public ulong MaxPCIEBandwidth; public uint MaxFanRPM; public uint TemperatureMax; public uint TemperatureWarning; }
    [StructLayout(LayoutKind.Sequential)] struct NODEPERFDATA {
        public uint NodeOrdinal; public uint PhysicalAdapterIndex; public ulong Frequency; public ulong MaxFrequency; public ulong MaxFrequencyOC;
        public uint Voltage; public uint VoltageMax; public uint VoltageMaxOC; public ulong MaxTransitionLatency; }
    [StructLayout(LayoutKind.Sequential)] struct SEGMENTSIZEINFO { public ulong DedicatedVideoMemorySize; public ulong DedicatedSystemMemorySize; public ulong SharedSystemMemorySize; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct REGISTRYINFO {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string AdapterString;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string BiosString;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string DacType;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string ChipType; }

    // Question numbers from the Windows driver kit (KMTQUERYADAPTERINFOTYPE).
    const int SEGMENT_SIZE = 3, REGISTRY_INFO = 8, NODE_PERF_DATA = 61, PERF_DATA = 62, PERF_DATA_CAPS = 63;

    [DllImport("gdi32.dll")] static extern int D3DKMTEnumAdapters2(ref ENUMADAPTERS2 p);
    [DllImport("gdi32.dll")] static extern int D3DKMTQueryAdapterInfo(ref QUERYADAPTERINFO p);
    [DllImport("gdi32.dll")] static extern int D3DKMTCloseAdapter(ref CLOSEADAPTER p);

    public class Adapter {
        public string Luid;              // matches the name Windows' GPU counters use
        public string Name;
        public ulong DedicatedBytes;     // the graphics card's own memory
        public ulong SharedBytes;        // system memory it may borrow
        public double TemperatureC;      // 0 when the driver does not share one
        public double TemperatureMaxC;   // 0 when the driver does not say
        public ulong MemoryClockHz;      // the video memory's clock; 0 when the driver does not say
        public uint FanRpm;              // the card's own fan; only meaningful when MaxFanRpm is above 0
        public uint MaxFanRpm;           // 0 when the driver does not report a fan at all
        public ulong EngineClockHz;      // the clock of the engine with the highest top speed; 0 when not said
        public ulong EngineMaxClockHz;
    }

    static bool Query<T>(uint handle, int type, ref T value) where T : struct {
        int size = Marshal.SizeOf(typeof(T));
        IntPtr buffer = Marshal.AllocHGlobal(size);
        try {
            Marshal.StructureToPtr(value, buffer, false);
            var q = new QUERYADAPTERINFO { hAdapter = handle, Type = type, pPrivateDriverData = buffer, PrivateDriverDataSize = (uint)size };
            if (D3DKMTQueryAdapterInfo(ref q) != 0) return false;
            value = (T)Marshal.PtrToStructure(buffer, typeof(T));
            return true;
        } finally { Marshal.FreeHGlobal(buffer); }
    }

    // One pass over every graphics adapter. Every handle is closed again before this returns.
    public static List<Adapter> Read() {
        var result = new List<Adapter>();
        var e = new ENUMADAPTERS2();
        if (D3DKMTEnumAdapters2(ref e) != 0 || e.NumAdapters == 0) return result;
        int itemSize = Marshal.SizeOf(typeof(ADAPTERINFO));
        e.pAdapters = Marshal.AllocHGlobal(itemSize * (int)e.NumAdapters);
        try {
            if (D3DKMTEnumAdapters2(ref e) != 0) return result;
            for (int i = 0; i < e.NumAdapters; i++) {
                var a = (ADAPTERINFO)Marshal.PtrToStructure(new IntPtr(e.pAdapters.ToInt64() + i * itemSize), typeof(ADAPTERINFO));
                try {
                    var reg = new REGISTRYINFO();
                    if (!Query(a.hAdapter, REGISTRY_INFO, ref reg) || string.IsNullOrEmpty(reg.AdapterString)) continue;
                    if (reg.AdapterString.IndexOf("Basic Render", StringComparison.OrdinalIgnoreCase) >= 0) continue;
                    var item = new Adapter {
                        Luid = string.Format("0x{0:x8}_0x{1:x8}", (uint)a.AdapterLuid.HighPart, a.AdapterLuid.LowPart),
                        Name = reg.AdapterString.Trim()
                    };
                    var seg = new SEGMENTSIZEINFO();
                    if (Query(a.hAdapter, SEGMENT_SIZE, ref seg)) { item.DedicatedBytes = seg.DedicatedVideoMemorySize; item.SharedBytes = seg.SharedSystemMemorySize; }
                    var perf = new PERFDATA();
                    if (Query(a.hAdapter, PERF_DATA, ref perf)) { item.TemperatureC = perf.Temperature / 10.0; item.MemoryClockHz = perf.MemoryFrequency; item.FanRpm = perf.FanRPM; }
                    var caps = new PERFDATACAPS();
                    if (Query(a.hAdapter, PERF_DATA_CAPS, ref caps)) { item.TemperatureMaxC = caps.TemperatureMax / 10.0; item.MaxFanRpm = caps.MaxFanRPM; }
                    // Each engine (3D, copy, video...) is asked its clock; the one with the highest top speed is the
                    // graphics engine. On this project's NVIDIA laptop that matches NVIDIA's own graphics clock exactly.
                    for (uint n = 0; n < 64; n++) {
                        var node = new NODEPERFDATA { NodeOrdinal = n };
                        if (!Query(a.hAdapter, NODE_PERF_DATA, ref node)) break;
                        if (node.MaxFrequency > item.EngineMaxClockHz) { item.EngineMaxClockHz = node.MaxFrequency; item.EngineClockHz = node.Frequency; }
                    }
                    result.Add(item);
                } finally {
                    var c = new CLOSEADAPTER { hAdapter = a.hAdapter };
                    D3DKMTCloseAdapter(ref c);
                }
            }
        } finally { Marshal.FreeHGlobal(e.pAdapters); }
        return result;
    }
}
'@

function Initialize-QpGpuSensors {
    <# Makes the graphics-driver questions above available. Returns $false, quietly, where it can't. #>
    if ('QuietpaneGpuSensors' -as [type]) { return $true }
    try { Add-Type -TypeDefinition $script:GpuSensorSource -Language CSharp -ErrorAction Stop; return $true }
    catch { return $false }   # e.g. a locked-down PC that doesn't allow it: usage still works, heat just isn't shown
}

# Asking the drive itself, because Windows' own answer is often a made-up one. Get-StorageReliabilityCounter
# returns whatever the storage driver felt like saying, and on a good many PCs - this one included - that
# is a flat 60 C that never moves however hard the disk is worked, with no wear and no hours at all. The
# drive knows all three perfectly well, so the questions below are put to the drive: the temperature Windows
# exposes for any device that reports one, and, on an NVMe drive, its own health log, which carries how much
# of its rated life is gone, how long it has been powered on and how much has been written to it. Read-only,
# opened with no access rights at all, so it needs no administrator and cannot alter a byte.

$script:DriveSensorSource = @'
using System;
using System.Runtime.InteropServices;

public static class QuietpaneDriveSensors {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool DeviceIoControl(IntPtr h, uint code, IntPtr inBuf, uint inSize, IntPtr outBuf, uint outSize, out uint ret, IntPtr ov);
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr h);

    const uint IOCTL_STORAGE_QUERY_PROPERTY = 0x002D1400;
    const int TEMPERATURE_PROPERTY = 52;        // StorageDeviceTemperatureProperty
    const int PROTOCOL_PROPERTY = 50;           // StorageDeviceProtocolSpecificProperty
    const int PROTOCOL_NVME = 3, NVME_LOG_PAGE = 2, NVME_HEALTH_LOG = 2;

    public class Reading {
        public bool HasTemperature;
        public int TemperatureC;
        public int WarnAtC;          // the drive's own "too warm" mark, 0 when it doesn't say
        public bool HasLife;
        public int LifeUsedPct;      // share of its rated writing life used up
        public long PowerOnHours;
        public long BytesWritten;
    }

    public static Reading Read(int driveNumber) {
        var r = new Reading();
        IntPtr h = CreateFileW(@"\\.\PhysicalDrive" + driveNumber, 0, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (h == (IntPtr)(-1)) return r;
        try {
            ReadTemperature(h, r);
            ReadNvmeHealth(h, r);
        } catch { } finally { CloseHandle(h); }
        return r;
    }

    // Every drive whose driver reports a sensor at all, NVMe or not.
    static void ReadTemperature(IntPtr h, Reading r) {
        int size = 512;
        IntPtr buf = Marshal.AllocHGlobal(size);
        try {
            Zero(buf, size);
            Marshal.WriteInt32(buf, 0, TEMPERATURE_PROPERTY);
            Marshal.WriteInt32(buf, 4, 0);                    // PropertyStandardQuery
            uint ret;
            if (!DeviceIoControl(h, IOCTL_STORAGE_QUERY_PROPERTY, buf, (uint)size, buf, (uint)size, out ret, IntPtr.Zero)) return;
            int count = (ushort)Marshal.ReadInt16(buf, 12);
            if (count < 1) return;
            short temp = Marshal.ReadInt16(buf, 24 + 2);      // first sensor: the drive as a whole
            short over = Marshal.ReadInt16(buf, 24 + 4);
            if (temp <= -100 || temp > 200) return;           // a sensor that isn't really there
            r.HasTemperature = true;
            r.TemperatureC = temp;
            if (over > 0 && over < 200) r.WarnAtC = over;
        } catch { } finally { Marshal.FreeHGlobal(buf); }
    }

    // NVMe only: log page 02h, the drive's own health record.
    static void ReadNvmeHealth(IntPtr h, Reading r) {
        int head = 8 + 40, size = head + 512;
        IntPtr buf = Marshal.AllocHGlobal(size);
        try {
            Zero(buf, size);
            Marshal.WriteInt32(buf, 0, PROTOCOL_PROPERTY);
            Marshal.WriteInt32(buf, 4, 0);
            Marshal.WriteInt32(buf, 8, PROTOCOL_NVME);
            Marshal.WriteInt32(buf, 12, NVME_LOG_PAGE);
            Marshal.WriteInt32(buf, 16, NVME_HEALTH_LOG);
            Marshal.WriteInt32(buf, 20, 0);
            Marshal.WriteInt32(buf, 24, 40);                  // where the log sits, counted from here
            Marshal.WriteInt32(buf, 28, 512);
            uint ret;
            if (!DeviceIoControl(h, IOCTL_STORAGE_QUERY_PROPERTY, buf, (uint)size, buf, (uint)size, out ret, IntPtr.Zero)) return;
            int kelvin = Marshal.ReadByte(buf, head + 1) | (Marshal.ReadByte(buf, head + 2) << 8);
            if (!r.HasTemperature && kelvin > 200 && kelvin < 400) { r.HasTemperature = true; r.TemperatureC = kelvin - 273; }
            int used = Marshal.ReadByte(buf, head + 5);
            long hours = Low64(buf, head + 128);
            long units = Low64(buf, head + 48);               // written in 512,000-byte units
            if (used <= 100) { r.HasLife = true; r.LifeUsedPct = used; }
            if (hours > 0 && hours < 2000000) r.PowerOnHours = hours;
            if (units > 0 && units < 100000000000L) r.BytesWritten = units * 512000L;
        } catch { } finally { Marshal.FreeHGlobal(buf); }
    }

    static long Low64(IntPtr buf, int at) {
        long v = 0;
        for (int i = 7; i >= 0; i--) v = (v << 8) | Marshal.ReadByte(buf, at + i);
        return v;
    }
    static void Zero(IntPtr buf, int size) { for (int i = 0; i < size; i++) Marshal.WriteByte(buf, i, 0); }
}
'@

function Initialize-QpDriveSensors {
    <# Makes the questions above available. Returns $false, quietly, where a PC won't allow it. #>
    if ('QuietpaneDriveSensors' -as [type]) { return $true }
    try { Add-Type -TypeDefinition $script:DriveSensorSource -Language CSharp -ErrorAction Stop; return $true }
    catch { return $false }
}

function New-QpCounter {
    <#
        One of Windows' own performance counters, asked for by its English name.

        .NET looks a counter's name up in the table for the language it is running under, and only the
        English table is on every Windows, so the lookup is made under the invariant culture. Without
        that, these same names would not resolve on a PC set to another language and the Health tab
        would quietly show nothing at all. Returns $null where a PC has no such counter.
    #>
    param([string]$Category, [string]$Counter, [string]$Instance = '')
    $was = [Threading.Thread]::CurrentThread.CurrentCulture
    try {
        [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture
        $c = New-Object Diagnostics.PerformanceCounter($Category, $Counter, $Instance, $true)
        [void]$c.NextValue()
        return $c
    } catch { return $null } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $was }
}

function New-QpCounterGroup {
    <# A whole category of counters, read in one go. English names, same reason as above. #>
    param([string]$Category)
    $was = [Threading.Thread]::CurrentThread.CurrentCulture
    try {
        [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture
        return (New-Object Diagnostics.PerformanceCounterCategory($Category))
    } catch { return $null } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $was }
}

# ------------------------------------------------------------------ facts about this PC, read now and then
# What the PC is, rather than what it is doing: its cores, its memory, its maker and model, Windows, its
# screens and its power plan. All read-only, from Windows' own inventory (WMI) and powercfg. Anything
# Windows does not say is left empty - never filled in from a guess.
#
# Fans: Windows' own fan class (Win32_Fan) carries a *desired* speed at most, never a measured one, and on
# most PCs not even that. Showing it as a fan speed would be inventing a number, so it is not used.
# Fan speed is shared by the graphics driver on some cards, and read there.

$script:MemoryTypeNames = @{ 20 = 'DDR'; 21 = 'DDR2'; 24 = 'DDR3'; 26 = 'DDR4'; 27 = 'LPDDR'; 28 = 'LPDDR2'; 29 = 'LPDDR3'; 30 = 'LPDDR4'; 34 = 'DDR5'; 35 = 'LPDDR5' }
$script:PowerPlanNames = @{
    '381b4222-f694-41f0-9685-ff5bb260df2e' = 'Balanced'
    '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' = 'High performance'
    'a1841308-3541-4fab-bc81-f71556f20b4a' = 'Power saver'
    'e9a42b02-d5df-448d-aa00-03f14749eb61' = 'Ultimate performance'
}

function ConvertFrom-QpPowerCfg {
    <# The active power plan from powercfg /getactivescheme: Windows' own plans by name, any other by its own name. #>
    param([string]$Text)
    if ($Text -notmatch '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\s*\(([^)]*)\)') { return $null }
    $guid = $matches[1].ToLowerInvariant(); $own = $matches[2].Trim()
    $name = if ($script:PowerPlanNames.ContainsKey($guid)) { $script:PowerPlanNames[$guid] } elseif ($own) { $own } else { $null }
    if (-not $name) { return $null }
    return [pscustomobject]@{ Guid = $guid; Name = $name }
}

function ConvertTo-QpSystemFacts {
    <#
        Turns what Windows said into the facts shown, leaving out anything missing, unclear or
        contradictory. Kept apart from the reading so the rules can be tested with made-up PCs.
    #>
    param($Processors, $Sticks, $Arrays, $System, $OS, $WindowsKey, $Video, [string]$PowerCfg)
    $num = { param($v) if ($null -ne $v -and "$v" -ne '' -and [double]$v -gt 0) { [double]$v } else { $null } }
    $procs = @($Processors | Where-Object { $_ })
    $cores = $null; $threads = $null
    if ($procs.Count) {
        $c = @($procs | ForEach-Object { & $num $_.NumberOfCores }); $l = @($procs | ForEach-Object { & $num $_.NumberOfLogicalProcessors })
        if ($c -notcontains $null) { $cores = [int](($c | Measure-Object -Sum).Sum) }
        if ($l -notcontains $null) { $threads = [int](($l | Measure-Object -Sum).Sum) }
    }
    # Memory: the type and the speed it is actually running at, only when every stick agrees.
    $sticks = @($Sticks | Where-Object { $_ -and (& $num $_.Capacity) })
    $memType = $null; $memSpeed = $null; $installed = $null; $slots = $null
    if ($sticks.Count) {
        $installed = $sticks.Count
        $types = @($sticks | ForEach-Object { $script:MemoryTypeNames[[int]$_.SMBIOSMemoryType] } | Select-Object -Unique)
        if ($types.Count -eq 1 -and $types[0]) { $memType = $types[0] }
        $speeds = @($sticks | ForEach-Object { & $num $_.ConfiguredClockSpeed } | Select-Object -Unique)
        if ($speeds.Count -eq 1 -and $null -ne $speeds[0]) { $memSpeed = [int]$speeds[0] }
    }
    # Slots come from the board's own count, never worked out from the sticks. Use 3 is system memory.
    $boards = @($Arrays | Where-Object { $_ -and [int]$_.Use -eq 3 -and (& $num $_.MemoryDevices) })
    if ($boards.Count) {
        $slots = [int](($boards | ForEach-Object { [int]$_.MemoryDevices } | Measure-Object -Sum).Sum)
        if ($null -ne $installed -and $slots -lt $installed) { $slots = $null }   # contradicts itself: say nothing
    }
    # Maker and model, unless the maker left the placeholder text in.
    $placeholder = '(?i)^(to be filled by o\.?e\.?m\.?|system manufacturer|system product name|default string|not applicable|o\.?e\.?m\.?|none|unknown|x+)$'
    $maker = $null; $model = $null
    if ($System) {
        $mk = ([string]$System.Manufacturer).Trim(); $md = ([string]$System.Model).Trim()
        if ($mk -and $mk -notmatch $placeholder) { $maker = ($mk -replace '(?i),?\s+(co\.?,?\s*ltd\.?|inc\.?|corporation|corp\.?|ltd\.?|llc|gmbh)$', '').Trim() }
        if ($md -and $md -notmatch $placeholder) { $model = $md }
    }
    # Windows: its own name for itself. The registry's ProductName still says "Windows 10" on Windows 11,
    # so the name comes from the operating system record instead.
    $windows = $null; $version = $null; $build = $null
    if ($OS -and $OS.Caption) { $windows = ([string]$OS.Caption -replace '^Microsoft\s+', '').Trim() }
    if ($WindowsKey) {
        if ($WindowsKey.DisplayVersion) { $version = [string]$WindowsKey.DisplayVersion }
        if ($WindowsKey.CurrentBuild) { $build = [string]$WindowsKey.CurrentBuild + $(if ($null -ne $WindowsKey.UBR) { '.' + $WindowsKey.UBR } else { '' }) }
    }
    # Screens: what each graphics card says it is showing right now. A refresh rate of 0 or 1 means
    # "the default", which is not a number, so it is left off.
    $screens = @(foreach ($v in @($Video | Where-Object { $_ })) {
        $w = & $num $v.CurrentHorizontalResolution; $h = & $num $v.CurrentVerticalResolution
        if (-not $w -or -not $h) { continue }
        $hz = & $num $v.CurrentRefreshRate
        if ($hz -and $hz -gt 1) { '{0} x {1}, {2} Hz' -f [int]$w, [int]$h, [int]$hz } else { '{0} x {1}' -f [int]$w, [int]$h }
    })
    $plan = ConvertFrom-QpPowerCfg $PowerCfg
    [pscustomobject]@{
        Cores = $cores; Threads = $threads
        MemoryType = $memType; MemorySpeedMTs = $memSpeed; MemorySticks = $installed; MemorySlots = $slots
        Maker = $maker; Model = $model
        Windows = $windows; WindowsVersion = $version; WindowsBuild = $build
        Screens = $screens
        PowerPlan = $(if ($plan) { $plan.Name } else { $null })
    }
}

function Get-QpSystemFacts {
    <# Reads the facts above. Each part is asked on its own, so one that fails leaves only itself empty. Never throws. #>
    $get = { param($class) try { @(Get-CimInstance -ClassName $class -ErrorAction Stop) } catch { @() } }
    $key = $null
    try { $key = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop } catch { }
    $os = @(& $get 'Win32_OperatingSystem') | Select-Object -First 1
    $power = ''
    try { $power = (& powercfg.exe /getactivescheme 2>$null | Out-String) } catch { }
    ConvertTo-QpSystemFacts -Processors (& $get 'Win32_Processor') -Sticks (& $get 'Win32_PhysicalMemory') -Arrays (& $get 'Win32_PhysicalMemoryArray') `
        -System (@(& $get 'Win32_ComputerSystem') | Select-Object -First 1) -OS $os -WindowsKey $key -Video (& $get 'Win32_VideoController') -PowerCfg $power
}
# ------------------------------------------------------------------ network speed, from Windows' own counters
# How fast this PC is sending and receiving, read from the counters Task Manager uses. Nothing is
# connected to and nothing is looked up: it is Windows' own tally of bytes through each network card.
#
# Only real network cards count - the Wi-Fi or wired card the traffic actually goes through. Virtual
# adapters (Hyper-V, WSL, VPNs, tunnels, Bluetooth) carry the same traffic a second time on its way
# through, so counting them too would double it. Where it cannot be told which is which, a card is left
# out rather than guessed at: a figure too low is better than one counted twice.

function ConvertTo-QpCounterInstance([string]$Description) {
    <# The name Windows' counters use for a network card: brackets and a few characters swapped. #>
    return ($Description -replace '\(', '[' -replace '\)', ']' -replace '#', '_' -replace '/', '_' -replace '\\', '_')
}

function Select-QpNetworkCards {
    <#
        From Get-NetAdapter's list, the physical Wi-Fi and wired cards, and whether each is connected.
        -Instances is the list of names the counters know; a card missing from it is left out.
    #>
    param($Adapters, [string[]]$Instances)
    $kinds = @{ 9 = 'Wi-Fi'; 14 = 'Wired' }   # NdisPhysicalMedium: Native 802.11, and 802.3 Ethernet
    foreach ($a in @($Adapters)) {
        if (-not $a) { continue }
        if (-not $a.HardwareInterface -or $a.Virtual) { continue }
        $kind = $kinds[[int]$a.NdisPhysicalMedium]
        if (-not $kind) { continue }
        # Belt and braces: a few drivers of virtual cards claim to be hardware.
        if ("$($a.InterfaceDescription)" -match '(?i)virtual|hyper-v|vpn|tap-windows|wireguard|tunnel|loopback|miniport|wsl|vmware|virtualbox') { continue }
        $inst = ConvertTo-QpCounterInstance ([string]$a.InterfaceDescription)
        if ($Instances -notcontains $inst) { continue }
        [pscustomobject]@{ Kind = $kind; Description = [string]$a.InterfaceDescription; Instance = $inst; Up = ("$($a.Status)" -eq 'Up') }
    }
}

function Update-QpNetMonitor {
    <# Which network cards to count, asked again every minute, since Wi-Fi comes and goes. Never throws. #>
    param([Parameter(Mandatory)]$Monitor)
    $m = $Monitor
    $m.NetAt = Get-Date
    try {
        $group = New-QpCounterGroup 'Network Interface'
        if (-not $group) { $m.Net = $null; return }
        $instances = @($group.GetInstanceNames())
        $cards = @(Select-QpNetworkCards -Adapters @(Get-NetAdapter -ErrorAction Stop) -Instances $instances)
        $old = @{}
        foreach ($c in @($m.Net)) { if ($c) { $old[$c.Instance] = $c } }
        $m.Net = @(foreach ($c in $cards) {
            $prev = $old[$c.Instance]
            $recv = if ($prev) { $prev.Received } else { New-QpCounter 'Network Interface' 'Bytes Received/sec' $c.Instance }
            $sent = if ($prev) { $prev.Sent } else { New-QpCounter 'Network Interface' 'Bytes Sent/sec' $c.Instance }
            if ($recv -and $sent) { [pscustomobject]@{ Kind = $c.Kind; Instance = $c.Instance; Up = $c.Up; Received = $recv; Sent = $sent } }
        })
    } catch { $m.Net = $null }
}

function Get-QpNetRates {
    <#
        Bytes a second, down and up, for Wi-Fi and for wired, over the connected cards of each kind.
        $null when Windows won't say which cards are which; a kind with nothing connected is left out.
    #>
    param([Parameter(Mandatory)]$Monitor)
    $m = $Monitor
    # A monitor made before network speed was added (or by a test) simply has none to give.
    if ($m.PSObject.Properties.Name -notcontains 'NetAt') { return $null }
    if ($null -eq $m.NetAt -or ((Get-Date) - [datetime]$m.NetAt).TotalSeconds -ge 60) { Update-QpNetMonitor -Monitor $m }
    if ($null -eq $m.Net) { return $null }
    $out = @()
    foreach ($kind in 'Wi-Fi', 'Wired') {
        $cards = @($m.Net | Where-Object { $_.Kind -eq $kind -and $_.Up })
        if (-not $cards.Count) { continue }
        $down = [double]0; $up = [double]0; $ok = $false
        foreach ($c in $cards) {
            try { $down += [math]::Max(0, [double]$c.Received.NextValue()); $up += [math]::Max(0, [double]$c.Sent.NextValue()); $ok = $true } catch { }
        }
        if ($ok) { $out += [pscustomobject]@{ Kind = $kind; DownBps = $down; UpBps = $up } }
    }
    return ,$out
}
function New-QpLiveMonitor {
    <# Sets the readers up once, so every reading after that is cheap. Never throws. #>
    $m = [pscustomobject]@{
        Cpu = $null; CpuName = ''; Zone = $null; ZoneName = ''; Limits = @()
        Available = $null; MemTotal = [double]0
        Commit = $null; CommitLimit = $null; Speed = $null; SpeedMhz = $null; DiskIdle = $null; DiskQueue = $null
        Engines = $null; EnginePrev = $null; GpuMemory = $null; GpuSensors = $false
        ZoneSeen = New-Object System.Collections.Generic.List[double]
        Procs = $null; ProcPrev = $null; Names = @{}; Cores = [math]::Max(1, [Environment]::ProcessorCount)
        Power = $false; BatteryRate = $null
        DiskRead = $null; DiskWrite = $null; Net = $null; NetAt = [datetime]::MinValue
    }
    # Task Manager's own processor figure first, the older one if this Windows doesn't have it.
    $m.Cpu = New-QpCounter 'Processor Information' '% Processor Utility' '_Total'
    if (-not $m.Cpu) { $m.Cpu = New-QpCounter 'Processor' '% Processor Time' '_Total' }
    try { $m.CpuName = ([string](Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -ErrorAction Stop).ProcessorNameString).Trim() } catch { }
    # Windows' thermal zones: prefer one named after the processor, otherwise the warmest one.
    try {
        $group = New-QpCounterGroup 'Thermal Zone Information'
        $zones = @(if ($group) { $group.GetInstanceNames() })
        $best = $null; $bestValue = -1
        foreach ($z in $zones) {
            # Every zone's cooling brake is watched, whichever one gives the temperature.
            $lc = New-QpCounter 'Thermal Zone Information' '% Passive Limit' $z
            if ($lc) { $m.Limits += $lc }
        }
        foreach ($z in $zones) {
            $pc = New-QpCounter 'Thermal Zone Information' 'High Precision Temperature' $z
            if (-not $pc) { continue }
            $v = [double]$pc.NextValue()
            if ($z -match '(?i)cpu|pkg|core') { $best = $pc; $m.ZoneName = $z; break }
            if ($v -gt $bestValue) { $best = $pc; $bestValue = $v; $m.ZoneName = $z }
        }
        $m.Zone = $best
    } catch { $m.Zone = $null }
    $m.Available = New-QpCounter 'Memory' 'Available Bytes'
    try { Add-Type -AssemblyName Microsoft.VisualBasic; $m.MemTotal = [double](New-Object Microsoft.VisualBasic.Devices.ComputerInfo).TotalPhysicalMemory } catch { }
    # What Windows has promised to programs, which fills up long before the memory chips do, and is
    # usually the real reason a PC starts crawling.
    $m.Commit = New-QpCounter 'Memory' 'Committed Bytes'
    $m.CommitLimit = New-QpCounter 'Memory' 'Commit Limit'
    # How much of its speed the processor is actually being allowed, and how busy the disk is.
    $m.Speed = New-QpCounter 'Processor Information' '% of Maximum Frequency' '_Total'
    $m.SpeedMhz = New-QpCounter 'Processor Information' 'Processor Frequency' '_Total'
    $m.DiskIdle = New-QpCounter 'PhysicalDisk' '% Idle Time' '_Total'
    $m.DiskQueue = New-QpCounter 'PhysicalDisk' 'Avg. Disk Queue Length' '_Total'
    # How fast the drives are reading and writing. These are Windows' own per-second rates (primed above,
    # so the first figure is already a rate), counted across all drives as the busy figure is.
    $m.DiskRead = New-QpCounter 'PhysicalDisk' 'Disk Read Bytes/sec' '_Total'
    $m.DiskWrite = New-QpCounter 'PhysicalDisk' 'Disk Write Bytes/sec' '_Total'
    Update-QpNetMonitor -Monitor $m
    $m.Engines = New-QpCounterGroup 'GPU Engine'
    if ($m.Engines) { try { $m.EnginePrev = $m.Engines.ReadCategory() } catch { $m.Engines = $null } }
    $m.GpuMemory = New-QpCounterGroup 'GPU Adapter Memory'
    # Per-program load, for "what's using it". One read of Windows' own counters covers every program.
    $m.Procs = New-QpCounterGroup 'Process'
    if ($m.Procs) { try { $m.ProcPrev = $m.Procs.ReadCategory() } catch { $m.Procs = $null } }
    # Battery charge and whether it's plugged in: the same figures as the battery icon by the clock.
    try { Add-Type -AssemblyName System.Windows.Forms; $m.Power = $true } catch { }
    # What the battery itself says it is giving or taking, in milliwatts. Asked through a searcher made
    # once, which is about 3 ms a reading instead of 14.
    try {
        $s = [wmisearcher]::new('SELECT DischargeRate,ChargeRate,Voltage,RemainingCapacity,Charging,Discharging FROM BatteryStatus')
        $s.Scope = [Management.ManagementScope]::new('root\wmi')
        [void]$s.Get()
        $m.BatteryRate = $s
    } catch { $m.BatteryRate = $null }
    $m.GpuSensors = Initialize-QpGpuSensors
    return $m
}

# Windows' own processes often don't describe themselves; these are the usual ones, in plain words.
$script:ProgramNames = @{
    'system' = 'Windows'; 'registry' = 'Windows'; 'memory compression' = 'Windows memory'; 'dwm' = 'Windows desktop'
    'csrss' = 'Windows'; 'svchost' = 'Windows services'; 'audiodg' = 'Windows audio'; 'searchindexer' = 'Windows search'
    'msmpeng' = 'Microsoft Defender'; 'mpdefendercoreservice' = 'Microsoft Defender'; 'wmiprvse' = 'Windows management'
    'nvdisplay.container' = 'NVIDIA display helper'; 'explorer' = 'Windows Explorer'; 'tiworker' = 'Windows Update'
    'nvcontainer' = 'NVIDIA helper'; 'nvsphelper64' = 'NVIDIA helper'; 'smartscreen' = 'Windows SmartScreen'
    'backgroundtransferhost' = 'Windows downloads'; 'runtimebroker' = 'Windows app helper'; 'lsass' = 'Windows sign-in'
    'services' = 'Windows'; 'taskhostw' = 'Windows background tasks'; 'sihost' = 'Windows shell'
}

function Get-QpProgramName {
    <# A program's own name for itself ("No Man's Sky", not "nms"), remembered once found. #>
    param([Parameter(Mandatory)]$Monitor, [string]$Instance, [int]$ProcessId)
    if ($ProcessId -eq $PID) { return 'Quietpane (this app)' }
    $key = $Instance.ToLower()
    if ($Monitor.Names.ContainsKey($key)) { return $Monitor.Names[$key] }
    $name = $script:ProgramNames[$key]
    if (-not $name) {
        try {
            $p = Get-Process -Id $ProcessId -ErrorAction Stop
            foreach ($n in [string]$p.Description, [string]$p.Product, [string]$p.MainWindowTitle) {
                $n = $n.Trim()
                if ($n -and $n.Length -le 40 -and $n -notmatch '(?i)operating system') { $name = $n; break }
            }
        } catch { }
    }
    if (-not $name) { $name = $Instance }
    $Monitor.Names[$key] = $name
    return $name
}

function Get-QpLiveReading {
    <#
        One reading of load and heat. Read-only, a few milliseconds, and it never throws: anything this
        PC doesn't share comes back empty rather than guessed.
    #>
    param([Parameter(Mandatory)]$Monitor)
    $m = $Monitor

    $cpu = $null
    if ($m.Cpu) { try { $cpu = [math]::Round([math]::Min([double]100, [math]::Max([double]0, [double]$m.Cpu.NextValue())), 1) } catch { } }

    # The thermal zone reports tenths of a kelvin. Anything outside a believable range is ignored.
    $cpuTemp = $null
    if ($m.Zone) {
        try {
            $c = [math]::Round([double]$m.Zone.NextValue() / 10 - 273.15, 1)
            if ($c -gt 5 -and $c -lt 130) {
                $cpuTemp = $c
                $m.ZoneSeen.Add($c)
                if ($m.ZoneSeen.Count -gt 60) { $m.ZoneSeen.RemoveAt(0) }
            }
        } catch { }
    }
    # Some PCs report a thermal zone that never moves. Say so rather than showing a stale number as live.
    $stuck = $false
    if ($m.ZoneSeen.Count -ge 20) {
        $s = $m.ZoneSeen | Measure-Object -Minimum -Maximum
        $stuck = ($s.Maximum - $s.Minimum) -lt 0.2
    }

    # Windows' own cooling brake. 100 means full speed; lower means Windows is holding the processor
    # back to shed heat. 0 or nonsense is treated as "not reported", never as fully throttled.
    # Throttling done inside the chip itself is invisible to Windows, so this can't catch every case.
    $limit = $null
    foreach ($lc in @($m.Limits)) {
        try {
            $v = [double]$lc.NextValue()
            if ($v -gt 0 -and $v -le 100 -and ($null -eq $limit -or $v -lt $limit)) { $limit = $v }
        } catch { }
    }

    # [double] on both sides: Max(0, big) picks the Int32 overload and overflows on gigabytes.
    $memUsed = $null
    if ($m.Available -and $m.MemTotal -gt 0) { try { $memUsed = [math]::Max([double]0, [double]$m.MemTotal - [double]$m.Available.NextValue()) } catch { } }

    # What Windows has promised to programs, against what it is willing to promise. This fills up before
    # the memory chips do, and it is what "everything went sluggish" usually means.
    $commitUsed = $null; $commitLimit = $null; $commitPct = $null
    if ($m.Commit -and $m.CommitLimit) {
        try {
            $commitUsed = [double]$m.Commit.NextValue()
            $commitLimit = [double]$m.CommitLimit.NextValue()
            if ($commitLimit -gt 0) { $commitPct = [int][math]::Round(100 * $commitUsed / $commitLimit) } else { $commitUsed = $null; $commitLimit = $null }
        } catch { $commitUsed = $null; $commitLimit = $null; $commitPct = $null }
    }

    # How much of its speed the processor is being allowed. Below 100 it is being held back - by heat, by
    # the power plan, or by running on battery. Turbo can read over 100, which is simply "all of it".
    $speedPct = $null; $speedMhz = $null
    if ($m.Speed) { try { $v = [double]$m.Speed.NextValue(); if ($v -gt 0) { $speedPct = [int][math]::Round([math]::Min(100, $v)) } } catch { } }
    if ($m.SpeedMhz) { try { $v = [double]$m.SpeedMhz.NextValue(); if ($v -gt 0) { $speedMhz = [int]$v } } catch { } }

    # How busy the disk is. Windows counts idle time, so busy is what is left of it.
    $diskBusy = $null; $diskQueue = $null
    if ($m.DiskIdle) {
        try {
            $idle = [double]$m.DiskIdle.NextValue()
            if ($idle -ge 0) { $diskBusy = [int][math]::Round([math]::Max(0, 100 - [math]::Min(100, $idle))) }
        } catch { }
    }
    if ($m.DiskQueue) { try { $diskQueue = [math]::Round([double]$m.DiskQueue.NextValue(), 1) } catch { } }
    $diskRead = $null; $diskWrite = $null
    if ($m.DiskRead) { try { $diskRead = [math]::Max(0, [double]$m.DiskRead.NextValue()) } catch { } }
    if ($m.DiskWrite) { try { $diskWrite = [math]::Max(0, [double]$m.DiskWrite.NextValue()) } catch { } }
    $network = Get-QpNetRates -Monitor $m

    # Which programs are using the processor. Windows counts per core, so divide by cores to match
    # Task Manager. Programs are keyed by process id, then added up under their friendly name.
    $pidName = @{}
    $topCpu = @()
    if ($m.Procs) {
        try {
            $now = $m.Procs.ReadCategory()
            $cn = $now['% Processor Time']; $ids = $now['ID Process']
            $cp = if ($m.ProcPrev) { $m.ProcPrev['% Processor Time'] } else { $null }
            $byName = @{}
            foreach ($inst in $cn.Keys) {
                $instName = ("$inst" -replace '#\d+$', '')
                if ($instName -in '_Total', 'Idle') { continue }
                $procId = if ($ids -and $ids.Contains($inst)) { [int]$ids[$inst].RawValue } else { 0 }
                if ($procId) { $pidName[$procId] = $instName }
                if (-not $cp -or -not $cp.Contains($inst)) { continue }
                $v = [Diagnostics.CounterSample]::Calculate($cp[$inst].Sample, $cn[$inst].Sample) / $m.Cores
                if ($v -le 0) { continue }
                $label = Get-QpProgramName -Monitor $m -Instance $instName -ProcessId $procId
                $byName[$label] = [double]$byName[$label] + $v
            }
            $m.ProcPrev = $now
            $topCpu = @($byName.GetEnumerator() | Where-Object { $_.Value -ge 1 } | Sort-Object Value -Descending | Select-Object -First 3 |
                ForEach-Object { [pscustomobject]@{ Name = $_.Key; Pct = [math]::Round([math]::Min([double]100, $_.Value)) } })
        } catch { }
    }

    # How busy each graphics adapter is: the busiest engine wins, as in Task Manager. The same numbers,
    # split by program, say what is using each card.
    $busy = @{}
    $perProgram = @{}   # "luid|pid" -> that program's busiest engine on that card
    if ($m.Engines) {
        try {
            $now = $m.Engines.ReadCategory()
            $pn = $now['Utilization Percentage']
            $pp = if ($m.EnginePrev) { $m.EnginePrev['Utilization Percentage'] } else { $null }
            $perEngine = @{}
            if ($pn -and $pp) {
                foreach ($name in $pn.Keys) {
                    if (-not $pp.Contains($name)) { continue }
                    if ("$name" -notmatch '(?i)pid_(\d+)_luid_(0x[0-9a-f]+_0x[0-9a-f]+)_phys_\d+_eng_(\d+)') { continue }
                    $procId = [int]$matches[1]; $luid = $matches[2].ToLower()
                    $key = $luid + '|' + $matches[3]
                    $v = [Diagnostics.CounterSample]::Calculate($pp[$name].Sample, $pn[$name].Sample)
                    $perEngine[$key] = [double]$perEngine[$key] + $v
                    $pk = "$luid|$procId"
                    if ($v -gt [double]$perProgram[$pk]) { $perProgram[$pk] = $v }
                }
            }
            $m.EnginePrev = $now
            foreach ($key in $perEngine.Keys) {
                $luid = $key.Split('|')[0]
                if ($perEngine[$key] -gt [double]$busy[$luid]) { $busy[$luid] = $perEngine[$key] }
            }
        } catch { }
    }

    # Graphics memory in use, per adapter.
    $dedicated = @{}; $shared = @{}
    if ($m.GpuMemory) {
        try {
            $all = $m.GpuMemory.ReadCategory()
            foreach ($pair in @(@('Dedicated Usage', $dedicated), @('Shared Usage', $shared))) {
                $col = $all[$pair[0]]
                if (-not $col) { continue }
                foreach ($name in $col.Keys) {
                    if ("$name" -match '(?i)luid_(0x[0-9a-f]+_0x[0-9a-f]+)') { $k = $matches[1].ToLower(); $pair[1][$k] = [double]$pair[1][$k] + [double]$col[$name].RawValue }
                }
            }
        } catch { }
    }

    $adapters = @()
    if ($m.GpuSensors) { try { $adapters = @(('QuietpaneGpuSensors' -as [type])::Read()) } catch { } }
    $gpus = @(foreach ($a in $adapters) {
        $k = ([string]$a.Luid).ToLower()
        [pscustomobject]@{
            Name = [string]$a.Name; Luid = $k
            Usage = [math]::Round([math]::Min([double]100, [double]$busy[$k]), 1)
            TempC = $(if ($a.TemperatureC -gt 0) { [math]::Round([double]$a.TemperatureC, 1) } else { $null })
            TempMaxC = $(if ($a.TemperatureMaxC -gt 0) { [double]$a.TemperatureMaxC } else { $null })
            DedicatedTotal = [double]$a.DedicatedBytes; DedicatedUsed = [double]$dedicated[$k]
            SharedTotal = [double]$a.SharedBytes; SharedUsed = [double]$shared[$k]
            Discrete = ([double]$a.DedicatedBytes -ge 512MB)
            # Clocks and fan exactly as the driver gives them. A driver that says 0 has said nothing, so it
            # is left empty - except a fan the driver says it has (a top speed above 0), which can truly stop.
            EngineClockMhz = $(if ([double]$a.EngineClockHz -gt 0) { [math]::Round([double]$a.EngineClockHz / 1e6) } else { $null })
            MemoryClockMhz = $(if ([double]$a.MemoryClockHz -gt 0) { [math]::Round([double]$a.MemoryClockHz / 1e6) } else { $null })
            FanRpm = $(if ([double]$a.MaxFanRpm -gt 0 -or [double]$a.FanRpm -gt 0) { [int]$a.FanRpm } else { $null })
        }
    })
    if (-not $gpus.Count -and $busy.Count) {
        # The driver questions aren't available here: still show how busy graphics is, just without names.
        $gpus = @(foreach ($k in $busy.Keys) {
            [pscustomobject]@{ Name = 'Graphics'; Luid = $k; Usage = [math]::Round([math]::Min([double]100, [double]$busy[$k]), 1); TempC = $null; TempMaxC = $null
                DedicatedTotal = 0; DedicatedUsed = [double]$dedicated[$k]; SharedTotal = 0; SharedUsed = [double]$shared[$k]; Discrete = ([double]$dedicated[$k] -gt 0)
                EngineClockMhz = $null; MemoryClockMhz = $null; FanRpm = $null }
        })
    }
    # What's using each card, busiest first. Anything under 1% isn't worth a line.
    foreach ($g in $gpus) {
        $byName = @{}
        foreach ($pk in @($perProgram.Keys | Where-Object { $_ -like "$($g.Luid)|*" })) {
            $procId = [int]($pk.Split('|')[1])
            $inst = if ($pidName.ContainsKey($procId)) { $pidName[$procId] } else { "program $procId" }
            $label = Get-QpProgramName -Monitor $m -Instance $inst -ProcessId $procId
            if ($perProgram[$pk] -gt [double]$byName[$label]) { $byName[$label] = $perProgram[$pk] }
        }
        $top = @($byName.GetEnumerator() | Where-Object { $_.Value -ge 1 } | Sort-Object Value -Descending | Select-Object -First 3 |
            ForEach-Object { [pscustomobject]@{ Name = $_.Key; Pct = [math]::Round([math]::Min([double]100, $_.Value)) } })
        $g | Add-Member -NotePropertyName Top -NotePropertyValue $top -Force
    }

    # The battery, as the icon by the clock sees it. 255 means "unknown"; no battery means a desktop.
    $battery = $null
    if ($m.Power) {
        try {
            $ps = [System.Windows.Forms.SystemInformation]::PowerStatus
            $noBattery = ([int]$ps.BatteryChargeStatus -band 128) -ne 0
            if (-not $noBattery -and $ps.BatteryLifePercent -le 1) {
                $battery = [pscustomobject]@{
                    Percent = [math]::Round([double]$ps.BatteryLifePercent * 100)
                    PluggedIn = ([string]$ps.PowerLineStatus -eq 'Online')
                    Charging = (([int]$ps.BatteryChargeStatus -band 8) -ne 0)
                    Watts = $null; Direction = 'steady'; MinutesLeft = $null
                }
                # What the cell itself says it is giving or taking. Windows' own "time remaining" is not
                # used: on mains it comes back as a made-up number (71582788 minutes on this laptop), so
                # the time left is worked out from the charge in the battery and the draw just measured.
                if ($m.BatteryRate) {
                    try {
                        $b = @($m.BatteryRate.Get())[0]
                        if ($b) {
                            $rate = [double]$b.DischargeRate
                            $charge = [double]$b.ChargeRate
                            $volts = [double]$b.Voltage / 1000
                            $left = [double]$b.RemainingCapacity
                            # Most batteries report milliwatts. Some report milliamps, which only makes
                            # sense once multiplied by the voltage; that is what the volts are for.
                            $toWatts = { param($mw) if ($volts -gt 0 -and $mw -gt 0 -and $mw -lt 1000) { ($mw * $volts) / 1000 } else { $mw / 1000 } }
                            if ($rate -gt 0) {
                                $battery.Watts = [math]::Round((& $toWatts $rate), 1)
                                $battery.Direction = 'draining'
                                if ($battery.Watts -gt 0 -and $left -gt 0) { $battery.MinutesLeft = [int][math]::Round(60 * ($left / 1000) / $battery.Watts) }
                            } elseif ($charge -gt 0) {
                                $battery.Watts = [math]::Round((& $toWatts $charge), 1)
                                $battery.Direction = 'charging'
                            }
                        }
                    } catch { }
                }
            }
        } catch { }
    }

    [pscustomobject]@{
        At = Get-Date
        CpuName = $m.CpuName; CpuUsage = $cpu; CpuTop = $topCpu
        CpuTempC = $cpuTemp; CpuTempSource = $m.ZoneName; CpuTempStuck = $stuck
        CpuLimitPct = $limit; CpuThrottled = ($null -ne $limit -and $limit -lt 100)
        MemTotal = $m.MemTotal; MemUsed = $memUsed
        CommitUsed = $commitUsed; CommitLimit = $commitLimit; CommitPct = $commitPct
        SpeedPct = $speedPct; SpeedMhz = $speedMhz
        DiskBusyPct = $diskBusy; DiskQueue = $diskQueue
        DiskReadBps = $diskRead; DiskWriteBps = $diskWrite
        Network = $network
        Battery = $battery
        # The card with its own memory first: on a gaming laptop that's the one that matters.
        Gpus = @($gpus | Sort-Object @{ Expression = { $_.Discrete }; Descending = $true }, @{ Expression = { $_.DedicatedTotal }; Descending = $true })
    }
}

function Get-QpHeatWord {
    <#
        A temperature in plain words, so heat is never shown by colour alone. Laptops run hot under
        load, so the words are calm: only "very hot" is meant to catch the eye.
    #>
    param($Celsius, $MaxC = $null, [ValidateSet('Chip', 'Drive')][string]$Kind = 'Chip')
    if ($null -eq $Celsius) { return [pscustomobject]@{ Word = 'not shared'; Level = 'none' } }
    $c = [double]$Celsius
    # Drives run much cooler than chips, and start slowing themselves down at around 70C.
    $t = if ($Kind -eq 'Drive') { @{ VeryHot = 70; Hot = 60; Warm = 50; Comfortable = 35 } } else { @{ VeryHot = 95; Hot = 85; Warm = 70; Comfortable = 50 } }
    if ($Kind -eq 'Chip' -and $null -ne $MaxC -and [double]$MaxC -gt 60) { $t.VeryHot = [math]::Min(95, [double]$MaxC - 10) }
    $word, $level = if ($c -ge $t.VeryHot) { 'very hot', 'high' }
        elseif ($c -ge $t.Hot) { 'hot', 'warn' }
        elseif ($c -ge $t.Warm) { 'warm', 'ok' }
        elseif ($c -ge $t.Comfortable) { 'comfortable', 'ok' }
        else { 'cool', 'ok' }
    [pscustomobject]@{ Word = $word; Level = $level }
}

# The unit temperatures are written in, chosen in Settings. Every reading and every threshold stays in
# Celsius; only what is written on screen changes.
$script:TempUnitFile = Join-Path $script:DataRoot 'temperature.txt'
$script:TempUnit = $null

function Get-QpTempUnit {
    <# 'C', unless Fahrenheit was chosen in Settings. Read from temperature.txt once, then remembered. #>
    param([string]$Path = $script:TempUnitFile)
    if ($script:TempUnit -and $Path -eq $script:TempUnitFile) { return $script:TempUnit }
    $unit = 'C'
    try { if (Test-Path -LiteralPath $Path) { if (([IO.File]::ReadAllText($Path)).Trim() -eq 'F') { $unit = 'F' } } } catch { }
    if ($Path -eq $script:TempUnitFile) { $script:TempUnit = $unit }
    return $unit
}

function Set-QpTempUnit {
    <#
        Remembers the choice as one letter in temperature.txt, next to appearance.txt. Returns $true only
        once it is written, so the Settings page never shows a choice that did not stick. -SessionOnly
        changes it for this window alone and writes nothing (the self-test, which must change nothing).
    #>
    param([Parameter(Mandatory)][ValidateSet('C', 'F')][string]$Unit, [string]$Path = $script:TempUnitFile, [switch]$SessionOnly)
    if ($SessionOnly) { $script:TempUnit = $Unit; return $true }
    try {
        $dir = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [IO.File]::WriteAllText($Path, $Unit)
    } catch { return $false }
    if ($Path -eq $script:TempUnitFile) { $script:TempUnit = $Unit }
    return $true
}

function Format-QpTemp {
    <#
        One temperature, as it is written everywhere: "47?C", or "117?F" when Fahrenheit was chosen.
        Nothing to show gives $null - never a made-up number.
    #>
    param($Celsius, [ValidateSet('', 'C', 'F')][string]$Unit = '')
    if ($null -eq $Celsius -or "$Celsius" -eq '') { return $null }
    if (-not $Unit) { $Unit = Get-QpTempUnit }
    $deg = [char]0x00B0
    if ($Unit -eq 'F') { return ('{0:N0}{1}F' -f ([double]$Celsius * 9 / 5 + 32), $deg) }
    return ('{0:N0}{1}C' -f [double]$Celsius, $deg)
}

function Get-QpLiveVerdict {
    <#
        One sentence for the whole tab.

        Twelve numbers on a screen ask the reader to work out which one matters, and most people
        reasonably decline. This does that work first: it looks at everything a reading holds, picks the
        single thing most worth knowing, and says it in a sentence. The tiles underneath then answer
        "where does that come from", rather than being the only thing on offer.

        Order is by what actually spoils an afternoon, not by which number is biggest: being held back
        to cool off beats being very hot, which beats running out of memory, which beats simply being
        busy. A PC with nothing wrong is told so plainly - silence reads as a fault.
    #>
    param($Reading)
    if (-not $Reading) { return [pscustomobject]@{ Text = 'Having a look...'; Level = 'none'; Why = '' } }
    $r = $Reading
    $gpu = @($r.Gpus) | Select-Object -First 1
    $busy = @(@($r.CpuUsage, $(if ($gpu) { $gpu.Usage } else { $null })) | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
    $busiest = if ($busy.Count) { ($busy | Measure-Object -Maximum).Maximum } else { $null }
    $memPct = if ($r.MemTotal -gt 0 -and $null -ne $r.MemUsed) { 100 * [double]$r.MemUsed / [double]$r.MemTotal } else { $null }
    $tight = @(@($memPct, $r.CommitPct) | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
    $fullest = if ($tight.Count) { ($tight | Measure-Object -Maximum).Maximum } else { $null }
    $chips = @()
    if ($null -ne $r.CpuTempC -and -not $r.CpuTempStuck) { $chips += (Get-QpHeatWord -Celsius $r.CpuTempC) }
    if ($gpu -and $null -ne $gpu.TempC) { $chips += (Get-QpHeatWord -Celsius $gpu.TempC -MaxC $gpu.TempMaxC) }
    $veryHot = @($chips | Where-Object { $_.Level -eq 'high' }).Count -gt 0
    $hot = @($chips | Where-Object { $_.Level -eq 'warn' }).Count -gt 0

    if ($r.CpuThrottled) {
        return [pscustomobject]@{ Level = 'high'; Text = 'Your PC is being held back to cool off.'
            Why = 'Things will feel slower until it cools. Clearing the vents and sitting it on something hard and flat is what helps.' }
    }
    if ($veryHot) {
        return [pscustomobject]@{ Level = 'high'; Text = 'Your PC is running very hot.'
            Why = 'Normal for a laptop in the middle of a game. Worth a look if it stays this hot while nothing much is happening.' }
    }
    if ($null -ne $fullest -and $fullest -ge 90) {
        return [pscustomobject]@{ Level = 'high'; Text = 'Your PC has nearly run out of memory.'
            Why = 'This, rather than heat, is what usually makes a PC crawl. Closing what you are not using gives it room.' }
    }
    if ($null -ne $r.DiskBusyPct -and [double]$r.DiskBusyPct -ge 90 -and $null -ne $busiest -and $busiest -lt 50) {
        return [pscustomobject]@{ Level = 'warn'; Text = 'Your PC is waiting on its drive.'
            Why = 'The processor is idle while the drive is flat out, which is what "slow" usually turns out to be. It often settles once Windows finishes what it started.' }
    }
    if ($null -ne $busiest -and $busiest -ge 80) {
        $text = if ($hot) { 'Your PC is working hard, and running warm with it.' } else { 'Your PC is working hard.' }
        return [pscustomobject]@{ Level = 'warn'; Text = $text; Why = 'Nothing is wrong - this is what a busy PC looks like.' }
    }
    if ($null -ne $fullest -and $fullest -ge 80) {
        return [pscustomobject]@{ Level = 'warn'; Text = 'Your PC is getting short of memory.'; Why = 'Still fine, but it is the number to watch if things start to drag.' }
    }
    if ($hot) { return [pscustomobject]@{ Level = 'ok'; Text = 'Your PC is running warm, and otherwise calm.'; Why = 'Warm is ordinary. Only "very hot" is worth acting on.' } }
    if ($null -eq $busiest) { return [pscustomobject]@{ Level = 'none'; Text = 'Having a look...'; Why = '' } }
    # Half of a PC in use is not "calm", and saying so would make the calm ones mean nothing.
    if ($busiest -ge 50) { return [pscustomobject]@{ Level = 'ok'; Text = 'Your PC is busy, and coping.'; Why = 'Plenty in hand. Nothing here needs anything from you.' } }
    [pscustomobject]@{ Level = 'ok'; Text = 'Your PC is calm.'; Why = 'Nothing here needs anything from you.' }
}

# ---------------------------------------------------------------- what a session cost
#
# The tiles say what is happening this second. A session record is the same readings remembered: the
# peaks, the minutes spent hot or held back, and what was busiest while it happened. It is kept in
# memory only, it starts when you press the button, and it ends when Quietpane closes - there is no
# service and no scheduled task behind it.
#
# Two rules keep it honest. Peaks are peaks, never averages, because an average hides the moment the
# PC choked. And a gap is a gap: if the readings stop for a while because the PC slept or the app was
# busy elsewhere, that time is recorded as missing rather than drawn through.

function New-QpSessionWatch {
    <# Starts a session record. Pure bookkeeping - it reads nothing by itself. #>
    param([int]$IntervalSeconds = 10, $Now = $null)
    if (-not $Now) { $Now = Get-Date }
    [pscustomobject]@{
        Started = $Now; Ended = $null; IntervalSeconds = [math]::Max(1, $IntervalSeconds)
        Samples = 0; LastAt = $null; WatchedSeconds = 0.0; Gaps = 0; GapSeconds = 0.0
        PeakCpu = $null; PeakCpuTempC = $null; PeakGpuTempC = $null; PeakGpuUsage = $null
        PeakCommitPct = $null; PeakMemUsed = $null; PeakDiskBusy = $null
        HotSeconds = 0.0; VeryHotSeconds = 0.0; HeldBackSeconds = 0.0; HeldBackSpells = 0; WasHeldBack = $false
        SlowestWhenBusyPct = $null
        BatteryStart = $null; BatteryEnd = $null; PeakWatts = $null
        Busy = @{}
        Alerts = (New-Object System.Collections.ArrayList)
        # One mark per reading, so the session can be drawn as well as described. Each holds how the PC
        # was at that moment and for how long, which is all a timeline needs.
        Marks = (New-Object System.Collections.ArrayList)
    }
}

# How hot the PC was at one moment, worst first. A timeline is stepped by these - darker and taller as
# it gets worse - and a legend names each one, so the picture never rests on colour alone. Being held
# back to cool off is a different measurement, not a fourth level of heat, so it rides its own row.
$script:SessionStates = [ordered]@{
    veryhot = @{ Rank = 3; Word = 'very hot' }
    hot     = @{ Rank = 2; Word = 'hot' }
    quiet   = @{ Rank = 1; Word = 'comfortable' }
    gap     = @{ Rank = 0; Word = 'not watched' }
}

function Get-QpSessionBands {
    <#
        The session squeezed into a fixed number of columns, for drawing. Each column says the worst the
        PC got during the slice of time it covers - worst, never average, because an average would hide
        the very spell a timeline exists to show. A slice with no readings in it stays a gap.
    #>
    param([Parameter(Mandatory)]$Watch, [int]$Columns = 120, $Now = $null)
    $marks = @($Watch.Marks | Where-Object { $_ })
    if (-not $marks.Count) { return @() }
    if (-not $Now) { $Now = Get-Date }
    $from = [datetime]$Watch.Started
    $to = if ($Watch.Ended) { [datetime]$Watch.Ended } else { $Now }
    $span = ($to - $from).TotalSeconds
    if ($span -le 0) { $span = 1 }
    $Columns = [math]::Max(1, $Columns)
    $bins = New-Object 'string[]' $Columns
    $held = New-Object 'bool[]' $Columns
    foreach ($m in $marks) {
        # A mark covers the stretch that ended at its own moment, so it fills every column it touches.
        $endAt = (([datetime]$m.At) - $from).TotalSeconds
        $startAt = $endAt - [double]$m.Seconds
        $first = [int][math]::Floor(($startAt / $span) * $Columns)
        $last = [int][math]::Floor((($endAt - 0.0001) / $span) * $Columns)
        if ($last -lt $first) { $last = $first }
        for ($i = [math]::Max(0, $first); $i -le [math]::Min($Columns - 1, $last); $i++) {
            $have = $bins[$i]
            if (-not $have -or $script:SessionStates[[string]$m.Heat].Rank -gt $script:SessionStates[$have].Rank) { $bins[$i] = [string]$m.Heat }
            if ($m.Held) { $held[$i] = $true }
        }
    }
    $out = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $Columns; $i++) {
        $state = if ($bins[$i]) { $bins[$i] } else { 'gap' }
        [void]$out.Add([pscustomobject]@{
            Index = $i; Heat = $state; Word = $script:SessionStates[$state].Word; Held = $held[$i]
            At = $from.AddSeconds($span * $i / $Columns)
        })
    }
    return @($out)
}

function Add-QpSessionSample {
    <#
        Folds one reading into the record. Each reading stands for the stretch of time since the one
        before it, so that stretch is what the minutes below are counted in. A stretch longer than three
        times the interval means the readings stopped - the PC slept, or the app was busy - and it is
        counted as a gap instead of as time spent hot.
    #>
    param([Parameter(Mandatory)]$Watch, [Parameter(Mandatory)]$Reading)
    if (-not $Reading) { return $Watch }
    $at = if ($Reading.At) { [datetime]$Reading.At } else { Get-Date }
    $span = 0.0
    if ($Watch.LastAt) {
        $span = ($at - [datetime]$Watch.LastAt).TotalSeconds
        if ($span -lt 0) { $span = 0 }
        if ($span -gt ($Watch.IntervalSeconds * 3)) {
            # All of it is unwatched except the usual step this reading itself stands for - that much is
            # known, and it is what lets the timeline show the PC coming back rather than ending in
            # a hole. The gap goes on at its true length, so the hole is never stretched over.
            $missed = $span - $Watch.IntervalSeconds
            $Watch.Gaps++
            $Watch.GapSeconds += $missed
            [void]$Watch.Marks.Add([pscustomobject]@{ At = $at.AddSeconds(-$Watch.IntervalSeconds); Seconds = $missed; Heat = 'gap'; Held = $false })
            $span = $Watch.IntervalSeconds
        }
    }
    $Watch.LastAt = $at
    $Watch.Samples++
    $Watch.WatchedSeconds += $span

    function Set-Peak([string]$Name, $Value) {
        if ($null -eq $Value) { return }
        $v = [double]$Value
        if ($null -eq $Watch.$Name -or $v -gt [double]$Watch.$Name) { $Watch.$Name = $v }
    }
    Set-Peak 'PeakCpu' $Reading.CpuUsage
    Set-Peak 'PeakCpuTempC' $Reading.CpuTempC
    Set-Peak 'PeakCommitPct' $Reading.CommitPct
    Set-Peak 'PeakMemUsed' $Reading.MemUsed
    Set-Peak 'PeakDiskBusy' $Reading.DiskBusyPct
    $hottestGpu = $null
    foreach ($g in @($Reading.Gpus)) {
        Set-Peak 'PeakGpuUsage' $g.Usage
        Set-Peak 'PeakGpuTempC' $g.TempC
        if ($null -ne $g.TempC -and ($null -eq $hottestGpu -or [double]$g.TempC -gt $hottestGpu)) { $hottestGpu = [double]$g.TempC }
    }

    # Heat, in the same words the tiles use, so the record and the screen never disagree.
    $level = 'ok'
    foreach ($t in $Reading.CpuTempC, $hottestGpu) {
        if ($null -eq $t) { continue }
        $w = Get-QpHeatWord $t
        if ($w.Level -eq 'high') { $level = 'high' } elseif ($w.Level -eq 'warn' -and $level -ne 'high') { $level = 'warn' }
    }
    if ($level -eq 'high') { $Watch.VeryHotSeconds += $span; $Watch.HotSeconds += $span }
    elseif ($level -eq 'warn') { $Watch.HotSeconds += $span }

    # Held back means Windows' own cooling brake is on. A processor idling at a low clock is not being
    # held back, it is being sensible, so the clock alone is never called throttling.
    if ($Reading.CpuThrottled) {
        $Watch.HeldBackSeconds += $span
        if (-not $Watch.WasHeldBack) { $Watch.HeldBackSpells++ }
        $Watch.WasHeldBack = $true
    } else { $Watch.WasHeldBack = $false }
    # How much of its speed it had while it was actually working: the figure that means something.
    if ($null -ne $Reading.SpeedPct -and $null -ne $Reading.CpuUsage -and [double]$Reading.CpuUsage -ge 50) {
        if ($null -eq $Watch.SlowestWhenBusyPct -or [double]$Reading.SpeedPct -lt [double]$Watch.SlowestWhenBusyPct) {
            $Watch.SlowestWhenBusyPct = [double]$Reading.SpeedPct
        }
    }

    if ($Reading.Battery) {
        if ($null -eq $Watch.BatteryStart) { $Watch.BatteryStart = [int]$Reading.Battery.Percent }
        $Watch.BatteryEnd = [int]$Reading.Battery.Percent
        if ($Reading.Battery.Direction -eq 'draining') { Set-Peak 'PeakWatts' $Reading.Battery.Watts }
    }

    # One mark for the stretch this reading stands for: how hot it was, and whether the brake was on.
    # Both are kept, because they are two different things and a drawing of the session shows both.
    if ($span -gt 0) {
        $heat = if ($level -eq 'high') { 'veryhot' } elseif ($level -eq 'warn') { 'hot' } else { 'quiet' }
        [void]$Watch.Marks.Add([pscustomobject]@{ At = $at; Seconds = $span; Heat = $heat; Held = [bool]$Reading.CpuThrottled })
        # A very long session is thinned rather than left to grow: neighbours merge, keeping the worse
        # of the two, so the shape of the session survives and nothing is quietly dropped.
        if ($Watch.Marks.Count -gt 4320) {
            $merged = New-Object System.Collections.ArrayList
            for ($i = 0; $i -lt $Watch.Marks.Count; $i += 2) {
                $a = $Watch.Marks[$i]
                $b = if ($i + 1 -lt $Watch.Marks.Count) { $Watch.Marks[$i + 1] } else { $null }
                if (-not $b) { [void]$merged.Add($a); continue }
                $worst = if ($script:SessionStates[[string]$b.Heat].Rank -gt $script:SessionStates[[string]$a.Heat].Rank) { $b.Heat } else { $a.Heat }
                [void]$merged.Add([pscustomobject]@{ At = $b.At; Seconds = ([double]$a.Seconds + [double]$b.Seconds); Heat = $worst; Held = ($a.Held -or $b.Held) })
            }
            $Watch.Marks = $merged
        }
    }

    # Who was at the top of the list, and for how long. One name per reading keeps it honest: it is
    # "busiest at the time", not a measure of how much work each program did.
    $top = @($Reading.CpuTop | Where-Object { $_ -and $_.Name })
    if ($top.Count -and $span -gt 0) {
        $name = [string]$top[0].Name
        if (-not $Watch.Busy.ContainsKey($name)) { $Watch.Busy[$name] = 0.0 }
        $Watch.Busy[$name] += $span
    }
    return $Watch
}

$script:SessionAlerts = @(
    # Worth interrupting someone for, and nothing else. Each one is said once per session: an alert that
    # repeats is an alert people learn to ignore. The wording says what is happening, never what to do
    # about it, because Quietpane cannot know whether the game you are playing is worth the heat.
    @{ Id = 'veryhot';  Level = 'high' }, @{ Id = 'heldback'; Level = 'warn' }
    @{ Id = 'memory';   Level = 'warn' }, @{ Id = 'drive';    Level = 'warn' }
    @{ Id = 'battery';  Level = 'warn' }
)

function Update-QpSessionAlerts {
    <#
        Looks at the session so far and says what is worth mentioning. Each kind is raised once and then
        stays on the record, so nothing nags. Returns only what is new this time.
    #>
    param(
        [Parameter(Mandatory)]$Watch, $Reading, $FreePct = $null, $Now = $null,
        [double]$VeryHotMinutes = 5, [double]$HeldBackMinutes = 5,
        [int]$MemoryPct = 90, [int]$DriveFreePct = 10, [int]$BatteryMinutes = 20
    )
    if (-not $Now) { $Now = Get-Date }
    if ($null -eq $Watch.Alerts) { $Watch | Add-Member -NotePropertyName Alerts -NotePropertyValue (New-Object System.Collections.ArrayList) -Force }
    $already = @($Watch.Alerts | ForEach-Object { $_.Id })
    $new = New-Object System.Collections.ArrayList
    function Raise([string]$Id, [string]$Text, [string]$Level) {
        if ($already -contains $Id) { return }
        $alert = [pscustomobject]@{ Id = $Id; Text = $Text; Level = $Level; At = $Now }
        [void]$Watch.Alerts.Add($alert)
        [void]$new.Add($alert)
    }
    if ($Watch.VeryHotSeconds -ge ($VeryHotMinutes * 60)) {
        Raise 'veryhot' ('It has been very hot for {0} now.' -f (Format-QpSpan $Watch.VeryHotSeconds)) 'high'
    }
    if ($Watch.HeldBackSeconds -ge ($HeldBackMinutes * 60)) {
        Raise 'heldback' ('It has spent {0} held back to cool off.' -f (Format-QpSpan $Watch.HeldBackSeconds)) 'warn'
    }
    if ($Reading) {
        if ($null -ne $Reading.CommitPct -and [int]$Reading.CommitPct -ge $MemoryPct) {
            Raise 'memory' ('Windows has promised {0}% of the memory it can. Things often start to crawl around here.' -f [int]$Reading.CommitPct) 'warn'
        }
        $b = $Reading.Battery
        if ($b -and $b.Direction -eq 'draining' -and $null -ne $b.MinutesLeft -and [int]$b.MinutesLeft -le $BatteryMinutes) {
            Raise 'battery' ('The battery has about {0} left at this rate.' -f (Format-QpSpan ([int]$b.MinutesLeft * 60))) 'warn'
        }
    }
    if ($null -ne $FreePct -and [double]$FreePct -le $DriveFreePct) {
        Raise 'drive' ('The drive Windows is on is down to {0:N0}% free.' -f $FreePct) 'warn'
    }
    return @($new)
}

function Stop-QpSessionWatch {
    param([Parameter(Mandatory)]$Watch, $Now = $null)
    if (-not $Watch.Ended) { $Watch.Ended = $(if ($Now) { $Now } else { Get-Date }) }
    return $Watch
}

function Format-QpSpan {
    <# A length of time in plain words: "40 seconds", "12 minutes", "3 h 20 min". #>
    param([double]$Seconds)
    if ($Seconds -lt 1) { return 'no time at all' }
    if ($Seconds -lt 90) { return ('{0} seconds' -f [int][math]::Round($Seconds)) }
    if ($Seconds -lt 3600) {
        $mins = [int][math]::Round($Seconds / 60)
        return $(if ($mins -eq 1) { '1 minute' } else { "$mins minutes" })
    }
    $h = [int][math]::Floor($Seconds / 3600)
    $m = [int][math]::Round(($Seconds - ($h * 3600)) / 60)
    if ($m -ge 60) { $h++; $m = 0 }
    return $(if ($m -gt 0) { '{0} h {1} min' -f $h, $m } else { $(if ($h -eq 1) { '1 hour' } else { "$h hours" }) })
}

function Get-QpSessionSummary {
    <#
        The session in plain sentences. Anything this PC does not report is left out rather than shown
        as a zero, and the headline is the one thing worth knowing.
    #>
    param([Parameter(Mandatory)]$Watch, $Now = $null)
    if (-not $Now) { $Now = Get-Date }
    $end = if ($Watch.Ended) { [datetime]$Watch.Ended } else { $Now }
    $total = ($end - [datetime]$Watch.Started).TotalSeconds
    $lines = New-Object System.Collections.ArrayList
    [void]$lines.Add('Watched for {0}.' -f (Format-QpSpan $total))
    if ($Watch.Samples -lt 2) {
        return [pscustomobject]@{ Headline = 'Just started - nothing to tell you yet.'; Lines = @($lines); Seconds = $total }
    }

    $heat = @()
    if ($null -ne $Watch.PeakCpuTempC) { $heat += 'the processor reached ' + (Format-QpTemp $Watch.PeakCpuTempC) }
    if ($null -ne $Watch.PeakGpuTempC) { $heat += 'graphics reached ' + (Format-QpTemp $Watch.PeakGpuTempC) }
    if ($heat.Count) { [void]$lines.Add('At its hottest ' + ($heat -join ', ') + '.') }
    if ($Watch.VeryHotSeconds -ge 1) { [void]$lines.Add('Very hot for {0}.' -f (Format-QpSpan $Watch.VeryHotSeconds)) }
    elseif ($Watch.HotSeconds -ge 1) { [void]$lines.Add('Hot for {0}.' -f (Format-QpSpan $Watch.HotSeconds)) }

    if ($Watch.HeldBackSeconds -ge 1) {
        $spells = if ($Watch.HeldBackSpells -eq 1) { 'once' } else { '{0} times' -f $Watch.HeldBackSpells }
        # The outer brackets matter: inside a method call, a comma separates arguments, so a format
        # string with more than one value has to be wrapped or it is handed its values one at a time.
        [void]$lines.Add(('Held back to cool off for {0}, {1}.' -f (Format-QpSpan $Watch.HeldBackSeconds), $spells))
    }
    if ($null -ne $Watch.SlowestWhenBusyPct -and $Watch.SlowestWhenBusyPct -lt 90) {
        [void]$lines.Add('While it was working hardest it had {0:N0}% of its speed.' -f $Watch.SlowestWhenBusyPct)
    }

    if ($null -ne $Watch.PeakMemUsed) {
        $mem = 'Memory peaked at {0}' -f (Format-QpBytes $Watch.PeakMemUsed)
        if ($null -ne $Watch.PeakCommitPct) { $mem += ', and Windows had promised {0:N0}% of what it can' -f $Watch.PeakCommitPct }
        [void]$lines.Add($mem + '.')
    }
    if ($null -ne $Watch.PeakCpu) { [void]$lines.Add('The processor peaked at {0:N0}%.' -f $Watch.PeakCpu) }

    if ($null -ne $Watch.BatteryStart -and $null -ne $Watch.BatteryEnd -and $Watch.BatteryStart -ne $Watch.BatteryEnd) {
        $word = if ($Watch.BatteryEnd -lt $Watch.BatteryStart) { 'dropped' } else { 'went up' }
        $line = 'The battery {0} from {1}% to {2}%' -f $word, $Watch.BatteryStart, $Watch.BatteryEnd
        if ($null -ne $Watch.PeakWatts) { $line += ', taking as much as {0:N1} W' -f $Watch.PeakWatts }
        [void]$lines.Add($line + '.')
    }

    $busy = @($Watch.Busy.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 3 | ForEach-Object { $_.Key })
    if ($busy.Count) { [void]$lines.Add('Busiest: ' + ($busy -join ', ') + '.') }
    if ($Watch.Gaps -gt 0) {
        $stretch = if ($Watch.Gaps -eq 1) { 'One stretch went' } else { '{0} stretches went' -f $Watch.Gaps }
        [void]$lines.Add(('{0} unwatched, {1} in all - the PC was asleep, or Quietpane was busy.' -f $stretch, (Format-QpSpan $Watch.GapSeconds)))
    }

    $headline = if ($Watch.VeryHotSeconds -ge 60) { 'It ran very hot for {0}.' -f (Format-QpSpan $Watch.VeryHotSeconds) }
        elseif ($Watch.HeldBackSeconds -ge 60) { 'It was held back to cool off for {0}.' -f (Format-QpSpan $Watch.HeldBackSeconds) }
        elseif ($null -ne $Watch.PeakCommitPct -and $Watch.PeakCommitPct -ge 90) { 'Memory got tight: Windows had promised {0:N0}% of what it can.' -f $Watch.PeakCommitPct }
        else { 'Nothing to worry about - it stayed comfortable.' }
    [pscustomobject]@{ Headline = $headline; Lines = @($lines); Seconds = $total }
}

function Get-QpBatteryHealth {
    <#
        How much a laptop battery holds now, next to what it held when new. Read-only; $null on a desktop
        or where the battery doesn't say. Windows' own battery report is the fallback: it is written to a
        temporary file, read, and deleted straight away.
    #>
    $design = 0; $full = 0; $cycles = 0
    try {
        $design = [double](@(Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction Stop)[0].DesignedCapacity)
        $full = [double](@(Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop)[0].FullChargedCapacity)
        $cycles = [int](@(Get-CimInstance -Namespace root\wmi -ClassName BatteryCycleCount -ErrorAction SilentlyContinue)[0].CycleCount)
    } catch { }
    if ($design -le 0 -or $full -le 0) {
        $tmp = Join-Path $env:TEMP ('Quietpane-battery-' + [guid]::NewGuid().ToString('N') + '.xml')
        try {
            & powercfg.exe /batteryreport /xml /output $tmp 2>$null | Out-Null
            if (Test-Path -LiteralPath $tmp) {
                [xml]$x = Get-Content -LiteralPath $tmp -Raw
                $b = @($x.BatteryReport.Batteries.Battery)[0]
                if ($b) { $design = [double]$b.DesignCapacity; $full = [double]$b.FullChargeCapacity; if (-not $cycles) { $cycles = [int]$b.CycleCount } }
            }
        } catch { } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
    if ($design -le 0 -or $full -le 0) { return $null }
    [pscustomobject]@{
        DesignWh = [math]::Round($design / 1000, 1); FullWh = [math]::Round($full / 1000, 1)
        # A new battery can hold a touch more than its label says; that is still "100% of new".
        Percent = [int][math]::Min(100, [math]::Round(100 * $full / $design))
        Cycles = $(if ($cycles -gt 0) { $cycles } else { $null })   # many laptops report 0, which means "not recorded"
    }
}

function Get-QpDriveHealth {
    <#
        The drive Windows runs from: Windows' verdict on it, plus its heat, its wear and its hours.

        The drive is asked first and Windows second, because Windows' own answer is often invented. Where
        the storage driver makes a figure up, it tends to make up the same one for ever: a temperature that
        reads exactly 60 C at three in the morning and under a heavy copy alike, a wear of nothing, and no
        hours. Asked directly, the same drive gives a temperature that moves with what it is doing, the real
        share of its writing life that is gone, and how long it has been switched on. Whatever neither can
        answer comes back $null, and is shown as "not shared" rather than as a number.
    #>
    try {
        $letter = ($env:SystemDrive, 'C:')[[int][string]::IsNullOrEmpty($env:SystemDrive)].TrimEnd(':')
        $num = (Get-Partition -DriveLetter $letter -ErrorAction Stop).DiskNumber
        $disk = Get-PhysicalDisk -ErrorAction Stop | Where-Object { "$($_.DeviceId)" -eq "$num" } | Select-Object -First 1
        if (-not $disk) { return $null }

        $temp = $null; $warnAt = $null; $wear = $null; $hours = $null; $written = $null; $fromDrive = $false
        if (Initialize-QpDriveSensors) {
            try {
                $d = [QuietpaneDriveSensors]::Read([int]$num)
                if ($d.HasTemperature) { $temp = [int]$d.TemperatureC; $fromDrive = $true }
                if ($d.WarnAtC -gt 0) { $warnAt = [int]$d.WarnAtC }
                if ($d.HasLife) { $wear = [int]$d.LifeUsedPct; $fromDrive = $true }
                if ($d.PowerOnHours -gt 0) { $hours = [int64]$d.PowerOnHours }
                if ($d.BytesWritten -gt 0) { $written = [int64]$d.BytesWritten }
            } catch { }
        }

        # Only where the drive itself said nothing. This needs administrator rights, which Quietpane has.
        if ($null -eq $temp -or $null -eq $wear -or $null -eq $hours) {
            $rel = $null
            try { $rel = $disk | Get-StorageReliabilityCounter -ErrorAction Stop } catch { }
            if ($rel) {
                if ($null -eq $temp -and [int]$rel.Temperature -gt 0) { $temp = [int]$rel.Temperature }
                if ($null -eq $wear -and $null -ne $rel.Wear -and "$($rel.Wear)" -ne '') { $wear = [int]$rel.Wear }
                if ($null -eq $hours -and [int]$rel.PowerOnHours -gt 0) { $hours = [int64]$rel.PowerOnHours }
            }
        }
        [pscustomobject]@{
            Name = [string]$disk.FriendlyName
            Media = $(switch ([string]$disk.MediaType) { 'SSD' { 'SSD' } 'HDD' { 'hard drive' } default { 'drive' } })
            Health = [string]$disk.HealthStatus          # Healthy, Warning or Unhealthy - Windows' own verdict
            WearPct = $wear                              # share of its rated life used up; SSDs only
            TempC = $temp
            WarnAtC = $warnAt                            # the drive's own "too warm" mark, $null when it doesn't say
            PowerOnHours = $hours
            BytesWritten = $written
            FromDrive = $fromDrive                       # $true when the drive answered for itself
        }
    } catch { return $null }
}

function Get-QpReliability {
    <#
        Windows keeps its own record of how steady this PC has been - the one behind Reliability Monitor,
        which almost nobody opens. Read-only.

        The score is Windows', out of ten, and it is shown with the date it was worked out. Where Windows
        has kept none, this says so rather than inventing one. What went wrong comes from the event log
        rather than from Win32_ReliabilityRecords: the same crashes and hangs, with the program's name,
        in about a tenth of a second instead of nearly six seconds. Windows Update and installer entries
        are deliberately not counted - an update that installed is not a problem.
    #>
    param([int]$Days = 30, $Now = $null)
    if (-not $Now) { $Now = Get-Date }
    $since = $Now.AddDays(-$Days)
    $score = $null; $scoreWhen = $null
    try {
        $m = @(Get-CimInstance Win32_ReliabilityStabilityMetrics -ErrorAction Stop |
            Where-Object { $_.SystemStabilityIndex -gt 0 } | Sort-Object TimeGenerated -Descending | Select-Object -First 1)[0]
        if ($m) { $score = [math]::Round([double]$m.SystemStabilityIndex, 1); $scoreWhen = $m.TimeGenerated }
    } catch { }

    function Read-Log([hashtable]$Filter) {
        try { return @(Get-WinEvent -FilterHashtable $Filter -ErrorAction Stop) } catch { return @() }
    }
    $crashes = Read-Log @{ LogName = 'Application'; ProviderName = 'Application Error'; Id = 1000; StartTime = $since }
    $hangs = Read-Log @{ LogName = 'Application'; ProviderName = 'Application Hang'; Id = 1002; StartTime = $since }
    $blue = Read-Log @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; StartTime = $since }
    $sudden = Read-Log @{ LogName = 'System'; Id = 41; StartTime = $since }

    # Which programs, worst first. The name is the first thing Windows records about the failure.
    $byProgram = @()
    try {
        $byProgram = @(@($crashes + $hangs) | ForEach-Object {
                $n = [string]$_.Properties[0].Value
                if ($n) { $n -replace '\.exe$', '' }
            } | Where-Object { $_ } | Group-Object | Sort-Object Count -Descending |
            ForEach-Object { [pscustomobject]@{ Name = $_.Name; Count = $_.Count } })
    } catch { }

    $up = $null
    try { $up = $Now - (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime } catch { }
    # Windows' own scale: ten is perfect, and it drops for days with a crash on them.
    $word = if ($null -eq $score) { 'not scored' } elseif ($score -ge 9) { 'steady' } elseif ($score -ge 7) { 'mostly steady' } else { 'bumpy' }
    [pscustomobject]@{
        Score = $score; ScoreWhen = $scoreWhen; Word = $word; Days = $Days
        Crashes = $crashes.Count; Hangs = $hangs.Count; BlueScreens = $blue.Count; SuddenStops = $sudden.Count
        Programs = $byProgram; Uptime = $up
        Available = ($null -ne $score -or $crashes.Count -or $hangs.Count -or $sudden.Count)
    }
}

#endregion

#region ---------------------------------------------------------------- came back (what switched itself on again)

# Big Windows updates and driver updates are known to switch settings back on and bring apps back.
# Quietpane keeps a short note of what was quiet last time (setting ids, app and startup names, and the
# Windows version - nothing personal) so it can say "these came back" instead of quietly re-counting.

function Get-QpWindowsVersion {
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    [pscustomobject]@{ Display = [string]$cv.DisplayVersion; Build = ('{0}.{1}' -f $cv.CurrentBuild, $cv.UBR) }
}

function Get-QpQuietSnapshot {
    <# What is quiet on this PC right now, reduced to plain lists, from the window's state. #>
    param([Parameter(Mandatory)]$State)
    [pscustomobject]@{
        Privacy     = @(@($State.Privacy.Keys) | Where-Object { $State.Privacy[$_] -eq 'Applied' } | Sort-Object)
        Vendors     = @(foreach ($v in @($State.Vendors | Where-Object { $_ })) { foreach ($i in @($v.Items)) { if ($i.Status -eq 'Applied') { [string]$i.Id } } }) | Sort-Object
        AppsPresent = @($State.Apps | Where-Object { $_ } | ForEach-Object { [string]$_.Name } | Sort-Object)
        StartupOff  = @($State.Startup | Where-Object { $_ -and -not $_.On -and -not $_.Keep } | ForEach-Object { [string]$_.Id } | Sort-Object)
    }
}

function Update-QpQuietNote {
    <#
        Compares this PC with the note from last time and says what came back. Anything that got quieter
        is simply added to the note; only things switching themselves back ON are reported, and they keep
        being reported until they are put right or you say "that was me" (-Accept). After your own changes
        the window passes -Accept too, so nothing you did yourself is ever reported as "came back".
    #>
    param([Parameter(Mandatory)]$State, [switch]$Accept, [string]$Path = (Join-Path $script:DataRoot 'quiet-note.json'))
    $now = Get-QpQuietSnapshot -State $State
    $win = Get-QpWindowsVersion
    $old = $null
    if (-not $Accept -and (Test-Path -LiteralPath $Path)) { try { $old = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { $old = $null } }
    $nothing = [pscustomobject]@{ Count = 0; Privacy = @(); Vendors = @(); Apps = @(); Startup = @(); Since = $null; WindowsBefore = ''; WindowsNow = ''; WindowsUpdated = $false }
    function Save-Note($lists, $since, $winAt) {
        try {
            $dir = Split-Path $Path -Parent
            if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            [pscustomobject]@{
                Saved = $since; Windows = $winAt
                Privacy = @($lists.Privacy); Vendors = @($lists.Vendors); AppsPresent = @($lists.AppsPresent); StartupOff = @($lists.StartupOff)
            } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Path -Encoding UTF8
        } catch { }
    }
    if (-not $old) {
        Save-Note $now ((Get-Date).ToString('s')) $win
        return $nothing
    }
    # Only what is really on again counts. A setting this PC no longer has, one a newer Quietpane no longer
    # lists, or a brand extra whose app was uninstalled hasn't "come back" - it has gone, and saying
    # otherwise would be a false alarm (and, with the sign-in check, a badge for nothing).
    $gonePrivacy = @(@($old.Privacy) | Where-Object { $_ -and $State.Privacy[$_] -in 'NotApplied', 'Partial' })
    $vendorNow = @{}
    foreach ($v in @($State.Vendors | Where-Object { $_ })) { foreach ($i in @($v.Items)) { $vendorNow[[string]$i.Id] = [string]$i.Status } }
    $goneVendors = @(@($old.Vendors) | Where-Object { $_ -and $vendorNow[$_] -in 'NotApplied', 'Partial' })
    $backApps    = @($now.AppsPresent | Where-Object { $_ -and @($old.AppsPresent) -notcontains $_ })
    # Only startup items that still exist and are on again count; one that was uninstalled hasn't "come back".
    $backStart   = @(@($old.StartupOff) | Where-Object { $id = $_; $id -and $now.StartupOff -notcontains $id -and @($State.Startup | Where-Object { $_.Id -eq $id -and $_.On }).Count })
    $count = $gonePrivacy.Count + $goneVendors.Count + $backApps.Count + $backStart.Count

    # Keep the note: what came back stays in it (so it's reported until dealt with), improvements join it.
    $merged = [pscustomobject]@{
        Privacy     = @(@($old.Privacy) + $now.Privacy | Where-Object { $_ } | Sort-Object -Unique)
        Vendors     = @(@($old.Vendors) + $now.Vendors | Where-Object { $_ } | Sort-Object -Unique)
        AppsPresent = @(@($old.AppsPresent) | Where-Object { $_ -and $now.AppsPresent -contains $_ })
        StartupOff  = @(@($old.StartupOff) + $now.StartupOff | Where-Object { $_ } | Sort-Object -Unique)
    }
    $since = if ($old.Saved) { [string]$old.Saved } else { (Get-Date).ToString('s') }
    $winAt = if ($count -and $old.Windows) { $old.Windows } else { $win }   # remember the old version while there's something to explain
    if (-not $count) { $since = (Get-Date).ToString('s') }
    Save-Note $merged $since $winAt
    if (-not $count) { return $nothing }

    $privacyCat = @((Get-QpCatalog privacy).Items)
    $vendorItems = @(foreach ($v in @($State.Vendors | Where-Object { $_ })) { @($v.Items) })
    $wasWin = if ($old.Windows) { $old.Windows } else { $win }
    [pscustomobject]@{
        Count   = $count
        Privacy = @($gonePrivacy | ForEach-Object { $id = $_; [pscustomobject]@{ Id = $id; Title = $(($privacyCat | Where-Object { $_.Id -eq $id } | Select-Object -First 1).Title) } })
        Vendors = @($goneVendors | ForEach-Object { $id = $_; [pscustomobject]@{ Id = $id; Title = $(($vendorItems | Where-Object { $_.Id -eq $id } | Select-Object -First 1).Title) } })
        Apps    = @($backApps | ForEach-Object { $n = $_; [pscustomobject]@{ Id = $n; Title = $(($State.Apps | Where-Object { $_.Name -eq $n } | Select-Object -First 1).Title) } })
        Startup = @($backStart | ForEach-Object { $id = $_; [pscustomobject]@{ Id = $id; Title = $(($State.Startup | Where-Object { $_.Id -eq $id } | Select-Object -First 1).Name) } })
        Since   = $(try { [datetime]$old.Saved } catch { $null })
        WindowsBefore = "$($wasWin.Display) build $($wasWin.Build)".Trim()
        WindowsNow    = "$($win.Display) build $($win.Build)".Trim()
        WindowsUpdated = ([string]$wasWin.Build -ne [string]$win.Build)
        # "from 24H2 to 25H2" for a big update, "from build 26200.9000 to 26200.9457" for a monthly one.
        WindowsChange = $(if ($wasWin.Display -and $win.Display -and $wasWin.Display -ne $win.Display) { "from $($wasWin.Display) to $($win.Display)" } else { "from build $($wasWin.Build) to $($win.Build)" })
    }
}

function Invoke-QpPutBack {
    <# Switches off again exactly what came back - nothing else - inside one restore point. #>
    param([string[]]$PrivacyIds, [string[]]$VendorIds, [string[]]$AppNames, [string[]]$StartupIds)
    if (-not ($PrivacyIds -or $VendorIds -or $AppNames -or $StartupIds)) { Write-QpLog 'Nothing came back - nothing to do.' 'OK'; return }
    Start-QpSession 'came-back'
    if ($PrivacyIds) { Invoke-QpPrivacy -Ids $PrivacyIds }
    if ($VendorIds)  { Invoke-QpVendor -Ids $VendorIds }
    if ($StartupIds) { Invoke-QpStartup -Ids $StartupIds }
    if ($AppNames)   { Invoke-QpRemoveApps -Names $AppNames -Deprovision }
    Stop-QpSession
}

#endregion

#region ---------------------------------------------------------------- restore points

function Start-QpSession {
    param([string]$Name)
    $stamp = Get-QpStamp
    $path = Join-Path $script:DataRoot "restore\$stamp-$Name"
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    $script:Session = @{ Name = $Name; Path = $path; Started = (Get-Date).ToString('s'); Entries = New-Object System.Collections.ArrayList }
    $script:LogFile = Join-Path $path 'log.txt'
    Write-QpLog "Restore point: $path" 'STEP'
}

function Save-QpSession {
    if (-not $script:Session) { return }
    $data = @{ Name = $script:Session.Name; Started = $script:Session.Started; Entries = @($script:Session.Entries) }
    $data | ConvertTo-Json -Depth 6 | Set-Content -Path (Join-Path $script:Session.Path 'state.json') -Encoding UTF8
}

function Add-QpUndo {
    param([hashtable]$Entry)
    if (-not $script:Session) { return }
    [void]$script:Session.Entries.Add($Entry)
    Save-QpSession
}

function Stop-QpSession {
    if (-not $script:Session) { return }
    if ($script:Session.Entries.Count -eq 0) {
        # Nothing changed, so there is nothing to undo - don't leave an empty restore point in the Undo list.
        $path = $script:Session.Path
        $script:Session = $null
        $script:LogFile = $null
        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
        Write-QpLog 'Nothing needed changing, so no restore point was kept.' 'OK'
        return
    }
    Save-QpSession
    Write-QpLog ("Finished. {0} change(s) recorded - they can be undone from the Undo tab." -f $script:Session.Entries.Count) 'OK'
    $script:Session = $null
    $script:LogFile = $null
}

function Get-QpRestorePoints {
    $roots = @((Join-Path $script:DataRoot 'restore'), (Join-Path $script:LegacyDataRoot 'restore')) | Where-Object { Test-Path $_ }
    if (-not $roots.Count) { return @() }
    Get-ChildItem -Path $roots -Directory | Sort-Object Name -Descending | ForEach-Object {
        $count = 0
        $state = Join-Path $_.FullName 'state.json'
        if (Test-Path $state) { try { $count = @((Get-Content $state -Raw | ConvertFrom-Json).Entries | Where-Object { $_ }).Count } catch { } }
        # A restore point with nothing in it has nothing to undo, so it isn't offered (older versions made some).
        if ($count -eq 0) { return }
        [pscustomobject]@{
            Name    = $_.Name
            Path    = $_.FullName
            Changes = $count
            Undone  = (Test-Path (Join-Path $_.FullName 'undone.txt'))
        }
    }
}

function Invoke-QpUndo {
    <#
        Puts back every change in one restore point, newest first. Returns how many changes came back and
        how many didn't. The restore point is only marked as undone when every change came back, so
        anything that failed can simply be tried again - putting a setting back twice does no harm.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $stateFile = Join-Path $Path 'state.json'
    if (-not (Test-Path $stateFile)) { Write-QpLog "No state.json in $Path" 'ERROR'; return [pscustomobject]@{ Restored = 0; Failed = 1; Readable = $false } }
    try { $state = Get-Content $stateFile -Raw | ConvertFrom-Json }
    catch {
        Write-QpLog "That restore point cannot be read, so nothing was undone from it. Its own folder is still at $Path." 'ERROR'
        return [pscustomobject]@{ Restored = 0; Failed = 1; Readable = $false }
    }
    $entries = @($state.Entries | Where-Object { $_ })
    [array]::Reverse($entries)
    Write-QpLog "Undoing $($entries.Count) change(s) from $(Split-Path $Path -Leaf)" 'STEP'
    $failed = 0
    foreach ($e in $entries) {
        try {
            switch ($e.Type) {
                'Service' {
                    try { Set-Service -Name $e.Name -StartupType $e.StartType -ErrorAction Stop }
                    catch {
                        $map = @{ Disabled = 'disabled'; Manual = 'demand'; Automatic = 'auto' }
                        $out = & sc.exe config $e.Name start= $map[[string]$e.StartType] 2>&1
                        if ($LASTEXITCODE -ne 0) { throw "Windows refused ($(($out | Out-String).Trim()))" }
                    }
                    if ($e.WasRunning) { Start-Service -Name $e.Name -ErrorAction SilentlyContinue }
                    Write-QpLog "Service $($e.Name) restored to $($e.StartType)" 'OK'
                }
                'Task' {
                    Enable-ScheduledTask -TaskPath $e.Path -TaskName $e.Name -ErrorAction Stop | Out-Null
                    Write-QpLog "Task $($e.Path)$($e.Name) re-enabled" 'OK'
                }
                'Reg' {
                    if ($e.Existed) {
                        Set-ItemProperty -Path $e.Path -Name $e.Name -Value $e.OldValue -Type $e.Kind -ErrorAction Stop
                        Write-QpLog "$($e.Path)\$($e.Name) restored to $($e.OldValue)" 'OK'
                    } else {
                        Remove-ItemProperty -Path $e.Path -Name $e.Name -ErrorAction SilentlyContinue
                        Write-QpLog "$($e.Path)\$($e.Name) removed (was not set before)" 'OK'
                    }
                }
                'StartupApproved' {
                    # Put back exactly what was there before - or nothing, if nothing was.
                    if ($e.Existed -and $e.OldBytes) {
                        Set-ItemProperty -Path $e.Path -Name $e.Name -Value ([Convert]::FromBase64String([string]$e.OldBytes)) -Type Binary -ErrorAction Stop
                    } else {
                        Remove-ItemProperty -Path $e.Path -Name $e.Name -ErrorAction SilentlyContinue
                    }
                    Write-QpLog "$(if ($e.Label) { $e.Label } else { $e.Name }) will start when you sign in again" 'OK'
                }
                'ExtBlock' {
                    # Take the policy line away again, and the list itself if Quietpane made it.
                    Remove-ItemProperty -Path $e.Path -Name $e.Name -ErrorAction SilentlyContinue
                    if ($e.KeyCreated) {
                        $left = $null
                        try { $left = Get-Item -Path $e.Path -ErrorAction Stop } catch { }
                        if ($left -and $left.ValueCount -eq 0 -and $left.SubKeyCount -eq 0) { Remove-Item -Path $e.Path -Force -ErrorAction SilentlyContinue }
                    }
                    Write-QpLog "$($e.Browser) can load $($e.Label) again the next time you open it" 'OK'
                }
                'Env' {
                    [Environment]::SetEnvironmentVariable($e.Name, $e.OldValue, 'Machine')
                    Write-QpLog "Environment variable $($e.Name) restored" 'OK'
                }
                'FileRestore' {
                    Copy-Item -LiteralPath $e.Backup -Destination $e.Path -Force
                    Write-QpLog "Restored $($e.Path) from backup" 'OK'
                }
                'FileCreated' {
                    if (Move-QpToRecycleBin $e.Path) { Write-QpLog "Moved created file $($e.Path) to the Recycle Bin" 'OK' }
                }
                'Hosts' {
                    Remove-QpHostsBlock -Tag $e.Tag
                }
                'Recycled' {
                    Write-QpLog "Files from $($e.Path) are in the Recycle Bin - restore them there if you need them" 'INFO'
                }
                'Appx' {
                    Write-QpLog "App $($e.Name) was removed - reinstall it from the Microsoft Store if you want it back" 'INFO'
                }
                default { Write-QpLog "Unknown undo entry type: $($e.Type)" 'WARN' }
            }
        } catch {
            $failed++
            Write-QpLog "Could not undo $($e.Type) $($e.Name)$($e.Path): $($_.Exception.Message)" 'WARN'
        }
    }
    if ($failed) {
        Write-QpLog ("{0} of {1} change(s) could not be put back. The rest are back as they were. This restore point stays in the Undo list, so you can try again." -f $failed, $entries.Count) 'WARN'
    } else {
        Set-Content -Path (Join-Path $Path 'undone.txt') -Value (Get-Date).ToString('s')
        Write-QpLog 'Undo finished. Restart the PC to make sure everything is back in effect.' 'OK'
    }
    [pscustomobject]@{ Restored = $entries.Count - $failed; Failed = $failed; Readable = $true }
}

#endregion

#region ---------------------------------------------------------------- change engine

function Invoke-QpServiceAction {
    param($Action, [switch]$Preview)
    $svc = Get-Service -Name $Action.Name -ErrorAction SilentlyContinue
    if (-not $svc) { Write-QpLog "Service $($Action.Name) is not on this PC - skipped" 'SKIP'; return }
    $current = [string]$svc.StartType
    $target = [string]$Action.StartType
    if ($current -eq $target) { Write-QpLog "Service $($Action.Name) is already $target" 'OK'; return }
    if ($Preview) { Write-QpLog "Would change service $($Action.Name): $current -> $target" 'PREVIEW'; return }
    Add-QpUndo @{ Type = 'Service'; Name = $Action.Name; StartType = $current; WasRunning = ($svc.Status -eq 'Running') }
    if ($target -eq 'Disabled') { Stop-Service -Name $Action.Name -Force -ErrorAction SilentlyContinue }
    try {
        Set-Service -Name $Action.Name -StartupType $target -ErrorAction Stop
    } catch {
        $map = @{ Disabled = 'disabled'; Manual = 'demand'; Automatic = 'auto' }
        & sc.exe config $Action.Name start= $map[$target] | Out-Null
    }
    $after = [string](Get-Service -Name $Action.Name).StartType
    if ($after -eq $target) { Write-QpLog "Service $($Action.Name) -> $target" 'OK' }
    else { Write-QpLog "Service $($Action.Name) is protected by Windows and could not be changed" 'WARN' }
}

function Invoke-QpTaskAction {
    param($Action, [switch]$Preview)
    # Found the quick way; switched off with Disable-ScheduledTask, as always.
    $tasks = @(Get-QpTasksMatching -Path $Action.Path -Name $Action.Name)
    if ($tasks.Count -eq 0) { Write-QpLog "Task $($Action.Path)$($Action.Name) is not on this PC - skipped" 'SKIP'; return }
    foreach ($t in $tasks) {
        $id = "$($t.TaskPath)$($t.TaskName)"
        if ($t.State -eq 'Disabled') { Write-QpLog "Task $id is already disabled" 'OK'; continue }
        if ($Preview) { Write-QpLog "Would disable task $id" 'PREVIEW'; continue }
        try {
            Disable-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName -ErrorAction Stop | Out-Null
            Add-QpUndo @{ Type = 'Task'; Path = $t.TaskPath; Name = $t.TaskName }
            Write-QpLog "Task $id disabled" 'OK'
        } catch {
            Write-QpLog "Task $id is protected by Windows - left as is" 'WARN'
        }
    }
}

function Invoke-QpRegAction {
    param($Action, [switch]$Preview)
    $kind = if ($Action.Kind) { $Action.Kind } else { 'DWord' }
    $label = "$($Action.Path)\$($Action.Name)"
    $cur = Get-QpRegValue -Path $Action.Path -Name $Action.Name
    if ($cur.Exists -and ("$($cur.Value)" -eq "$($Action.Value)")) { Write-QpLog "$label is already $($Action.Value)" 'OK'; return }
    if ($Preview) {
        $from = if ($cur.Exists) { $cur.Value } else { '(not set)' }
        Write-QpLog "Would set $label : $from -> $($Action.Value)" 'PREVIEW'
        return
    }
    # Undo puts back the old value with its OLD type: text stays text, even where the new value is a number.
    $oldKind = if ($cur.Exists -and $cur.Kind -in 'String', 'ExpandString', 'Binary', 'DWord', 'MultiString', 'QWord') { $cur.Kind } else { $kind }
    Add-QpUndo @{ Type = 'Reg'; Path = $Action.Path; Name = $Action.Name; Existed = $cur.Exists; OldValue = $cur.Value; Kind = $oldKind }
    try {
        if (-not (Test-Path -Path $Action.Path)) { New-Item -Path $Action.Path -Force | Out-Null }
        Set-ItemProperty -Path $Action.Path -Name $Action.Name -Value $Action.Value -Type $kind -ErrorAction Stop
        Write-QpLog "$label = $($Action.Value)" 'OK'
    } catch {
        Write-QpLog "Could not set $label : $($_.Exception.Message)" 'ERROR'
    }
}

function Invoke-QpEnvAction {
    param($Action, [switch]$Preview)
    $cur = [Environment]::GetEnvironmentVariable($Action.Name, 'Machine')
    if ($cur -eq $Action.Value) { Write-QpLog "$($Action.Name) is already $($Action.Value)" 'OK'; return }
    if ($Preview) { Write-QpLog "Would set environment variable $($Action.Name)=$($Action.Value)" 'PREVIEW'; return }
    Add-QpUndo @{ Type = 'Env'; Name = $Action.Name; OldValue = $cur }
    [Environment]::SetEnvironmentVariable($Action.Name, $Action.Value, 'Machine')
    Write-QpLog "Environment variable $($Action.Name)=$($Action.Value)" 'OK'
}

function Invoke-QpVSCodeTelemetry {
    param([switch]$Preview)
    $codeRoot = Join-Path $env:APPDATA 'Code'
    if (-not (Test-Path $codeRoot)) { Write-QpLog 'VS Code is not installed for this user - skipped' 'SKIP'; return }
    $userDir = Join-Path $codeRoot 'User'
    $file = Join-Path $userDir 'settings.json'
    $setting = '"telemetry.telemetryLevel": "off"'
    if (Test-Path $file) {
        $raw = Get-Content -LiteralPath $file -Raw
        if ($raw -match '"telemetry\.telemetryLevel"\s*:\s*"off"') { Write-QpLog 'VS Code telemetry is already off' 'OK'; return }
        if ($raw -match '"telemetry\.telemetryLevel"') { Write-QpLog 'VS Code has telemetry.telemetryLevel set to another value - set it to "off" in VS Code settings' 'WARN'; return }
        if ($Preview) { Write-QpLog "Would add $setting to $file" 'PREVIEW'; return }
        $backup = Join-Path $script:Session.Path 'vscode-settings.json.bak'
        Copy-Item -LiteralPath $file -Destination $backup -Force
        Add-QpUndo @{ Type = 'FileRestore'; Path = $file; Backup = $backup }
        $new = ([regex]'\{').Replace($raw, "{`r`n    $setting,", 1)
        Set-Content -LiteralPath $file -Value $new -Encoding UTF8
    } else {
        if ($Preview) { Write-QpLog "Would create $file with $setting" 'PREVIEW'; return }
        New-Item -ItemType Directory -Path $userDir -Force | Out-Null
        Set-Content -LiteralPath $file -Value "{`r`n    $setting`r`n}" -Encoding UTF8
        Add-QpUndo @{ Type = 'FileCreated'; Path = $file }
    }
    Write-QpLog 'VS Code telemetry turned off' 'OK'
}

function Invoke-QpAction {
    param($Action, [switch]$Preview)
    switch ($Action.Type) {
        'Service'         { Invoke-QpServiceAction -Action $Action -Preview:$Preview }
        'Task'            { Invoke-QpTaskAction -Action $Action -Preview:$Preview }
        'Reg'             { Invoke-QpRegAction -Action $Action -Preview:$Preview }
        'Env'             { Invoke-QpEnvAction -Action $Action -Preview:$Preview }
        'Hosts'           { Add-QpHostsBlock -HostNames $Action.Hosts -Tag $Action.Tag -Preview:$Preview }
        'VSCodeTelemetry' { Invoke-QpVSCodeTelemetry -Preview:$Preview }
        default           { Write-QpLog "Unknown action type '$($Action.Type)'" 'WARN' }
    }
}

function Test-QpActionApplied {
    # Returns $true (done), $false (not done) or $null (not applicable on this PC).
    param($Action)
    switch ($Action.Type) {
        'Service' {
            $svc = Get-Service -Name $Action.Name -ErrorAction SilentlyContinue
            if (-not $svc) { return $null }
            return ([string]$svc.StartType -eq [string]$Action.StartType)
        }
        'Task' {
            $tasks = @(Get-QpTasksMatching -Path $Action.Path -Name $Action.Name)
            if ($tasks.Count -eq 0) { return $null }
            return (@($tasks | Where-Object { $_.State -ne 'Disabled' }).Count -eq 0)
        }
        'Reg' {
            $cur = Get-QpRegValue -Path $Action.Path -Name $Action.Name
            return ($cur.Exists -and ("$($cur.Value)" -eq "$($Action.Value)"))
        }
        'Env' { return ([Environment]::GetEnvironmentVariable($Action.Name, 'Machine') -eq $Action.Value) }
        'Hosts' {
            $lines = @(Get-Content -Path $script:HostsPath -ErrorAction SilentlyContinue)
            return (@($Action.Hosts | Where-Object { -not (Test-QpHostBlocked -Lines $lines -HostName $_) }).Count -eq 0)
        }
        'VSCodeTelemetry' {
            $file = Join-Path $env:APPDATA 'Code\User\settings.json'
            if (-not (Test-Path (Join-Path $env:APPDATA 'Code'))) { return $null }
            if (-not (Test-Path $file)) { return $false }
            return ((Get-Content -LiteralPath $file -Raw) -match '"telemetry\.telemetryLevel"\s*:\s*"off"')
        }
    }
    return $null
}

function Get-QpPrivacyStatus {
    # Returns a hashtable Id -> 'Applied' | 'Partial' | 'NotApplied' | 'NotApplicable'
    $result = @{}
    foreach ($item in (Get-QpCatalog privacy).Items) {
        $states = @($item.Actions | ForEach-Object { Test-QpActionApplied $_ })
        $relevant = @($states | Where-Object { $null -ne $_ })
        if ($relevant.Count -eq 0) { $result[$item.Id] = 'NotApplicable'; continue }
        $done = @($relevant | Where-Object { $_ }).Count
        if ($done -eq $relevant.Count) { $result[$item.Id] = 'Applied' }
        elseif ($done -gt 0) { $result[$item.Id] = 'Partial' }
        else { $result[$item.Id] = 'NotApplied' }
    }
    return $result
}

function Invoke-QpPrivacy {
    param([string[]]$Ids, [switch]$Preview)
    $items = @((Get-QpCatalog privacy).Items | Where-Object { $Ids -contains $_.Id })
    if ($items.Count -eq 0) { Write-QpLog 'Nothing selected.' 'WARN'; return }
    $own = (-not $Preview) -and (-not $script:Session)   # join an existing restore point (one-click) if there is one
    if ($Preview) { Write-QpLog 'PREVIEW - nothing will be changed.' 'STEP' } elseif ($own) { Start-QpSession 'privacy' }
    foreach ($item in $items) {
        Write-QpLog $item.Title 'STEP'
        foreach ($a in $item.Actions) { Invoke-QpAction -Action $a -Preview:$Preview }
    }
    if ($Preview) { Write-QpLog 'Preview finished. Nothing was changed.' 'OK' } elseif ($own) { Stop-QpSession }
}

#endregion

#region ---------------------------------------------------------------- apps

function Test-QpProtectedApp {
    param([string]$Name)
    return ($Name -match $script:ProtectedAppPattern)
}

function Get-QpBloatApps {
    $installed = @(Get-QpAppxPackages)
    foreach ($item in (Get-QpCatalog apps).Items) {
        $pkg = $installed | Where-Object { $_.Name -like $item.Name } | Select-Object -First 1
        if ($pkg -and -not (Test-QpProtectedApp $pkg.Name)) {
            [pscustomobject]@{
                Name        = $pkg.Name
                Title       = $item.Title
                Description = $item.Description
                Recommended = [bool]$item.Recommended
            }
        }
    }
}

function Invoke-QpRemoveApps {
    param([string[]]$Names, [switch]$Deprovision, [switch]$Preview)
    if (-not $Names) { Write-QpLog 'Nothing selected.' 'WARN'; return }
    $own = (-not $Preview) -and (-not $script:Session)
    if ($Preview) { Write-QpLog 'PREVIEW - nothing will be changed.' 'STEP' } elseif ($own) { Start-QpSession 'apps' }
    foreach ($n in $Names) {
        if (Test-QpProtectedApp $n) { Write-QpLog "$n is protected and will not be removed" 'WARN'; continue }
        $pkgs = @(Get-AppxPackage -Name $n -ErrorAction SilentlyContinue)
        if ($pkgs.Count -eq 0) { Write-QpLog "$n is not installed - skipped" 'SKIP'; continue }
        if ($Preview) { Write-QpLog "Would remove $n" 'PREVIEW'; continue }
        foreach ($p in $pkgs) {
            try {
                Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop
                Add-QpUndo @{ Type = 'Appx'; Name = $n }
                Write-QpLog "Removed $n" 'OK'
            } catch {
                Write-QpLog "Could not remove $n : $($_.Exception.Message)" 'WARN'
            }
        }
        if ($Deprovision) {
            Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue | Where-Object DisplayName -eq $n | ForEach-Object {
                try {
                    Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -ErrorAction Stop | Out-Null
                    Write-QpLog "$n will not be reinstalled for new user accounts" 'OK'
                } catch { }
            }
        }
    }
    if ($Preview) { Write-QpLog 'Preview finished. Nothing was changed.' 'OK' } elseif ($own) { Stop-QpSession }
}

#endregion

#region ---------------------------------------------------------------- startup (what runs at sign-in)

# Switching an item off works exactly like Task Manager's Startup tab: the entry stays where it is,
# and Windows is told to skip it at sign-in. Nothing is deleted, the program still opens normally,
# and Undo switches it back on.

$script:StartupApprovedRoot = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
$script:AppStartupRoot = 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\SystemAppData'

function Get-QpStartupAdvice {
    <# Whether an item must stay on, and a plain-language line about it, from the startup catalog. #>
    param([string]$Text, $Catalog = (Get-QpCatalog startup))
    foreach ($k in $Catalog.Keep) { if ($Text -match $k.Match) { return [pscustomobject]@{ Keep = $true; Why = $k.Why; Note = $k.Why } } }
    foreach ($n in $Catalog.Notes) { if ($Text -match $n.Match) { return [pscustomobject]@{ Keep = $false; Why = ''; Note = $n.Note } } }
    [pscustomobject]@{ Keep = $false; Why = ''; Note = '' }
}

function Resolve-QpCommandTarget {
    <# The program a startup command points to, as best it can be worked out. Never throws. #>
    param([string]$Command)
    try {
        $c = [Environment]::ExpandEnvironmentVariables("$Command").Trim()
        if (-not $c) { return '' }
        if ($c -match '^"([^"]+)"') { return $matches[1] }
        if ($c -match '^(.+?\.(exe|com|bat|cmd|vbs|js|ps1|scr))(\s|$)') { return $matches[1] }
        return ($c -split '\s+')[0]
    } catch { return '' }
}

function Get-QpStartupItems {
    <#
        Everything that starts when you sign in - Run entries, the Startup folders and Store apps - and
        whether each is switched on. Read-only. Policy-set entries are listed but can't be changed here.
        The source lists can be swapped for tests, so tests never touch the real sign-in settings.
    #>
    param($RunSources, $FolderSources, [string]$AppRoot = $script:AppStartupRoot)
    $cat = Get-QpCatalog startup
    $sa = $script:StartupApprovedRoot
    if ($null -eq $RunSources) {
        $RunSources = @(
            @{ Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Approved = "HKCU:\$sa\Run"; Everyone = $false }
            @{ Key = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'; Approved = "HKLM:\$sa\Run"; Everyone = $true }
            @{ Key = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = "HKLM:\$sa\Run32"; Everyone = $true }
        )
    }
    if ($null -eq $FolderSources) {
        $FolderSources = @(
            @{ Folder = [Environment]::GetFolderPath('Startup'); Approved = "HKCU:\$sa\StartupFolder"; Everyone = $false }
            @{ Folder = [Environment]::GetFolderPath('CommonStartup'); Approved = "HKLM:\$sa\StartupFolder"; Everyone = $true }
        )
    }
    function Test-Off($ApprovedPath, [string]$Name) {
        # Task Manager marks a switched-off entry with an odd first byte (usually 03).
        $v = Get-QpRegValue -Path $ApprovedPath -Name $Name
        return ($v.Exists -and $v.Value -is [byte[]] -and $v.Value.Length -and ($v.Value[0] -band 1))
    }
    function Get-Publisher([string]$Path) {
        try { if ($Path -and (Test-Path -LiteralPath $Path -PathType Leaf)) { return ([string](Get-Item -LiteralPath $Path).VersionInfo.CompanyName).Trim() } } catch { }
        return ''
    }
    function Get-FriendlyName([string]$Path, [string]$Fallback) {
        # "utweb" -> "uTorrent Web": the program's own name for itself, when it has one.
        try {
            if ($Path -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
                $vi = (Get-Item -LiteralPath $Path).VersionInfo
                # Description first: Windows' own files all call their product "Microsoft Windows Operating System".
                foreach ($n in [string]$vi.FileDescription, [string]$vi.ProductName) {
                    $n = $n.Trim()
                    if ($n -and $n.Length -le 60 -and $n -notmatch '(?i)operating system') { return $n }
                }
            }
        } catch { }
        return $Fallback
    }
    $out = New-Object System.Collections.ArrayList

    foreach ($s in $RunSources) {
        $p = Get-ItemProperty -Path $s.Key -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        foreach ($prop in ($p.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' })) {
            $target = Resolve-QpCommandTarget $prop.Value
            $advice = Get-QpStartupAdvice -Text "$($prop.Name) $($prop.Value)" -Catalog $cat
            [void]$out.Add([pscustomobject]@{
                Id = "$($s.Approved)|$($prop.Name)"; Name = (Get-FriendlyName $target $prop.Name); Kind = 'Run'; Everyone = [bool]$s.Everyone
                Command = [string]$prop.Value; Target = $target; Publisher = (Get-Publisher $target)
                On = -not (Test-Off $s.Approved $prop.Name); Locked = $false
                Keep = $advice.Keep; KeepWhy = $advice.Why; Note = $advice.Note
                Missing = ($target -and [IO.Path]::IsPathRooted($target) -and -not (Test-Path -LiteralPath $target))
                ApprovedPath = $s.Approved; ApprovedName = $prop.Name; StatePath = ''
            })
        }
    }

    $shell = $null
    foreach ($s in $FolderSources) {
        if (-not $s.Folder -or -not (Test-Path -LiteralPath $s.Folder)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $s.Folder -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' })) {
            $target = $f.FullName
            if ($f.Extension -eq '.lnk') {
                try { if (-not $shell) { $shell = New-Object -ComObject WScript.Shell }; $target = $shell.CreateShortcut($f.FullName).TargetPath } catch { }
            }
            $advice = Get-QpStartupAdvice -Text "$($f.BaseName) $target" -Catalog $cat
            [void]$out.Add([pscustomobject]@{
                Id = "$($s.Approved)|$($f.Name)"; Name = (Get-FriendlyName $target $f.BaseName); Kind = 'Folder'; Everyone = [bool]$s.Everyone
                Command = $f.FullName; Target = $target; Publisher = (Get-Publisher $target)
                On = -not (Test-Off $s.Approved $f.Name); Locked = $false
                Keep = $advice.Keep; KeepWhy = $advice.Why; Note = $advice.Note
                Missing = ($target -and -not (Test-Path -LiteralPath $target))
                ApprovedPath = $s.Approved; ApprovedName = $f.Name; StatePath = ''
            })
        }
    }

    # Store apps keep their own switch. State: 0 off, 1 switched off by you, 2 on, 3 off by policy, 4 on by policy.
    if ($AppRoot -and (Test-Path $AppRoot)) {
        $names = @{}
        try { foreach ($pkg in @(Get-QpAppxPackages)) { $names[$pkg.PackageFamilyName] = $pkg } } catch { }
        foreach ($pkgKey in @(Get-ChildItem -Path $AppRoot -ErrorAction SilentlyContinue)) {
            foreach ($task in @(Get-ChildItem -Path $pkgKey.PSPath -ErrorAction SilentlyContinue)) {
                $state = (Get-ItemProperty -Path $task.PSPath -ErrorAction SilentlyContinue).State
                if ($null -eq $state) { continue }
                $pfn = $pkgKey.PSChildName
                $display = ''; $publisher = ''
                $pkg = $names[$pfn]
                if ($pkg) {
                    try {
                        $props = (Get-AppxPackageManifest -Package $pkg.PackageFullName -ErrorAction Stop).Package.Properties
                        $display = [string]$props.DisplayName
                        $publisher = [string]$props.PublisherDisplayName
                    } catch { }
                }
                if ($publisher -like 'ms-resource:*') { $publisher = '' }
                if (-not $display -or $display -like 'ms-resource:*') {
                    # "SpotifyAB.SpotifyMusic_zpdnekdrzrea0" -> "Spotify Music"
                    $short = (($pfn -split '_')[0] -split '\.')[-1]
                    $display = ($short -creplace '(?<=[a-z])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])', ' ').Trim()
                }
                $advice = Get-QpStartupAdvice -Text "$display $pfn $($task.PSChildName)" -Catalog $cat
                [void]$out.Add([pscustomobject]@{
                    Id = "App|$pfn|$($task.PSChildName)"; Name = $display; Kind = 'App'; Everyone = $false
                    Command = "$pfn ($($task.PSChildName))"; Target = ''; Publisher = $publisher
                    On = ([int]$state -in 2, 4); Locked = ([int]$state -in 3, 4)
                    Keep = $advice.Keep; KeepWhy = $advice.Why; Note = $advice.Note
                    Missing = $false; ApprovedPath = ''; ApprovedName = ''; StatePath = $task.PSPath
                })
            }
        }
    }
    return @($out)
}

#region ---------------------------------------------------------------- what signing in costs
# What each startup program actually costs you, measured rather than guessed:
#   * the memory it is using now, and how long after you signed in it started (always available);
#   * what Windows itself recorded about it, when Windows has a record.
# Windows only measures a full restart - not waking from sleep, and not a shutdown with fast startup -
# so its record is often weeks old. It is always shown with its date, and never mixed up with today.

function Get-QpSignInTime {
    <# When this Windows session signed in, and when the PC last started. Never throws. #>
    $boot = $null; $logon = $null
    try { $boot = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime } catch { }
    try {
        # The oldest process of this sign-in session is the closest honest mark for "when you signed in".
        $session = (Get-Process -Id $PID -ErrorAction Stop).SessionId
        foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
            try {
                if ($p.SessionId -ne $session) { continue }
                $started = $p.StartTime      # some processes refuse to say; those are skipped
                if (-not $logon -or $started -lt $logon) { $logon = $started }
            } catch { }
        }
    } catch { }
    if (-not $logon) { $logon = $boot }
    [pscustomobject]@{ Boot = $boot; Logon = $logon }
}

function Get-QpBootRecord {
    <#
        What Windows recorded about the last full restart: how long it took, and which programs it
        noticed holding it up. Needs administrator rights and the Diagnostics-Performance log; without
        either, this is simply $null and the rest of the feature carries on without it.
    #>
    param([int]$MaxEvents = 120)
    try {
        $events = @(Get-WinEvent -LogName 'Microsoft-Windows-Diagnostics-Performance/Operational' -MaxEvents $MaxEvents -ErrorAction Stop)
    } catch { return $null }
    if (-not $events.Count) { return $null }
    function Read-Fields($Event) {
        $f = @{}
        try { foreach ($d in ([xml]$Event.ToXml()).Event.EventData.Data) { $f[[string]$d.Name] = [string]$d.'#text' } } catch { }
        return $f
    }
    $last = @($events | Where-Object { $_.Id -eq 100 } | Select-Object -First 1)[0]
    $boot = $null
    if ($last) {
        $f = Read-Fields $last
        $boot = [pscustomobject]@{
            When = $last.TimeCreated
            Seconds = [math]::Round(([double]$f['BootTime']) / 1000, 1)
            ToDesktopSeconds = [math]::Round(([double]$f['MainPathBootTime']) / 1000, 1)
            AfterDesktopSeconds = [math]::Round(([double]$f['BootPostBootTime']) / 1000, 1)
            StartupApps = [int]$f['BootNumStartupApps']
        }
    }
    # Programs Windows timed at start-up (id 101). The most recent figure for each wins.
    $slow = @{}
    foreach ($e in @($events | Where-Object { $_.Id -eq 101 })) {
        $f = Read-Fields $e
        $name = [string]$f['Name']
        if (-not $name -or $slow.ContainsKey($name.ToLowerInvariant())) { continue }
        $slow[$name.ToLowerInvariant()] = [pscustomobject]@{
            Name = $name; Friendly = [string]$f['FriendlyName']; Path = [string]$f['Path']
            Seconds = [math]::Round(([double]$f['TotalTime']) / 1000, 1); When = $e.TimeCreated
        }
    }
    [pscustomobject]@{ Boot = $boot; Slow = $slow; Stale = [bool]($boot -and ((Get-Date) - $boot.When).TotalDays -gt 30) }
}

function Get-QpSignInCost {
    <#
        Adds to each startup item what it is costing: memory in use now, how long after sign-in it
        started, and Windows' own figure where there is one. Items that are not running say so rather
        than guessing. Read-only.
    #>
    param($Items, $Record = $null, $Times = $null)
    if ($null -eq $Times) { $Times = Get-QpSignInTime }
    $procs = @{}
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
        try {
            $key = $p.ProcessName.ToLowerInvariant()
            $mb = 0; try { $mb = [math]::Round($p.WorkingSet64 / 1MB) } catch { }
            # Some programs won't say when they started (another user's, or one with more rights than
            # us). That's no reason to call them "not running": the memory still counts.
            $started = $null; try { $started = $p.StartTime } catch { }
            $cur = $procs[$key]
            if ($cur) {
                $cur.MemoryMB += $mb
                if ($started -and (-not $cur.Started -or $started -lt $cur.Started)) { $cur.Started = $started }
                $cur.Count++
            } else {
                $procs[$key] = [pscustomobject]@{ MemoryMB = $mb; Started = $started; Count = 1 }
            }
        } catch { }   # a process that ends while it is being read
    }
    $out = New-Object System.Collections.ArrayList
    foreach ($i in @($Items | Where-Object { $_ })) {
        $exe = if ($i.Target) { Split-Path $i.Target -Leaf } else { '' }
        $key = if ($exe) { [IO.Path]::GetFileNameWithoutExtension($exe).ToLowerInvariant() } else { '' }
        $run = if ($key -and $procs.ContainsKey($key)) { $procs[$key] } else { $null }
        $windows = if ($Record -and $exe -and $Record.Slow.ContainsKey($exe.ToLowerInvariant())) { $Record.Slow[$exe.ToLowerInvariant()] } else { $null }
        $after = $null
        if ($run -and $run.Started -and $Times.Logon) {
            $secs = ($run.Started - $Times.Logon).TotalSeconds
            if ($secs -ge 0 -and $secs -le 180) { $after = [math]::Round($secs, 1) }   # later than three minutes: you started it yourself
        }
        [void]$out.Add([pscustomobject]@{
            Id = $i.Id; Name = $i.Name; Running = [bool]$run
            MemoryMB = $(if ($run) { [int]$run.MemoryMB } else { 0 })
            Copies = $(if ($run) { [int]$run.Count } else { 0 })
            StartedAfterSeconds = $after
            WindowsSeconds = $(if ($windows) { $windows.Seconds } else { $null })
            WindowsWhen = $(if ($windows) { $windows.When } else { $null })
        })
    }
    return @($out)
}

function Format-QpSignInCost {
    <# The cost of one startup item, in plain words. Empty when there is nothing honest to say. #>
    param($Cost)
    if (-not $Cost) { return '' }
    $bits = @()
    if ($Cost.WindowsSeconds) { $bits += ('Windows timed it at {0} seconds' -f $Cost.WindowsSeconds) }
    if ($Cost.Running) {
        $mem = if ($Cost.MemoryMB -ge 1024) { '{0:N1} GB' -f ($Cost.MemoryMB / 1024) } else { '{0} MB' -f $Cost.MemoryMB }
        $copies = if ($Cost.Copies -gt 1) { ' in {0} copies' -f $Cost.Copies } else { '' }
        $bits += ('using {0}{1} now' -f $mem, $copies)
        if ($null -ne $Cost.StartedAfterSeconds) { $bits += ('started {0} seconds after you signed in' -f $Cost.StartedAfterSeconds) }
    } else {
        $bits += 'not running at the moment'
    }
    $text = ($bits -join ', ')
    return ($text.Substring(0, 1).ToUpper() + $text.Substring(1) + '.')
}

#endregion

function Set-QpStartupApproved {
    <# Writes the same 12 bytes Task Manager does: 03 = switched off (plus when), 02 = on. #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name, [bool]$On)
    $bytes = New-Object byte[] 12
    $bytes[0] = $(if ($On) { 2 } else { 3 })
    if (-not $On) { [BitConverter]::GetBytes([DateTime]::UtcNow.ToFileTimeUtc()).CopyTo($bytes, 4) }
    if (-not (Test-Path -Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    Set-ItemProperty -Path $Path -Name $Name -Value $bytes -Type Binary -ErrorAction Stop
}

function Invoke-QpStartup {
    <#
        Stops the chosen items starting at sign-in. Each change goes into a restore point first, so
        Undo switches it back on. Items Windows or your drivers need are refused, whatever is ticked.
    #>
    param([string[]]$Ids, [switch]$Preview, $Items)
    if (-not $Ids) { Write-QpLog 'Nothing selected.' 'WARN'; return }
    $all = if ($null -ne $Items) { @($Items) } else { @(Get-QpStartupItems) }
    $own = $false   # set once this call opens its own restore point
    if ($Preview) { Write-QpLog 'PREVIEW - nothing will be changed.' 'STEP' }
    foreach ($id in $Ids) {
        $it = @($all | Where-Object { $_.Id -eq $id }) | Select-Object -First 1
        if (-not $it) { Write-QpLog "$id is not there any more - skipped" 'SKIP'; continue }
        if ($it.Keep) { Write-QpLog "$($it.Name) stays on: $($it.KeepWhy)" 'WARN'; continue }
        if ($it.Locked) { Write-QpLog "$($it.Name) is set by a policy on this PC, so it can't be changed here." 'WARN'; continue }
        if (-not $it.On) { Write-QpLog "$($it.Name) is already switched off" 'OK'; continue }
        if ($Preview) { Write-QpLog "Would stop $($it.Name) starting when you sign in" 'PREVIEW'; continue }
        # The restore point is opened at the first real change, so refusals never leave an empty one in Undo.
        if (-not $script:Session) { Start-QpSession 'startup'; $own = $true }
        try {
            if ($it.Kind -eq 'App') {
                $old = [int](Get-ItemProperty -Path $it.StatePath -Name State -ErrorAction Stop).State
                Add-QpUndo @{ Type = 'Reg'; Path = $it.StatePath; Name = 'State'; Existed = $true; OldValue = $old; Kind = 'DWord' }
                Set-ItemProperty -Path $it.StatePath -Name State -Value 1 -Type DWord -ErrorAction Stop
            } else {
                $cur = Get-QpRegValue -Path $it.ApprovedPath -Name $it.ApprovedName
                $oldBytes = if ($cur.Exists -and $cur.Value -is [byte[]]) { [Convert]::ToBase64String($cur.Value) } else { '' }
                Add-QpUndo @{ Type = 'StartupApproved'; Path = $it.ApprovedPath; Name = $it.ApprovedName; Existed = [bool]$cur.Exists; OldBytes = $oldBytes; Label = $it.Name }
                Set-QpStartupApproved -Path $it.ApprovedPath -Name $it.ApprovedName -On $false
            }
            Write-QpLog "$($it.Name) won't start when you sign in any more. It still opens normally when you start it." 'OK'
        } catch {
            Write-QpLog "Could not switch off $($it.Name): $(Get-QpFailureReason $_.Exception)" 'WARN'
        }
    }
    if ($Preview) { Write-QpLog 'Preview finished. Nothing was changed.' 'OK' } elseif ($own) { Stop-QpSession }
}

#endregion

#region ---------------------------------------------------------------- camera, microphone and location (who used them)

# Windows keeps its own record of which apps used the camera, microphone and location, and when: the
# record behind Settings > Privacy & security. Quietpane only reads it. Switching an app off writes the
# same value as the switch in Settings, so the two always agree, and Undo puts back what was there.

$script:ConsentRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore'
$script:ConsentRootMachine = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore'
$script:DeviceNames = [ordered]@{ webcam = 'camera'; microphone = 'microphone'; location = 'location' }

function Format-QpWhen {
    <# A moment in plain words: "a moment ago", "3 hours ago", "yesterday", "16 September". #>
    param($When, [datetime]$Now = (Get-Date))
    if (-not $When) { return 'never' }
    $en = [Globalization.CultureInfo]::InvariantCulture
    $span = $Now - [datetime]$When
    if ($span.TotalMinutes -lt 2) { return 'a moment ago' }
    if ($span.TotalMinutes -lt 60) { return ('{0} minutes ago' -f [int][math]::Floor($span.TotalMinutes)) }
    if ($span.TotalHours -lt 12) {
        $h = [int][math]::Floor($span.TotalHours)
        return $(if ($h -eq 1) { 'an hour ago' } else { "$h hours ago" })
    }
    $days = ($Now.Date - ([datetime]$When).Date).Days
    if ($days -le 0) { return 'earlier today' }
    if ($days -eq 1) { return 'yesterday' }
    if ($days -lt 7) { return "$days days ago" }
    if (([datetime]$When).Year -eq $Now.Year) { return ([datetime]$When).ToString('d MMMM', $en) }
    return ([datetime]$When).ToString('d MMMM yyyy', $en)
}

function Get-QpPackageNames {
    <# Store app names as the Start menu shows them ("Camera", "Settings"), by package family name. #>
    if ($script:StateCache -and $script:StateCache.ContainsKey('StartNames')) { return $script:StateCache.StartNames }
    $map = @{}
    try {
        foreach ($a in @(Get-StartApps -ErrorAction Stop)) {
            $pfn = ([string]$a.AppID -split '!')[0]
            if ($pfn -match '_[a-z0-9]{13}$' -and -not $map.ContainsKey($pfn)) { $map[$pfn] = [string]$a.Name }
        }
    } catch { }
    if ($script:StateCache) { $script:StateCache.StartNames = $map }
    return $map
}

function Get-QpProgramLabel {
    <#
        What a program calls itself ("Google Chrome"). Windows' own helpers are simply "Windows itself".
        For a program that has since gone: the game's folder ("Battlefield 6"), or the first folder
        under Program Files ("Adobe").
    #>
    param([string]$Path)
    if ($env:WINDIR -and $Path -like "$env:WINDIR\*") { return 'Windows itself' }
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $vi = (Get-Item -LiteralPath $Path).VersionInfo
            foreach ($n in [string]$vi.FileDescription, [string]$vi.ProductName) {
                $n = $n.Trim()
                if ($n -and $n.Length -le 60 -and $n -notmatch '(?i)operating system') { return $n }
            }
            return [IO.Path]::GetFileNameWithoutExtension($Path)
        }
        if ($Path -match '\\steamapps\\common\\([^\\]+)\\') { return $matches[1] }
        if ($Path -match '^[a-z]:\\Program Files( \(x86\))?\\([^\\]+)\\') { return $matches[2] }
    } catch { }
    return [IO.Path]::GetFileNameWithoutExtension($Path)
}

function Get-QpDeviceUse {
    <#
        Who used the camera, microphone and location, and when, from Windows' own record. Read-only.
        Store apps each have their own switch. Desktop programs are recorded by path, but Windows only
        has one switch for all of them. The registry roots can be swapped for tests.
    #>
    param([string]$UserRoot = $script:ConsentRoot, [string]$MachineRoot = $script:ConsentRootMachine, $BootTime)
    if ($null -eq $BootTime) {
        $BootTime = try { (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime } catch { [datetime]::MinValue }
    }
    function Get-Use($props) {
        # Windows notes when each use started and stopped. Started but not stopped (since the PC was
        # switched on) means it is in use right now.
        $start = [int64]0; $stop = [int64]0
        try { if ($props.LastUsedTimeStart) { $start = [int64]$props.LastUsedTimeStart } } catch { }
        try { if ($props.LastUsedTimeStop) { $stop = [int64]$props.LastUsedTimeStop } } catch { }
        $last = $null; $inUse = $false
        try {
            if ($start -gt 0) {
                $s = [DateTime]::FromFileTime($start)
                $last = if ($stop -gt $start) { [DateTime]::FromFileTime($stop) } else { $s }
                $inUse = ($stop -lt $start) -and ($s -gt $BootTime)
            }
        } catch { }
        [pscustomobject]@{ Last = $last; InUse = $inUse }
    }
    $names = $null
    $out = foreach ($kind in $script:DeviceNames.Keys) {
        $userKey = Join-Path $UserRoot $kind
        $machineKey = Join-Path $MachineRoot $kind
        $desktopKey = Join-Path $userKey 'NonPackaged'
        $apps = New-Object System.Collections.ArrayList

        foreach ($k in @(Get-ChildItem -Path $userKey -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -ne 'NonPackaged' })) {
            $pfn = $k.PSChildName
            $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue
            $use = Get-Use $p
            if (-not $names) { $names = Get-QpPackageNames }
            $name = $names[$pfn]
            if (-not $name) {
                # "SpotifyAB.SpotifyMusic_zpdnekdrzrea0" -> "Spotify Music"
                $short = (($pfn -split '_')[0] -split '\.')[-1]
                $name = ($short -creplace '(?<=[a-z])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])', ' ').Trim()
            }
            $setting = [string]$p.Value
            [void]$apps.Add([pscustomobject]@{
                Id = "$kind|App|$pfn"; Kind = $kind; Type = 'App'; Name = $name; Path = $pfn
                Setting = $setting; Allowed = ($setting -ne 'Deny'); Asks = ($setting -eq 'Prompt')
                # Without a switch of its own (Settings, for example) an app is managed by Windows.
                Locked = (-not $setting); LastUsed = $use.Last; InUse = $use.InUse; Missing = $false
                RegPath = (Join-Path $userKey $pfn)
            })
        }

        $desktopOn = (Get-QpRegValue -Path $desktopKey -Name 'Value').Value -ne 'Deny'
        $programs = @{}
        foreach ($root in $desktopKey, (Join-Path $machineKey 'NonPackaged')) {
            foreach ($k in @(Get-ChildItem -Path $root -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like '*#*' })) {
                $use = Get-Use (Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue)
                if (-not $use.Last) { continue }
                $path = $k.PSChildName.Replace('#', '\')
                $name = Get-QpProgramLabel $path
                # One line per program, however many copies of it Windows noted.
                $prev = $programs[$name]
                if ($prev -and $prev.LastUsed -ge $use.Last) { if ($use.InUse) { $prev.InUse = $true }; continue }
                $programs[$name] = [pscustomobject]@{
                    Id = "$kind|Desktop|$path"; Kind = $kind; Type = 'Desktop'; Name = $name; Path = $path
                    Setting = ''; Allowed = $desktopOn; Asks = $false; Locked = $true
                    LastUsed = $use.Last; InUse = ($use.InUse -or ($prev -and $prev.InUse))
                    Missing = ($name -ne 'Windows itself' -and -not (Test-Path -LiteralPath $path)); RegPath = ''
                }
            }
        }
        foreach ($v in $programs.Values) { [void]$apps.Add($v) }

        [pscustomobject]@{
            Kind = $kind; Name = $script:DeviceNames[$kind]
            PcOn = ((Get-QpRegValue -Path $machineKey -Name 'Value').Value -ne 'Deny')
            UserOn = ((Get-QpRegValue -Path $userKey -Name 'Value').Value -ne 'Deny')
            DesktopOn = $desktopOn; DesktopId = "$kind|AllDesktop"; DesktopKey = $desktopKey
            # In use first, then the most recent, then the ones that have never used it.
            Apps = @($apps | Sort-Object @{ Expression = { $_.InUse }; Descending = $true },
                @{ Expression = { if ($_.LastUsed) { $_.LastUsed } else { [datetime]::MinValue } }; Descending = $true }, Name)
        }
    }
    return @($out)
}

function Invoke-QpDeviceAccess {
    <#
        Stops the chosen apps using the camera, microphone or location. It is the same switch as in
        Settings > Privacy & security, so Settings shows it off too. Each change goes into a restore
        point first, so Undo switches it back on. Apps that are part of Windows are refused.
    #>
    param([string[]]$Ids, [switch]$Preview, $Use)
    $Ids = @($Ids | Where-Object { $_ })
    if (-not $Ids.Count) { Write-QpLog 'Nothing selected.' 'WARN'; return }
    $devices = if ($null -ne $Use) { @($Use) } else { @(Get-QpDeviceUse) }
    $own = $false   # set once this call opens its own restore point
    if ($Preview) { Write-QpLog 'PREVIEW - nothing will be changed.' 'STEP' }
    foreach ($id in $Ids) {
        $d = @($devices | Where-Object { $_.Kind -eq ($id -split '\|')[0] }) | Select-Object -First 1
        if (-not $d) { Write-QpLog "$id is not there any more - skipped" 'SKIP'; continue }
        if ($id -eq $d.DesktopId) {
            $label = 'all desktop programs'; $key = $d.DesktopKey; $already = -not $d.DesktopOn
        } else {
            $a = @($d.Apps | Where-Object { $_.Id -eq $id }) | Select-Object -First 1
            if (-not $a) { Write-QpLog "$id is not there any more - skipped" 'SKIP'; continue }
            if ($a.Type -ne 'App') { Write-QpLog "Windows can't stop one desktop program at a time - $($a.Name) left as is." 'WARN'; continue }
            if ($a.Locked) { Write-QpLog "$($a.Name) is part of Windows, so Windows decides its $($d.Name) access." 'WARN'; continue }
            $label = $a.Name; $key = $a.RegPath; $already = ($a.Setting -eq 'Deny')
        }
        $opening = $label.Substring(0, 1).ToUpper() + $label.Substring(1)   # the same, to start a sentence
        if ($already) { Write-QpLog "$opening already can't use the $($d.Name)" 'OK'; continue }
        if ($Preview) { Write-QpLog "Would stop $label using the $($d.Name)" 'PREVIEW'; continue }
        # The restore point is opened at the first real change, so refusals never leave an empty one in Undo.
        if (-not $script:Session) { Start-QpSession 'devices'; $own = $true }
        try {
            $cur = Get-QpRegValue -Path $key -Name 'Value'
            Add-QpUndo @{ Type = 'Reg'; Path = $key; Name = 'Value'; Existed = [bool]$cur.Exists; OldValue = $cur.Value; Kind = 'String' }
            if (-not (Test-Path -Path $key)) { New-Item -Path $key -Force | Out-Null }
            Set-ItemProperty -Path $key -Name 'Value' -Value 'Deny' -Type String -ErrorAction Stop
            Write-QpLog "$opening can't use the $($d.Name) any more. Settings shows it switched off too, and Undo turns it back on." 'OK'
        } catch {
            Write-QpLog "Could not switch off $label for the $($d.Name): $(Get-QpFailureReason $_.Exception)" 'WARN'
        }
    }
    if ($Preview) { Write-QpLog 'Preview finished. Nothing was changed.' 'OK' } elseif ($own) { Stop-QpSession }
}

#endregion

#region ---------------------------------------------------------------- browser add-ons

<#
    Add-ons are where most adware lives now, and the browser never says plainly what each one is allowed
    to read. Quietpane reads three of the browser's own files: the folder the add-on was unpacked into,
    its manifest.json (which lists what it may do) and the browser's settings file (which says whether it
    is on and where it came from). Nothing is looked up online, and none of those files is written to.

    Switching one off is done the way a workplace does it: a policy under this user's own settings that
    tells the browser not to load that add-on. Editing the browser's own settings file would be tampering
    - the browser signs that file and puts back what it expects - so Quietpane leaves it alone. The
    browser then says an administrator blocked the add-on; on this PC that administrator is you, and Undo
    takes the policy away again.
#>

# Where each browser keeps its profiles, and where it reads its policies from. The three with a policy
# are the ones that could be checked: Microsoft documents Edge's and Chrome's, and Brave's own program
# file names its key. Vivaldi and Opera are listed so their add-ons can be seen, with no switch, because
# their policy keys could not be verified here - better to say so than to write a setting into the
# registry and hope.
$script:BrowserFamily = @(
    @{ Key = 'edge';    Name = 'Edge';     Data = 'Microsoft\Edge\User Data';              Roaming = $false; Policy = 'SOFTWARE\Policies\Microsoft\Edge' },
    @{ Key = 'chrome';  Name = 'Chrome';   Data = 'Google\Chrome\User Data';               Roaming = $false; Policy = 'SOFTWARE\Policies\Google\Chrome' },
    @{ Key = 'brave';   Name = 'Brave';    Data = 'BraveSoftware\Brave-Browser\User Data'; Roaming = $false; Policy = 'SOFTWARE\Policies\BraveSoftware\Brave' },
    @{ Key = 'vivaldi'; Name = 'Vivaldi';  Data = 'Vivaldi\User Data';                     Roaming = $false; Policy = '' },
    @{ Key = 'opera';   Name = 'Opera';    Data = 'Opera Software\Opera Stable';           Roaming = $true;  Policy = '' },
    @{ Key = 'operagx'; Name = 'Opera GX'; Data = 'Opera Software\Opera GX Stable';        Roaming = $true;  Policy = '' }
)

# How the browser records where an add-on came from (Chromium calls it the install location).
$script:ExtensionSource = @{
    1  = 'You added it yourself'
    2  = 'Another program on this PC put it there'
    3  = 'Another program on this PC put it there'
    4  = 'Loaded from a folder, in developer mode'
    5  = 'Part of the browser itself'
    6  = 'It came with the browser'
    7  = 'Set by a policy on this PC'
    8  = 'Started from the command line'
    9  = 'Set by a policy on this PC'
    10 = 'Part of the browser itself'
}

function ConvertFrom-QpChromeTime {
    <# Chromium counts microseconds since 1601, where Windows counts ten-millionths of a second. #>
    param($Value)
    try {
        $v = [int64]$Value
        if ($v -le 0) { return $null }
        return [datetime]::FromFileTimeUtc($v * 10).ToLocalTime()
    } catch { return $null }
}

function Get-QpExtensionReach {
    <#
        What an add-on may do, in plain words: how far it reaches into the sites you visit, and anything
        else worth knowing. A permission Quietpane has no plain words for is counted but never guessed at.
    #>
    param([string[]]$Permissions)
    $cat = Get-QpCatalog extensions
    $quiet = @{}
    foreach ($q in @($cat.Quiet)) { $quiet[[string]$q] = $true }
    $known = @{}
    foreach ($p in @($cat.Permissions)) { $known[[string]$p.Name] = $p }
    $everywhere = @{}
    foreach ($e in @($cat.Everywhere)) { $everywhere[[string]$e] = $true }

    $all = $false
    $sites = New-Object System.Collections.ArrayList
    $can = New-Object System.Collections.ArrayList
    $other = 0
    foreach ($name in @($Permissions | Where-Object { $_ -is [string] -and $_ } | Select-Object -Unique)) {
        if ($everywhere.ContainsKey($name)) { $all = $true; continue }
        if ($name -match '://|^\*|/' ) {
            # A site pattern, like https://*.example.com/*. The browser's own pages (edge://settings and
            # the like) are not sites you visit, so they are left out rather than listed as one.
            if ($name -match '^(https?|wss?|ftp|\*)://([^/]+)') {
                $where = $matches[2] -replace '^\*\.', '' -replace ':\d+$', ''
                if ($where -eq '*' -or -not $where) { $all = $true; continue }
                if ($sites -notcontains $where) { [void]$sites.Add($where) }
            }
            continue
        }
        if ($quiet.ContainsKey($name) -or $name -match 'Private$') { continue }
        $hit = $known[$name]
        if ($hit) {
            if ($can -notcontains $hit.Plain) { [void]$can.Add([string]$hit.Plain) }
        } else { $other++ }
    }
    # Worst first, and inside a level in the order the catalog is written.
    $order = @{ 'Everything' = 0; 'Watching' = 1; 'Ordinary' = 2 }
    $rank = @{}
    $i = 0
    foreach ($p in @($cat.Permissions)) { $rank[[string]$p.Plain] = ($order[[string]$p.Level] * 100) + $i; $i++ }
    $ranked = @($can | Sort-Object { $rank[[string]$_] })
    $level = if ($all) { 'Everything' } elseif ($ranked.Count -and $rank[[string]$ranked[0]] -lt 100) { 'Everything' } elseif ($ranked.Count -and $rank[[string]$ranked[0]] -lt 200) { 'Watching' } elseif ($sites.Count) { 'Watching' } else { 'Ordinary' }
    [pscustomobject]@{
        Everywhere = $all
        Sites      = @($sites | Sort-Object)
        Can        = $ranked
        Unnamed    = $other
        Level      = $level
    }
}

function Format-QpExtensionUse {
    <# One line about an add-on: how far it reaches, whether it is on, and when it arrived. #>
    param($Extension)
    if (-not $Extension) { return '' }
    $r = $Extension.Reach
    $bits = @()
    if ($r.Everywhere) { $bits += 'Reads and changes everything on every site you visit' }
    elseif (@($r.Sites).Count -eq 0) { $bits += 'Cannot read the pages you visit' }
    elseif (@($r.Sites).Count -le 2) { $bits += 'Only works on ' + (@($r.Sites) -join ' and ') }
    else { $bits += 'Only works on {0} sites, {1} among them' -f @($r.Sites).Count, ((@($r.Sites) | Select-Object -First 2) -join ' and ') }
    if (@($r.Can).Count) { $bits[0] = $bits[0] + '. It ' + $r.Can[0] }
    $line = $bits[0] + '.'
    if ($Extension.Blocked) { $line += ' Switched off by a policy on this PC.' }
    elseif (-not $Extension.On) { $line += ' Switched off in the browser at the moment.' }
    if ($Extension.Added) { $line += ' Added ' + (Format-QpWhen $Extension.Added) + '.' }
    return $line
}

function Get-QpExtensionBlocks {
    <# The add-ons a policy on this PC already tells a browser not to load, and where that policy is. #>
    param([string]$Policy)
    $out = @{}
    if (-not $Policy) { return $out }
    foreach ($hive in 'HKCU', 'HKLM') {
        foreach ($listName in 'ExtensionInstallBlocklist', 'ExtensionInstallBlacklist') {
            $key = '{0}:\{1}\{2}' -f $hive, $Policy, $listName
            $k = $null
            try { $k = Get-Item -Path $key -ErrorAction Stop } catch { continue }
            foreach ($name in @($k.GetValueNames())) {
                $id = [string]$k.GetValue($name)
                if (-not $id) { continue }
                $id = $id.ToLowerInvariant()
                if (-not $out.ContainsKey($id)) { $out[$id] = [pscustomobject]@{ Key = $key; Name = $name; Mine = ($hive -eq 'HKCU') } }
            }
        }
    }
    return $out
}

function Get-QpExtensionSlot {
    <# The blocklist is numbered 1, 2, 3...; this finds the first number nobody is using. #>
    param([string]$Key)
    $used = @{}
    try {
        $k = Get-Item -Path $Key -ErrorAction Stop
        foreach ($n in @($k.GetValueNames())) { $used[$n] = $true }
    } catch { }
    for ($i = 1; $i -lt 10000; $i++) { if (-not $used.ContainsKey("$i")) { return "$i" } }
    return '1'
}

function Resolve-QpExtensionName {
    <# An add-on written for several languages keeps its name in a message file; this reads it. #>
    param([string]$Name, [string]$Folder)
    if (-not $Name) { return '' }
    if ($Name -notlike '__MSG_*') { return $Name }
    $key = $Name.Trim('_')
    if ($key -like 'MSG_*') { $key = $key.Substring(4) }
    foreach ($loc in 'en', 'en_US', 'en_GB') {
        $mf = Join-Path $Folder "_locales\$loc\messages.json"
        if (-not (Test-Path -LiteralPath $mf)) { continue }
        try {
            $msgs = Get-Content -LiteralPath $mf -Raw | ConvertFrom-Json
            $hit = $msgs.PSObject.Properties | Where-Object { $_.Name -ieq $key } | Select-Object -First 1
            if ($hit) { return [string]$hit.Value.message }
        } catch { }
    }
    return $Name
}

function Get-QpChromiumExtensions {
    <#
        The add-ons in one Chromium profile (Edge, Chrome, Brave, Vivaldi, Opera), read from the browser's
        own settings file and each add-on's manifest. Read-only.
    #>
    param([string]$ProfilePath, [hashtable]$Family, [hashtable]$Blocks = @{}, [string]$ProfileLabel = '')
    $extRoot = Join-Path $ProfilePath 'Extensions'
    $folders = @{}
    foreach ($d in @(Get-ChildItem -LiteralPath $extRoot -Directory -ErrorAction SilentlyContinue)) { $folders[$d.Name] = $d }
    $settings = @{}
    foreach ($file in 'Secure Preferences', 'Preferences') {
        # These files run to tens of thousands of lines. The second one is only opened when the first
        # did not account for every add-on on disk, which saves a second on every read.
        $missing = @($folders.Keys | Where-Object { -not $settings.ContainsKey($_) }).Count
        if ($file -eq 'Preferences' -and $settings.Count -and -not $missing) { break }
        $p = Join-Path $ProfilePath $file
        if (-not (Test-Path -LiteralPath $p)) { continue }
        try {
            $js = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json
            if ($js.extensions.settings) {
                foreach ($s in $js.extensions.settings.PSObject.Properties) { if (-not $settings.ContainsKey($s.Name)) { $settings[$s.Name] = $s.Value } }
            }
        } catch { }
    }
    $ids = @(@($settings.Keys) + @($folders.Keys) | Select-Object -Unique)
    foreach ($id in $ids) {
        $rec = $settings[$id]
        $dir = $folders[$id]
        # The newest version folder is the one the browser loads.
        $versionDir = $null
        if ($dir) { $versionDir = @(Get-ChildItem -LiteralPath $dir.FullName -Directory -ErrorAction SilentlyContinue | Sort-Object Name) | Select-Object -Last 1 }
        $manifest = $null
        if ($versionDir) {
            $mf = Join-Path $versionDir.FullName 'manifest.json'
            if (Test-Path -LiteralPath $mf) { try { $manifest = Get-Content -LiteralPath $mf -Raw | ConvertFrom-Json } catch { } }
        }
        if (-not $manifest -and $rec) { $manifest = $rec.manifest }
        # An id with no manifest anywhere is a note the browser keeps about something that is not installed.
        if (-not $manifest) { continue }
        $folder = if ($versionDir) { $versionDir.FullName } else { '' }
        $name = Resolve-QpExtensionName -Name ([string]$manifest.name) -Folder $folder
        if (-not $name) { $name = $id }
        $location = 0
        if ($rec -and $null -ne $rec.location) { try { $location = [int]$rec.location } catch { } }
        $builtIn = $location -in 5, 10
        $byPolicy = $location -in 7, 9
        # Chromium writes "off" either as a state of 0 or as a reason for switching it off - newer
        # versions keep those reasons as a list. When it records neither, which is how the parts of the
        # browser itself are written, the add-on is loaded.
        $on = $true
        if ($rec) {
            if ($null -ne $rec.state) { try { $on = ([int]$rec.state -eq 1) } catch { } }
            elseif ($null -ne $rec.disable_reasons) {
                $why = @(@($rec.disable_reasons) | Where-Object { $_ -and "$_" -ne '0' })
                if ($why.Count) { $on = $false }
            }
        }
        $perms = @()
        foreach ($set in $manifest.permissions, $manifest.host_permissions) { $perms += @($set | Where-Object { $_ -is [string] }) }
        foreach ($cs in @($manifest.content_scripts)) { $perms += @($cs.matches | Where-Object { $_ -is [string] }) }
        if ($rec -and $rec.active_permissions) {
            foreach ($set in $rec.active_permissions.api, $rec.active_permissions.explicit_host, $rec.active_permissions.scriptable_host) {
                $perms += @($set | Where-Object { $_ -is [string] })
            }
        }
        $added = $null
        if ($rec) { $added = ConvertFrom-QpChromeTime $rec.first_install_time }
        if (-not $added -and $versionDir) { try { $added = $versionDir.CreationTime } catch { } }
        $block = $Blocks[$id.ToLowerInvariant()]
        [pscustomobject]@{
            Id          = '{0}|{1}|{2}' -f $Family.Key, (Split-Path $ProfilePath -Leaf), $id
            ExtId       = $id
            Browser     = [string]$Family.Name
            BrowserKey  = [string]$Family.Key
            Profile     = $ProfileLabel
            Name        = $name
            Version     = [string]$manifest.version
            On          = ($on -and -not $block)
            BuiltIn     = $builtIn
            Locked      = $byPolicy
            Blocked     = [bool]$block
            BlockedByMe = [bool]($block -and $block.Mine)
            Source      = $(if ($script:ExtensionSource.ContainsKey($location)) { $script:ExtensionSource[$location] } else { 'Where it came from is not recorded' })
            Reach       = (Get-QpExtensionReach -Permissions $perms)
            Added       = $added
            Folder      = $folder
            PolicyRoot  = $(if ($Family.Policy) { 'HKCU:\' + $Family.Policy } else { '' })
        }
    }
}

function Get-QpFirefoxAddons {
    <#
        Firefox keeps its add-ons in a list of its own. Quietpane reads it so they are on the list too;
        it cannot switch a Firefox add-on off, and says so rather than pretending.
    #>
    param([string]$Root = (Join-Path $env:APPDATA 'Mozilla\Firefox\Profiles'))
    if (-not (Test-Path -LiteralPath $Root)) { return }
    foreach ($prof in @(Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue)) {
        $file = Join-Path $prof.FullName 'extensions.json'
        if (-not (Test-Path -LiteralPath $file)) { continue }
        $js = $null
        try { $js = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json } catch { continue }
        foreach ($a in @($js.addons)) {
            if ([string]$a.type -ne 'extension') { continue }
            $loc = [string]$a.location
            $builtIn = $loc -like 'app-*'
            $perms = @()
            if ($a.userPermissions) { $perms += @($a.userPermissions.permissions) + @($a.userPermissions.origins) }
            $added = $null
            try { if ($a.installDate) { $added = [datetime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc).AddMilliseconds([double]$a.installDate).ToLocalTime() } } catch { }
            $name = [string]$a.defaultLocale.name
            if (-not $name) { $name = [string]$a.id }
            [pscustomobject]@{
                Id          = 'firefox|{0}|{1}' -f $prof.Name, $a.id
                ExtId       = [string]$a.id
                Browser     = 'Firefox'
                BrowserKey  = 'firefox'
                Profile     = ''
                Name        = $name
                Version     = [string]$a.version
                On          = [bool]$a.active
                BuiltIn     = $builtIn
                Locked      = $false
                Blocked     = $false
                BlockedByMe = $false
                Source      = $(if ($builtIn) { 'Part of the browser itself' } elseif ($loc -like 'winreg*') { 'Another program on this PC put it there' } else { 'You added it yourself' })
                Reach       = (Get-QpExtensionReach -Permissions $perms)
                Added       = $added
                Folder      = [string]$a.path
                PolicyRoot  = ''
            }
        }
    }
}

function Get-QpBrowserExtensions {
    <#
        Every add-on in Edge, Chrome, Brave, Vivaldi, Opera, Opera GX and Firefox, with what it may do and where it came from. Read-only.
        The roots can be pointed somewhere else for testing.
    #>
    param($Families = $script:BrowserFamily, [string]$LocalRoot = $env:LOCALAPPDATA, [string]$RoamingRoot = $env:APPDATA, [switch]$NoFirefox)
    $out = New-Object System.Collections.ArrayList
    foreach ($fam in @($Families)) {
        $base = Join-Path $(if ($fam.Roaming) { $RoamingRoot } else { $LocalRoot }) $fam.Data
        if (-not (Test-Path -LiteralPath $base)) { continue }
        $blocks = Get-QpExtensionBlocks -Policy ([string]$fam.Policy)
        # Most browsers keep one folder per profile; Opera's profile is the folder itself.
        $profs = @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })
        if (-not $profs.Count -and (Test-Path -LiteralPath (Join-Path $base 'Preferences'))) { $profs = @(Get-Item -LiteralPath $base) }
        $many = $profs.Count -gt 1
        foreach ($p in $profs) {
            $label = ''
            if ($many) {
                $label = $p.Name
                try {
                    $pj = Get-Content -LiteralPath (Join-Path $p.FullName 'Preferences') -Raw -ErrorAction Stop | ConvertFrom-Json
                    if ($pj.profile.name) { $label = [string]$pj.profile.name }
                } catch { }
            }
            foreach ($e in @(Get-QpChromiumExtensions -ProfilePath $p.FullName -Family $fam -Blocks $blocks -ProfileLabel $label)) { [void]$out.Add($e) }
        }
    }
    if (-not $NoFirefox) { foreach ($e in @(Get-QpFirefoxAddons)) { [void]$out.Add($e) } }
    # The ones that reach furthest first, then the ones still switched on, then by name.
    $order = @{ 'Everything' = 0; 'Watching' = 1; 'Ordinary' = 2 }
    @($out | Sort-Object @{ Expression = { $order[[string]$_.Reach.Level] } }, @{ Expression = { -not $_.On }; }, Name)
}

function Invoke-QpExtension {
    <#
        Tells the chosen browsers not to load the add-ons you ticked. It is a policy under your own
        settings, the same one a workplace would use, so the browser says an administrator blocked it -
        that administrator is you, and Undo takes the policy away again. The browser's own files are
        never touched. Add-ons that are part of the browser, or that a policy already controls, are
        refused with a reason.
    #>
    param([string[]]$Ids, [switch]$Preview, $Extensions)
    $Ids = @($Ids | Where-Object { $_ })
    if (-not $Ids.Count) { Write-QpLog 'Nothing selected.' 'WARN'; return }
    $list = if ($null -ne $Extensions) { @($Extensions) } else { @(Get-QpBrowserExtensions) }
    $own = $false
    if ($Preview) { Write-QpLog 'PREVIEW - nothing will be changed.' 'STEP' }
    foreach ($id in $Ids) {
        $e = @($list | Where-Object { $_.Id -eq $id }) | Select-Object -First 1
        if (-not $e) { Write-QpLog "$id is not there any more - skipped" 'SKIP'; continue }
        if ($e.BuiltIn) { Write-QpLog "$($e.Name) is part of $($e.Browser) itself, so it stays." 'WARN'; continue }
        if ($e.Locked) { Write-QpLog "$($e.Name) is set by a policy on this PC, so it stays as it is." 'WARN'; continue }
        if (-not $e.PolicyRoot) { Write-QpLog "Quietpane cannot switch $($e.Browser) add-ons off. Remove $($e.Name) in $($e.Browser) itself, under its add-ons page." 'WARN'; continue }
        if ($e.Blocked) { Write-QpLog "$($e.Browser) is already told not to load $($e.Name)" 'OK'; continue }
        if ($Preview) { Write-QpLog "Would stop $($e.Browser) loading $($e.Name)" 'PREVIEW'; continue }
        # The restore point is opened at the first real change, so refusals never leave an empty one in Undo.
        if (-not $script:Session) { Start-QpSession 'browser-add-ons'; $own = $true }
        try {
            $key = Join-Path $e.PolicyRoot 'ExtensionInstallBlocklist'
            $made = -not (Test-Path -Path $key)
            if ($made) { New-Item -Path $key -Force | Out-Null }
            $slot = Get-QpExtensionSlot -Key $key
            Add-QpUndo @{ Type = 'ExtBlock'; Path = $key; Name = $slot; KeyCreated = $made; Label = $e.Name; Browser = $e.Browser }
            Set-ItemProperty -Path $key -Name $slot -Value $e.ExtId -Type String -ErrorAction Stop
            Write-QpLog "$($e.Browser) will not load $($e.Name) any more. It says an administrator blocked it, which is you; Undo puts it back and it works again." 'OK'
        } catch {
            Write-QpLog "Could not switch off $($e.Name): $(Get-QpFailureReason $_.Exception)" 'WARN'
        }
    }
    if ($Preview) { Write-QpLog 'Preview finished. Nothing was changed.' 'OK' }
    elseif ($own) {
        Write-QpLog 'The browser picks this up on its own; close it and open it again if you want to see it straight away.' 'INFO'
        Stop-QpSession
    }
}

#endregion

#region ---------------------------------------------------------------- clean-up

function Resolve-QpPaths {
    param([string[]]$Patterns)
    foreach ($pat in $Patterns) {
        $expanded = [Environment]::ExpandEnvironmentVariables($pat)
        Get-Item -Path $expanded -Force -ErrorAction SilentlyContinue | Where-Object { $_.PSIsContainer } | ForEach-Object { $_.FullName }
    }
}

function Get-QpCleanupTargets {
    foreach ($item in (Get-QpCatalog cleanup).Items) {
        $paths = @(Resolve-QpPaths $item.Paths)
        # Only count what Clean-up would actually move (respects the MinAgeHours safety rule).
        $cutoff = if ($item.MinAgeHours) { (Get-Date).AddHours(-[double]$item.MinAgeHours) } else { $null }
        $size = 0
        foreach ($p in $paths) {
            if ($cutoff) {
                foreach ($c in @(Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cutoff })) {
                    $size += if ($c.PSIsContainer) { Get-QpSize @($c.FullName) } else { $c.Length }
                }
            } else {
                $size += Get-QpSize @($p)
            }
        }
        [pscustomobject]@{
            Id          = $item.Id
            Title       = $item.Title
            Description = $item.Description
            Recommended = [bool]$item.Recommended
            Paths       = $paths
            SizeBytes   = $size
        }
    }
}

function Invoke-QpCleanup {
    param([string[]]$Ids, [switch]$Preview)
    $items = @((Get-QpCatalog cleanup).Items | Where-Object { $Ids -contains $_.Id })
    if ($items.Count -eq 0) { Write-QpLog 'Nothing selected.' 'WARN'; return }
    $own = (-not $Preview) -and (-not $script:Session)
    if ($Preview) { Write-QpLog 'PREVIEW - nothing will be moved.' 'STEP' } elseif ($own) { Start-QpSession 'cleanup' }
    $total = 0
    foreach ($item in $items) {
        Write-QpLog $item.Title 'STEP'
        if ($item.RequiresClosed -and (Get-Process -Name $item.RequiresClosed -ErrorAction SilentlyContinue)) {
            Write-QpLog "Close $($item.RequiresClosed) first - skipped" 'WARN'
            continue
        }
        $cutoff = if ($item.MinAgeHours) { (Get-Date).AddHours(-[double]$item.MinAgeHours) } else { $null }
        foreach ($root in @(Resolve-QpPaths $item.Paths)) {
            $children = @(Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue)
            if ($cutoff) { $children = @($children | Where-Object { $_.LastWriteTime -lt $cutoff }) }
            $moved = 0; $bytes = 0
            foreach ($c in $children) {
                $size = if ($c.PSIsContainer) { Get-QpSize @($c.FullName) } else { $c.Length }
                if ($Preview) { $moved++; $bytes += $size; continue }
                if (Move-QpToRecycleBin -Path $c.FullName -SizeBytes $size) { $moved++; $bytes += $size }
            }
            $total += $bytes
            if ($Preview) {
                Write-QpLog ("Would move {0} item(s), {1}, from {2}" -f $moved, (Format-QpBytes $bytes), $root) 'PREVIEW'
            } else {
                Write-QpLog ("Moved {0} item(s), {1}, from {2} to the Recycle Bin (items in use were skipped)" -f $moved, (Format-QpBytes $bytes), $root) 'OK'
                if ($moved) { Add-QpUndo @{ Type = 'Recycled'; Path = $root; Items = $moved } }
            }
        }
    }
    if ($Preview) {
        Write-QpLog ("Preview finished. About {0} could be freed." -f (Format-QpBytes $total)) 'OK'
    } else {
        Write-QpLog ("About {0} moved to the Recycle Bin. Empty the Recycle Bin yourself when you are happy - clean-up never deletes anything for good." -f (Format-QpBytes $total)) 'OK'
        Add-QpTotals -SpaceBytes $total
        if ($own) { Stop-QpSession }
    }
    [pscustomobject]@{ BytesFreed = [int64]$total }
}

#endregion

#region ---------------------------------------------------------------- what's talking to the internet

# Which programs have a connection open right now, and where to. Read-only, and nothing is looked up
# online: the list comes from Windows' own connection table, and the names come from the DNS cache
# Windows already has. Quietpane makes no network requests of its own, here or anywhere else.
#
# What it cannot see: connections made over QUIC (UDP), which some browsers and games prefer. Windows
# does not record where those go, so the window says so rather than pretending the list is complete.

$script:ServicesByPid = $null
$script:ServicesAt = [datetime]::MinValue

function Test-QpPrivateAddress {
    <# Your own network (or this PC), rather than the internet. #>
    param([string]$Address)
    if (-not $Address) { return $true }
    $a = $Address.Split('%')[0]
    if ($a -eq '::1' -or $a -eq '0.0.0.0' -or $a -eq '::') { return $true }
    if ($a -match '^(127\.|10\.|192\.168\.|169\.254\.)') { return $true }
    if ($a -match '^172\.(1[6-9]|2[0-9]|3[01])\.') { return $true }
    if ($a -match '^(?i)(fe[89ab]|f[cd])') { return $true }
    return $false
}

function Get-QpAddressLabel {
    <# A destination in plain words: the name Windows has for it, and who is behind it. #>
    param([string]$Address, [string]$HostName, $Catalog = (Get-QpCatalog network))
    $owner = ''; $note = ''
    if ($HostName) {
        foreach ($o in $Catalog.Owners) { if ($HostName -match $o.Match) { $owner = $o.Name; break } }
        foreach ($r in $Catalog.Reporting) { if ($HostName -match $r.Match) { $note = $r.Note; break } }
    }
    [pscustomobject]@{ Address = $Address; Host = $HostName; Owner = $owner; Note = $note; Text = $(if ($HostName) { $HostName } else { $Address }) }
}

function Get-QpServicesByPid {
    <# Which Windows services live in which process, so "svchost" can say what it actually is. #>
    if ($script:ServicesByPid -and ((Get-Date) - $script:ServicesAt).TotalSeconds -lt 60) { return $script:ServicesByPid }
    $map = @{}
    foreach ($s in @(Get-CimInstance Win32_Service -Filter "State='Running'" -ErrorAction SilentlyContinue)) {
        $id = [int]$s.ProcessId
        if ($id -le 0) { continue }
        if (-not $map.ContainsKey($id)) { $map[$id] = New-Object System.Collections.ArrayList }
        [void]$map[$id].Add([string]$s.DisplayName)
    }
    $script:ServicesByPid = $map
    $script:ServicesAt = Get-Date
    return $map
}

function Get-QpConnections {
    <#
        Programs with a connection open right now, newest-busiest first. Read-only. The connection
        table, DNS cache and process list can all be passed in, so tests never need a real network.
    #>
    param($Connections, $DnsCache, $Processes, $Catalog = (Get-QpCatalog network), $Services)
    if ($null -eq $Connections) { $Connections = @(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue) }
    if ($null -eq $DnsCache) { $DnsCache = @(Get-DnsClientCache -ErrorAction SilentlyContinue) }
    if ($null -eq $Processes) { $Processes = @(Get-Process -ErrorAction SilentlyContinue) }
    $byId = @{}
    foreach ($p in $Processes) { $byId[[int]$p.Id] = $p }
    # Windows' own DNS cache: address -> the name that was asked for.
    $names = @{}
    foreach ($e in $DnsCache) {
        $data = [string]$e.Data
        if (-not $data -or $data -notmatch '[\.:]') { continue }
        if ("$($e.Type)" -notin 'A', 'AAAA', '1', '28') { continue }
        if (-not $names.ContainsKey($data)) { $names[$data] = [string]$e.Entry }
    }
    $groups = @{}
    $localOnly = @{}
    foreach ($c in $Connections) {
        $addr = "$($c.RemoteAddress)".Split('%')[0]
        if (-not $addr) { continue }
        $procId = [int]$c.OwningProcess
        if (Test-QpPrivateAddress $addr) {
            if ($addr -notmatch '^(127\.|::1$)') { $localOnly[$procId] = [int]$localOnly[$procId] + 1 }
            continue
        }
        if (-not $groups.ContainsKey($procId)) { $groups[$procId] = New-Object System.Collections.ArrayList }
        [void]$groups[$procId].Add((Get-QpAddressLabel -Address $addr -HostName ([string]$names[$addr]) -Catalog $Catalog))
    }
    $out = foreach ($procId in @($groups.Keys)) {
        $p = $byId[$procId]
        $name = ''
        $path = ''
        if ($procId -eq $PID) { $name = 'Quietpane (this app)' }
        elseif (-not $p) { $name = 'A program that has since closed' }
        else {
            try { $path = [string]$p.Path } catch { }
            if ($p.ProcessName -eq 'svchost') {
                if ($null -eq $Services) { $Services = Get-QpServicesByPid }
                $list = @($Services[$procId])
                $name = if ($list -and $list[0]) { 'Windows: ' + (($list | Select-Object -First 2) -join ', ') } else { 'A Windows service' }
            } else {
                # The plain names Windows' own programs go by, then what the program calls itself.
                $name = [string]$script:ProgramNames["$($p.ProcessName)".ToLower()]
                if (-not $name) {
                    foreach ($n in [string]$p.Description, [string]$p.Product) {
                        $n = "$n".Trim()
                        if ($n -and $n.Length -le 40 -and $n -notmatch '(?i)operating system') { $name = $n; break }
                    }
                }
                if (-not $name) { $name = [string]$p.ProcessName }
            }
        }
        [pscustomobject]@{ Name = $name; ProcessId = $procId; Path = $path; Dests = @($groups[$procId]); LocalCount = [int]$localOnly[$procId] }
    }
    # One line per program, not per process: a browser or a game may have several at once.
    $merged = foreach ($grp in @($out | Group-Object Name)) {
        $all = @($grp.Group)
        $dests = @($all | ForEach-Object { $_.Dests })
        $named = @($dests | Where-Object { $_.Host } | Sort-Object Text -Unique)
        $plain = @($dests | Where-Object { -not $_.Host } | Sort-Object Text -Unique)
        [pscustomobject]@{
            Name = $grp.Name; ProcessId = $all[0].ProcessId; Path = $all[0].Path; Processes = $all.Count
            Count = $dests.Count
            Destinations = @($named + $plain)          # the ones with a name first: they say more
            Owners = @($dests | ForEach-Object { $_.Owner } | Where-Object { $_ } | Select-Object -Unique)
            Reporting = @($dests | Where-Object { $_.Note } | ForEach-Object { '{0} ({1})' -f $_.Text, $_.Note } | Select-Object -Unique)
            LocalCount = [int](($all | Measure-Object -Property LocalCount -Sum).Sum)
        }
    }
    $localNames = foreach ($procId in @($localOnly.Keys)) {
        if ($groups.ContainsKey($procId)) { continue }
        if ($byId[$procId]) { [string]$byId[$procId].ProcessName } else { 'a program' }
    }
    [pscustomobject]@{
        Programs = @($merged | Sort-Object -Property @{ Expression = { $_.Count }; Descending = $true }, Name)
        Internet = @($merged).Count
        LocalOnly = @($localNames | Sort-Object -Unique)
        At = Get-Date
    }
}

#endregion

#region ---------------------------------------------------------------- Start menu, desktop and sign-in

# A shortcut that carries the same app id as the window, so Windows treats them as one app: the
# taskbar shows the emblem, and "Pin to taskbar" pins something that really opens Quietpane.
#
# Shortcuts and the sign-in start never point at the folder you unzipped: folders get moved, renamed
# and deleted, and a shortcut can't follow them. They open Quietpane's own copy in Program Files
# instead, made the first time you ask for either. Program Files is also the only safe home for
# something that starts with administrator rights, because ordinary programs can't change what is in
# it. When you take both away again, the copy goes to the Recycle Bin.

$script:AppUserModelId = 'KomodoWorks.Quietpane'
$script:InstallRoot = Join-Path $(if ($env:ProgramW6432) { $env:ProgramW6432 } else { $env:ProgramFiles }) 'Quietpane'
$script:SignInTaskName = 'Quietpane (KomodoWorks)'
# What the copy is made of: the app and the documents its About tab shows. Tests and build tools stay behind.
$script:AppFileNames = @('Quietpane.ps1', 'Start Quietpane.cmd', 'Safety scan only.cmd', 'README.md', 'PRIVACY.md', 'TERMS.md', 'SECURITY.md', 'LICENSE')
$script:AppFolderNames = @('src', 'assets')
$script:ShortcutSource = @'
using System;
using System.Runtime.InteropServices;

// Windows' own shortcut object, used the way Explorer uses it. No Windows functions are imported.
public static class QuietpaneShortcut {
    [ComImport, Guid("00021401-0000-0000-C000-000000000046")] class ShellLink { }

    [ComImport, Guid("000214F9-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellLinkW {
        void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder file, int cch, IntPtr fd, int flags);
        void GetIDList(out IntPtr ppidl);
        void SetIDList(IntPtr pidl);
        void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder name, int cch);
        void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string name);
        void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder dir, int cch);
        void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string dir);
        void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder args, int cch);
        void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string args);
        void GetHotkey(out short hotkey);
        void SetHotkey(short hotkey);
        void GetShowCmd(out int show);
        void SetShowCmd(int show);
        void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder icon, int cch, out int index);
        void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string icon, int index);
        void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string path, int reserved);
        void Resolve(IntPtr hwnd, int flags);
        void SetPath([MarshalAs(UnmanagedType.LPWStr)] string path);
    }

    [ComImport, Guid("0000010b-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPersistFile {
        void GetClassID(out Guid clsid);
        [PreserveSig] int IsDirty();
        void Load([MarshalAs(UnmanagedType.LPWStr)] string file, int mode);
        void Save([MarshalAs(UnmanagedType.LPWStr)] string file, [MarshalAs(UnmanagedType.Bool)] bool remember);
        void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string file);
        void GetCurFile([Out, MarshalAs(UnmanagedType.LPWStr)] out string file);
    }

    [ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore {
        void GetCount(out uint count);
        void GetAt(uint index, out PROPERTYKEY key);
        void GetValue(ref PROPERTYKEY key, out PROPVARIANT value);
        void SetValue(ref PROPERTYKEY key, ref PROPVARIANT value);
        void Commit();
    }

    [StructLayout(LayoutKind.Sequential)] struct PROPERTYKEY { public Guid fmtid; public uint pid; }
    [StructLayout(LayoutKind.Sequential)] struct PROPVARIANT { public ushort vt; ushort r1, r2, r3; public IntPtr value; public IntPtr unused; }

    public static void Create(string linkPath, string target, string args, string workingDir, string icon, string description, string appId) {
        var link = (IShellLinkW)new ShellLink();
        link.SetPath(target);
        link.SetArguments(args);
        link.SetWorkingDirectory(workingDir);
        link.SetDescription(description);
        if (!string.IsNullOrEmpty(icon)) link.SetIconLocation(icon, 0);
        link.SetShowCmd(7);                       // start out of the way; the window itself opens normally
        if (!string.IsNullOrEmpty(appId)) {
            // System.AppUserModel.ID: what makes the taskbar treat shortcut and window as one app.
            var store = (IPropertyStore)link;
            var key = new PROPERTYKEY { fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), pid = 5 };
            var v = new PROPVARIANT { vt = 31, value = Marshal.StringToCoTaskMemUni(appId) };   // 31 = a text value
            try { store.SetValue(ref key, ref v); store.Commit(); } finally { Marshal.FreeCoTaskMem(v.value); }
        }
        ((IPersistFile)link).Save(linkPath, true);
        Marshal.FinalReleaseComObject(link);
    }

    // Reads the app id back out of a shortcut, so it can be checked.
    public static string ReadAppId(string linkPath) {
        var link = (IShellLinkW)new ShellLink();
        ((IPersistFile)link).Load(linkPath, 0);
        var key = new PROPERTYKEY { fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), pid = 5 };
        PROPVARIANT v;
        ((IPropertyStore)link).GetValue(ref key, out v);
        string id = v.vt == 31 ? Marshal.PtrToStringUni(v.value) : "";
        Marshal.FinalReleaseComObject(link);
        return id;
    }

    // Reads what a shortcut hands to the program it opens, so Quietpane can tell which copy it opens.
    public static string ReadArguments(string linkPath) {
        var link = (IShellLinkW)new ShellLink();
        ((IPersistFile)link).Load(linkPath, 0);
        var text = new System.Text.StringBuilder(2048);
        link.GetArguments(text, text.Capacity);
        Marshal.FinalReleaseComObject(link);
        return text.ToString();
    }
}
'@

function Test-QpSamePath([string]$A, [string]$B) {
    if (-not $A -or -not $B) { return $false }
    try { return ([IO.Path]::GetFullPath($A).TrimEnd('\') -ieq [IO.Path]::GetFullPath($B).TrimEnd('\')) } catch { return $false }
}

function Compare-QpVersion([string]$A, [string]$B) {
    <# -1, 0 or 1, the way version numbers compare: 1.10.0 is newer than 1.9.2. #>
    try { return ([version]$A).CompareTo([version]$B) } catch { return [math]::Sign([string]::Compare($A, $B, $true)) }
}

function Get-QpAppVersion([string]$Root) {
    <# The version of the Quietpane in that folder, or nothing if the folder isn't Quietpane. #>
    if (-not $Root) { return '' }
    $engine = Join-Path $Root 'src\Quietpane.psm1'
    if (-not (Test-Path -LiteralPath $engine -PathType Leaf) -or -not (Test-Path -LiteralPath (Join-Path $Root 'Quietpane.ps1') -PathType Leaf)) { return '' }
    # -TotalCount closes the file straight after, so the copy can be replaced a moment later.
    foreach ($line in @(Get-Content -LiteralPath $engine -TotalCount 80)) {
        if ($line -match "^\`$script:AppVersion\s*=\s*'([^']+)'") { return $matches[1] }
    }
    return ''
}

# ---------------------------------------------------------------- updates, without a connection
#
# Quietpane never asks the internet whether there is a newer version, and never will. What it can do is
# notice a newer Quietpane you have already downloaded yourself, and install it for you.
#
# Two protections matter more than the convenience. First, a ZIP from the internet carries Windows' mark
# saying so, and everything unzipped from it inherits that mark - it is what makes SmartScreen look at
# a file before it runs. Windows' own "Extract All" copies the mark across; so does this. Second, this
# window runs with administrator rights. Starting the new version from it directly would hand those
# rights to whatever was inside the ZIP without anyone being asked, so the new version is started the
# way a double-click starts it - by the signed-in user, through Explorer - and Windows asks as usual.

$script:UpdateMaxZipBytes = 10MB       # the real download is a quarter of a megabyte
$script:UpdateMaxUnpackedBytes = 50MB  # and unpacks to about one megabyte

function Get-QpDownloadsFolder {
    <# The signed-in user's Downloads folder, wherever it has been moved to. #>
    try {
        $p = (New-Object -ComObject Shell.Application).NameSpace('shell:Downloads').Self.Path
        if ($p -and (Test-Path -LiteralPath $p -PathType Container)) { return $p }
    } catch { }
    return (Join-Path $env:USERPROFILE 'Downloads')
}

function Get-QpZipVersion {
    <#
        Which Quietpane is inside a ZIP, read from inside it - nothing is unpacked. The ZIP counts only if
        it has the engine and the window side by side; otherwise, or if it can't be read, $null.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $zip = $null
    try {
        $f = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($f.Length -gt $script:UpdateMaxZipBytes) { return $null }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($f.FullName)
        $names = @($zip.Entries | ForEach-Object { $_.FullName -replace '\\', '/' })
        # A real download never names a path outside itself; one that does is not offered at all.
        if (@($names | Where-Object { $_ -match '(^|/)\.\.(/|$)' -or $_ -match '^/' -or $_ -match ':' }).Count) { return $null }
        $engine =@($zip.Entries | Where-Object { ($_.FullName -replace '\\', '/') -match '(^|/)src/Quietpane\.psm1$' } | Sort-Object { $_.FullName.Length })[0]
        if (-not $engine) { return $null }
        $root = ($engine.FullName -replace '\\', '/') -replace 'src/Quietpane\.psm1$', ''
        if ($names -notcontains ($root + 'Quietpane.ps1')) { return $null }
        $reader = New-Object IO.StreamReader($engine.Open())
        try {
            $version = $null; $released = $null
            for ($i = 0; $i -lt 80 -and -not $reader.EndOfStream; $i++) {
                $line = $reader.ReadLine()
                if ($line -match "^\`$script:AppVersion\s*=\s*'([0-9][0-9.]*)'") { $version = $matches[1] }
                if ($line -match "^\`$script:AppReleased\s*=\s*'([0-9-]+)'") { $released = $matches[1] }
            }
        } finally { $reader.Dispose() }
        if (-not $version) { return $null }
        [pscustomobject]@{ Path = $f.FullName; Name = $f.Name; Version = $version; Released = $released; Size = $f.Length; AppRoot = $root }
    } catch { return $null } finally { if ($zip) { $zip.Dispose() } }
}

function Find-QpDownloadedUpdate {
    <#
        The newest Quietpane ZIP in a folder (the Downloads folder unless told otherwise) that is newer than
        the one running. Only files named Quietpane*.zip are looked at - "Quietpane (1).zip" included -
        and nothing else in the folder is opened. $null when there is none.
    #>
    param([string]$Folder = '', [string]$Current = $script:AppVersion)
    if (-not $Folder) { $Folder = Get-QpDownloadsFolder }
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { return $null }
    $best = $null
    foreach ($f in @(Get-ChildItem -LiteralPath $Folder -Filter 'Quietpane*.zip' -File -ErrorAction SilentlyContinue)) {
        $z = Get-QpZipVersion -Path $f.FullName
        if (-not $z) { continue }
        if ((Compare-QpVersion $z.Version $Current) -le 0) { continue }
        if (-not $best -or (Compare-QpVersion $z.Version $best.Version) -gt 0) { $best = $z }
    }
    return $best
}

function Expand-QpUpdate {
    <#
        Unpacks a newer Quietpane into a visible folder beside the ZIP ("Quietpane 1.23.0"), carrying the
        ZIP's downloaded-from-the-internet mark onto every file, exactly as Windows' own Extract All does.
        Returns where it went and which file starts it. Refuses anything that is not a newer Quietpane,
        anything that would write outside that folder, and anything implausibly large.
    #>
    param([Parameter(Mandatory)][string]$Zip, [string]$Current = $script:AppVersion, [string]$Destination = '')
    $z = Get-QpZipVersion -Path $Zip
    if (-not $z) { throw 'That file is not a Quietpane download.' }
    if ((Compare-QpVersion $z.Version $Current) -le 0) { throw ('That is Quietpane {0}, which is not newer than this one ({1}).' -f $z.Version, $Current) }
    if (-not $Destination) { $Destination = Join-Path (Split-Path -Parent $z.Path) ('Quietpane ' + $z.Version) }
    $Destination = [IO.Path]::GetFullPath($Destination).TrimEnd('\')

    # Already unpacked, and still that version: use it rather than unpack again.
    $startName = 'Start Quietpane.cmd'
    $existing = @(Get-ChildItem -LiteralPath $Destination -Recurse -Filter $startName -File -ErrorAction SilentlyContinue | Sort-Object { $_.FullName.Length })
    foreach ($s in $existing) {
        $appRoot = @($s.Directory.FullName, (Join-Path $s.Directory.FullName 'App files - no need to open')) | Where-Object { Get-QpAppVersion $_ } | Select-Object -First 1
        if ($appRoot -and (Get-QpAppVersion $appRoot) -eq $z.Version) {
            return [pscustomobject]@{ Folder = $Destination; Start = $s.FullName; Version = $z.Version; Reused = $true }
        }
    }
    if (Test-Path -LiteralPath $Destination) {
        $n = 2
        while (Test-Path -LiteralPath ('{0} ({1})' -f $Destination, $n)) { $n++ }
        $Destination = '{0} ({1})' -f $Destination, $n
    }

    $mark = $null
    try { $mark = Get-Content -LiteralPath $z.Path -Stream 'Zone.Identifier' -Raw -ErrorAction Stop } catch { }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($z.Path)
    try {
        $total = ($archive.Entries | Measure-Object -Property Length -Sum).Sum
        if ($total -gt $script:UpdateMaxUnpackedBytes) { throw 'That file unpacks to far more than Quietpane is, so it was not opened.' }
        $prefix = $Destination + '\'
        foreach ($e in $archive.Entries) {
            $target = [IO.Path]::GetFullPath((Join-Path $Destination ($e.FullName -replace '/', '\')))
            # Nothing may land outside the folder, whatever the names inside the ZIP say.
            if (-not $target.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'That file tries to put things outside its own folder, so it was not unpacked.' }
            if ($e.FullName.EndsWith('/') -or $e.FullName.EndsWith('\')) { New-Item -ItemType Directory -Path $target -Force | Out-Null; continue }
            New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $false)
            if ($mark) { Set-Content -LiteralPath $target -Stream 'Zone.Identifier' -Value $mark -NoNewline -ErrorAction Stop }
        }
    } finally { $archive.Dispose() }
    $start = @(Get-ChildItem -LiteralPath $Destination -Recurse -Filter $startName -File | Sort-Object { $_.FullName.Length })[0]
    if (-not $start) { throw 'The unpacked copy has no Start Quietpane file.' }
    [pscustomobject]@{ Folder = $Destination; Start = $start.FullName; Version = $z.Version; Reused = $false; Marked = [bool]$mark }
}

function Get-QpNewerInstalledCopy {
    <#
        Quietpane's own copy in Program Files, when it is newer than the one running from somewhere else -
        so opening an old unzipped folder brings up the version you updated to. That copy can only have
        been written by an administrator, which is why it is safe to start directly. $null otherwise,
        and always $null when this IS that copy, so it can never send itself round in a circle.
    #>
    param([Parameter(Mandatory)][string]$Running, [string]$InstallRoot = $script:InstallRoot, [string]$Current = $script:AppVersion)
    if (Test-QpSamePath $Running $InstallRoot) { return $null }
    $v = Get-QpAppVersion $InstallRoot
    if (-not $v -or (Compare-QpVersion $v $Current) -le 0) { return $null }
    [pscustomobject]@{ Root = $InstallRoot; Version = $v; Script = (Join-Path $InstallRoot 'Quietpane.ps1') }
}

function Get-QpAppFileList([string]$Root) {
    <# The files that make up Quietpane, relative to its folder. #>
    $Root = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($n in $script:AppFileNames) { if (Test-Path -LiteralPath (Join-Path $Root $n) -PathType Leaf) { $list.Add($n) } }
    foreach ($d in $script:AppFolderNames) {
        $dir = Join-Path $Root $d
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Recurse -File -Force -ErrorAction SilentlyContinue)) { $list.Add($f.FullName.Substring($Root.Length + 1)) }
    }
    return @($list | Sort-Object)
}

function Test-QpCopyMatches([string]$From, [string]$To) {
    <# True when every Quietpane file in $From is in $To, byte for byte. #>
    foreach ($rel in (Get-QpAppFileList $From)) {
        $a = Join-Path $From $rel; $b = Join-Path $To $rel
        if (-not (Test-Path -LiteralPath $b -PathType Leaf)) { return $false }
        if ((Get-Item -LiteralPath $a).Length -ne (Get-Item -LiteralPath $b).Length) { return $false }
        if ((Get-FileHash -LiteralPath $a).Hash -ne (Get-FileHash -LiteralPath $b).Hash) { return $false }
    }
    return $true
}

function Install-QpCopy {
    <#
        Makes Quietpane's own copy in Program Files, or brings it up to date. It only moves forward:
        opening an older Quietpane never replaces a newer copy. Files are copied over the old ones and
        nothing is deleted. Needs administrator rights, like the rest of the app.
    #>
    param([string]$From = (Split-Path $PSScriptRoot -Parent), [string]$To = $script:InstallRoot)
    if (Test-QpSamePath $From $To) { return [pscustomobject]@{ Ok = $true; Changed = $false; Note = '' } }
    $fromVersion = Get-QpAppVersion $From
    if (-not $fromVersion) { return [pscustomobject]@{ Ok = $false; Changed = $false; Note = 'Quietpane could not find its own files, so nothing was changed.' } }
    $toVersion = Get-QpAppVersion $To
    if ($toVersion) {
        $cmp = Compare-QpVersion $fromVersion $toVersion
        if ($cmp -lt 0) { return [pscustomobject]@{ Ok = $true; Changed = $false; Note = "Quietpane's own copy is newer ($toVersion), so it was left as it is." } }
        if ($cmp -eq 0 -and (Test-QpCopyMatches $From $To)) { return [pscustomobject]@{ Ok = $true; Changed = $false; Note = '' } }
    }
    try {
        # The engine goes last: a copy that stops half way still reads as the old version, and is
        # simply finished the next time Quietpane opens.
        $engine = 'src\Quietpane.psm1'
        $files = @(Get-QpAppFileList $From | Where-Object { $_ -ne $engine }) + @($engine)
        foreach ($rel in $files) {
            $target = Join-Path $To $rel
            $dir = Split-Path $target -Parent
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop | Out-Null }
            Copy-Item -LiteralPath (Join-Path $From $rel) -Destination $target -Force -ErrorAction Stop
        }
    } catch {
        Write-QpLog "Could not copy Quietpane to $To : $(Get-QpFailureReason $_.Exception)" 'WARN'
        return [pscustomobject]@{ Ok = $false; Changed = $false; Note = "Windows would not let Quietpane copy itself to $To, so nothing was changed." }
    }
    $what = if (-not $toVersion) { "made ($fromVersion)" } elseif ($toVersion -eq $fromVersion) { 'put right' } else { "brought up to date ($toVersion to $fromVersion)" }
    Write-QpLog "Quietpane's own copy in $To was $what." 'OK'
    [pscustomobject]@{ Ok = $true; Changed = $true; Note = '' }
}

function Remove-QpCopy {
    <#
        Sends Quietpane's own copy to the Recycle Bin once nothing uses it. If that copy is the one open
        right now it can't go yet, and 'Later' tells the window to send it as it closes.
    #>
    param([string]$InstallRoot = $script:InstallRoot)
    if (-not (Test-Path -LiteralPath $InstallRoot)) { return 'None' }
    # Only ever a folder that really is a copy of Quietpane.
    if (-not (Get-QpAppVersion $InstallRoot)) { Write-QpLog "$InstallRoot does not look like Quietpane, so it was left alone." 'WARN'; return 'Failed' }
    if (Test-QpSamePath (Split-Path $PSScriptRoot -Parent) $InstallRoot) { return 'Later' }
    if (Move-QpToRecycleBin -Path $InstallRoot) { Write-QpLog "Quietpane's own copy in $InstallRoot is in the Recycle Bin." 'OK'; return 'Recycled' }
    Write-QpLog "Could not move $InstallRoot to the Recycle Bin, so it was left where it is." 'WARN'
    return 'Failed'
}

function Start-QpCopyRemoval {
    <#
        For the window, as it closes, when its own copy was taken away while it was open. A hidden
        PowerShell waits for this one to finish, then sends Program Files\Quietpane to the Recycle Bin,
        the same way any other tidy-up does. It never acts on any other folder.
    #>
    $root = $script:InstallRoot
    if (-not (Test-Path -LiteralPath $root) -or $root -match '[''"]' -or -not (Get-QpAppVersion $root)) { return $false }
    # Too big for the bin would mean Windows deletes it for good, so it would stay instead.
    $limit = Get-QpRecycleBinLimit $root
    if ($limit -le 0 -or (Get-QpSize @($root)) -gt $limit) { Write-QpLog "The Recycle Bin can't take $root, so it was left where it is." 'WARN'; return $false }
    $command = "Wait-Process -Id $PID -ErrorAction SilentlyContinue; Add-Type -AssemblyName Microsoft.VisualBasic; [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory('$root', 'OnlyErrorDialogs', 'SendToRecycleBin')"
    $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    # Started from the Windows folder, so it isn't "inside" the folder it is about to move.
    Start-Process -FilePath $ps -WorkingDirectory $env:WINDIR -WindowStyle Hidden -ArgumentList ('-NoProfile -NonInteractive -Command "{0}"' -f $command) | Out-Null
    return $true
}

function Get-QpCopyNote([string]$State, [string]$Root = $script:InstallRoot) {
    switch ($State) {
        'Recycled' { " Quietpane's own copy from Program Files is in the Recycle Bin too." }
        'Later'    { " Quietpane's own copy in Program Files goes to the Recycle Bin when you close this window." }
        'Failed'   { " Quietpane's own copy is still in $Root." }
        default    { '' }
    }
}

function Get-QpShortcutPaths {
    <# Where the shortcuts go (your own Start menu and desktop - nothing system-wide) and what they open. #>
    param([string]$InstallRoot = $script:InstallRoot)
    $root = Split-Path $PSScriptRoot -Parent
    [pscustomobject]@{
        StartMenu   = Join-Path ([Environment]::GetFolderPath('Programs')) 'Quietpane.lnk'
        Desktop     = Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) 'Quietpane.lnk'
        Pinned      = Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
        AppRoot     = $root
        InstallRoot = $InstallRoot
        Script      = Join-Path $InstallRoot 'Quietpane.ps1'
        Icon        = Join-Path $InstallRoot 'assets\quietpane.ico'
        FromCopy    = (Test-QpSamePath $root $InstallRoot)
    }
}

function Initialize-QpShortcut {
    if (-not ('QuietpaneShortcut' -as [type])) { Add-Type -TypeDefinition $script:ShortcutSource -ErrorAction Stop }
}

function Get-QpLinkScript([string]$Arguments) {
    <# Which Quietpane.ps1 a shortcut or task opens, read from its -File part. #>
    if ($Arguments -match '-File\s+"([^"]+)"') { return $matches[1] }
    return ''
}

function Get-QpOwnShortcuts {
    <#
        Quietpane's shortcuts: the Start menu and desktop ones, and any copy of them pinned to the
        taskbar. Only shortcuts carrying Quietpane's app id count, so one you made yourself is left alone.
    #>
    param($Paths = (Get-QpShortcutPaths))
    Initialize-QpShortcut
    $candidates = @(@{ Path = $Paths.StartMenu; Kind = 'StartMenu' }, @{ Path = $Paths.Desktop; Kind = 'Desktop' })
    if ($Paths.Pinned -and (Test-Path -LiteralPath $Paths.Pinned)) {
        foreach ($f in @(Get-ChildItem -LiteralPath $Paths.Pinned -Filter '*.lnk' -File -Force -ErrorAction SilentlyContinue)) { $candidates += @{ Path = $f.FullName; Kind = 'Pinned' } }
    }
    $out = New-Object System.Collections.ArrayList
    foreach ($c in $candidates) {
        if (-not $c.Path -or -not (Test-Path -LiteralPath $c.Path -PathType Leaf)) { continue }
        try {
            if ([QuietpaneShortcut]::ReadAppId($c.Path) -ne $script:AppUserModelId) { continue }
            [void]$out.Add([pscustomobject]@{ Path = $c.Path; Kind = $c.Kind; Script = (Get-QpLinkScript ([QuietpaneShortcut]::ReadArguments($c.Path))) })
        } catch { }
    }
    return @($out)
}

function Test-QpShortcuts {
    param($Paths = (Get-QpShortcutPaths))
    $own = @(Get-QpOwnShortcuts -Paths $Paths)
    [pscustomobject]@{
        StartMenu = (@($own | Where-Object { $_.Kind -eq 'StartMenu' }).Count -gt 0)
        Desktop   = (@($own | Where-Object { $_.Kind -eq 'Desktop' }).Count -gt 0)
        Pinned    = (@($own | Where-Object { $_.Kind -eq 'Pinned' }).Count -gt 0)
    }
}

function Set-QpShortcut([string]$Link, $Paths) {
    $target = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    # (not $args: PowerShell keeps that name for a function's own arguments)
    $argLine = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}"' -f $Paths.Script
    [QuietpaneShortcut]::Create($Link, $target, $argLine, $Paths.InstallRoot, $Paths.Icon, 'Quietpane - take your Windows PC back', $script:AppUserModelId)
}

function New-QpShortcuts {
    <#
        Puts Quietpane in your Start menu and on your desktop, with the KomodoWorks emblem. They open
        Quietpane's own copy, so moving or deleting the folder you unzipped doesn't break them.
    #>
    param([string]$InstallRoot = $script:InstallRoot)
    $p = Get-QpShortcutPaths -InstallRoot $InstallRoot
    $copy = Install-QpCopy -To $InstallRoot
    if (-not $copy.Ok) { return [pscustomobject]@{ Ok = $false; Note = $copy.Note } }
    Initialize-QpShortcut
    $made = 0
    foreach ($link in $p.StartMenu, $p.Desktop) {
        try { Set-QpShortcut $link $p; $made++; Write-QpLog "Shortcut ready: $link" 'OK' }
        catch { Write-QpLog "Could not make the shortcut at $link : $(Get-QpFailureReason $_.Exception)" 'WARN' }
    }
    if (-not $made) { return [pscustomobject]@{ Ok = $false; Note = 'Windows would not let Quietpane make the shortcuts.' } }
    [pscustomobject]@{ Ok = $true; Note = 'Quietpane is in your Start menu and on your desktop, and they keep working even if you move or delete the folder you unzipped. To keep it on the taskbar, right-click it in the Start menu and choose "Pin to taskbar".' }
}

function Remove-QpShortcuts {
    <# Takes the Start menu and desktop shortcuts away again. They go to the Recycle Bin, like everything else. #>
    param([string]$InstallRoot = $script:InstallRoot, [string]$TaskName = $script:SignInTaskName)
    $p = Get-QpShortcutPaths -InstallRoot $InstallRoot
    $own = @(Get-QpOwnShortcuts -Paths $p)
    $gone = 0
    foreach ($l in @($own | Where-Object { $_.Kind -ne 'Pinned' })) {
        if (Move-QpToRecycleBin -Path $l.Path) { $gone++; Write-QpLog "Shortcut removed: $($l.Path)" 'OK' }
        else { Write-QpLog "Could not remove the shortcut at $($l.Path)" 'WARN' }
    }
    $note = if ($gone) { 'The shortcuts are in your Recycle Bin.' } else { 'There were no Quietpane shortcuts to remove.' }
    $copy = 'Kept'
    if (-not (Get-QpSignInTask -Name $TaskName)) { $copy = Remove-QpCopy -InstallRoot $InstallRoot }
    $note += Get-QpCopyNote $copy $InstallRoot
    if (@($own | Where-Object { $_.Kind -eq 'Pinned' }).Count) { $note += ' It is still pinned to your taskbar: right-click it there and choose "Unpin from taskbar".' }
    [pscustomobject]@{ Ok = ($gone -gt 0); Note = $note; Copy = $copy }
}

function Get-QpSignInTask {
    <#
        Quietpane's sign-in task, or nothing. Asked of Task Scheduler directly: the window checks this as
        it opens, and Get-ScheduledTask would hold it up for a second each time.
    #>
    param([string]$Name = $script:SignInTaskName)
    try { $t = (Get-QpTaskService).GetFolder('\').GetTask($Name) }
    catch {
        # Not there (0x80070002, "file not found") - or Task Scheduler can't be asked directly, in which
        # case ask the slower way. The code, not the message: messages are translated.
        $ex = $_.Exception; while ($ex.InnerException) { $ex = $ex.InnerException }
        if ($ex.HResult -eq -2147024894) { return $null }
        try {
            $s = Get-ScheduledTask -TaskPath '\' -TaskName $Name -ErrorAction Stop
            return [pscustomobject]@{
                TaskPath = $s.TaskPath; TaskName = $s.TaskName; State = [string]$s.State
                Actions = @(foreach ($a in @($s.Actions)) { [pscustomobject]@{ Execute = [string]$a.Execute; Arguments = [string]$a.Arguments } })
                Principal = [pscustomobject]@{ RunLevel = [string]$s.Principal.RunLevel }
            }
        } catch { return $null }
    }
    $def = $t.Definition
    [pscustomobject]@{
        TaskPath = '\'; TaskName = [string]$t.Name; State = $script:TaskStates[[int]$t.State]
        # Type 0 is "start a program", the only kind Quietpane makes.
        Actions = @(foreach ($a in @($def.Actions)) { if ([int]$a.Type -eq 0) { [pscustomobject]@{ Execute = [string]$a.Path; Arguments = [string]$a.Arguments } } })
        Principal = [pscustomobject]@{ RunLevel = $(if ([int]$def.Principal.RunLevel -eq 1) { 'Highest' } else { 'Limited' }) }
    }
}

function Test-QpSignInStart {
    param([string]$Name = $script:SignInTaskName)
    $t = Get-QpSignInTask -Name $Name
    return [bool]($t -and "$($t.State)" -ne 'Disabled')
}

function Get-QpSignInAction {
    <#
        What the sign-in task runs. -Watch adds "check once, quietly, for anything Windows switched back
        on" - the choice lives in the task itself, so there is no separate setting to get out of step.
    #>
    param([string]$Script, [switch]$Watch)
    $argLine = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}" -Minimized' -f $Script
    if ($Watch) { $argLine += ' -Watch' }
    New-ScheduledTaskAction -Execute (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -Argument $argLine
}

function Test-QpTaskWatches($Task) {
    <# Whether a sign-in task also checks for things that came back. #>
    return [bool]($Task -and @(@($Task.Actions) | Where-Object { "$($_.Arguments)" -match '(^|\s)-Watch(\s|$)' }).Count)
}

function Test-QpSignInWatch {
    param([string]$Name = $script:SignInTaskName)
    return (Test-QpTaskWatches (Get-QpSignInTask -Name $Name))
}

function Test-QpOwnSignInTask($Task) {
    <# Quietpane's own sign-in task, exactly as Quietpane makes it. A task that only borrows the name is not. #>
    if (-not $Task -or $Task.TaskPath -ne '\' -or $Task.TaskName -ne $script:SignInTaskName) { return $false }
    $a = @($Task.Actions)
    if ($a.Count -ne 1) { return $false }
    $opens = Join-Path $script:InstallRoot 'Quietpane.ps1'
    foreach ($want in (Get-QpSignInAction $opens), (Get-QpSignInAction $opens -Watch)) {
        if ($a[0].Execute -ieq $want.Execute -and $a[0].Arguments -ceq $want.Arguments) { return $true }
    }
    return $false
}

function New-QpSignInTask {
    <#
        A task in Task Scheduler rather than a Run entry, because Quietpane needs administrator rights:
        this way Windows doesn't ask you for them every time you sign in. Only describes the task;
        Register-QpSignInTask is what hands it to Windows.
    #>
    param([string]$Script, [switch]$Watch)
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $trigger.Delay = 'PT20S'   # let Windows finish signing you in first
    # A laptop on battery still starts it, and it is never stopped for running "too long".
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -Priority 6
    $parts = @{
        Action      = Get-QpSignInAction $Script -Watch:$Watch
        Trigger     = $trigger
        Principal   = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
        Settings    = $settings
        Description = $(if ($Watch) { 'Opens Quietpane on the taskbar when you sign in, and checks once for anything Windows switched back on. Change this in Quietpane > About.' }
                        else { 'Opens Quietpane on the taskbar when you sign in. Switch it off in Quietpane > About.' })
    }
    $task = New-ScheduledTask @parts
    $task.Author = 'KomodoWorks'
    return $task
}

function Register-QpSignInTask {
    param([string]$Script, [string]$Name = $script:SignInTaskName, [switch]$Watch)
    Register-ScheduledTask -TaskPath '\' -TaskName $Name -InputObject (New-QpSignInTask -Script $Script -Watch:$Watch) -Force -ErrorAction Stop | Out-Null
}

function Enable-QpSignInStart {
    <#
        Opens Quietpane quietly on the taskbar each time you sign in, from its own copy in Program Files.
        With -Watch it also checks once for anything Windows switched back on. Calling it again with or
        without -Watch is how that choice is changed.
    #>
    param([string]$InstallRoot = $script:InstallRoot, [string]$Name = $script:SignInTaskName, [switch]$Watch)
    if (-not (Test-QpAdmin)) { return [pscustomobject]@{ Ok = $false; Note = 'Quietpane needs administrator rights for this, so nothing was changed.' } }
    $copy = Install-QpCopy -To $InstallRoot
    if (-not $copy.Ok) { return [pscustomobject]@{ Ok = $false; Note = $copy.Note } }
    try { Register-QpSignInTask -Script (Join-Path $InstallRoot 'Quietpane.ps1') -Name $Name -Watch:$Watch }
    catch {
        Write-QpLog "Could not set Quietpane to start when you sign in: $(Get-QpFailureReason $_.Exception)" 'WARN'
        return [pscustomobject]@{ Ok = $false; Note = 'Windows would not let Quietpane start when you sign in, so nothing was changed.' }
    }
    if ($Watch) {
        Write-QpLog 'Quietpane will open on the taskbar when you sign in, and check once for anything that switched back on.' 'OK'
        return [pscustomobject]@{ Ok = $true; Note = 'When you sign in, Quietpane will check once, quietly. If anything switched back on, its taskbar icon gets a small badge.' }
    }
    Write-QpLog 'Quietpane will open on the taskbar when you sign in.' 'OK'
    [pscustomobject]@{ Ok = $true; Note = 'Quietpane will open on the taskbar each time you sign in, and wait there until you click it.' }
}

function Disable-QpSignInStart {
    param([string]$InstallRoot = $script:InstallRoot, [string]$Name = $script:SignInTaskName)
    if (Get-QpSignInTask -Name $Name) {
        # Quietpane's own task goes completely. (Other programs' tasks are only ever switched off.)
        try { Unregister-ScheduledTask -TaskPath '\' -TaskName $Name -Confirm:$false -ErrorAction Stop }
        catch { return [pscustomobject]@{ Ok = $false; Note = 'Windows would not let Quietpane switch this off, so it still starts when you sign in.' } }
        Write-QpLog 'Quietpane no longer starts when you sign in.' 'OK'
    }
    $copy = 'Kept'
    $links = @(Get-QpOwnShortcuts -Paths (Get-QpShortcutPaths -InstallRoot $InstallRoot) | Where-Object { $_.Kind -ne 'Pinned' })
    if (-not $links.Count) { $copy = Remove-QpCopy -InstallRoot $InstallRoot }
    [pscustomobject]@{ Ok = $true; Note = 'Quietpane no longer starts when you sign in.' + (Get-QpCopyNote $copy $InstallRoot); Copy = $copy }
}

function Sync-QpInstall {
    <#
        Runs as Quietpane opens. If it has shortcuts or starts when you sign in, this makes sure they all
        open Quietpane's own copy - pointing back any that still open the folder you unzipped - and
        brings that copy up to date when you open a newer Quietpane. With no shortcuts and no sign-in
        start, it does nothing at all.
    #>
    param([string]$InstallRoot = $script:InstallRoot, [string]$Name = $script:SignInTaskName, $Paths = $null)
    $p = if ($Paths) { $Paths } else { Get-QpShortcutPaths -InstallRoot $InstallRoot }
    $links = @(Get-QpOwnShortcuts -Paths $p)
    $task = Get-QpSignInTask -Name $Name
    $result = [pscustomobject]@{ InUse = ($links.Count -gt 0 -or $null -ne $task); Ok = $true; Updated = $false; Repaired = 0 }
    if (-not $result.InUse) { return $result }
    $copy = Install-QpCopy -From $p.AppRoot -To $InstallRoot
    if (-not $copy.Ok) { $result.Ok = $false; return $result }
    $result.Updated = $copy.Changed
    if ($copy.Note) { Write-QpLog $copy.Note 'INFO' }
    foreach ($l in $links) {
        if (Test-QpSamePath $l.Script $p.Script) { continue }
        try { Set-QpShortcut $l.Path $p; $result.Repaired++; Write-QpLog "This shortcut now opens Quietpane's own copy: $($l.Path)" 'OK' }
        catch { Write-QpLog "Could not update the shortcut at $($l.Path) : $(Get-QpFailureReason $_.Exception)" 'WARN' }
    }
    if ($task) {
        $opens = Get-QpLinkScript ((@($task.Actions) | ForEach-Object { $_.Arguments }) -join ' ')
        if (-not (Test-QpSamePath $opens $p.Script) -and (Test-QpAdmin)) {
            try { Register-QpSignInTask -Script $p.Script -Name $Name -Watch:(Test-QpTaskWatches $task); $result.Repaired++; Write-QpLog "Starting at sign-in now opens Quietpane's own copy." 'OK' }
            catch { Write-QpLog "Could not update the sign-in start: $(Get-QpFailureReason $_.Exception)" 'WARN' }
        }
    }
    return $result
}

#endregion

#region ---------------------------------------------------------------- where the space went

# Adds up how much room each folder takes, so you can see where your disk went. It reads names and
# sizes only - no file is opened - and skips links, so nothing is counted twice. Online-only OneDrive
# files take no room on this PC, so they aren't counted either. Windows' own folder isn't walked: its
# files are hard-linked many times over, so the honest figure is simply "whatever else is in use".

$script:SpaceScannerSource = @'
using System;
using System.Collections.Generic;
using System.IO;

public class QuietpaneSpaceNode {
    public string Name; public string Path; public long Size; public bool IsFile; public bool Denied;
    public long Files; public long Folders; public long OtherSize; public int OtherCount; public long CloudSize;
    // A program's own folder has its .exe and .dll files side by side. Moving that, or anything
    // holding it, would stop the program working.
    public bool HasProgram; public bool ContainsProgram;
    public DateTime Modified; public QuietpaneSpaceNode Parent;
    public List<QuietpaneSpaceNode> Children = new List<QuietpaneSpaceNode>();
}

// Only reads directory listings. It never opens, changes or deletes anything.
public static class QuietpaneSpaceScanner {
    const FileAttributes RecallOnOpen = (FileAttributes)0x40000, RecallOnData = (FileAttributes)0x400000;
    static string[] skip; static string[] cloud; static long keep; static Func<string, long, bool> tick;
    static long seen; static bool stopped;
    public static bool WasStopped { get { return stopped; } }

    public static QuietpaneSpaceNode Scan(string root, string[] skipPaths, string[] cloudRoots, long keepAbove, Func<string, long, bool> onTick) {
        skip = skipPaths ?? new string[0]; cloud = cloudRoots ?? new string[0]; keep = keepAbove; tick = onTick; seen = 0; stopped = false;
        var node = new QuietpaneSpaceNode { Name = root, Path = root };
        Walk(new DirectoryInfo(root), node);
        return node;
    }

    static bool Under(string path, string[] roots) {
        foreach (var r in roots) {
            if (string.IsNullOrEmpty(r)) continue;
            if (path.Equals(r, StringComparison.OrdinalIgnoreCase) || path.StartsWith(r.TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase)) return true;
        }
        return false;
    }

    static void Walk(DirectoryInfo dir, QuietpaneSpaceNode node) {
        if (stopped) return;
        seen++;
        if (tick != null && seen % 500 == 0 && !tick(dir.FullName, seen)) { stopped = true; return; }
        IEnumerable<FileSystemInfo> entries;
        try { entries = dir.EnumerateFileSystemInfos(); } catch { node.Denied = true; return; }
        bool exe = false, dll = false;
        try {
            foreach (var e in entries) {
                if (stopped) return;
                var a = e.Attributes;
                if ((a & FileAttributes.Directory) != 0) {
                    // Links and junctions point at something counted elsewhere; OneDrive's folders are real.
                    if ((a & FileAttributes.ReparsePoint) != 0 && !Under(e.FullName, cloud)) continue;
                    if (Under(e.FullName, skip)) continue;
                    var child = new QuietpaneSpaceNode { Name = e.Name, Path = e.FullName, Parent = node, Modified = e.LastWriteTime };
                    Walk((DirectoryInfo)e, child);
                    node.Size += child.Size; node.Files += child.Files; node.Folders += child.Folders + 1; node.CloudSize += child.CloudSize;
                    if (child.ContainsProgram) node.ContainsProgram = true;
                    if (child.Size >= keep) node.Children.Add(child); else { node.OtherSize += child.Size; node.OtherCount++; }
                } else {
                    string ext = e.Extension;
                    if (ext.Equals(".exe", StringComparison.OrdinalIgnoreCase)) exe = true;
                    else if (ext.Equals(".dll", StringComparison.OrdinalIgnoreCase)) dll = true;
                    long len = ((FileInfo)e).Length;
                    // Online-only files take no room on this PC, however big they say they are.
                    if ((a & (FileAttributes.Offline | RecallOnOpen | RecallOnData)) != 0) { node.CloudSize += len; continue; }
                    node.Size += len; node.Files++;
                    if (len >= keep) node.Children.Add(new QuietpaneSpaceNode { Name = e.Name, Path = e.FullName, Size = len, IsFile = true, Parent = node, Modified = e.LastWriteTime, Files = 1 });
                    else { node.OtherSize += len; node.OtherCount++; }
                }
            }
        } catch { node.Denied = true; }
        if (exe && dll) { node.HasProgram = true; node.ContainsProgram = true; }
    }
}
'@

function Initialize-QpSpaceScanner {
    if (-not ('QuietpaneSpaceScanner' -as [type])) { Add-Type -TypeDefinition $script:SpaceScannerSource -ErrorAction Stop }
}

function Get-QpSpaceUse {
    <#
        Where the space on a drive went: every folder's size, keeping the ones worth showing (50 MB and
        up) and adding the rest up as "smaller items". Read-only. Stop works at any point.
    #>
    param([string]$Root = ($env:SystemDrive + '\'), [int64]$KeepAbove = 50MB)
    Initialize-QpSpaceScanner
    $Root = $Root.TrimEnd('\') + '\'
    $isSystem = $Root -like ($env:SystemDrive + '\*')
    $skip = @(if ($isSystem) { $env:WINDIR })
    $cloud = @($env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial | Where-Object { $_ } | Select-Object -Unique)
    $started = Get-Date
    $tick = [Func[string, long, bool]]{
        param($path, $count)
        Write-QpProgress -Stage 'Adding up folder sizes' -Object $path -Scanned ([int]$count)
        -not (Test-QpCancelled)
    }
    $tree = [QuietpaneSpaceScanner]::Scan($Root, [string[]]$skip, [string[]]$cloud, $KeepAbove, $tick)
    $drive = New-Object IO.DriveInfo $Root
    $used = [int64]($drive.TotalSize - $drive.AvailableFreeSpace)
    [pscustomobject]@{
        Root = $Root; Tree = $tree; Total = [int64]$drive.TotalSize; Free = [int64]$drive.AvailableFreeSpace; Used = $used
        # Whatever is in use but wasn't counted: Windows itself, restore points, and files nobody may read.
        Hidden = [int64][math]::Max([double]0, [double]($used - $tree.Size))
        HiddenLabel = $(if ($isSystem) { 'Windows and system files' } else { 'System and hidden files' })
        Cloud = [int64]$tree.CloudSize; Folders = [int64]$tree.Folders; Files = [int64]$tree.Files
        BinLimit = (Get-QpRecycleBinLimit $Root)
        Installed = @(Get-QpInstallPlaces)
        Cancelled = [QuietpaneSpaceScanner]::WasStopped; Seconds = [int]((Get-Date) - $started).TotalSeconds
    }
}

function Get-QpInstallPlaces {
    <#
        Where installed programs and games live, as they told Windows when they were installed
        ("The Sims 4" -> C:\Games\The Sims 4). Read-only.
    #>
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $places = @{}
    foreach ($k in $keys) {
        foreach ($e in @(Get-ItemProperty -Path $k -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName })) {
            $where = [string]$e.InstallLocation
            if (-not $where.Trim()) {
                # No folder given: a program's own uninstaller usually sits in its folder ("unins000.exe").
                $exe = Resolve-QpCommandTarget ([string]$e.UninstallString)
                if ($exe -and [IO.Path]::IsPathRooted($exe) -and (Split-Path $exe -Leaf) -match '^(?i)(unins|uninst)') { $where = Split-Path $exe -Parent }
            }
            $where = $where.Trim().Trim('"').TrimEnd('\')
            if ($where.Length -le 3 -or -not [IO.Path]::IsPathRooted($where)) { continue }
            if ($env:WINDIR -and $where -like "$env:WINDIR*") { continue }
            if (-not $places.ContainsKey($where)) { $places[$where] = [string]$e.DisplayName }
        }
    }
    return @($places.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Path = $_.Key; Name = $_.Value } })
}

function Get-QpSpaceAdvice {
    <#
        What a place on the disk is, in plain words, and whether Quietpane will move it to the Recycle
        Bin. Your own files can go; Windows, installed programs, games and app data are explained instead,
        with where to remove them properly. -Installed is Get-QpInstallPlaces; -NearProgram says the
        scan found a program's own files in or around it.
    #>
    param([Parameter(Mandatory)][string]$Path, $Installed = @(), [bool]$NearProgram = $false)
    function Out-Advice([bool]$Can, [string]$Why, [string]$Note = '') { [pscustomobject]@{ CanRecycle = $Can; Why = $Why; Note = $Note } }
    $p = try { [IO.Path]::GetFullPath($Path).TrimEnd('\') } catch { return (Out-Advice $false 'Quietpane could not work out where this is.') }
    function Test-Under([string]$Root) { $Root = "$Root".TrimEnd('\'); return ($Root -and ($p -eq $Root -or $p.StartsWith($Root + '\', [StringComparison]::OrdinalIgnoreCase))) }
    $leaf = Split-Path $p -Leaf
    $appRoot = Split-Path $PSScriptRoot -Parent
    $userDir = [Environment]::GetFolderPath('UserProfile')
    $usersRoot = Split-Path $userDir -Parent

    if ($p.Length -le 3) { return (Out-Advice $false 'A whole drive.') }
    if ($p -match '^[a-z]:\\(pagefile|swapfile)\.sys$') { return (Out-Advice $false "Windows' page file, which works alongside your memory. Windows looks after its size." "Windows' page file") }
    if ($p -match '^[a-z]:\\hiberfil\.sys$') { return (Out-Advice $false "Windows' hibernation file, which lets the PC sleep deeply and start quickly. Windows looks after it." "Windows' hibernation file") }
    if ($p -match '^[a-z]:\\DumpStack\.log') { return (Out-Advice $false 'A small log Windows keeps for when it crashes.') }
    if ($p -match '^[a-z]:\\\$Recycle\.Bin') { return (Out-Advice $false "Your Recycle Bin. Empty it yourself when you're sure." 'Your Recycle Bin') }
    if ($p -match '^[a-z]:\\(System Volume Information|Recovery|Config\.Msi|\$WinREAgent|\$SysReset|\$Windows\.~BT|\$Windows\.~WS|\$GetCurrent)(\\|$)') { return (Out-Advice $false 'Kept by Windows for recovery and updates.') }
    if ($p -match '^[a-z]:\\Windows\.old(\\|$)') { return (Out-Advice $false 'Your previous version of Windows. Remove it in Settings > System > Storage > Temporary files, which does it safely.' 'Your previous Windows') }
    if (Test-Under $env:WINDIR) { return (Out-Advice $false 'Windows itself. Quietpane never touches it.' 'Windows itself') }
    if ($appRoot -and (Test-Under $appRoot)) { return (Out-Advice $false 'Quietpane itself.' 'Quietpane') }
    if ($p -match '\\steamapps(\\|$)') { return (Out-Advice $false 'A Steam game, or its files. Uninstall it in Steam, so Steam knows it has gone.' 'Steam games') }
    if ($p -match '\\(Epic Games|EA Games|XboxGames|Riot Games|GOG Galaxy\\Games|Ubisoft Game Launcher\\games)(\\|$)') { return (Out-Advice $false "A game. Uninstall it in the launcher it came from, so the launcher knows it has gone." 'Games') }
    foreach ($root in $env:ProgramFiles, ${env:ProgramFiles(x86)}) {
        if ($root -and (Test-Under $root)) { return (Out-Advice $false 'Installed programs. Remove them in Settings > Apps > Installed apps, so they are removed properly.' 'Installed programs') }
    }
    if (Test-Under $env:ProgramData) { return (Out-Advice $false 'Settings and data your programs share. Moving them could break those programs.' 'Shared program data') }
    if ($p -match '\\AppData(\\|$)') { return (Out-Advice $false "Your apps' settings and caches. The list above clears the parts that are safe to clear." "Apps' settings and caches") }
    # ".codex", ".vscode", ".cache"... in your own folder: where tools keep their settings and parts.
    if ($p -match ('^' + [regex]::Escape($userDir.TrimEnd('\')) + '\\\.[^\\]+')) { return (Out-Advice $false "An app's own settings and parts (its folder name starts with a dot). Remove the app itself to remove it properly." "An app's own folder") }
    if ($p -eq $usersRoot.TrimEnd('\')) { return (Out-Advice $false 'Everyone who uses this PC has a folder in here.' 'Accounts on this PC') }
    if ((Test-Under $usersRoot) -and -not (Test-Under $userDir)) {
        if ($leaf -eq 'Public' -or (Split-Path $p -Parent) -ne $usersRoot.TrimEnd('\')) { return (Out-Advice $false "Files that belong to another account on this PC, or shared by everyone. Quietpane leaves them to their owner.") }
        return (Out-Advice $false "Another person's files on this PC. Quietpane leaves them to their owner." 'Another account')
    }
    if ($p -eq $userDir.TrimEnd('\')) { return (Out-Advice $false 'Your own folder. Open it to pick what to move.' 'Your files') }
    $main = @('Desktop', 'MyDocuments', 'MyMusic', 'MyPictures', 'MyVideos') | ForEach-Object { [Environment]::GetFolderPath($_) }
    $main += @('Downloads', 'Saved Games', 'Contacts', 'Favorites', 'Links', 'Searches', '3D Objects', 'OneDrive') | ForEach-Object { Join-Path $userDir $_ }
    $main += @($env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial)
    foreach ($m in @($main | Where-Object { $_ })) { if ($p -eq $m.TrimEnd('\')) { return (Out-Advice $false 'One of your main folders. Open it to pick what to move.') } }
    foreach ($i in @($Installed | Where-Object { $_ -and $_.Path })) {
        if (Test-Under $i.Path) { return (Out-Advice $false "Part of $($i.Name). Uninstall it in Settings > Apps > Installed apps (or the launcher it came from), so it is removed properly." $i.Name) }
        if ("$($i.Path)".StartsWith($p + '\', [StringComparison]::OrdinalIgnoreCase)) { return (Out-Advice $false "It holds $($i.Name). Uninstall that first, so it is removed properly." "Holds $($i.Name)") }
    }
    if ($NearProgram) { return (Out-Advice $false 'It holds a program, or sits with one, so moving it could stop that program working. Open the folder and decide there.' 'Holds a program') }
    $cloudNote = ''
    foreach ($c in @($env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial | Where-Object { $_ })) {
        if (Test-Under $c) { $cloudNote = 'It is in OneDrive, so moving it also removes it from your other devices.' }
    }
    return (Out-Advice $true '' $cloudNote)
}

function Invoke-QpSpaceRecycle {
    <#
        Moves one folder or file you picked to the Recycle Bin, after checking again that it's yours to
        move and that the bin can hold it. Nothing is ever deleted for good.
    #>
    param([Parameter(Mandatory)][string]$Path, [int64]$SizeBytes = -1, [bool]$NearProgram = $false)
    $name = Split-Path $Path -Leaf
    $advice = Get-QpSpaceAdvice -Path $Path -Installed (Get-QpInstallPlaces) -NearProgram $NearProgram
    if (-not $advice.CanRecycle) {
        Write-QpLog "$name stays where it is: $($advice.Why)" 'WARN'
        return [pscustomobject]@{ Ok = $false; Note = $advice.Why }
    }
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{ Ok = $false; Note = 'It is not there any more. Look again to bring the list up to date.' } }
    if ($SizeBytes -lt 0) { $SizeBytes = if (Test-Path -LiteralPath $Path -PathType Container) { Get-QpSize @($Path) } else { (Get-Item -LiteralPath $Path -Force).Length } }
    $limit = Get-QpRecycleBinLimit $Path
    if ($limit -le 0 -or $SizeBytes -gt $limit) {
        $why = if ($limit -gt 0) { "It's bigger than your Recycle Bin can hold ($(Format-QpBytes $limit)), so Windows would delete it for good. Quietpane won't. If you're sure, delete it yourself in File Explorer." }
               else { "The Recycle Bin is switched off on that drive, so Windows would delete it for good. Quietpane won't." }
        Write-QpLog "$name stays where it is: $why" 'WARN'
        return [pscustomobject]@{ Ok = $false; Note = $why }
    }
    $own = -not $script:Session
    if ($own) { Start-QpSession 'space' }
    try {
        if (Move-QpToRecycleBin -Path $Path -SizeBytes $SizeBytes) {
            Add-QpUndo @{ Type = 'Recycled'; Path = $Path; Items = 1 }
            Add-QpTotals -SpaceBytes $SizeBytes
            Write-QpLog ("Moved {0} ({1}) to the Recycle Bin. It stays there until you empty the bin, so you can still put it back." -f $name, (Format-QpBytes $SizeBytes)) 'OK'
            return [pscustomobject]@{ Ok = $true; Note = '' }
        }
        $note = 'It could not be moved - something may be using it. Close it and try again. Anything that did move is in the Recycle Bin.'
        Write-QpLog "$name : $note" 'WARN'
        return [pscustomobject]@{ Ok = $false; Note = $note }
    } finally { if ($own) { Stop-QpSession } }
}

# ---------------------------------------------------------------- the easy wins
#
# Seeing the biggest folders is only half the answer. These are the ones nearly everybody has and
# nobody thinks of: installers for programs already installed, downloads from years ago, big files
# left where they landed, and what Windows keeps after an update.
#
# Quietpane goes by the date written on the file, not by "last opened". Windows does record when a
# file was last opened, but anything that reads it updates that too - antivirus, Windows Search, a
# backup - so on most PCs every file looks as though it was opened this morning. Saying "you never
# opened this" from that would be a guess dressed up as a fact.

$script:InstallerExtensions = @('.exe', '.msi', '.msix', '.appx', '.appxbundle', '.msu', '.iso', '.img')

function Get-QpOldFiles {
    <#
        Files under the given folders, older than a date and bigger than a size. Read-only: it reads
        names, sizes and dates, never contents. Links are skipped, so nothing is counted twice, and
        online-only OneDrive files are left out because they take no room here. It gives up politely
        after MaxSeconds and says so, rather than holding the window.
    #>
    param(
        [string[]]$Roots, [datetime]$Before, [int64]$MinSize = 0,
        [string[]]$Extensions = @(), [string[]]$Exclude = @(), [int]$MaxSeconds = 20, [int]$MaxFiles = 200000
    )
    $out = New-Object System.Collections.ArrayList
    $deadline = (Get-Date).AddSeconds($MaxSeconds)
    $seen = 0
    $truncated = $false
    $wanted = @{}
    foreach ($e in @($Extensions | Where-Object { $_ })) { $wanted[$e.ToLowerInvariant()] = $true }
    $skip = @($Exclude | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') })
    function Test-Skipped([string]$Path) {
        foreach ($s in $skip) { if ($Path -eq $s -or $Path.StartsWith($s + '\', [StringComparison]::OrdinalIgnoreCase)) { return $true } }
        return $false
    }
    foreach ($root in @($Roots | Where-Object { $_ -and (Test-Path -LiteralPath $_) })) {
        $stack = New-Object System.Collections.Stack
        $stack.Push((New-Object IO.DirectoryInfo $root))
        while ($stack.Count) {
            if ((Get-Date) -gt $deadline -or $seen -ge $MaxFiles) { $truncated = $true; break }
            $dir = $stack.Pop()
            $entries = $null
            try { $entries = $dir.GetFileSystemInfos() } catch { continue }
            foreach ($e in $entries) {
                $a = [int]$e.Attributes
                if ($a -band [int][IO.FileAttributes]::ReparsePoint) { continue }
                if ($e -is [IO.DirectoryInfo]) {
                    if (-not (Test-Skipped $e.FullName)) { $stack.Push($e) }
                    continue
                }
                $seen++
                # Offline, recall-on-open, recall-on-data: online-only, so no room is used here.
                if ($a -band 0x441000) { continue }
                if ($e.LastWriteTime -ge $Before) { continue }
                if ([int64]$e.Length -lt $MinSize) { continue }
                $ext = $e.Extension.ToLowerInvariant()
                if ($wanted.Count -and -not $wanted.ContainsKey($ext)) { continue }
                [void]$out.Add([pscustomobject]@{ Path = $e.FullName; Name = $e.Name; Bytes = [int64]$e.Length; When = $e.LastWriteTime; Ext = $ext })
            }
        }
    }
    [pscustomobject]@{ Files = @($out | Sort-Object Bytes -Descending); Truncated = $truncated; Looked = $seen }
}

function Get-QpEasyWins {
    <#
        The room worth clearing first, from a scan that has already been done: installers for programs
        already installed, old downloads, big files nobody has changed in years, and what Windows keeps
        after an update. Read-only. Anything that is not yours to move - a program, a game, another
        account, OneDrive - is left out, by the same rules as the rest of this tab.
    #>
    param(
        $Space, $Cleanup = $null, [datetime]$Now = (Get-Date),
        [int]$InstallerDays = 90, [int]$DownloadDays = 365, [int]$OldYears = 2, [int64]$BigFile = 250MB,
        [string]$UserDir = ([Environment]::GetFolderPath('UserProfile')), [int]$MaxSeconds = 20
    )
    if (-not $Space) { return @() }
    $wins = New-Object System.Collections.ArrayList
    $root = ([string]$Space.Root).TrimEnd('\')
    $drive = if ($root.Length -ge 2) { $root.Substring(0, 2) } else { $env:SystemDrive }
    $isSystem = $drive -eq "$env:SystemDrive".TrimEnd('\')
    $cloud = @($env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial | Where-Object { $_ })
    $onThisDrive = { param($p) $p -and $p.Length -ge 2 -and $p.Substring(0, 2).ToUpperInvariant() -eq $drive.ToUpperInvariant() }
    $installed = @($Space.Installed)
    # Anything bigger than the Recycle Bin can hold would be deleted for good, so it is never offered
    # here; and with the bin switched off, these become things to look at rather than things to move.
    $binLimit = [int64]$Space.BinLimit
    $canMove = $binLimit -gt 0
    $binOff = 'The Recycle Bin is switched off on this drive, so Quietpane will not move anything. Have a look yourself in File Explorer.'

    function New-Win([string]$Id, [string]$Title, [string]$Short, [string]$Why, [int64]$Bytes, $Items, [bool]$CanRecycle, [string]$Advice = '', [bool]$Truncated = $false) {
        [pscustomobject]@{
            Id = $Id; Title = $Title; Short = $Short; Why = $Why; Bytes = $Bytes
            Count = @($Items).Count; Items = @($Items); CanRecycle = $CanRecycle; Advice = $Advice; Truncated = $Truncated
        }
    }
    function Add-Sizes($Items) { [int64](( @($Items) | Measure-Object -Property Bytes -Sum).Sum) }

    # ---- your own folders: installers, and downloads from another year
    $downloads = Join-Path $UserDir 'Downloads'
    # Your Desktop can live somewhere else entirely (OneDrive moves it), so Windows is asked where it is.
    $desktop = if ($UserDir -eq [Environment]::GetFolderPath('UserProfile')) { [Environment]::GetFolderPath('Desktop') } else { Join-Path $UserDir 'Desktop' }
    $looked = @($downloads, $desktop | Where-Object { $_ -and (& $onThisDrive $_) } | Select-Object -Unique)
    if ($looked.Count) {
        $found = Get-QpOldFiles -Roots $looked -Before $Now.AddDays(-$InstallerDays) -Exclude $cloud -MaxSeconds $MaxSeconds
        if ($canMove) { $found.Files = @($found.Files | Where-Object { $_.Bytes -le $binLimit }) }
        $installers = @($found.Files | Where-Object { $script:InstallerExtensions -contains $_.Ext })
        if ($installers.Count) {
            $newest = @($installers | Sort-Object When -Descending)[0].When
            [void]$wins.Add((New-Win 'installers' 'Installers you have already used' `
                ('{0} of them, the newest from {1}. Removing an installer does not remove the program.' -f $installers.Count, (Format-QpWhen $newest $Now)) `
                'An installer is only needed once. The program it installed stays exactly where it is.' `
                (Add-Sizes $installers) $installers $canMove $(if ($canMove) { '' } else { $binOff }) $found.Truncated))
        }
        $old = @($found.Files |
            Where-Object { $script:InstallerExtensions -notcontains $_.Ext -and $_.When -lt $Now.AddDays(-$DownloadDays) -and $_.Path.StartsWith($downloads + '\', [StringComparison]::OrdinalIgnoreCase) })
        if ($old.Count) {
            $newest = @($old | Sort-Object When -Descending)[0].When
            [void]$wins.Add((New-Win 'downloads' 'Downloads from another year' `
                ('{0} of them in your Downloads folder, and the newest is from {1}.' -f $old.Count, (Format-QpWhen $newest $Now)) `
                'This goes by the date on the file, not by when it was last opened: anything that reads a file - your antivirus, Windows Search - updates "last opened" too.' `
                (Add-Sizes $old) $old $canMove $(if ($canMove) { '' } else { $binOff }) $found.Truncated))
        }
    }

    # ---- big files nobody has changed in years, from the scan that has already been done
    $seenPaths = @{}
    foreach ($w in $wins) { foreach ($i in $w.Items) { $seenPaths[$i.Path.ToLowerInvariant()] = $true } }
    $cutoff = $Now.AddYears(-$OldYears)
    $big = New-Object System.Collections.ArrayList
    $stack = New-Object System.Collections.Stack
    $stack.Push($Space.Tree)
    while ($stack.Count) {
        $node = $stack.Pop()
        foreach ($c in $node.Children) {
            if (-not $c.IsFile) { $stack.Push($c); continue }
            if ([int64]$c.Size -lt $BigFile -or $c.Modified -ge $cutoff) { continue }
            if ($canMove -and [int64]$c.Size -gt $binLimit) { continue }
            $path = [string]$c.Path
            if ($seenPaths.ContainsKey($path.ToLowerInvariant())) { continue }
            $skipIt = $false
            foreach ($cl in $cloud) { if ($path.StartsWith($cl.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { $skipIt = $true } }
            if ($skipIt) { continue }
            if (-not (Test-Path -LiteralPath $path)) { continue }
            if (-not (Get-QpSpaceAdvice -Path $path -Installed $installed).CanRecycle) { continue }
            [void]$big.Add([pscustomobject]@{ Path = $path; Name = [string]$c.Name; Bytes = [int64]$c.Size; When = $c.Modified; Ext = ([IO.Path]::GetExtension($path)).ToLowerInvariant() })
        }
    }
    if ($big.Count) {
        $sorted = @($big | Sort-Object Bytes -Descending)
        $newest = @($sorted | Sort-Object When -Descending)[0].When
        [void]$wins.Add((New-Win 'bigold' 'Big files you have not changed in years' `
            ('{0} of them, each over {1}, and the newest was last changed {2}.' -f $sorted.Count, (Format-QpBytes $BigFile), (Format-QpWhen $newest $Now)) `
            'Only files that are yours to move: games, programs and other accounts are left out. This goes by the date on the file, not by when it was last opened.' `
            (Add-Sizes $sorted) $sorted $canMove $(if ($canMove) { '' } else { $binOff })))
    }

    # ---- what Windows keeps after an update, and the bin itself
    if ($isSystem) {
        $wuItem = @($Cleanup | Where-Object { $_ -and $_.Id -eq 'wu.download' })[0]
        if ($wuItem -and [int64]$wuItem.SizeBytes -gt 0) {
            [void]$wins.Add((New-Win 'wu.download' 'Windows Update leftovers' `
                'Update files Windows has already installed and kept.' `
                'Windows keeps these in case it needs them again. It fetches them afresh if it ever does.' `
                ([int64]$wuItem.SizeBytes) @() $false 'Tick "Windows Update download cache" in the list above, then Apply.'))
        }
        foreach ($c in $Space.Tree.Children) {
            if ($c.IsFile) { continue }
            if ($c.Name -eq 'Windows.old') {
                [void]$wins.Add((New-Win 'windows.old' 'Your previous version of Windows' `
                    'Kept after a Windows upgrade so you could go back.' `
                    'Windows removes this by itself about ten days after an upgrade, and once it is gone you cannot go back to the old version.' `
                    ([int64]$c.Size) @() $false 'Remove it in Settings > System > Storage > Temporary files, which does it safely. Quietpane will not touch it.'))
            }
        }
    }
    foreach ($c in $Space.Tree.Children) {
        if (-not $c.IsFile -and $c.Name -like '$Recycle.Bin' -and [int64]$c.Size -gt 0) {
            [void]$wins.Add((New-Win 'recyclebin' 'Your Recycle Bin' `
                'Already deleted, still taking up room until the bin is emptied.' `
                'Everything in here can still be put back, which is why Quietpane leaves the emptying to you.' `
                ([int64]$c.Size) @() $false 'Right-click the Recycle Bin on your desktop and choose Empty Recycle Bin.'))
        }
    }

    # The ones that are yours to move come first, biggest first; the ones that need Windows follow.
    @($wins | Sort-Object @{ Expression = { -not $_.CanRecycle } }, @{ Expression = { $_.Bytes }; Descending = $true })
}

function Invoke-QpEasyWin {
    <#
        Moves everything in one suggestion to the Recycle Bin, in a single restore point. Each file is
        checked again on its way out - still there, still yours to move, small enough for the bin - so a
        list that has gone stale cannot take anything with it. Nothing is ever deleted for good.
    #>
    param([Parameter(Mandatory)]$Win, [switch]$Preview)
    $items = @($Win.Items | Where-Object { $_ })
    if (-not $items.Count) { Write-QpLog 'Nothing to move.' 'WARN'; return [pscustomobject]@{ Moved = 0; Bytes = [int64]0; Failed = 0 } }
    if ($Preview) {
        Write-QpLog 'PREVIEW - nothing will be changed.' 'STEP'
        foreach ($i in $items) { Write-QpLog ("Would move {0} ({1})" -f $i.Path, (Format-QpBytes $i.Bytes)) 'PREVIEW' }
        Write-QpLog ('Preview finished. {0} file(s), {1}. Nothing was changed.' -f $items.Count, (Format-QpBytes (($items | Measure-Object -Property Bytes -Sum).Sum))) 'OK'
        return [pscustomobject]@{ Moved = 0; Bytes = [int64]0; Failed = 0 }
    }
    $own = -not $script:Session
    if ($own) { Start-QpSession 'space-tidy' }
    $moved = 0; $failed = 0; $bytes = [int64]0
    try {
        foreach ($i in $items) {
            $r = Invoke-QpSpaceRecycle -Path $i.Path -SizeBytes ([int64]$i.Bytes)
            if ($r.Ok) { $moved++; $bytes += [int64]$i.Bytes } else { $failed++ }
        }
        if ($moved) { Write-QpLog ('{0}: {1} file(s) moved to the Recycle Bin, {2} in all. They stay there until you empty it.' -f $Win.Title, $moved, (Format-QpBytes $bytes)) 'OK' }
        if ($failed) { Write-QpLog ('{0} file(s) stayed where they were - the lines above say why.' -f $failed) 'WARN' }
    } finally { if ($own) { Stop-QpSession } }
    [pscustomobject]@{ Moved = $moved; Bytes = $bytes; Failed = $failed }
}

#endregion

#region ---------------------------------------------------------------- NVIDIA

function Test-QpHostBlocked {
    param([string[]]$Lines, [string]$HostName)
    return [bool]($Lines | Where-Object { $_ -match "^\s*0\.0\.0\.0\s+$([regex]::Escape($HostName))(\s|$)" })
}

function Add-QpHostsBlock {
    param([string[]]$HostNames, [string]$Tag, [switch]$Preview)
    $lines = @(Get-Content -Path $script:HostsPath -ErrorAction SilentlyContinue)
    $missing = @($HostNames | Where-Object { -not (Test-QpHostBlocked -Lines $lines -HostName $_) })
    if ($missing.Count -eq 0) { Write-QpLog 'All listed servers are already blocked' 'OK'; return }
    if ($Preview) { foreach ($m in $missing) { Write-QpLog "Would block $m" 'PREVIEW' }; return }
    Copy-Item -Path $script:HostsPath -Destination (Join-Path $script:Session.Path 'hosts.bak') -Force
    Add-QpUndo @{ Type = 'Hosts'; Tag = $Tag }
    $add = @('') + @($missing | ForEach-Object { "0.0.0.0 $_  # $Tag" })
    Add-Content -Path $script:HostsPath -Value $add -Encoding ASCII
    foreach ($m in $missing) { Write-QpLog "Blocked $m" 'OK' }
}

function Remove-QpHostsBlock {
    param([string]$Tag)
    $lines = @(Get-Content -Path $script:HostsPath -ErrorAction SilentlyContinue)
    $keep = @($lines | Where-Object { $_ -notmatch [regex]::Escape("# $Tag") })
    Set-Content -Path $script:HostsPath -Value $keep -Encoding ASCII
    & ipconfig.exe /flushdns | Out-Null
    Write-QpLog "Removed hosts entries tagged '$Tag'" 'OK'
}

function Test-QpNeverTouch {
    # Drivers, audio and the bits people rely on are off limits, whatever a catalog entry says.
    param([string]$Name)
    if (-not $Name) { return $false }
    foreach ($p in (Get-QpCatalog vendors).NeverTouch) { if ($Name -like $p -or $Name -eq $p) { return $true } }
    return $false
}

function Test-QpVendorPresent {
    # Is this brand's software actually on this PC?
    param($Vendor)
    $d = $Vendor.Detect
    if (-not $d) { return $false }
    if ($d.Manufacturer) {
        if (-not $script:ComputerMaker) { $script:ComputerMaker = [string](Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).Manufacturer }
        if ($script:ComputerMaker -match $d.Manufacturer) { return $true }
    }
    if ($d.Gpu) {
        if ($null -eq $script:GpuNames) { $script:GpuNames = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) -join ' | ' }
        if ($script:GpuNames -match $d.Gpu) { return $true }
    }
    foreach ($p in @($d.Paths)) { if ($p -and (Test-Path ([Environment]::ExpandEnvironmentVariables($p)))) { return $true } }
    foreach ($s in @($d.Services)) { if ($s -and (Get-Service -Name $s -ErrorAction SilentlyContinue)) { return $true } }
    return $false
}

function Get-QpInstalledPrograms {
    # Ordinary installed programs (not Store apps), from the places Windows lists them.
    if ($script:InstalledPrograms) { return $script:InstalledPrograms }
    # Read straight from the registry: a few hundred keys through Get-ItemProperty is the slow part otherwise.
    # (commas, not new lines: arrays on separate lines would run together into one list)
    $sources = @(
        @([Microsoft.Win32.Registry]::LocalMachine, 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'),
        @([Microsoft.Win32.Registry]::LocalMachine, 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'),
        @([Microsoft.Win32.Registry]::CurrentUser, 'SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall')
    )
    $script:InstalledPrograms = @(
        foreach ($s in $sources) {
            $root = $null
            try {
                $root = $s[0].OpenSubKey($s[1], $false)
                if (-not $root) { continue }
                foreach ($name in $root.GetSubKeyNames()) {
                    $k = $null
                    try {
                        $k = $root.OpenSubKey($name, $false)
                        if (-not $k) { continue }
                        $display = [string]$k.GetValue('DisplayName')
                        $system = $k.GetValue('SystemComponent')   # parts of Windows or of another program: not listed
                        if (-not $display -or ($system -and "$system" -ne '0')) { continue }
                        $quiet = [string]$k.GetValue('QuietUninstallString')
                        [pscustomobject]@{
                            Name      = $display
                            Publisher = [string]$k.GetValue('Publisher')
                            Uninstall = $(if ($quiet) { $quiet } else { [string]$k.GetValue('UninstallString') })
                            Quiet     = [bool]$quiet
                            Key       = $name
                        }
                    } catch { } finally { if ($k) { $k.Close() } }
                }
            } catch { } finally { if ($root) { $root.Close() } }
        }
    )
    return $script:InstalledPrograms
}

function Get-QpVendorStatus {
    <#
        What brand and hardware software is on this PC, and which of its background bits are still on.
        Read-only. Vendors and items that are not on this PC are left out entirely.
    #>
    $hostLines = @(Get-Content -Path $script:HostsPath -ErrorAction SilentlyContinue)
    $programs = Get-QpInstalledPrograms
    $result = foreach ($v in (Get-QpCatalog vendors).Vendors) {
        if (-not (Test-QpVendorPresent $v)) { continue }
        $items = foreach ($item in @($v.Items)) {
            $blocked = @($item.Actions | Where-Object { $_.Name -and (Test-QpNeverTouch $_.Name) })
            if ($blocked.Count) { continue }
            $states = @($item.Actions | ForEach-Object { Test-QpActionApplied $_ })
            $relevant = @($states | Where-Object { $null -ne $_ })
            if ($relevant.Count -eq 0) { continue }   # nothing of this item exists here - don't mention it
            $done = @($relevant | Where-Object { $_ }).Count
            $status = if ($done -eq $relevant.Count) { 'Applied' } elseif ($done -gt 0) { 'Partial' } else { 'NotApplied' }
            [pscustomobject]@{
                Id = $item.Id; VendorId = $v.Id; Title = $item.Title; Description = $item.Description
                Recommended = [bool]$item.Recommended; Status = $status
            }
        }
        $junk = foreach ($j in @($v.Junk)) {
            foreach ($p in @($programs | Where-Object { $_.Name -match $j.Match -and $_.Uninstall })) {
                if (Test-QpNeverTouch $p.Name) { continue }
                [pscustomobject]@{ VendorId = $v.Id; Title = $j.Title; Why = $j.Why; Name = $p.Name; Key = $p.Key; Uninstall = $p.Uninstall; Quiet = $p.Quiet }
            }
        }
        $items = @($items); $junk = @($junk)
        if ($items.Count -eq 0 -and $junk.Count -eq 0) { continue }
        [pscustomobject]@{
            Id = $v.Id; Name = $v.Name; Kind = $v.Kind; Note = $v.Note
            Items = $items; Junk = $junk
            Open = @($items | Where-Object { $_.Status -ne 'Applied' }).Count
        }
    }
    return @($result)
}

function Invoke-QpVendor {
    param([string[]]$Ids, [switch]$Preview)
    if (-not $Ids) { Write-QpLog 'Pick at least one thing first.' 'WARN'; return }
    $items = @(foreach ($v in (Get-QpCatalog vendors).Vendors) { foreach ($i in @($v.Items)) { if ($Ids -contains $i.Id) { $i } } })
    if ($items.Count -eq 0) { Write-QpLog 'Pick at least one thing first.' 'WARN'; return }
    $own = (-not $Preview) -and (-not $script:Session)
    if ($Preview) { Write-QpLog 'PREVIEW - nothing will be changed.' 'STEP' } elseif ($own) { Start-QpSession 'brands' }
    $touchedHosts = $false
    foreach ($item in $items) {
        Write-QpLog $item.Title 'STEP'
        foreach ($a in $item.Actions) {
            if ($a.Name -and (Test-QpNeverTouch $a.Name)) { Write-QpLog "$($a.Name) is on the protected list - left alone" 'SKIP'; continue }
            if ($a.Type -eq 'Hosts') { $touchedHosts = $true }
            Invoke-QpAction -Action $a -Preview:$Preview
        }
    }
    if ($Preview) {
        Write-QpLog 'Preview finished. Nothing was changed.' 'OK'
    } else {
        if ($touchedHosts) { & ipconfig.exe /flushdns | Out-Null }
        Write-QpLog 'The apps themselves still open and work. Run this again after a big brand-software update.' 'INFO'
        if ($own) { Stop-QpSession }
    }
}

function Split-QpUninstallCommand {
    <#
        A program's uninstall command, split into the program and what it is given. For Windows
        Installer packages, "install" (/I{product}) becomes "remove" (/X{product}), and it runs with a
        progress bar and no surprise restart. Nothing else in the command is touched.
    #>
    param([string]$Command)
    $cmd = $Command.Trim()
    if ($cmd -match '^"([^"]+)"\s*(.*)$') { $exe = $matches[1]; $argText = $matches[2] }
    elseif ($cmd -match '^(\S+\.exe)\s*(.*)$') { $exe = $matches[1]; $argText = $matches[2] }
    else { $exe = $cmd; $argText = '' }
    if ($exe -match '(?i)(^|\\)msiexec(\.exe)?$') {
        $argText = $argText -replace '(?i)/I(\s*\{)', '/X$1'
        if ($argText -notmatch '(?i)/qn|/quiet|/passive') { $argText = ($argText + ' /passive /norestart').Trim() }
    }
    [pscustomobject]@{ Program = $exe; Arguments = $argText.Trim() }
}

function Invoke-QpVendorUninstall {
    <#
        Runs the program's own uninstaller. The window always asks first, one program at a time.
        This CANNOT be undone - the program has to be downloaded again from its maker.
    #>
    param([string[]]$Keys)
    $all = Get-QpVendorStatus
    $targets = @(foreach ($v in $all) { foreach ($j in $v.Junk) { if ($Keys -contains $j.Key) { $j } } })
    if ($targets.Count -eq 0) { Write-QpLog 'Nothing to remove.' 'WARN'; return }
    foreach ($t in $targets) {
        Write-QpLog "Removing $($t.Name) using its own uninstaller (this cannot be undone)" 'STEP'
        try {
            $run = Split-QpUninstallCommand $t.Uninstall
            $p = if ($run.Arguments) { Start-Process -FilePath $run.Program -ArgumentList $run.Arguments -PassThru -Wait -ErrorAction Stop } else { Start-Process -FilePath $run.Program -PassThru -Wait -ErrorAction Stop }
            Write-QpLog "$($t.Name): uninstaller finished (exit code $($p.ExitCode))" 'OK'
        } catch {
            Write-QpLog "$($t.Name) could not be removed automatically: $($_.Exception.Message). You can remove it from Settings > Apps." 'WARN'
        }
    }
    $script:InstalledPrograms = $null
    Write-QpLog 'Removed programs can be installed again from the maker''s website.' 'INFO'
}

#endregion

#region ---------------------------------------------------------------- one-click

function Get-QpState {
    <#
        Everything the window shows about this PC, read in one pass that shares its slow lookups.
        Read-only. Battery and drive health aren't here: the Health tab reads those itself, when open.
    #>
    Start-QpStateCache
    $problems = New-Object System.Collections.ArrayList
    # Each part stands on its own: if one cannot be read on this PC, the rest of the window still works
    # and the part that failed says so, rather than leaving the whole window empty.
    function Read-Part([string]$What, [scriptblock]$Body, $Fallback) {
        try { return (& $Body) }
        catch {
            [void]$problems.Add($What)
            Write-QpLog "Could not read $What : $($_.Exception.Message)" 'WARN'
            return $Fallback
        }
    }
    try {
        # Read once, then cost it: what signing in costs is about these very items.
        $startup = Read-Part 'what starts at sign-in' { @(Get-QpStartupItems) } @()
        @{
            Privacy  = Read-Part 'the privacy settings' { Get-QpPrivacyStatus } @{}
            Vendors  = Read-Part 'the brand extras' { @(Get-QpVendorStatus) } @()
            Apps     = Read-Part 'the installed apps' { @(Get-QpBloatApps) } @()
            Startup  = $startup
            SignIn   = Read-Part 'what signing in costs' {
                $times = Get-QpSignInTime
                $record = Get-QpBootRecord
                [pscustomobject]@{ Times = $times; Record = $record; Costs = @(Get-QpSignInCost -Items $startup -Record $record -Times $times) }
            } $null
            Devices  = Read-Part 'camera, microphone and location use' { @(Get-QpDeviceUse) } @()
            Addons   = Read-Part 'your browser add-ons' { @(Get-QpBrowserExtensions) } @()
            Cleanup  = Read-Part 'what can be cleaned up' { @(Get-QpCleanupTargets) } @()
            Restore  = Read-Part 'the restore points' { @(Get-QpRestorePoints) } @()
            Problems = @($problems)
        }
    } finally { Stop-QpStateCache }
}

function Get-QpRecommendedPlan {
    <# What "Quiet my PC now" would do on this PC: only recommended items that are not done yet. Read-only. #>
    $ownCache = -not $script:StateCache
    if ($ownCache) { Start-QpStateCache }
    try { return (Get-QpRecommendedPlanCore) } finally { if ($ownCache) { Stop-QpStateCache } }
}

function Get-QpRecommendedPlanCore {
    $status = Get-QpPrivacyStatus
    $privacy = @((Get-QpCatalog privacy).Items | Where-Object { $_.Recommended -and $status[$_.Id] -in 'NotApplied', 'Partial' })
    # Brand and hardware items: only the recommended switch-offs. Uninstalling anything is never automatic.
    $vendors = Get-QpVendorStatus
    $vendorItems = @(foreach ($v in $vendors) { $v.Items | Where-Object { $_.Recommended -and $_.Status -ne 'Applied' } })
    $apps = @(Get-QpBloatApps | Where-Object { $_.Recommended })
    $clean = @(Get-QpCleanupTargets | Where-Object { $_.Recommended -and $_.SizeBytes -gt 0 })
    [pscustomobject]@{
        PrivacyIds    = @($privacy | ForEach-Object { $_.Id })
        PrivacyTitles = @($privacy | ForEach-Object { $_.Title })
        VendorIds     = @($vendorItems | ForEach-Object { $_.Id })
        VendorTitles  = @($vendorItems | ForEach-Object { $_.Title })
        VendorNames   = @($vendors | Where-Object { @($_.Items | Where-Object { $_.Recommended -and $_.Status -ne 'Applied' }).Count } | ForEach-Object { $_.Name })
        AppNames      = @($apps | ForEach-Object { $_.Name })
        AppTitles     = @($apps | ForEach-Object { $_.Title })
        CleanupIds    = @($clean | ForEach-Object { $_.Id })
        CleanupBytes  = [int64](($clean | Measure-Object -Property SizeBytes -Sum).Sum)
        IsEmpty       = (-not $privacy -and -not $vendorItems -and -not $apps -and -not $clean)
    }
}

function Invoke-QpRecommended {
    <#
        "Quiet my PC now": applies every recommended item that is not done yet, all inside ONE restore point,
        so "Undo everything" restores every setting in one go (cleared files stay in the Recycle Bin; removed
        Store apps must be reinstalled from the Store). Returns a plain summary for the Home screen.
    #>
    $plan = Get-QpRecommendedPlan
    if ($plan.IsEmpty) {
        Write-QpLog 'Nothing to do - this PC already has every recommended setting.' 'OK'
        return [pscustomobject]@{ Nothing = $true }
    }
    Start-QpSession 'one-click'
    $restore = $script:Session.Path
    $before = Get-QpSystemUsage
    if ($plan.PrivacyIds.Count) { Invoke-QpPrivacy -Ids $plan.PrivacyIds }
    if ($plan.VendorIds.Count)  { Invoke-QpVendor -Ids $plan.VendorIds }
    if ($plan.AppNames.Count)   { Invoke-QpRemoveApps -Names $plan.AppNames -Deprovision }
    $freed = 0
    if ($plan.CleanupIds.Count) {
        $r = @(Invoke-QpCleanup -Ids $plan.CleanupIds) | Where-Object { $_ -and $_.PSObject.Properties['BytesFreed'] } | Select-Object -Last 1
        if ($r) { $freed = $r.BytesFreed }
    }
    $entries = @($script:Session.Entries)
    # Services and startup items that were switched off release memory straight away; a restart frees more.
    Start-Sleep -Seconds 2
    $after = Get-QpSystemUsage
    $memFreed = [int64][Math]::Max(0, $before.MemUsed - $after.MemUsed)
    if ($memFreed -gt 0) { Write-QpLog ("Memory in use dropped by about {0}. A restart usually frees more." -f (Format-QpBytes $memFreed)) 'OK' }
    Add-QpTotals -MemoryBytes $memFreed -CountRun
    $summary = [pscustomobject]@{
        Nothing       = $false
        Settings      = $plan.PrivacyIds.Count
        AppsRemoved   = @($entries | Where-Object { $_.Type -eq 'Appx' }).Count
        BrandsQuieted = @($plan.VendorNames)
        BytesFreed    = [int64]$freed
        MemoryFreed   = $memFreed
        RestorePoint  = $(if ($entries.Count) { $restore } else { $null })   # nothing changed means nothing to undo
    }
    Stop-QpSession
    return $summary
}

#endregion

#region ---------------------------------------------------------------- threats (Defender first, heuristics labelled)

# Quietpane does not identify malware families itself. Microsoft Defender names a threat; this code
# translates that name into plain words and an impact tier, and always keeps Defender's own name and
# classification visible. Quietpane's own checks are reported as heuristics and never claim a family.

$script:SeverityRank = @{ Critical = 0; High = 1; Medium = 2; Low = 3; Info = 4 }
$script:DefenderStatusMap = @{ '0' = 'Detected'; '1' = 'Detected'; '2' = 'Removed'; '3' = 'Quarantined'; '4' = 'Removed'; '5' = 'Allowed'; '6' = 'Removed' }

function Get-QpDefenderState {
    <# Can we ask Defender anything, and should we trust the answer? Never throws. #>
    $s = [pscustomobject]@{
        Available = $false; RealTime = $false; SignatureAge = $null
        CanScan = $false; CanRemediate = $false; ThirdParty = @(); Note = ''
    }
    $mp = Get-MpComputerStatus -ErrorAction SilentlyContinue
    if ($mp) {
        $s.Available = $true
        $s.RealTime = [bool]$mp.RealTimeProtectionEnabled
        $s.SignatureAge = [int]$mp.AntivirusSignatureAge
        $s.CanScan = [bool](Get-Command Start-MpScan -ErrorAction SilentlyContinue)
        $s.CanRemediate = [bool](Get-Command Remove-MpThreat -ErrorAction SilentlyContinue)
    }
    try {
        $av = @(Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop | ForEach-Object { [string]$_.displayName })
        $s.ThirdParty = @($av | Where-Object { $_ -and $_ -notmatch '(?i)(windows|microsoft) defender' })
    } catch { }
    if (-not $s.Available) {
        $s.Note = 'Microsoft Defender could not be reached, so only Quietpane''s own checks ran. Nothing here can confirm a virus by name.'
    } elseif ($s.ThirdParty.Count) {
        $s.Note = 'Another antivirus is installed (' + ($s.ThirdParty -join ', ') + '), so Defender may be standing down and its list of threats can look empty. Check that program as well.'
    } elseif (-not $s.RealTime) {
        $s.Note = 'Defender real-time protection is off, so new threats are not being caught as they arrive.'
    }
    return $s
}

function Resolve-QpThreatInfo {
    <# Defender's threat name -> Quietpane tier and plain-language note. Nothing is ever dropped. #>
    param([string]$ThreatName, [int]$VendorSeverity = 0)
    $cat = Get-QpCatalog threats
    foreach ($f in $cat.Families) {
        if ($ThreatName -match $f.Match) {
            return [pscustomobject]@{ Family = $f.Family; Tier = $f.Tier; Category = $f.Category; What = $f.What; Why = $f.Why; MatchedBy = 'family' }
        }
    }
    foreach ($c in $cat.CategoryFallback) {
        if ($ThreatName -match $c.Match) {
            return [pscustomobject]@{ Family = ''; Tier = $c.Tier; Category = $c.Category; What = $c.What; Why = $c.Why; MatchedBy = 'category' }
        }
    }
    $tier = if ($cat.SeverityFallback["$VendorSeverity"]) { $cat.SeverityFallback["$VendorSeverity"] } else { 'Medium' }
    [pscustomobject]@{
        Family = ''; Tier = $tier; Category = 'Malware'
        What = 'Defender reported this, and Quietpane has no plain-language note for this name yet.'
        Why = 'Follow what Defender recommends. The exact name is in the technical details.'
        MatchedBy = 'severity'
    }
}

function Get-QpFileHash {
    param([string]$Path, [int64]$MaxBytes = 104857600)
    try {
        if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
        if ((Get-Item -LiteralPath $Path -Force -ErrorAction Stop).Length -gt $MaxBytes) { return '' }
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
    } catch { return '' }   # locked or unreadable: a missing hash is fine, a failed scan is not
}

function New-QpFinding {
    <# The one shape every finding has, whoever found it. #>
    param(
        [string]$Section = 'Threats',
        [ValidateSet('Critical', 'High', 'Medium', 'Low', 'Info')][string]$Severity = 'Info',
        [string]$ThreatName = '', [string]$Family = '', [string]$Category = '',
        [string]$Source = 'Quietpane check', [string]$Method = '',
        [string]$Object = '', [string]$Path = '', [string]$Sha256 = '',
        [ValidateSet('Confirmed', 'Likely', 'Heuristic', 'Informational')][string]$Confidence = 'Informational',
        [string]$VendorName = '', [string]$VendorSeverity = '',
        $FirstSeen = $null, [string]$Recommended = '', [string]$Status = 'Detected',
        [string]$What = '', [string]$Why = '', [string]$Technical = '',
        [string]$Title = '', [string]$Detail = '',
        [string]$ThreatId = '', [bool]$VendorActive = $false
    )
    $seed = '{0}|{1}|{2}|{3}' -f $Source, $ThreatName, $Path, $Object
    $bytes = [Security.Cryptography.SHA1]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($seed))
    $id = (($bytes | Select-Object -First 8) | ForEach-Object { $_.ToString('x2') }) -join ''
    if (-not $Title) { $Title = if ($ThreatName) { $ThreatName } else { $Object } }
    if (-not $Detail) { $Detail = $Technical }
    [pscustomobject]@{
        Id = $id; Section = $Section; Severity = $Severity
        ThreatName = $ThreatName; Family = $Family; Category = $Category
        Source = $Source; Method = $Method
        Object = $Object; Path = $Path; Sha256 = $Sha256
        Confidence = $Confidence; VendorName = $VendorName; VendorSeverity = $VendorSeverity
        FirstSeen = $(if ($FirstSeen) { $FirstSeen } else { Get-Date })
        Recommended = $Recommended; Status = $Status
        What = $What; Why = $Why; Technical = $Technical
        Title = $Title; Detail = $Detail
        ThreatId = $ThreatId; VendorActive = $VendorActive
    }
}

function Split-QpFindingDetail {
    <#
        A check's detail, split for the window: plain sentences are the "why", and paths, commands,
        registry values, dates and lists are the technical part. Each line goes to exactly one side.
    #>
    param([string]$Detail)
    $lines = @("$Detail" -split "`r?`n" | Where-Object { $_.Trim() })
    $plain = @($lines | Where-Object { $_ -match '\s\S+\s' -and $_ -match '[.!?)]\s*$' -and $_ -notmatch '[A-Za-z]:\\|\\\\|^\s*\S+\s*=|HK(LM|CU)|^\s*\d{4}-\d\d-\d\d|^\s*-\s' })
    $tech = @($lines | Where-Object { $plain -notcontains $_ })
    [pscustomobject]@{ Why = ($plain -join ' '); Technical = ($tech -join "`n") }
}

function Get-QpDefenderFindings {
    <# Everything Defender has detected on this PC, in Quietpane's shape. Read-only. #>
    $state = Get-QpDefenderState
    if (-not $state.Available) { return @() }
    $threats = @{}
    foreach ($t in @(Get-MpThreat -ErrorAction SilentlyContinue)) { $threats["$($t.ThreatID)"] = $t }
    $seen = @{}
    $out = foreach ($d in @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Sort-Object InitialDetectionTime -Descending)) {
        $t = $threats["$($d.ThreatID)"]
        $name = if ($t -and $t.ThreatName) { [string]$t.ThreatName } else { "Unnamed detection $($d.ThreatID)" }
        $vendorSev = if ($t) { [int]$t.SeverityID } else { 0 }
        $info = Resolve-QpThreatInfo -ThreatName $name -VendorSeverity $vendorSev
        $path = ''; $kind = 'file'
        foreach ($r in @($d.Resources | Where-Object { $_ })) {
            if ($r -match '^(?<k>[a-z]+):_?(?<v>.+)$') { if (-not $path) { $kind = $matches['k']; $path = $matches['v'] } }
            elseif (-not $path) { $path = [string]$r }
        }
        $key = "$name|$path"
        if ($seen.ContainsKey($key)) { continue }   # keep only the newest detection of the same thing
        $seen[$key] = $true
        $status = $script:DefenderStatusMap["$([int]$d.ThreatStatusID)"]
        if (-not $status) { $status = 'Detected' }
        $confidence = if ($name -match '^Behavior:') { 'Likely' } else { 'Confirmed' }
        $recommended = if ($status -eq 'Detected') { 'Let Defender remove it, or quarantine it with Quietpane.' } else { "Already handled by Defender ($status). Nothing more to do." }
        $tech = @(
            "Defender threat name: $name"
            "Defender severity: $vendorSev (5 = severe, 4 = high, 2 = moderate, 1 = low)"
            "Defender status: $($d.ThreatStatusID) ($status)"
            "Resource: $kind $path"
            "Detected: $($d.InitialDetectionTime)"
            "Ran before it was caught: $(if ($t) { $t.DidThreatExecute } else { 'unknown' })"
            "Matched Quietpane note by: $($info.MatchedBy)"
        ) -join "`n"
        New-QpFinding -Section 'Threats' -Severity $info.Tier -ThreatName $name -Family $info.Family -Category $info.Category `
            -Source 'Microsoft Defender' -Method 'Antivirus signature' -Object (Split-Path $path -Leaf) -Path $path `
            -Sha256 (Get-QpFileHash $path) -Confidence $confidence -VendorName $name -VendorSeverity "$vendorSev" `
            -FirstSeen $d.InitialDetectionTime -Recommended $recommended -Status $status `
            -What $info.What -Why $info.Why -Technical $tech `
            -Title $(if ($info.Family) { $info.Family } else { $name }) `
            -ThreatId "$($d.ThreatID)" -VendorActive $(if ($t) { [bool]$t.IsActive } else { $false })
    }
    return @($out)
}

function Invoke-QpThreatScan {
    <#
        Asks Microsoft Defender to scan, then reads what it found. Quietpane never opens or runs a
        detected file. Quick scan covers the places malware normally lives; a custom scan takes a folder.
    #>
    param([ValidateSet('Quick', 'Full', 'Custom')][string]$Type = 'Quick', [string]$Path)
    $state = Get-QpDefenderState
    if (-not $state.Available -or -not $state.CanScan) {
        Write-QpLog 'Microsoft Defender is not available here, so no antivirus scan was run. Quietpane''s own checks still work.' 'WARN'
        return [pscustomobject]@{ Ran = $false; Findings = @(); State = $state }
    }
    if ($state.ThirdParty.Count) { Write-QpLog $state.Note 'INFO' }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $scanArgs = @{ ErrorAction = 'Stop' }
    if ($Type -eq 'Custom') {
        if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { Write-QpLog 'That folder could not be found - nothing scanned.' 'WARN'; return [pscustomobject]@{ Ran = $false; Findings = @(); State = $state } }
        Write-QpLog "Asking Defender to scan $Path ..." 'STEP'
        $scanArgs['ScanType'] = 'CustomScan'; $scanArgs['ScanPath'] = $Path
    } else {
        Write-QpLog "Asking Defender to run a $($Type.ToLower()) scan. This is Defender's own engine, not ours." 'STEP'
        $scanArgs['ScanType'] = "$($Type)Scan"
    }
    # Run it as a job where we can, so the window stays responsive and Stop works while Defender is busy.
    $canJob = [bool]((Get-Command Start-MpScan -ErrorAction SilentlyContinue).Parameters.ContainsKey('AsJob'))
    try {
        if ($canJob) {
            $job = Start-MpScan @scanArgs -AsJob
            while ($job.State -eq 'Running') {
                if (Test-QpCancelled) {
                    Stop-Job $job -ErrorAction SilentlyContinue
                    Remove-Job $job -Force -ErrorAction SilentlyContinue
                    # Defender may carry on in the background for a bit. That is Defender's own scan,
                    # it is safe to leave, and Quietpane has changed nothing.
                    Write-QpLog 'Stopped waiting for Defender at your request. Nothing was changed.' 'WARN'
                    return [pscustomobject]@{ Ran = $false; Cancelled = $true; Findings = @(); State = $state }
                }
                Write-QpProgress -Stage 'Microsoft Defender is scanning' -Step 1 -Of 2 -Object ('{0:N0} seconds so far' -f $sw.Elapsed.TotalSeconds)
                Start-Sleep -Milliseconds 700
            }
            Receive-Job $job -ErrorAction SilentlyContinue | Out-Null
            Remove-Job $job -Force -ErrorAction SilentlyContinue
        } else {
            Start-MpScan @scanArgs
        }
        Write-QpLog ("Defender finished in {0:N0} seconds." -f $sw.Elapsed.TotalSeconds) 'OK'
    } catch {
        Write-QpLog "Defender could not complete the scan: $($_.Exception.Message)" 'WARN'
        return [pscustomobject]@{ Ran = $false; Findings = @(Get-QpDefenderFindings); State = $state }
    }
    [pscustomobject]@{ Ran = $true; Findings = @(Get-QpDefenderFindings); State = $state; Seconds = [int]$sw.Elapsed.TotalSeconds }
}

function Write-QpAudit {
    <# Append-only record of everything Quietpane did to a threat, including failures. #>
    param([string]$FindingId, [string]$Action, [string]$Result, [string]$Object = '', [string]$Note = '')
    try {
        if (-not (Test-Path $script:DataRoot)) { New-Item -ItemType Directory -Path $script:DataRoot -Force | Out-Null }
        $line = [pscustomobject]@{
            Time = (Get-Date).ToString('s'); FindingId = $FindingId; Action = $Action; Result = $Result
            Object = $Object; Note = $Note; User = "$env:USERDOMAIN\$env:USERNAME"
        } | ConvertTo-Json -Compress
        Add-Content -Path (Join-Path $script:DataRoot 'audit.log') -Value $line -Encoding UTF8
    } catch { Write-QpLog "Could not write the audit log: $($_.Exception.Message)" 'WARN' }
}

function Get-QpAllowList {
    $file = Join-Path $script:DataRoot 'allowed.json'
    if (-not (Test-Path $file)) { return @() }
    try { return @(Get-Content $file -Raw | ConvertFrom-Json) } catch { return @() }
}

function Add-QpAllow {
    <#
        The user chose to leave something in place. This is Quietpane's own note only: it never creates a
        Defender exclusion and never weakens any future scan. The item keeps showing up, marked Allowed.
    #>
    param([string]$FindingId, [string]$ThreatName, [string]$Path)
    $all = @(Get-QpAllowList | Where-Object { $_.FindingId -ne $FindingId })
    $all += [pscustomobject]@{ FindingId = $FindingId; ThreatName = $ThreatName; Path = $Path; Allowed = (Get-Date).ToString('s') }
    try {
        if (-not (Test-Path $script:DataRoot)) { New-Item -ItemType Directory -Path $script:DataRoot -Force | Out-Null }
        $all | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $script:DataRoot 'allowed.json') -Encoding UTF8
        Write-QpLog "Left in place on purpose: $ThreatName. It is still on this PC, and Quietpane will keep showing it." 'WARN'
        Write-QpAudit -FindingId $FindingId -Action 'Allow' -Result 'Recorded' -Object $Path -Note 'Quietpane note only - no Defender exclusion was created'
    } catch { Write-QpLog "Could not record that choice: $($_.Exception.Message)" 'WARN' }
}

function Get-QpFailureReason {
    <# Say what actually went wrong, rather than guessing. #>
    param($Ex)
    $name = if ($Ex) { $Ex.GetType().Name } else { '' }
    switch -Regex ($name) {
        'UnauthorizedAccessException' { return 'Windows would not allow it. Quietpane needs administrator rights, or the file is protected.' }
        'FileNotFoundException|DirectoryNotFoundException' { return 'It is not there any more. Run the check again.' }
        'IOException' { return 'The file is in use, so it could not be moved. Close whatever is using it, or restart and try again.' }
        default { return $(if ($Ex) { $Ex.Message } else { 'It did not work.' }) }
    }
}

function Get-QpQuarantineRoot {
    <# The quarantine folder, locked down the first time it is needed. #>
    $root = Join-Path $script:DataRoot 'quarantine'
    if (-not (Test-Path $root)) {
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        try {
            # Only SYSTEM and administrators may look inside. Inheritance off, so a wide-open
            # ProgramData permission cannot leak in.
            & icacls.exe $root /inheritance:r /grant:r 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F' | Out-Null
        } catch { Write-QpLog "Could not lock down the quarantine folder: $($_.Exception.Message)" 'WARN' }
    }
    return $root
}

function Test-QpProtectedPath {
    <# Places Quietpane will never move, recycle or delete, whatever a finding says. #>
    param([string]$Path)
    if (-not $Path) { return $true }
    $p = ''
    try { $p = [IO.Path]::GetFullPath($Path) } catch { return $true }
    if ($p.Length -lt 8) { return $true }                                  # a drive root or similar
    if (Test-Path -LiteralPath $p -PathType Container) { return $true }    # only ever single files
    $protected = @(
        [Environment]::GetFolderPath('Windows')
        (Join-Path $env:WINDIR 'System32'), (Join-Path $env:WINDIR 'SysWOW64'), (Join-Path $env:WINDIR 'WinSxS')
        (Join-Path $env:SystemDrive '\Program Files\WindowsApps')
        $env:ProgramFiles, ${env:ProgramFiles(x86)}
        $script:DataRoot
    ) | Where-Object { $_ }
    foreach ($root in $protected) {
        if ($p -eq $root -or $p.StartsWith(($root.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-QpFindingStillTrue {
    <# Before anything destructive: is this still the same file we were told about? #>
    param($Finding)
    if (-not $Finding.Path) { return [pscustomobject]@{ Ok = $false; Why = 'This finding has no file attached, so there is nothing to act on.' } }
    if (-not (Test-Path -LiteralPath $Finding.Path -PathType Leaf)) { return [pscustomobject]@{ Ok = $false; Why = 'That file is not there any more. Run the check again.' } }
    if (Test-QpProtectedPath $Finding.Path) { return [pscustomobject]@{ Ok = $false; Why = 'That file lives in a protected Windows folder. Quietpane will not touch it - use Windows Security instead.' } }
    if ($Finding.Sha256) {
        $now = Get-QpFileHash $Finding.Path
        if ($now -and $now -ne $Finding.Sha256) { return [pscustomobject]@{ Ok = $false; Why = 'That file has changed since the check ran, so it may not be the same thing. Run the check again.' } }
    }
    return [pscustomobject]@{ Ok = $true; Why = '' }
}

function Invoke-QpQuarantine {
    <#
        Moves the file into Quietpane's quarantine: renamed so it cannot run, with everything needed
        to put it back. The original folder, name, times and hash are recorded.
    #>
    param([Parameter(Mandatory)]$Finding)
    $check = Test-QpFindingStillTrue $Finding
    if (-not $check.Ok) { return [pscustomobject]@{ Ok = $false; Status = 'Failed'; Note = $check.Why } }
    $root = Get-QpQuarantineRoot
    # The quarantine folder is deliberately locked to administrators. Check we can write before moving anything.
    try {
        $probe = Join-Path $root ('.write-test-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $probe -Force -ErrorAction Stop | Out-Null
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    } catch {
        return [pscustomobject]@{ Ok = $false; Status = 'Failed'; Note = 'The quarantine folder is locked to administrators, and Quietpane is not running as one. Start it with "Start Quietpane", which asks Windows for permission.' }
    }
    $id = '{0}-{1}' -f (Get-QpStamp), $Finding.Id
    $dir = Join-Path $root $id
    try {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $src = Get-Item -LiteralPath $Finding.Path -Force
        $hash = if ($Finding.Sha256) { $Finding.Sha256 } else { Get-QpFileHash $Finding.Path }
        $meta = [pscustomobject]@{
            Id = $id; OriginalPath = $src.FullName; FileName = $src.Name; Size = $src.Length
            Sha256 = $hash; ThreatName = $Finding.ThreatName; Family = $Finding.Family
            Severity = $Finding.Severity; Source = $Finding.Source; Confidence = $Finding.Confidence
            QuarantinedAt = (Get-Date).ToString('s'); Status = 'Quarantined'
            CreationTime = $src.CreationTime.ToString('o'); LastWriteTime = $src.LastWriteTime.ToString('o')
            Attributes = "$($src.Attributes)"
        }
        $meta | ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $dir 'meta.json') -Encoding UTF8
        Move-Item -LiteralPath $src.FullName -Destination (Join-Path $dir 'payload.bin') -Force -ErrorAction Stop
        Set-ItemProperty -LiteralPath (Join-Path $dir 'payload.bin') -Name Attributes -Value 'Normal' -ErrorAction SilentlyContinue
        Write-QpLog "Quarantined $($src.Name). It cannot run from there, and you can put it back any time." 'OK'
        Write-QpAudit -FindingId $Finding.Id -Action 'Quarantine' -Result 'Quarantined' -Object $src.FullName -Note $id
        [pscustomobject]@{ Ok = $true; Status = 'Quarantined'; Note = "Moved into Quietpane's quarantine. You can restore it from the Safety scan tab."; QuarantineId = $id }
    } catch {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        $why = Get-QpFailureReason $_.Exception
        Write-QpLog "Could not quarantine $($Finding.Path): $why" 'ERROR'
        Write-QpAudit -FindingId $Finding.Id -Action 'Quarantine' -Result 'Failed' -Object $Finding.Path -Note $_.Exception.Message
        [pscustomobject]@{ Ok = $false; Status = 'Failed'; Note = $why }
    }
}

function Get-QpQuarantineItems {
    $root = Join-Path $script:DataRoot 'quarantine'
    if (-not (Test-Path $root)) { return @() }
    @(Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | ForEach-Object {
        $metaFile = Join-Path $_.FullName 'meta.json'
        if (-not (Test-Path $metaFile)) { return }
        try {
            $m = Get-Content $metaFile -Raw | ConvertFrom-Json
            $payload = Join-Path $_.FullName 'payload.bin'
            [pscustomobject]@{
                Id = $m.Id; FileName = $m.FileName; OriginalPath = $m.OriginalPath; Size = [int64]$m.Size
                Sha256 = $m.Sha256; ThreatName = $m.ThreatName; Severity = $m.Severity; Source = $m.Source
                QuarantinedAt = $m.QuarantinedAt; Folder = $_.FullName; HasPayload = (Test-Path $payload)
            }
        } catch { }
    })
}

function Restore-QpQuarantineItem {
    <# Puts a quarantined file back exactly where it was, but only if it is still byte-for-byte the same. #>
    param([Parameter(Mandatory)][string]$Id)
    $item = @(Get-QpQuarantineItems | Where-Object { $_.Id -eq $Id }) | Select-Object -First 1
    if (-not $item) { return [pscustomobject]@{ Ok = $false; Status = 'Failed'; Note = 'That quarantined item is no longer there.' } }
    $payload = Join-Path $item.Folder 'payload.bin'
    if (-not (Test-Path $payload)) { return [pscustomobject]@{ Ok = $false; Status = 'Failed'; Note = 'The quarantined file is missing.' } }
    if ($item.Sha256) {
        $now = Get-QpFileHash $payload
        if ($now -and $now -ne $item.Sha256) {
            Write-QpAudit -FindingId $Id -Action 'Restore' -Result 'Failed' -Object $item.OriginalPath -Note 'hash mismatch'
            return [pscustomobject]@{ Ok = $false; Status = 'Failed'; Note = 'The quarantined file does not match what was stored, so it was left alone.' }
        }
    }
    try {
        $dest = $item.OriginalPath
        $parent = Split-Path $dest -Parent
        if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        if (Test-Path -LiteralPath $dest) { return [pscustomobject]@{ Ok = $false; Status = 'Failed'; Note = "Something is already at $dest, so nothing was overwritten." } }
        Move-Item -LiteralPath $payload -Destination $dest -ErrorAction Stop
        $meta = Get-Content (Join-Path $item.Folder 'meta.json') -Raw | ConvertFrom-Json
        try {
            $f = Get-Item -LiteralPath $dest -Force
            # Saved in the round-trip format; read back the same way whatever the PC's language and calendar.
            $f.CreationTime = [datetime]::Parse($meta.CreationTime, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
            $f.LastWriteTime = [datetime]::Parse($meta.LastWriteTime, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        } catch { }
        Remove-Item -LiteralPath $item.Folder -Recurse -Force -ErrorAction SilentlyContinue
        Write-QpLog "Restored $($item.FileName) to $dest" 'OK'
        Write-QpAudit -FindingId $Id -Action 'Restore' -Result 'Restored' -Object $dest
        [pscustomobject]@{ Ok = $true; Status = 'Restored'; Note = "Put back at $dest. Your antivirus may catch it again straight away." }
    } catch {
        Write-QpAudit -FindingId $Id -Action 'Restore' -Result 'Failed' -Object $item.OriginalPath -Note $_.Exception.Message
        [pscustomobject]@{ Ok = $false; Status = 'Failed'; Note = $_.Exception.Message }
    }
}

function Remove-QpQuarantineItem {
    <# Deletes a quarantined file for good. There is no undo, and the window asks first. #>
    param([Parameter(Mandatory)][string]$Id, [switch]$Force)
    if (-not $Force) { return [pscustomobject]@{ Ok = $false; Status = 'Failed'; Note = 'Permanent deletion has to be confirmed.' } }
    $item = @(Get-QpQuarantineItems | Where-Object { $_.Id -eq $Id }) | Select-Object -First 1
    if (-not $item) { return [pscustomobject]@{ Ok = $false; Status = 'Failed'; Note = 'That quarantined item is no longer there.' } }
    try {
        Remove-Item -LiteralPath $item.Folder -Recurse -Force -ErrorAction Stop
        Write-QpLog "Deleted $($item.FileName) for good. This one cannot be undone." 'OK'
        Write-QpAudit -FindingId $Id -Action 'DeletePermanently' -Result 'Deleted' -Object $item.OriginalPath -Note 'from quarantine'
        [pscustomobject]@{ Ok = $true; Status = 'Removed'; Note = 'Deleted for good.' }
    } catch {
        Write-QpAudit -FindingId $Id -Action 'DeletePermanently' -Result 'Failed' -Object $item.OriginalPath -Note $_.Exception.Message
        [pscustomobject]@{ Ok = $false; Status = 'Failed'; Note = $_.Exception.Message }
    }
}

function Invoke-QpRemediate {
    <#
        What happens to a finding. Defender first for things Defender found, then Quietpane's own
        quarantine, the Recycle Bin, or - only when the user says so outright - permanent deletion.
    #>
    param([Parameter(Mandatory)]$Finding, [ValidateSet('Defender', 'Quarantine', 'RecycleBin', 'Delete', 'Allow')][string]$Action = 'Defender', [switch]$Force)
    if ($Action -eq 'Allow') {
        Add-QpAllow -FindingId $Finding.Id -ThreatName $Finding.ThreatName -Path $Finding.Path
        return [pscustomobject]@{ Id = $Finding.Id; Action = $Action; Status = 'Allowed'; Ok = $true; Note = 'Left in place at your request.' }
    }
    if ($Action -in 'Quarantine', 'RecycleBin', 'Delete') {
        if (-not (Test-QpAdmin)) {
            Write-QpAudit -FindingId $Finding.Id -Action $Action -Result 'Failed' -Object $Finding.Path -Note 'not running as administrator'
            return [pscustomobject]@{ Id = $Finding.Id; Action = $Action; Status = 'Failed'; Ok = $false; Note = 'Quietpane needs administrator rights for this. Start it again with "Start Quietpane", which asks Windows for permission.' }
        }
        if ($Action -eq 'Quarantine') {
            $r = Invoke-QpQuarantine -Finding $Finding
            return [pscustomobject]@{ Id = $Finding.Id; Action = $Action; Status = $r.Status; Ok = $r.Ok; Note = $r.Note }
        }
        $check = Test-QpFindingStillTrue $Finding
        if (-not $check.Ok) {
            Write-QpAudit -FindingId $Finding.Id -Action $Action -Result 'Failed' -Object $Finding.Path -Note $check.Why
            return [pscustomobject]@{ Id = $Finding.Id; Action = $Action; Status = 'Failed'; Ok = $false; Note = $check.Why }
        }
        if ($Action -eq 'RecycleBin') {
            if (Move-QpToRecycleBin $Finding.Path) {
                Write-QpLog "Moved $($Finding.Path) to the Recycle Bin. It is still on this PC until you empty the bin." 'OK'
                Write-QpAudit -FindingId $Finding.Id -Action 'RecycleBin' -Result 'Removed' -Object $Finding.Path
                return [pscustomobject]@{ Id = $Finding.Id; Action = $Action; Status = 'Removed'; Ok = $true; Note = 'In your Recycle Bin. Empty the bin to finish the job, or restore it from there.' }
            }
            Write-QpAudit -FindingId $Finding.Id -Action 'RecycleBin' -Result 'Failed' -Object $Finding.Path -Note 'move failed'
            return [pscustomobject]@{ Id = $Finding.Id; Action = $Action; Status = 'Failed'; Ok = $false; Note = 'It could not be moved - it is probably in use, or bigger than the Recycle Bin can hold. Close what is using it and try again, or use Quarantine.' }
        }
        # Delete: gone for good, and only ever when the window has asked outright.
        if (-not $Force) { return [pscustomobject]@{ Id = $Finding.Id; Action = $Action; Status = 'Failed'; Ok = $false; Note = 'Permanent deletion has to be confirmed first.' } }
        try {
            Remove-Item -LiteralPath $Finding.Path -Force -ErrorAction Stop
            Write-QpLog "Deleted $($Finding.Path) for good. This one cannot be undone." 'OK'
            Write-QpAudit -FindingId $Finding.Id -Action 'DeletePermanently' -Result 'Deleted' -Object $Finding.Path
            return [pscustomobject]@{ Id = $Finding.Id; Action = $Action; Status = 'Removed'; Ok = $true; Note = 'Deleted for good.' }
        } catch {
            $why = Get-QpFailureReason $_.Exception
            Write-QpAudit -FindingId $Finding.Id -Action 'DeletePermanently' -Result 'Failed' -Object $Finding.Path -Note $_.Exception.Message
            return [pscustomobject]@{ Id = $Finding.Id; Action = $Action; Status = 'Failed'; Ok = $false; Note = $why }
        }
    }
    if ($Finding.Source -ne 'Microsoft Defender') {
        Write-QpLog 'Only Defender can remove its own detections. This finding came from a Quietpane check, so there is nothing for Defender to remove.' 'WARN'
        return [pscustomobject]@{ Id = $Finding.Id; Action = $Action; Status = 'Failed'; Ok = $false; Note = 'Not a Defender detection.' }
    }
    $state = Get-QpDefenderState
    if (-not $state.CanRemediate) {
        Write-QpAudit -FindingId $Finding.Id -Action 'Remove' -Result 'Failed' -Object $Finding.Path -Note 'Defender remediation unavailable'
        return [pscustomobject]@{ Id = $Finding.Id; Action = $Action; Status = 'Failed'; Ok = $false; Note = 'Defender cannot be asked to remove anything on this PC.' }
    }
    if (-not (Test-QpAdmin)) {
        Write-QpLog 'Administrator rights are needed before Defender will remove anything. Nothing was changed.' 'WARN'
        Write-QpAudit -FindingId $Finding.Id -Action 'Remove' -Result 'Failed' -Object $Finding.Path -Note 'not running as administrator'
        return [pscustomobject]@{ Id = $Finding.Id; Action = $Action; Status = 'Failed'; Ok = $false; Note = 'Quietpane needs administrator rights for this. Close it and start it again with "Start Quietpane", which asks Windows for permission.' }
    }
    Write-QpLog "Asking Defender to deal with $($Finding.ThreatName)" 'STEP'
    $hadFile = $Finding.Path -and (Test-Path -LiteralPath $Finding.Path)
    $tried = @()
    try {
        # A targeted scan of the file is what actually makes Defender clean it. Remove-MpThreat only ever
        # touches threats Defender still counts as active, which is why it can quietly do nothing.
        if ($hadFile) {
            $mp = Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe'
            if (Test-Path $mp) {
                & $mp -Scan -ScanType 3 -File $Finding.Path | Out-Null
                $tried += "MpCmdRun -Scan -File (exit $LASTEXITCODE)"
            }
        }
        if ($Finding.VendorActive -or -not $hadFile) {
            $tried += 'Remove-MpThreat'
            Remove-MpThreat -ErrorAction SilentlyContinue | Out-Null
        }
    } catch {
        Write-QpLog "Defender returned an error: $($_.Exception.Message)" 'WARN'
    }
    # Never report success without checking. A claim of "removed" has to be true.
    Start-Sleep -Milliseconds 800
    $stillThere = $Finding.Path -and (Test-Path -LiteralPath $Finding.Path)
    if ($hadFile -and -not $stillThere) {
        Write-QpLog "Defender removed $($Finding.Path)" 'OK'
        Write-QpAudit -FindingId $Finding.Id -Action 'Remove' -Result 'Removed' -Object $Finding.Path -Note ($tried -join ' + ')
        return [pscustomobject]@{ Id = $Finding.Id; Action = $Action; Status = 'Removed'; Ok = $true; Note = 'Defender removed the file. It is in Defender''s own quarantine, and Windows Security can restore it.' }
    }
    $now = @(Get-MpThreat -ErrorAction SilentlyContinue | Where-Object { "$($_.ThreatID)" -eq $Finding.ThreatId })
    if (-not $hadFile -and $now.Count -and -not $now[0].IsActive) {
        Write-QpLog 'Defender says this one is no longer active. Nothing is left to remove.' 'OK'
        Write-QpAudit -FindingId $Finding.Id -Action 'Remove' -Result 'AlreadyHandled' -Object $Finding.Path -Note ($tried -join ' + ')
        return [pscustomobject]@{ Id = $Finding.Id; Action = $Action; Status = 'Removed'; Ok = $true; Note = 'Defender had already dealt with this one.' }
    }
    $note = 'Defender did not remove it. Try "Remove it" again and choose Quarantine, or open Windows Security > Protection history and act there.'
    Write-QpLog "Defender did not remove $($Finding.Path). Nothing was changed by Quietpane." 'WARN'
    Write-QpAudit -FindingId $Finding.Id -Action 'Remove' -Result 'Failed' -Object $Finding.Path -Note ("tried: " + ($tried -join ' + '))
    [pscustomobject]@{ Id = $Finding.Id; Action = $Action; Status = 'Failed'; Ok = $false; Note = $note }
}

#endregion

#region ---------------------------------------------------------------- scan (read-only)

function New-QpScanSummary {
    <#
        What the window says once a check has finished: how much was looked at, what turned up, what
        was done about it, and the one thing worth doing next. It lives here so it can be tested, and
        so the window and the log always say the same thing.
    #>
    param(
        $Counts, $Tally, [int]$Scanned = 0, [int]$Seconds = 0,
        [int]$Outstanding = 0, [bool]$IsAdmin = $true, [bool]$Cancelled = $false
    )
    $num = {
        param($bag, $key)
        if ($null -eq $bag) { return 0 }
        if ($bag -is [System.Collections.IDictionary]) { if ($bag.Contains($key)) { return [int]$bag[$key] } return 0 }
        $p = $bag.PSObject.Properties[$key]
        if ($p) { return [int]$p.Value }
        return 0
    }
    $took = if ($Seconds -ge 60) { '{0} min {1} sec' -f [int][math]::Floor($Seconds / 60), ($Seconds % 60) } else { "$Seconds seconds" }
    $lines = @()
    $lines += if ($Cancelled) {
        'Stopped after {0}. {1:N0} things had been looked at. Nothing on this PC was changed.' -f $took, $Scanned
    } else {
        'Looked at {0:N0} things in {1}. Nothing was changed while we looked.' -f $Scanned, $took
    }
    $sev = foreach ($s in 'Critical', 'High', 'Medium', 'Low', 'Info') {
        '{0} {1}' -f (& $num $Counts $s), $(if ($s -eq 'Info') { 'for information' } else { $s.ToLower() })
    }
    $total = 0; foreach ($s in 'Critical', 'High', 'Medium', 'Low', 'Info') { $total += (& $num $Counts $s) }
    $lines += 'Found {0}: {1}.' -f $(if ($total -eq 1) { '1 thing' } else { "$total things" }), (($sev -join ', ') -replace ', ([^,]+)$', ' and $1')

    # What the user has actually done about it so far, in their own words rather than status codes.
    $done = @()
    $removed = (& $num $Tally 'Removed'); $quar = (& $num $Tally 'Quarantined'); $bin = (& $num $Tally 'Recycled')
    $deleted = (& $num $Tally 'Deleted'); $left = (& $num $Tally 'Allowed'); $failed = (& $num $Tally 'Failed')
    if ($removed) { $done += "$removed removed by Defender" }
    if ($quar)    { $done += "$quar in Quietpane's quarantine" }
    if ($bin)     { $done += "$bin in the Recycle Bin" }
    if ($deleted) { $done += "$deleted deleted for good" }
    if ($left)    { $done += "$left left alone on purpose" }
    if ($failed)  { $done += "$failed that did not work" }
    if ($done.Count) { $lines += 'Dealt with: ' + (($done -join ', ') -replace ', ([^,]+)$', ' and $1') + '.' }

    $next = if ($Cancelled) {
        'Next: run the check again when you have a few minutes, so nothing is missed.'
    } elseif ($failed -gt 0 -and -not $IsAdmin) {
        'Next: some actions did not work because Quietpane was not started as administrator. Close it, start it again with "Start Quietpane", and try those again.'
    } elseif ($Outstanding -gt 0) {
        'Next: deal with the {0} serious item{1} above. "Remove it" is the safest start - Defender keeps its own copy, and quarantine can be undone.' -f $Outstanding, $(if ($Outstanding -eq 1) { '' } else { 's' })
    } elseif ($failed -gt 0) {
        'Next: some actions did not work. Open "Show details" at the bottom to see why, then try those again.'
    } elseif (((& $num $Counts 'Medium') + (& $num $Counts 'Low')) -gt 0) {
        'Next: nothing urgent. Have a look at the {0} item(s) marked medium or low when you have a minute.' -f ((& $num $Counts 'Medium') + (& $num $Counts 'Low'))
    } else {
        'Next: nothing needs doing. Run this again in a month, or after installing something you are unsure about.'
    }
    [pscustomobject]@{ Lines = @($lines); NextStep = $next; Failed = $failed; Total = $total }
}

function Invoke-QpAudit {
    <#
        Read-only health, privacy and malware check. Writes an HTML report and returns a summary.
        Nothing on the PC is changed.
    #>
    param([string]$OutFile = (Join-Path ([Environment]::GetFolderPath('Desktop')) ("Quietpane-Report-{0}.html" -f (Get-QpStamp 'yyyyMMdd-HHmm'))))

    $findings = New-Object System.Collections.ArrayList
    $isAdmin = Test-QpAdmin
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $scanned = 0          # how many things have been looked at, for the progress line
    $defender = $null
    $steps = 14

    function Write-Step([int]$Step, [string]$Stage, [string]$Object = '') {
        # The window shows this while it works. Nothing here reads or changes the PC.
        Write-QpProgress -Stage $Stage -Step $Step -Of $steps -Object $Object -Scanned $scanned `
            -Found @($findings | Where-Object { $_.Severity -in 'Critical', 'High' }).Count
    }
    function New-Stopped {
        # Stop is always taken at a safe point, between steps. Nothing is half-done.
        Write-QpLog 'Stopped at your request. Nothing on this PC was changed.' 'WARN'
        [pscustomobject]@{
            Cancelled = $true; Critical = 0; High = 0; Medium = 0; Low = 0; Info = 0
            Counts = $null; Total = 0; Findings = @(); Defender = $defender; Report = $null
            Scanned = $scanned; Seconds = [int]$sw.Elapsed.TotalSeconds
        }
    }

    function Add-Finding([string]$Section, [string]$Severity, [string]$Title, [string]$Detail = '', [string]$Path = '', [string]$Todo = '', $Items = $null) {
        <#
            Quietpane's own checks. They are heuristics: useful signals, never proof, and never a family
            name. The detail is split so the window shows it once: plain sentences become the "why",
            paths, commands and values the technical part. The report keeps the whole detail.
            -Path is the one file the finding is about, when there is one: that is what makes Quarantine
            and Remove possible, and its fingerprint lets Quietpane check it is still the same file first.
            -Items is a list of such files under one heading (one card, a row each).
        #>
        $confidence = if ($Severity -eq 'Info') { 'Informational' } else { 'Heuristic' }
        $split = Split-QpFindingDetail $Detail
        $hash = ''
        if ($Path) {
            if (Test-Path -LiteralPath $Path -PathType Leaf) { $hash = Get-QpFileHash $Path } else { $Path = '' }   # folders are shown, never moved
        }
        $f = New-QpFinding -Section $Section -Severity $Severity -Title $Title -Detail $Detail `
            -Source 'Quietpane check' -Method 'Heuristic check' -Confidence $confidence `
            -Object $Title -Path $Path -Sha256 $hash -What '' -Why $split.Why -Technical $split.Technical -Recommended $Todo
        if ($Items) { $f | Add-Member -NotePropertyName Items -NotePropertyValue @($Items) }
        [void]$findings.Add($f)
    }
    function New-FileItem([string]$File, [string]$Note, [string]$Severity = 'Medium') {
        # One file under a grouped finding, with everything Quarantine and Remove need.
        New-QpFinding -Section 'Files' -Severity $Severity -Title (Split-Path $File -Leaf) -Source 'Quietpane check' -Method 'Heuristic check' `
            -Confidence 'Heuristic' -Object $File -Path $File -Sha256 (Get-QpFileHash $File) -Technical $Note
    }
    $todoFile = 'If you don''t recognise it, quarantine it - you can put it back later.'

    $suspiciousCmd = '(?i)(cmd(\.exe)?\s+/c\s+start\s+\S*(https?:|www\.))|(\bstart\s+(https?://|www\.))|\bmshta\b|\bwscript\b|\bcscript\b|powershell[^;|]*\s-(e|enc|encodedcommand)\s|-w(indowstyle)?\s+hidden|downloadstring|\\AppData\\Local\\Temp\\|\\Users\\Public\\'
    $suspiciousTask = '(?i)reg(\.exe)?\s+add\s+\S*\\CurrentVersion\\Run|\bstart\s+\S*(https?://|www\.)|\bmshta\b|\bwscript\b|\bcscript\b|powershell[^;]*\s-(e|enc|encodedcommand)\s|downloadstring|invoke-webrequest|\\AppData\\Local\\Temp\\|\\Users\\Public\\'
    $correlationRoots = @($env:LOCALAPPDATA, $env:APPDATA, (Join-Path $env:USERPROFILE 'AppData\LocalLow'), $env:ProgramData,
        $env:ProgramFiles, ${env:ProgramFiles(x86)}, (Join-Path $env:USERPROFILE 'Downloads'), ([Environment]::GetFolderPath('Desktop')), 'C:\Games') |
        Where-Object { $_ -and (Test-Path $_) }

    function Get-NearbyFolders([datetime]$When) {
        # Folders created within 3 minutes of $When - the likely source of a malicious entry.
        $hits = foreach ($r in $correlationRoots) {
            Get-ChildItem -Path $r -Directory -Force -ErrorAction SilentlyContinue |
                Where-Object { [math]::Abs(($_.CreationTime - $When).TotalMinutes) -le 3 } |
                ForEach-Object { '{0}  (created {1:yyyy-MM-dd HH:mm:ss})' -f $_.FullName, $_.CreationTime }
        }
        return @($hits)
    }

    Write-QpLog 'Scan started (read-only - nothing will be changed)' 'STEP'

    # ---- 0. What Microsoft Defender has found. Defender names threats; Quietpane only explains them.
    Write-Step 1 'Asking Microsoft Defender what it has found'
    Write-QpLog 'Asking Microsoft Defender what it has found...' 'INFO'
    $defender = Get-QpDefenderState
    foreach ($f in @(Get-QpDefenderFindings)) { [void]$findings.Add($f); $scanned++ }
    if ($defender.Note) { Add-Finding 'Threats' 'Medium' 'Antivirus cover is not complete' $defender.Note }
    if ($defender.Available -and -not @($findings | Where-Object { $_.Source -eq 'Microsoft Defender' }).Count) {
        Add-Finding 'Threats' 'Info' 'Microsoft Defender has no threats on record for this PC' 'Nothing has been detected or quarantined. Quietpane cannot confirm a PC is clean on its own - it only reports what Defender knows plus its own checks below.'
    }

    # ---- 1. Startup entries
    if (Test-QpCancelled) { return (New-Stopped) }
    Write-Step 2 'Checking startup entries'
    Write-QpLog 'Checking startup entries...' 'INFO'
    # Each Run key is paired with the key where Task Manager records whether that entry is switched off.
    $sa = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
    $runKeys = @(
        @{ Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'; Approved = "HKCU:\$sa\Run" },
        @{ Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'; Approved = $null },
        @{ Key = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'; Approved = "HKLM:\$sa\Run" },
        @{ Key = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce'; Approved = $null },
        @{ Key = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = "HKLM:\$sa\Run32" },
        @{ Key = 'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce'; Approved = $null },
        @{ Key = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\Run'; Approved = $null },
        @{ Key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer\Run'; Approved = $null })
    function Get-DisabledNames([string]$ApprovedKey) {
        # Task Manager stores a switched-off entry with an odd first byte (usually 03).
        $names = @{}
        if (-not $ApprovedKey) { return $names }
        $p = Get-ItemProperty -Path $ApprovedKey -ErrorAction SilentlyContinue
        if ($p) { $p.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object { if ($_.Value -is [byte[]] -and $_.Value.Length -and ($_.Value[0] -band 1)) { $names[$_.Name] = $true } } }
        return $names
    }
    function Test-StartupTarget([string]$Command) {
        # $true if the program a startup command points to exists (or if that can't be worked out).
        try {
            $c = [Environment]::ExpandEnvironmentVariables("$Command").Trim()
            if (-not $c) { return $true }
            $exePath = if ($c -match '^"([^"]+)"') { $matches[1] } elseif ($c -match '^(.+?\.(exe|com|bat|cmd|vbs|js|ps1|scr))(\s|$)') { $matches[1] } else { ($c -split '\s+')[0] }
            if ([IO.Path]::IsPathRooted($exePath)) { return (Test-Path -LiteralPath $exePath) }
            return [bool](Get-Command $exePath -CommandType Application -ErrorAction SilentlyContinue)
        } catch { return $true }
    }
    $startupTotal = 0
    $startupOn = 0
    foreach ($rk in $runKeys) {
        $p = Get-ItemProperty -Path $rk.Key -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        $off = Get-DisabledNames $rk.Approved
        foreach ($prop in ($p.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' })) {
            $startupTotal++; $scanned++
            $disabled = $off.ContainsKey($prop.Name)
            $exists = Test-StartupTarget $prop.Value
            if (-not $disabled -and $exists) { $startupOn++ }
            $state = if ($disabled) { ' (disabled in Task Manager)' } else { '' }
            $detail = "$($rk.Key)`n$($prop.Name) = $($prop.Value)"
            if ("$($prop.Value)" -match $suspiciousCmd) { Add-Finding 'Startup & persistence' 'High' "Suspicious startup entry: $($prop.Name)$state" "$detail`nThis launches a website, script or hidden command at login - typical adware/browser-hijacker behaviour." }
            elseif (-not $exists) {
                $how = if ($rk.Key -like '*RunOnce') { 'Windows removes this kind of entry by itself the next time you sign in.' } elseif ($disabled) { 'It is already switched off, so it does nothing.' } else { 'You can switch it off in Task Manager > Startup apps.' }
                Add-Finding 'Startup & persistence' 'Info' "Leftover startup entry: $($prop.Name)$state" "$detail`nThe program it points to no longer exists - probably left behind by something you uninstalled. Harmless. $how"
            }
            else { Add-Finding 'Startup & persistence' 'Info' "Startup entry: $($prop.Name)$state" $detail }
        }
    }
    $folderOff = @{}
    foreach ($ak in "HKCU:\$sa\StartupFolder", "HKLM:\$sa\StartupFolder") { foreach ($n in (Get-DisabledNames $ak).Keys) { $folderOff[$n] = $true } }
    $shell = New-Object -ComObject WScript.Shell
    foreach ($folder in @([Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('CommonStartup'))) {
        Get-ChildItem -Path $folder -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' } | ForEach-Object {
            $startupTotal++; $scanned++
            $disabled = $folderOff.ContainsKey($_.Name)
            $targetExe = $_.FullName
            $target = $_.FullName
            if ($_.Extension -eq '.lnk') { $s = $shell.CreateShortcut($_.FullName); $targetExe = $s.TargetPath; $target = "$($s.TargetPath) $($s.Arguments)" }
            $exists = (-not $targetExe) -or (Test-Path -LiteralPath $targetExe)
            if (-not $disabled -and $exists) { $startupOn++ }
            $state = if ($disabled) { ' (disabled in Task Manager)' } else { '' }
            if ($target -match $suspiciousCmd -or $_.Extension -match '\.(bat|cmd|vbs|js|ps1|hta)$') {
                Add-Finding 'Startup & persistence' 'High' "Suspicious item in Startup folder: $($_.Name)$state" "$($_.FullName)`n-> $target`nIt runs a script or a hidden command every time you sign in." -Path $_.FullName -Todo $todoFile
            }
            elseif (-not $exists) { Add-Finding 'Startup & persistence' 'Info' "Leftover item in Startup folder: $($_.Name)$state" "$($_.FullName)`n-> $target`nThe program it points to no longer exists. Harmless - you can delete this shortcut." }
            else { Add-Finding 'Startup & persistence' 'Info' "Startup folder item: $($_.Name)$state" "$($_.FullName)`n-> $target" }
        }
    }

    # ---- 2. Scheduled tasks
    if (Test-QpCancelled) { return (New-Stopped) }
    Write-Step 3 'Checking scheduled tasks'
    Write-QpLog 'Checking scheduled tasks...' 'INFO'
    foreach ($t in @(Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        $scanned++
        $actions = (@($t.Actions) | ForEach-Object { ("{0} {1}" -f $_.Execute, $_.Arguments).Trim() }) -join ' ; '
        $id = "$($t.TaskPath)$($t.TaskName)"
        if (Test-QpOwnSignInTask $t) {
            Add-Finding 'Scheduled tasks' 'Info' "Quietpane's own sign-in start: $id" "You switched this on in Quietpane > About. It opens Quietpane from $($script:InstallRoot) when you sign in.`nAction: $actions"
            continue
        }
        if ($actions -match $suspiciousTask) {
            $detail = "Action: $actions`nState: $($t.State)"
            $taskFile = Join-Path $env:WINDIR ("System32\Tasks\" + $t.TaskPath.TrimStart('\') + $t.TaskName)
            if (Test-Path $taskFile) {
                $created = (Get-Item $taskFile -Force).CreationTime
                $detail += "`nTask created: $(Get-QpStamp 'yyyy-MM-dd HH:mm:ss' $created)"
                $near = Get-NearbyFolders $created
                if ($near.Count) { $detail += "`nFolders created within 3 minutes of this task (likely source):`n  " + ($near -join "`n  ") }
            } elseif (-not $isAdmin) { $detail += "`n(Run as administrator to see when it was created and what was installed at the same time.)" }
            Add-Finding 'Scheduled tasks' 'High' "Suspicious scheduled task: $id" $detail
        } elseif ($t.TaskPath -notlike '\Microsoft\*') {
            Add-Finding 'Scheduled tasks' 'Info' "Third-party task: $id" "Action: $actions`nState: $($t.State)"
        }
    }

    # ---- 3. Other persistence tricks
    if (Test-QpCancelled) { return (New-Stopped) }
    Write-Step 4 'Checking the other places things hide'
    Write-QpLog 'Checking other persistence locations...' 'INFO'
    foreach ($cls in 'CommandLineEventConsumer', 'ActiveScriptEventConsumer') {
        Get-CimInstance -Namespace root\subscription -ClassName $cls -ErrorAction SilentlyContinue | ForEach-Object {
            Add-Finding 'Startup & persistence' 'High' "WMI event consumer: $($_.Name)" ("{0}{1}" -f $_.CommandLineTemplate, $_.ScriptText)
        }
    }
    Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options' -ErrorAction SilentlyContinue | ForEach-Object {
        $dbg = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).Debugger
        if ($dbg) { Add-Finding 'Startup & persistence' 'Medium' "Program hijack (IFEO debugger) on $($_.PSChildName)" "Runs instead: $dbg" }
    }
    $wl = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction SilentlyContinue
    if ($wl.Shell -and $wl.Shell -notmatch '^\s*explorer\.exe\s*$') { Add-Finding 'Startup & persistence' 'High' 'Winlogon shell has been changed' "Shell = $($wl.Shell)" }
    if ($wl.Userinit -and $wl.Userinit -notmatch '^\s*C:\\Windows\\system32\\userinit\.exe,?\s*$') { Add-Finding 'Startup & persistence' 'High' 'Winlogon Userinit has been changed' "Userinit = $($wl.Userinit)" }
    $appinit = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows' -ErrorAction SilentlyContinue
    if ($appinit.AppInit_DLLs -and $appinit.LoadAppInit_DLLs -eq 1) { Add-Finding 'Startup & persistence' 'High' 'AppInit_DLLs is loading extra DLLs into every program' $appinit.AppInit_DLLs }

    # ---- 4. Network hijacks
    if (Test-QpCancelled) { return (New-Stopped) }
    Write-Step 5 'Checking the hosts file, proxy and DNS'
    Write-QpLog 'Checking hosts file, proxy and DNS...' 'INFO'
    $blockedHosts = New-Object System.Collections.ArrayList
    foreach ($line in @(Get-Content $script:HostsPath -ErrorAction SilentlyContinue)) {
        $scanned++
        $l = $line.Trim()
        if (-not $l -or $l.StartsWith('#')) { continue }
        $parts = $l -split '\s+'
        if ($parts[0] -in '0.0.0.0', '127.0.0.1', '::1', '::') { [void]$blockedHosts.Add($parts[1]) }
        else { Add-Finding 'Network' 'High' "Hosts file redirects $($parts[1]) to $($parts[0])" "$l`nRedirecting real websites to other addresses is a classic phishing/hijack trick unless you set it up yourself." }
    }
    if ($blockedHosts.Count) { Add-Finding 'Network' 'Info' "Hosts file blocks $($blockedHosts.Count) domain(s)" ($blockedHosts -join "`n") }
    $inet = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
    if ($inet.ProxyEnable -eq 1 -or $inet.AutoConfigURL) { Add-Finding 'Network' 'Medium' 'A proxy is configured' "ProxyServer = $($inet.ProxyServer)`nAutoConfigURL = $($inet.AutoConfigURL)`nIf you did not set this up (VPN, work, school), it may be intercepting your traffic." }
    $dns = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object ServerAddresses | ForEach-Object { "$($_.InterfaceAlias): $($_.ServerAddresses -join ', ')" })
    if ($dns) { Add-Finding 'Network' 'Info' 'DNS servers in use' ($dns -join "`n") }

    # ---- 5. Services running from unusual places
    if (Test-QpCancelled) { return (New-Stopped) }
    Write-Step 6 'Checking services'
    Write-QpLog 'Checking services...' 'INFO'
    Get-CimInstance Win32_Service -ErrorAction SilentlyContinue | Where-Object { $_.PathName } | ForEach-Object {
        $scanned++
        # Only look at the executable itself, not its arguments (arguments often mention AppData legitimately).
        $exePath = if ($_.PathName -match '^\s*"([^"]+)"') { $matches[1] } elseif ($_.PathName -match '^\s*(\S+?\.exe)\b') { $matches[1] } else { $_.PathName }
        if ($exePath -match '(?i)\\AppData\\|\\Temp\\|\\Users\\Public\\') {
            Add-Finding 'Services' 'Medium' "Service runs from a user folder: $($_.DisplayName)" "$($_.Name)`n$($_.PathName)`nState: $($_.State), start: $($_.StartMode)`nReal services almost always live in Program Files or Windows." -Path $exePath -Todo $todoFile
        }
    }

    # ---- 6. Unsigned programs in user-writable folders
    if (Test-QpCancelled) { return (New-Stopped) }
    Write-Step 7 'Checking programs in your own folders'
    Write-QpLog 'Checking programs in user folders for missing/invalid signatures (this can take a minute)...' 'INFO'
    $skip = '(?i)\\node_modules\\|\\npm-cache\\|\\\.vscode\\|\\Programs\\Python\\|\\go\\pkg\\|\\Android\\Sdk\\|\\\.gradle\\|\\\.m2\\|\\\.cargo\\|\\\.rustup\\|\\WindowsApps\\|\\Packages\\|\\Microsoft\\WindowsApps\\'
    $scanRoots = @($env:LOCALAPPDATA, $env:APPDATA, (Join-Path $env:USERPROFILE 'AppData\LocalLow'), (Join-Path $env:USERPROFILE 'Downloads'), $env:PUBLIC, $env:TEMP) | Where-Object { $_ -and (Test-Path $_) }
    $exe = foreach ($r in $scanRoots) { Get-ChildItem -Path $r -Recurse -Force -File -Include *.exe, *.scr -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch $skip } }
    $exe = @($exe | Sort-Object LastWriteTime -Descending | Select-Object -First 1500)
    # Folders that hold a validly signed program: an unsigned file next to one is usually that app's own helper.
    $signedIn = @{}
    function Get-SignerName($Sig) { try { $Sig.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false) } catch { 'unknown publisher' } }
    $abort = $false
    $seenFiles = 0
    $unsigned = foreach ($f in $exe) {
        $seenFiles++; $scanned++
        # The long part of the check, so it says where it has got to - and it is the one place where
        # Stop is polled inside a loop rather than between steps.
        if (($seenFiles % 25) -eq 0) {
            if (Test-QpCancelled) { $abort = $true; break }
            Write-Step 7 'Checking programs in your own folders' ('{0:N0} of {1:N0}: {2}' -f $seenFiles, $exe.Count, $f.Name)
        }
        $sig = Get-AuthenticodeSignature -FilePath $f.FullName -ErrorAction SilentlyContinue
        if (-not $sig) { continue }
        if ($sig.Status -eq 'Valid') {
            # Prefer naming the app's main program over its uninstaller.
            $cur = $signedIn[$f.DirectoryName]
            if (-not $cur -or ($cur -match '^(?i)unins' -and $f.Name -notmatch '^(?i)unins')) { $signedIn[$f.DirectoryName] = '{0} (signed by {1})' -f $f.Name, (Get-SignerName $sig) }
        }
        else { [pscustomobject]@{ File = $f.FullName; Dir = $f.DirectoryName; Status = [string]$sig.Status; Date = $f.LastWriteTime } }
    }
    if ($abort) { return (New-Stopped) }
    function Get-SignedSibling([string]$Dir) {
        if ($signedIn.ContainsKey($Dir)) { return $signedIn[$Dir] }
        $found = $null
        foreach ($s in @(Get-ChildItem -LiteralPath $Dir -Filter *.exe -File -Force -ErrorAction SilentlyContinue | Sort-Object { $_.Name -match '^(?i)unins' } | Select-Object -First 20)) {
            $sg = Get-AuthenticodeSignature -FilePath $s.FullName -ErrorAction SilentlyContinue
            if ($sg -and $sg.Status -eq 'Valid') { $found = '{0} (signed by {1})' -f $s.Name, (Get-SignerName $sg); break }
        }
        $signedIn[$Dir] = $found
        return $found
    }
    foreach ($u in @($unsigned | Where-Object Status -eq 'HashMismatch')) { Add-Finding 'Files' 'High' "Modified signed program (signature broken): $(Split-Path $u.File -Leaf)" "$($u.File)`nThe file was signed by its publisher but has been altered since - typical of cracks or infected files." -Path $u.File -Todo $todoFile }
    $alone = New-Object System.Collections.ArrayList
    $helpers = New-Object System.Collections.ArrayList
    foreach ($u in @($unsigned | Where-Object Status -ne 'HashMismatch')) {
        $sib = Get-SignedSibling $u.Dir
        if ($sib) { [void]$helpers.Add([pscustomobject]@{ U = $u; Sibling = $sib }) } else { [void]$alone.Add($u) }
    }
    $plain = @($alone | Select-Object -First 40)
    if ($plain.Count) {
        # One card, a row per program, each with its own buttons - rather than a card each.
        $rows = @(foreach ($u in $plain) { New-FileItem $u.File ('{0:yyyy-MM-dd}  {1}' -f $u.Date, $u.File) })
        Add-Finding 'Files' 'Medium' "$($plain.Count) unsigned program(s) in user folders (newest first)" ((($plain | ForEach-Object { '{0:yyyy-MM-dd}  {1}' -f $_.Date, $_.File }) -join "`n") + "`nUnsigned doesn't mean harmful, but make sure you recognise each one.") -Todo 'Quarantine any you don''t recognise - you can put them back later.' -Items $rows
    }
    $help = @($helpers | Select-Object -First 40)
    if ($help.Count) { Add-Finding 'Files' 'Info' "$($help.Count) unsigned helper file(s) belonging to signed programs" ((($help | ForEach-Object { "{0:yyyy-MM-dd}  {1}`n            next to {2}" -f $_.U.Date, $_.U.File, $_.Sibling }) -join "`n") + "`nMany apps ship small unsigned helpers (for example crash reporters) next to their signed main program. Lower risk.") }

    # ---- 7. Unofficial / cracked software indicators
    if (Test-QpCancelled) { return (New-Stopped) }
    Write-Step 8 'Looking for unofficial software'
    Write-QpLog 'Looking for signs of cracked/unofficial software...' 'INFO'
    # Only unambiguous names - generic words (codex, rune, plaza, reloaded...) collide with legitimate software.
    $crackNames = '(?i)^(nodvd|crack|cracked|codex-rune|empress|skidrow|fitgirl|fitgirl repacks|dodi|dodi repacks|anadius|goldberg|goldberg_emu|steam_emu|smartsteamemu|creamapi|cream_api|tenoke)$'
    $crackFiles = '(?i)^(steam_emu\.ini|cream_api\.ini|codex\.ini|rune\.ini|steam_api64\.cdx|smartsteamemu\.ini|onlinefix\.ini|cpy\.ini)$'
    $gameRoots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, 'C:\Games', (Join-Path $env:USERPROFILE 'Downloads'), ([Environment]::GetFolderPath('Desktop')), $env:LOCALAPPDATA, $env:APPDATA) | Where-Object { $_ -and (Test-Path $_) }
    $indicators = foreach ($r in $gameRoots) {
        Get-ChildItem -Path $r -Recurse -Depth 4 -Force -ErrorAction SilentlyContinue |
            Where-Object { ($_.PSIsContainer -and $_.Name -match $crackNames) -or (-not $_.PSIsContainer -and $_.Name -match $crackFiles) } |
            Select-Object -ExpandProperty FullName
    }
    foreach ($i in @($indicators | Select-Object -Unique -First 25)) {
        Add-Finding 'Files' 'Medium' 'Cracked/unofficial software indicator' "$i`nCracked games and software are one of the most common ways adware and password stealers get onto PCs." -Path $i -Todo $todoFile
    }

    # ---- 8. Browsers
    if (Test-QpCancelled) { return (New-Stopped) }
    Write-Step 9 'Checking browser add-ons and notifications'
    Write-QpLog 'Checking browser extensions and notification permissions...' 'INFO'
    # The same reading the Privacy tab shows, so the report and the window never disagree.
    $addons = @()
    try { $addons = @(Get-QpBrowserExtensions) } catch { Write-QpLog "Could not read the browser add-ons: $($_.Exception.Message)" 'WARN' }
    $scanned += $addons.Count
    $ownParts = @($addons | Where-Object { $_.BuiltIn })
    foreach ($e in @($addons | Where-Object { -not $_.BuiltIn })) {
        $sev = if ($e.On -and $e.Reach.Everywhere) { 'Medium' } else { 'Info' }
        $detail = @((Format-QpExtensionUse $e), "$($e.Source).")
        if (@($e.Reach.Can).Count) { $detail += 'It ' + ((@($e.Reach.Can)) -join ', and ') + '.' }
        if ($sev -eq 'Medium') { $detail += 'An add-on that reads every site can see anything you type or read in the browser. Keep it only if you meant to have it.' }
        $detail += 'You can see and switch off add-ons on the Privacy tab.'
        if (@($e.Reach.Sites).Count) { $detail += 'Sites: ' + (@($e.Reach.Sites) -join ', ') }
        $detail += "ID: $($e.ExtId)"
        if ($e.Folder) { $detail += $e.Folder }
        Add-Finding 'Browsers' $sev ('{0} add-on: {1}' -f $e.Browser, $e.Name) ($detail -join "`n")
    }
    if ($ownParts.Count) {
        Add-Finding 'Browsers' 'Info' ("{0} add-on(s) that are part of the browsers themselves" -f $ownParts.Count) `
            ((@($ownParts | ForEach-Object { '{0} ({1})' -f $_.Name, $_.Browser }) -join "`n") + "`nThese came with the browser - its PDF viewer, its store and the like - and did not come from you or from another program.")
    }
    $browsers = @{ 'Chrome' = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data'; 'Edge' = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data'; 'Brave' = Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data' }
    foreach ($b in $browsers.Keys) {
        $root = $browsers[$b]
        if (-not (Test-Path $root)) { continue }
        foreach ($prof in @(Get-ChildItem $root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' })) {
            # Which websites the browser lets send notifications: a favourite trick of adware.
            $pj = $null
            $pp = Join-Path $prof.FullName 'Preferences'
            if (Test-Path $pp) { try { $pj = Get-Content $pp -Raw | ConvertFrom-Json } catch { } }
            if ($pj) {
                try {
                    $n = $pj.profile.content_settings.exceptions.notifications
                    if ($n) {
                        $allowed = @($n.PSObject.Properties | Where-Object { $_.Value.setting -eq 1 } | ForEach-Object { $_.Name })
                        if ($allowed.Count) { Add-Finding 'Browsers' 'Medium' "$b ($($prof.Name)): sites allowed to show notifications" (($allowed -join "`n") + "`nNotification spam from sites like these is a common adware trick. Remove any you do not recognise in the browser's site settings.") }
                    }
                } catch { }
            }
        }
    }

    # ---- 9. Security basics
    if (Test-QpCancelled) { return (New-Stopped) }
    Write-Step 10 'Checking Defender and the firewall'
    Write-QpLog 'Checking Microsoft Defender and firewall...' 'INFO'
    $mp = Get-MpComputerStatus -ErrorAction SilentlyContinue
    if ($mp) {
        if (-not $mp.RealTimeProtectionEnabled) { Add-Finding 'Security' 'High' 'Defender real-time protection is OFF' 'Turn it back on in Windows Security unless another antivirus is installed.' }
        $age = ((Get-Date) - $mp.AntivirusSignatureLastUpdated).Days
        if ($age -gt 7) { Add-Finding 'Security' 'Medium' "Defender virus definitions are $age days old" 'Run Windows Update or open Windows Security > Protection updates.' }
        $lastFull = if ($mp.FullScanEndTime) { Get-QpStamp 'yyyy-MM-dd' $mp.FullScanEndTime } else { 'never' }
        Add-Finding 'Security' 'Info' 'Microsoft Defender status' ("Real-time protection: {0}`nDefinitions updated: {1:yyyy-MM-dd}`nLast full scan: {2}" -f $mp.RealTimeProtectionEnabled, $mp.AntivirusSignatureLastUpdated, $lastFull)
    }
    if ($isAdmin) {
        $pref = Get-MpPreference -ErrorAction SilentlyContinue
        foreach ($x in @($pref.ExclusionPath) | Where-Object { $_ }) {
            $sev = if ($x -match '(?i)\\AppData\\|\\Temp\\|\\Users\\Public\\|^[A-Z]:\\?$') { 'High' } else { 'Info' }
            Add-Finding 'Security' $sev "Defender exclusion: $x" 'Files here are not scanned. Malware sometimes adds exclusions for itself.'
        }
    }
    Get-NetFirewallProfile -ErrorAction SilentlyContinue | Where-Object { -not $_.Enabled } | ForEach-Object { Add-Finding 'Security' 'High' "Windows Firewall is off for the $($_.Name) profile" '' }

    # ---- 10. Telemetry status
    if (Test-QpCancelled) { return (New-Stopped) }
    Write-Step 11 'Checking what is reporting home'
    Write-QpLog 'Checking telemetry status...' 'INFO'
    $status = Get-QpPrivacyStatus
    $open = @((Get-QpCatalog privacy).Items | Where-Object { $status[$_.Id] -in 'NotApplied', 'Partial' -and $_.Recommended })
    if ($open.Count) { Add-Finding 'Privacy & telemetry' 'Medium' "$($open.Count) recommended privacy setting(s) are not fully applied yet" (($open | ForEach-Object { "- $($_.Title)" + $(if ($status[$_.Id] -eq 'Partial') { ' (partly done)' } else { '' }) }) -join "`n") }
    else { Add-Finding 'Privacy & telemetry' 'Info' 'All recommended privacy settings are applied' '' }
    # ---- 10b. Brand and hardware software (whatever came with this PC)
    Write-QpLog 'Looking for brand software that came with this PC...' 'INFO'
    foreach ($v in (Get-QpVendorStatus)) {
        $open = @($v.Items | Where-Object { $_.Status -ne 'Applied' })
        if ($open.Count) {
            $detail = (($open | ForEach-Object { "- $($_.Title)" }) -join "`n") + "`n`n" + $v.Note + "`nSwitch these off in the Telemetry tab, or use the one-click button on the Home screen."
            Add-Finding 'Brand & hardware software' 'Medium' "$($v.Name): $($open.Count) background item(s) still switched on" $detail
        } else {
            Add-Finding 'Brand & hardware software' 'Info' "$($v.Name): background tracking is already switched off" $v.Note
        }
        if ($v.Junk.Count) {
            $detail = (($v.Junk | ForEach-Object { "- $($_.Name): $($_.Why)" }) -join "`n") + "`nThese are ordinary programs. Quietpane only removes one if you ask it to, and removing cannot be undone."
            Add-Finding 'Brand & hardware software' 'Info' "$($v.Name): $($v.Junk.Count) extra program(s) you could remove" $detail
        }
    }

    # ---- 11. Performance snapshot
    if (Test-QpCancelled) { return (New-Stopped) }
    Write-Step 12 'Taking a performance snapshot'
    Write-QpLog 'Taking a performance snapshot...' 'INFO'
    $os = Get-CimInstance Win32_OperatingSystem
    $usedGB = ($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1MB
    $top = Get-Process | Group-Object ProcessName | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Count = $_.Count; MB = [math]::Round((($_.Group | Measure-Object WorkingSet64 -Sum).Sum) / 1MB) } } | Sort-Object MB -Descending | Select-Object -First 12
    Add-Finding 'Performance' 'Info' ("RAM in use: {0:N1} of {1:N1} GB, {2} processes, {3} program(s) start at sign-in" -f $usedGB, ($os.TotalVisibleMemorySize / 1MB), @(Get-Process).Count, $startupOn) ((($top | ForEach-Object { '{0,6} MB  {1} (x{2})' -f $_.MB, $_.Name, $_.Count }) -join "`n") + ("`n{0} startup entries in total; the rest are switched off in Task Manager or point to programs that no longer exist." -f $startupTotal))

    # ---- 12. Disk space
    if (Test-QpCancelled) { return (New-Stopped) }
    Write-Step 13 'Measuring space you could free up'
    Write-QpLog 'Measuring reclaimable space...' 'INFO'
    $targets = @(Get-QpCleanupTargets | Where-Object SizeBytes -gt 0)
    if ($targets.Count) { Add-Finding 'Disk space' 'Info' ("Reclaimable with the Clean-up tab: about {0}" -f (Format-QpBytes (($targets | Measure-Object SizeBytes -Sum).Sum))) (($targets | ForEach-Object { '{0,10}  {1}' -f (Format-QpBytes $_.SizeBytes), $_.Title }) -join "`n") }
    if (Test-Path 'C:\Windows.old') { Add-Finding 'Disk space' 'Info' 'C:\Windows.old exists (previous Windows version)' 'Remove it with Settings > System > Storage > Temporary files > "Previous Windows installation(s)".' }

    # ---- 13. Possibly leftover folders
    if (Test-QpCancelled) { return (New-Stopped) }
    Write-Step 14 'Looking for folders left behind'
    Write-QpLog 'Looking for folders left behind by uninstalled programs...' 'INFO'
    $cutoff = (Get-Date).AddDays(-180)
    $old = foreach ($r in @($env:LOCALAPPDATA, $env:APPDATA, (Join-Path $env:USERPROFILE 'AppData\LocalLow'), $env:ProgramData)) {
        if (Test-QpCancelled) { $abort = $true; break }
        Write-Step 14 'Looking for folders left behind' $r
        Get-ChildItem -Path $r -Directory -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff -and $_.CreationTime -lt $cutoff -and $_.Name -notmatch '^(Microsoft|Packages|Temp|Comms|ConnectedDevicesPlatform|Programs|Application Data|History|Temporary Internet Files|Package Cache|USOPrivate|USOShared|ssh|regid\..*|Desktop|Documents|Start Menu|Templates|Favorites|VirtualStore|Publishers|PlaceholderTileLogoFolder)$' } |
            ForEach-Object {
                $dir = $_
                $scanned++
                # A folder's own date doesn't change when files inside it change, so look inside too.
                # Stop at the first recent item - a folder with anything changed in the last 6 months is still in use.
                $recent = Get-ChildItem -LiteralPath $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -ge $cutoff -or $_.CreationTime -ge $cutoff } | Select-Object -First 1
                if (-not $recent) {
                    $newest = Get-ChildItem -LiteralPath $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                    $last = if ($newest -and $newest.LastWriteTime -gt $dir.LastWriteTime) { $newest.LastWriteTime } else { $dir.LastWriteTime }
                    [pscustomobject]@{ Path = $dir.FullName; Last = $last; Size = (Get-QpSize @($dir.FullName)) }
                }
            }
    }
    $old = @($old | Sort-Object Size -Descending | Select-Object -First 30)
    if ($old.Count) { Add-Finding 'Disk space' 'Info' 'Folders where nothing has changed for 6+ months (review before deleting - may belong to uninstalled programs)' ((($old | ForEach-Object { '{0,10}  {1:yyyy-MM-dd}  {2}' -f (Format-QpBytes $_.Size), $_.Last, $_.Path }) -join "`n") + "`nThe date is the last time anything inside the folder changed. Check what a folder belongs to before deleting it - some apps you still use rarely write to their folders.") }

    # ---- Report
    if ($abort) { return (New-Stopped) }
    $counts = [ordered]@{}
    foreach ($s in 'Critical', 'High', 'Medium', 'Low', 'Info') { $counts[$s] = @($findings | Where-Object { $_.Severity -eq $s }).Count }
    $high = $counts['High']; $med = $counts['Medium']
    $html = New-QpReportHtml -Findings $findings -Counts $counts -IsAdmin $isAdmin -Scanned $scanned
    try {
        $dir = Split-Path -Path $OutFile -Parent
        if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Set-Content -Path $OutFile -Value $html -Encoding UTF8 -ErrorAction Stop
    } catch {
        $OutFile = Join-Path $env:TEMP ("Quietpane-Report-{0}.html" -f (Get-QpStamp 'yyyyMMdd-HHmm'))
        Set-Content -Path $OutFile -Value $html -Encoding UTF8
        Write-QpLog "Could not save the report to the chosen location - saved to $OutFile instead" 'WARN'
    }
    Write-QpLog ("Check finished: {0:N0} things looked at, {1} critical, {2} high, {3} medium, {4} low, {5} for information. Report: {6}" -f $scanned, $counts['Critical'], $counts['High'], $counts['Medium'], $counts['Low'], $counts['Info'], $OutFile) 'OK'
    [pscustomobject]@{
        Critical = $counts['Critical']; High = $high; Medium = $med; Low = $counts['Low']; Info = $counts['Info']
        Counts = $counts; Total = @($findings).Count
        Findings = @($findings)
        Defender = $defender
        Report = $OutFile
        Scanned = $scanned; Seconds = [int]$sw.Elapsed.TotalSeconds; Cancelled = $false
    }
}

function New-QpDonutSvg {
    <#
        The severity doughnut, drawn as plain inline SVG: no scripts, no fonts, no network.
        Every segment is also written out in the legend, so the picture never carries meaning on its own.
    #>
    param([hashtable]$Counts, [hashtable]$Colours)
    $order = @('Critical', 'High', 'Medium', 'Low', 'Info')
    $total = 0; foreach ($s in $order) { $total += [int]$Counts[$s] }
    $cx = 90; $cy = 90; $r = 68; $w = 26
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<svg viewBox="0 0 180 180" width="180" height="180" role="img" aria-label="Findings by severity">')
    [void]$sb.Append(('<circle cx="{0}" cy="{1}" r="{2}" fill="none" stroke="{3}" stroke-width="{4}"/>' -f $cx, $cy, $r, '#e6dfcc', $w))
    if ($total -gt 0) {
        $angle = -90.0
        foreach ($s in $order) {
            $n = [int]$Counts[$s]
            if ($n -le 0) { continue }
            $sweep = 360.0 * $n / $total
            # a full circle cannot be drawn as one arc, so draw it as a ring
            if ([Math]::Abs($sweep - 360) -lt 0.01) {
                [void]$sb.Append(('<circle cx="{0}" cy="{1}" r="{2}" fill="none" stroke="{3}" stroke-width="{4}"/>' -f $cx, $cy, $r, $Colours[$s], $w))
                break
            }
            $a1 = $angle * [Math]::PI / 180.0
            $a2 = ($angle + $sweep) * [Math]::PI / 180.0
            $x1 = $cx + $r * [Math]::Cos($a1); $y1 = $cy + $r * [Math]::Sin($a1)
            $x2 = $cx + $r * [Math]::Cos($a2); $y2 = $cy + $r * [Math]::Sin($a2)
            $large = if ($sweep -gt 180) { 1 } else { 0 }
            [void]$sb.Append(('<path d="M {0:F2} {1:F2} A {2} {2} 0 {3} 1 {4:F2} {5:F2}" fill="none" stroke="{6}" stroke-width="{7}"><title>{8}: {9}</title></path>' -f $x1, $y1, $r, $large, $x2, $y2, $Colours[$s], $w, $s, $n))
            $angle += $sweep
        }
    }
    [void]$sb.Append(('<text x="{0}" y="{1}" text-anchor="middle" font-size="34" font-weight="700" fill="currentColor">{2}</text>' -f $cx, ($cy + 4), $total))
    [void]$sb.Append(('<text x="{0}" y="{1}" text-anchor="middle" font-size="12" fill="currentColor" opacity="0.75">{2}</text>' -f $cx, ($cy + 24), $(if ($total -eq 1) { 'finding' } else { 'findings' })))
    [void]$sb.Append('</svg>')
    return $sb.ToString()
}

function New-QpSessionReportHtml {
    <#
        A session written up as one page you can keep, open offline, or send to whoever is asking why
        the PC is slow. Same rules as the scan report: no scripts, no fonts or pictures from the
        internet, and nothing in it that Quietpane did not measure on this PC.
    #>
    param([Parameter(Mandatory)]$Watch, $Summary = $null, $Steady = $null, $Now = $null)
    if (-not $Now) { $Now = Get-Date }
    if (-not $Summary) { $Summary = Get-QpSessionSummary -Watch $Watch -Now $Now }
    $enc = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
    $logoPath = Join-Path $script:AssetsRoot 'komodoworks-logo.png'
    $logo = if (Test-Path $logoPath) { 'data:image/png;base64,' + [Convert]::ToBase64String([IO.File]::ReadAllBytes($logoPath)) } else { '' }
    $started = [datetime]$Watch.Started
    $ended = if ($Watch.Ended) { [datetime]$Watch.Ended } else { $Now }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append(@"
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="referrer" content="no-referrer">
<title>Quietpane session</title>
<style>
$($script:ReportCss)
.sum{display:flex;gap:12px;flex-wrap:wrap;margin-bottom:24px}.pill{background:var(--card);border:1px solid var(--line);padding:10px 16px;min-width:130px}
.pill b{font:600 24px/1.2 "Fraunces",Georgia,serif;display:block}.pill span{font-size:13px;color:var(--muted)}
.head{background:var(--card);border:1px solid var(--line);border-left:4px solid var(--teal);padding:12px 16px;margin-bottom:18px;font-size:17px}
.a{background:var(--card);border:1px solid var(--line);border-left:4px solid var(--med);padding:10px 14px;margin:8px 0}
.a.high{border-left-color:var(--high)}
ul.plain{list-style:none;margin:0;padding:0}ul.plain li{padding:4px 0;border-bottom:1px solid var(--line)}
table{border-collapse:collapse;width:100%;background:var(--card);border:1px solid var(--line)}
th,td{text-align:left;padding:8px 12px;border-bottom:1px solid var(--line);font-size:14px}
th{color:var(--muted);font-weight:600;width:52%}
svg.tl{display:block;margin-top:4px;shape-rendering:crispEdges}
.tlax{display:flex;justify-content:space-between;color:var(--muted);font-size:12px;margin-top:3px}
ul.key{list-style:none;display:flex;flex-wrap:wrap;gap:16px;margin:10px 0 0;padding:0;font-size:13px;color:var(--muted)}
ul.key li{display:flex;align-items:center;gap:6px}
ul.key i{width:12px;height:12px;display:inline-block}
/* One hue in steps, checked against the card it sits on. Dark mode has its own steps, not a flip. */
.b-quiet{fill:#CFAB60}.b-hot{fill:#AB7409}.b-veryhot{fill:#5E3A03}.b-held{fill:#7B1D1D}
.k-quiet{background:#CFAB60}.k-hot{background:#AB7409}.k-veryhot{background:#5E3A03}.k-held{background:#7B1D1D}
.k-none{border:1px solid var(--line)}
@media (prefers-color-scheme:dark){
.b-quiet{fill:#6E5726}.b-hot{fill:#C58A1A}.b-veryhot{fill:#EFC05A}.b-held{fill:#FF7B7B}
.k-quiet{background:#6E5726}.k-hot{background:#C58A1A}.k-veryhot{background:#EFC05A}.k-held{background:#FF7B7B}
}
</style></head><body>
<header class="brand"><div class="wrap row">
$(if ($logo) { '<img src="' + $logo + '" alt="">' })
<div><h1>Your session</h1><p class="by">Quietpane $($script:AppVersion) &middot; Developed by <a href="$($script:Brand.Url)" rel="noopener noreferrer">KomodoWorks.com</a></p></div>
</div></header><main><div class="wrap">
<p class="meta">From $(& $enc (Get-QpStamp 'd MMMM yyyy, HH:mm' $started)) to $(& $enc (Get-QpStamp 'HH:mm' $ended)) &middot; $(& $enc (Format-QpSpan $Summary.Seconds)) &middot; $($Watch.Samples) readings</p>
<div class="head">$(& $enc $Summary.Headline)</div>
"@)
    # The session drawn end to end, as one strip of colour with the words beside it. Inline SVG, so it
    # needs nothing from the internet and nothing runs.
    $bands = @(Get-QpSessionBands -Watch $Watch -Columns 188 -Now $Now)
    if ($bands.Count) {
        # Colour by CSS class, never a fixed fill: dark mode gets its own steps, chosen for the dark
        # card rather than flipped, and a light cream "nothing here" would shout on a dark page.
        $heights = @{ quiet = 10; hot = 19; veryhot = 28; gap = 0 }
        $cell = 5; $band = 28; $heldRow = 6; $height = $band + 3 + $heldRow
        $width = $bands.Count * $cell
        $anyHeld = @($bands | Where-Object { $_.Held }).Count -gt 0
        [void]$sb.Append('<h2>The session, start to finish</h2>')
        [void]$sb.Append('<svg class="tl" viewBox="0 0 ' + $width + ' ' + $height + '" width="100%" height="' + $height + '" role="img" aria-label="' + (& $enc ('How hot the PC was from {0} to {1}, and when it was held back to cool off' -f (Get-QpStamp 'HH:mm' $started), (Get-QpStamp 'HH:mm' $ended))) + '">')
        foreach ($b in $bands) {
            $h = $heights[[string]$b.Heat]
            if ($h -gt 0) { [void]$sb.Append('<rect class="b-' + $b.Heat + '" x="' + ($b.Index * $cell) + '" y="' + ($band - $h) + '" width="' + $cell + '" height="' + $h + '"/>') }
            if ($b.Held) { [void]$sb.Append('<rect class="b-held" x="' + ($b.Index * $cell) + '" y="' + ($band + 3) + '" width="' + $cell + '" height="' + $heldRow + '"/>') }
        }
        [void]$sb.Append('</svg>')
        [void]$sb.Append('<div class="tlax"><span>' + (& $enc (Get-QpStamp 'HH:mm' $started)) + '</span><span>' + (& $enc (Get-QpStamp 'HH:mm' $ended)) + '</span></div>')
        $seen = @($bands | ForEach-Object { $_.Heat } | Select-Object -Unique)
        [void]$sb.Append('<ul class="key">')
        foreach ($state in 'veryhot', 'hot', 'quiet', 'gap') {
            if ($seen -notcontains $state) { continue }
            $word = @($bands | Where-Object { $_.Heat -eq $state })[0].Word
            # "Not watched" is drawn as nothing at all, so its key is an outline, not a colour.
            $cls = if ($state -eq 'gap') { 'k-none' } else { 'k-' + $state }
            [void]$sb.Append('<li><i class="' + $cls + '"></i>' + (& $enc $word) + '</li>')
        }
        if ($anyHeld) { [void]$sb.Append('<li><i class="k-held"></i>held back to cool off</li>') }
        [void]$sb.Append('</ul>')
    }

    # The pills: only what this PC actually reported.
    $pills = New-Object System.Collections.ArrayList
    if ($null -ne $Watch.PeakCpuTempC) { [void]$pills.Add(((Format-QpTemp $Watch.PeakCpuTempC) + '|hottest the processor got')) }
    if ($null -ne $Watch.PeakGpuTempC) { [void]$pills.Add(((Format-QpTemp $Watch.PeakGpuTempC) + '|hottest graphics got')) }
    if ($null -ne $Watch.PeakCpu) { [void]$pills.Add(('{0:N0}%|busiest the processor got' -f $Watch.PeakCpu)) }
    if ($null -ne $Watch.PeakMemUsed) { [void]$pills.Add(('{0}|most memory in use' -f (Format-QpBytes $Watch.PeakMemUsed))) }
    if ($null -ne $Watch.PeakCommitPct) { [void]$pills.Add(('{0:N0}%|most memory promised' -f $Watch.PeakCommitPct)) }
    if ($null -ne $Watch.PeakDiskBusy) { [void]$pills.Add(('{0:N0}%|busiest the drive got' -f $Watch.PeakDiskBusy)) }
    if ($pills.Count) {
        [void]$sb.Append('<div class="sum">')
        foreach ($p in $pills) {
            $parts = $p -split '\|'
            [void]$sb.Append('<div class="pill"><b>' + (& $enc $parts[0]) + '</b><span>' + (& $enc $parts[1]) + '</span></div>')
        }
        [void]$sb.Append('</div>')
    }

    $alerts = @($Watch.Alerts | Where-Object { $_ })
    if ($alerts.Count) {
        [void]$sb.Append('<h2>What it spoke up about</h2>')
        foreach ($a in $alerts) {
            $cls = if ($a.Level -eq 'high') { 'a high' } else { 'a' }
            [void]$sb.Append('<div class="' + $cls + '"><b>' + (& $enc (Get-QpStamp 'HH:mm' $a.At)) + '</b> &middot; ' + (& $enc $a.Text) + '</div>')
        }
    }

    [void]$sb.Append('<h2>The session</h2><ul class="plain">')
    foreach ($line in @($Summary.Lines)) { [void]$sb.Append('<li>' + (& $enc $line) + '</li>') }
    [void]$sb.Append('</ul>')

    # How long it spent in each state, and what was at the top while it did.
    $rows = New-Object System.Collections.ArrayList
    [void]$rows.Add(('Watched, with readings|{0}' -f (Format-QpSpan $Watch.WatchedSeconds)))
    if ($Watch.HotSeconds -ge 1) { [void]$rows.Add(('Hot or hotter|{0}' -f (Format-QpSpan $Watch.HotSeconds))) }
    if ($Watch.VeryHotSeconds -ge 1) { [void]$rows.Add(('Very hot|{0}' -f (Format-QpSpan $Watch.VeryHotSeconds))) }
    if ($Watch.HeldBackSeconds -ge 1) { [void]$rows.Add(('Held back to cool off|{0}, over {1} spell(s)' -f (Format-QpSpan $Watch.HeldBackSeconds), $Watch.HeldBackSpells)) }
    if ($null -ne $Watch.SlowestWhenBusyPct) { [void]$rows.Add(('Least speed it was allowed while busy|{0:N0}%' -f $Watch.SlowestWhenBusyPct)) }
    if ($Watch.Gaps -gt 0) { [void]$rows.Add(('Not watched - asleep, or Quietpane was busy|{0}, over {1} stretch(es)' -f (Format-QpSpan $Watch.GapSeconds), $Watch.Gaps)) }
    if ($null -ne $Watch.BatteryStart -and $null -ne $Watch.BatteryEnd) { [void]$rows.Add(('Battery|{0}% to {1}%' -f $Watch.BatteryStart, $Watch.BatteryEnd)) }
    if ($null -ne $Watch.PeakWatts) { [void]$rows.Add(('Most the battery gave out|{0:N1} W' -f $Watch.PeakWatts)) }
    [void]$sb.Append('<h2>Where the time went</h2><table>')
    foreach ($r in $rows) {
        $parts = $r -split '\|'
        [void]$sb.Append('<tr><th>' + (& $enc $parts[0]) + '</th><td>' + (& $enc $parts[1]) + '</td></tr>')
    }
    [void]$sb.Append('</table>')

    $busy = @($Watch.Busy.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 8)
    if ($busy.Count) {
        [void]$sb.Append('<h2>Busiest, and for how long</h2><table>')
        foreach ($b in $busy) { [void]$sb.Append('<tr><th>' + (& $enc $b.Key) + '</th><td>' + (& $enc (Format-QpSpan ([double]$b.Value))) + ' at the top</td></tr>') }
        [void]$sb.Append('</table><p class="meta2">Whoever was using the processor most at each reading. It says who was at the top, not how much work each one did.</p>')
    }

    if ($Steady -and $Steady.Available) {
        [void]$sb.Append('<h2>How this PC has been holding up</h2><table>')
        if ($null -ne $Steady.Score) { [void]$sb.Append('<tr><th>Windows'' own score</th><td>' + ('{0:N1} out of 10, {1}' -f $Steady.Score, (& $enc $Steady.Word)) + '</td></tr>') }
        [void]$sb.Append('<tr><th>Stopped working in the last ' + $Steady.Days + ' days</th><td>' + ([int]$Steady.Crashes + [int]$Steady.Hangs) + '</td></tr>')
        [void]$sb.Append('<tr><th>Stopped without warning</th><td>' + [int]$Steady.SuddenStops + '</td></tr>')
        [void]$sb.Append('</table>')
    }

    [void]$sb.Append(('<footer>Peaks, never averages: an average hides the moment a PC chokes. Where the readings stop, the report says so rather than drawing a line through the gap. Heat is Windows'' own reading and what the graphics driver shares.<br>This report was made on this PC and was not sent anywhere. It describes your PC, so have a look before sharing it.<br>Quietpane {0} &middot; free and open source (MIT) &middot; Developed by <a href="{1}" rel="noopener noreferrer">KomodoWorks.com</a> &middot; <a href="mailto:{2}">{2}</a></footer></div></main></body></html>' -f $script:AppVersion, $script:Brand.Url, $script:Brand.Email))
    return $sb.ToString()
}

function Save-QpSessionReport {
    <# Writes the session report where you can find it: your Desktop, dated. Returns the path. #>
    param([Parameter(Mandatory)]$Watch, $Summary = $null, $Steady = $null, [string]$OutFile = '')
    if (-not $OutFile) {
        $OutFile = Join-Path ([Environment]::GetFolderPath('Desktop')) ('Quietpane-Session-{0}.html' -f (Get-QpStamp 'yyyyMMdd-HHmm'))
    }
    $html = New-QpSessionReportHtml -Watch $Watch -Summary $Summary -Steady $Steady
    $dir = Split-Path -Path $OutFile -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($OutFile, $html, (New-Object Text.UTF8Encoding($false)))
    Write-QpLog "Session report saved to $OutFile" 'OK'
    return $OutFile
}

# The look every report shares, kept in one place so the scan report and the session report cannot
# drift apart. No web fonts and no stylesheets from the internet: a report opens the same offline.
$script:ReportCss = @'
:root{--bg:#faf6ec;--card:#fffdf8;--text:#0f1b1c;--muted:#4b5b5c;--line:#e6dfcc;--anchor:#0f1b1c;--accent:#ffb627;--teal:#117a68;--crit:#7b1d1d;--high:#a83232;--med:#9a6700;--low:#4b5b5c;--info:#117a68}
@media (prefers-color-scheme:dark){:root{--bg:#0f1b1c;--card:#162627;--text:#faf6ec;--muted:#a9b5b3;--line:#22393a;--teal:#1fa187;--crit:#ff7b7b;--high:#e06666;--med:#ffb627;--low:#a9b5b3;--info:#1fa187}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:15px/1.55 "Sora","Segoe UI",system-ui,sans-serif}
header.brand{background:var(--anchor);color:#faf6ec;padding:18px 16px}
.wrap{max-width:980px;margin:0 auto}.row{display:flex;align-items:center;gap:14px;flex-wrap:wrap}
.row img{width:48px;height:48px;display:block}
h1{font:600 26px/1.2 "Fraunces",Georgia,"Times New Roman",serif;margin:0}
.by{margin:2px 0 0;font-size:13px;color:#d9d3c4}.by a{color:var(--accent);text-decoration:none;font-weight:600}.by a:hover{text-decoration:underline}
main{padding:24px 16px}p.meta{color:var(--muted);margin:0 0 20px}
h2{font:600 19px/1.3 "Fraunces",Georgia,serif;margin:28px 0 8px;color:var(--teal)}
.meta2{color:var(--muted);font-size:13px;margin:4px 0 0}.meta2 b{color:var(--text)}
pre{white-space:pre-wrap;word-break:break-all;margin:6px 0 0;color:var(--muted);font:13px/1.45 Consolas,monospace}
footer{border-top:1px solid var(--line);margin-top:32px;padding:16px 0;color:var(--muted);font-size:13px}footer a{color:var(--teal)}
'@

function New-QpReportHtml {
    param($Findings, [System.Collections.IDictionary]$Counts, [bool]$IsAdmin, [int]$Scanned = 0)
    $enc = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
    # The logo is embedded as a data URI so the report makes no network requests at all
    # (no web fonts, no CDNs, no images from the internet).
    $logoPath = Join-Path $script:AssetsRoot 'komodoworks-logo.png'
    $logo = if (Test-Path $logoPath) { 'data:image/png;base64,' + [Convert]::ToBase64String([IO.File]::ReadAllBytes($logoPath)) } else { '' }
    $brandUrl = $script:Brand.Url
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append(@"
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="referrer" content="no-referrer">
<title>Quietpane report</title>
<style>
$($script:ReportCss)
.sum{display:flex;gap:12px;flex-wrap:wrap;margin-bottom:24px}.pill{background:var(--card);border:1px solid var(--line);padding:10px 16px;min-width:110px}
.pill b{font:600 24px/1.2 "Fraunces",Georgia,serif;display:block}
.f{background:var(--card);border:1px solid var(--line);border-left:4px solid var(--info);padding:10px 14px;margin:8px 0}
.f.Critical{border-left-color:var(--crit)}.f.High{border-left-color:var(--high)}.f.Medium{border-left-color:var(--med)}.f.Low{border-left-color:var(--low)}
.sev{font-size:12px;font-weight:700;text-transform:uppercase;letter-spacing:.04em;margin-right:8px}
.Critical .sev{color:var(--crit)}.High .sev{color:var(--high)}.Medium .sev{color:var(--med)}.Low .sev{color:var(--low)}.Info .sev{color:var(--info)}
.chart{display:flex;gap:24px;align-items:center;flex-wrap:wrap;background:var(--card);border:1px solid var(--line);padding:16px;margin-bottom:24px}
.legend{list-style:none;margin:0;padding:0;min-width:230px}
.legend li{display:flex;align-items:center;gap:10px;padding:3px 0;font-size:14px}
.legend .k{width:14px;height:14px;flex:0 0 14px;display:inline-block;border:1px solid rgba(0,0,0,.15)}
.legend .n{margin-left:auto;font-weight:700}.legend li.zero{opacity:.45}
</style></head><body>
<header class="brand"><div class="wrap row">
"@)
    if ($logo) { [void]$sb.Append(('<img src="{0}" alt="KomodoWorks emblem">' -f $logo)) }
    [void]$sb.Append(('<div><h1>Quietpane &ndash; scan report</h1><p class="by">Developed by <a href="{0}" rel="noopener noreferrer">KomodoWorks.com</a></p></div></div></header><main><div class="wrap">' -f $brandUrl))
    $adminNote = if (-not $IsAdmin) { ' &middot; run as administrator for the full scan' } else { '' }
    $lookedAt = if ($Scanned -gt 0) { ' &middot; {0:N0} things looked at' -f $Scanned } else { '' }
    [void]$sb.Append(('<p class="meta">{0} &middot; version {1} &middot; read-only scan, nothing was changed{2}{3}</p>' -f (Get-QpStamp 'yyyy-MM-dd HH:mm'), $script:AppVersion, $lookedAt, $adminNote))
    # Severity doughnut plus a written legend: the chart never carries meaning through colour alone.
    $colours = @{ Critical = '#7b1d1d'; High = '#a83232'; Medium = '#9a6700'; Low = '#6e695c'; Info = '#117a68' }   # all pass WCAG AA under white text
    $meaning = @{ Critical = 'act now'; High = 'act on it'; Medium = 'worth a look'; Low = 'minor'; Info = 'just so you know' }
    $plain = @{}
    foreach ($s in 'Critical', 'High', 'Medium', 'Low', 'Info') { $plain[$s] = [int]$Counts[$s] }
    [void]$sb.Append('<div class="chart">' + (New-QpDonutSvg -Counts $plain -Colours $colours) + '<ul class="legend">')
    foreach ($s in 'Critical', 'High', 'Medium', 'Low', 'Info') {
        $cls = if ($plain[$s] -eq 0) { ' class="zero"' } else { '' }
        [void]$sb.Append(('<li{0}><span class="k" style="background:{1}"></span>{2} <span style="color:var(--muted)">- {3}</span><span class="n">{4}</span></li>' -f $cls, $colours[$s], $s, $meaning[$s], $plain[$s]))
    }
    [void]$sb.Append('</ul></div>')
    $order = @{ Critical = 0; High = 1; Medium = 2; Low = 3; Info = 4 }
    foreach ($g in ($Findings | Group-Object Section | Sort-Object { ($_.Group | ForEach-Object { $order[$_.Severity] } | Measure-Object -Minimum).Minimum })) {
        [void]$sb.Append("<h2>$(& $enc $g.Name)</h2>")
        foreach ($f in ($g.Group | Sort-Object { $order[$_.Severity] })) {
            $line = '<div class="f {0}"><span class="sev">{0}</span>{1}' -f $f.Severity, (& $enc $f.Title)
            # Findings that came from Defender carry extra facts worth printing.
            if ($f.Source -and $f.Source -ne 'Quietpane check') {
                $bits = @("found by <b>$(& $enc $f.Source)</b>", "confidence: <b>$(& $enc $f.Confidence)</b>", "status: <b>$(& $enc $f.Status)</b>")
                if ($f.Category) { $bits += 'type: <b>' + (& $enc $f.Category) + '</b>' }
                $line += '<p class="meta2">' + ($bits -join ' &middot; ') + '</p>'
                if ($f.What) { $line += '<p class="meta2">' + (& $enc $f.What) + '</p>' }
                if ($f.Why) { $line += '<p class="meta2">' + (& $enc $f.Why) + '</p>' }
                if ($f.Recommended) { $line += '<p class="meta2">What to do: <b>' + (& $enc $f.Recommended) + '</b></p>' }
                if ($f.Path) { $line += '<p class="meta2">Where: ' + (& $enc $f.Path) + '</p>' }
                if ($f.Sha256) { $line += '<p class="meta2">SHA256: ' + (& $enc $f.Sha256) + '</p>' }
            }
            if ($f.Detail) { $line += '<pre>' + (& $enc $f.Detail) + '</pre>' }
            [void]$sb.Append($line + '</div>')
        }
    }
    [void]$sb.Append(('<footer>Critical = act now &middot; High = act on it &middot; Medium = worth a look &middot; Low = minor &middot; Info = just so you know.<br>Threat names come from Microsoft Defender. Quietpane''s own checks are marked as such and are signals, not proof.<br>This report was created on this PC and was not sent anywhere. It describes your PC, so review it before sharing it with anyone.<br><b>A good start, not a guarantee.</b> This check looks at the places problems usually hide, but it cannot promise a PC is clean. If yours still feels wrong, run a deeper scan with a dedicated security tool as well.<br>Quietpane {0} &middot; free and open source (MIT) &middot; Developed by <a href="{1}" rel="noopener noreferrer">KomodoWorks.com</a> &middot; <a href="mailto:{2}">{2}</a></footer></div></main></body></html>' -f $script:AppVersion, $brandUrl, $script:Brand.Email))
    return $sb.ToString()
}

#endregion

Export-ModuleMember -Function Get-QpInfo, Set-QpLogSink, Write-QpLog, Test-QpAdmin, Get-QpCatalog, Format-QpBytes, Format-QpRate,
    Set-QpProgressSink, Write-QpProgress, Set-QpCancelCheck, Test-QpCancelled, New-QpScanSummary,
    Get-QpState, Get-QpSystemUsage, Get-QpTotals, New-QpLiveMonitor, Get-QpLiveReading, Get-QpHeatWord, Get-QpTempUnit, Set-QpTempUnit, Format-QpTemp, Get-QpLiveVerdict, Get-QpSystemFacts, ConvertTo-QpSystemFacts, ConvertFrom-QpPowerCfg,
    Select-QpNetworkCards, ConvertTo-QpCounterInstance, Get-QpNetRates, Get-QpProgramName,
    New-QpCounter, New-QpCounterGroup,
    New-QpSessionWatch, Add-QpSessionSample, Stop-QpSessionWatch, Get-QpSessionSummary, Format-QpSpan,
    Update-QpSessionAlerts, Get-QpReliability, New-QpSessionReportHtml, Save-QpSessionReport, Get-QpSessionBands,
    Get-QpBatteryHealth, Get-QpDriveHealth, Get-QpWindowsVersion, Get-QpQuietSnapshot, Update-QpQuietNote, Invoke-QpPutBack,
    Get-QpRestorePoints, Invoke-QpUndo,
    Get-QpPrivacyStatus, Invoke-QpPrivacy,
    Get-QpBloatApps, Invoke-QpRemoveApps,
    Get-QpStartupItems, Invoke-QpStartup, Set-QpStartupApproved, Get-QpStartupAdvice,
    Get-QpSignInTime, Get-QpBootRecord, Get-QpSignInCost, Format-QpSignInCost,
    Get-QpDeviceUse, Invoke-QpDeviceAccess, Format-QpWhen,
    Get-QpBrowserExtensions, Get-QpChromiumExtensions, Get-QpFirefoxAddons, Get-QpExtensionReach, Format-QpExtensionUse,
    Get-QpExtensionBlocks, Get-QpExtensionSlot, Invoke-QpExtension, ConvertFrom-QpChromeTime,
    Get-QpCleanupTargets, Invoke-QpCleanup, Get-QpRecycleBinLimit, Move-QpToRecycleBin,
    Get-QpSpaceUse, Get-QpSpaceAdvice, Invoke-QpSpaceRecycle, Get-QpInstallPlaces,
    Get-QpOldFiles, Get-QpEasyWins, Invoke-QpEasyWin,
    Get-QpShortcutPaths, Test-QpShortcuts, New-QpShortcuts, Remove-QpShortcuts, Initialize-QpShortcut, Get-QpOwnShortcuts,
    Install-QpCopy, Remove-QpCopy, Start-QpCopyRemoval, Get-QpAppVersion, Compare-QpVersion, Test-QpCopyMatches, Sync-QpInstall,
    Get-QpDownloadsFolder, Get-QpZipVersion, Find-QpDownloadedUpdate, Expand-QpUpdate, Get-QpNewerInstalledCopy,
    Get-QpSignInTask, Test-QpSignInStart, Enable-QpSignInStart, Disable-QpSignInStart, Test-QpOwnSignInTask, New-QpSignInTask, Get-QpSignInAction,
    Test-QpSignInWatch, Test-QpTaskWatches,
    Get-QpConnections, Get-QpAddressLabel, Test-QpPrivateAddress,
    Get-QpVendorStatus, Invoke-QpVendor, Invoke-QpVendorUninstall, Split-QpUninstallCommand,
    Get-QpRegValue, Get-QpTasksByPath, Get-QpTasksMatching, Get-QpStamp, Split-QpFindingDetail,
    Get-QpDefenderState, Get-QpDefenderFindings, Invoke-QpThreatScan, Invoke-QpRemediate, Get-QpAllowList, Resolve-QpThreatInfo, New-QpFinding,
    New-QpDonutSvg, New-QpReportHtml, Get-QpFileHash,
    Invoke-QpQuarantine, Get-QpQuarantineItems, Restore-QpQuarantineItem, Remove-QpQuarantineItem, Test-QpProtectedPath, Test-QpFindingStillTrue,
    Get-QpRecommendedPlan, Invoke-QpRecommended,
    Invoke-QpAudit
