# ============================================================================
#  LOOKING FOR HOW TO START Quietpane?  This file is the app's code.
#  Close this window, then double-click "Start Quietpane" instead.
# ============================================================================
#Requires -Version 5.1
<#
.SYNOPSIS
    Quietpane - privacy, telemetry, bloat and clutter clean-up for Windows 10/11.
    Developed by KomodoWorks - https://www.komodoworks.com - free and open source (MIT).

.DESCRIPTION
    Double-click "Start Quietpane" to open the app. From PowerShell:
        .\Quietpane.ps1                          open the app (asks for administrator rights)
        .\Quietpane.ps1 -Scan                    run only the read-only scan and open the HTML report
        .\Quietpane.ps1 -Minimized               open on the taskbar, out of the way (used at sign-in)
        .\Quietpane.ps1 -Minimized -Watch        the same, and check once for anything Windows switched
                                                 back on - the taskbar icon gets a badge if something did
        .\Quietpane.ps1 -SelfTest                build the window without showing it (used for testing)
        .\Quietpane.ps1 -SelfTest -Snapshot x.png -SnapshotTab 1
                                                 also render the window to an image (used for screenshots)

    Privacy: this app collects nothing and makes no network connections. See PRIVACY.md.
#>
param(
    [switch]$Scan,
    [switch]$Minimized,
    [switch]$Watch,
    [switch]$SelfTest,
    [string]$Snapshot,
    [int]$SnapshotTab = 0
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot 'src\Quietpane.psm1'

function Test-IsAdmin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ------------------------------------------------------------------ elevation
if (-not $SelfTest -and -not (Test-IsAdmin)) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$PSCommandPath`"")
    if ($Scan) { $argList += '-Scan' } else { $argList = @('-WindowStyle', 'Hidden') + $argList }
    if ($Minimized) { $argList += '-Minimized' }
    if ($Watch) { $argList += '-Watch' }
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList | Out-Null
    } catch {
        Write-Host 'Administrator rights are needed. Nothing was changed.' -ForegroundColor Yellow
        Start-Sleep -Seconds 3
    }
    exit
}

Import-Module $modulePath -Force
$info = Get-QpInfo

# One Quietpane at a time. Two copies could make changes at once and record them in two different
# restore points, so the second one brings the first to the front and steps aside.
$script:OnlyInstance = $null
if (-not $SelfTest -and -not $Scan) {
    $script:OnlyInstance = New-Object System.Threading.Mutex($false, 'Local\Quietpane-single-instance')
    if (-not $script:OnlyInstance.WaitOne(0, $false)) {
        $other = @(Get-Process powershell -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne $PID -and $_.MainWindowTitle -like 'Quietpane*' })[0]
        if ($other) { try { (New-Object -ComObject WScript.Shell).AppActivate($other.Id) | Out-Null } catch { } }
        exit
    }
}

function Open-AsUser([string]$Target) {
    # Opening through explorer.exe hands links and files to the normal (non-admin) desktop session,
    # so the browser or mail app does not run with administrator rights.
    Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$Target`""
}

# ------------------------------------------------------------------ scan-only mode
if ($Scan) {
    $host.UI.RawUI.WindowTitle = "Quietpane $($info.Version) - Developed by KomodoWorks.com"
    Write-Host ''
    Write-Host '  Quietpane - read-only scan' -ForegroundColor Yellow
    Write-Host '  Developed by KomodoWorks.com  |  free and open source  |  nothing leaves this PC' -ForegroundColor DarkCyan
    Write-Host ''
    # One line that says where it has got to, rewritten in place so the window stays tidy.
    Set-QpProgressSink {
        param($p)
        $text = '  Step {0} of {1}: {2}' -f $p.Step, $p.Of, $p.Stage
        if ($p.Object) { $text += " - $($p.Object)" }
        $text += ' ({0:N0} looked at)' -f $p.Scanned
        Write-Host ("`r" + $text.PadRight(112).Substring(0, 112)) -NoNewline -ForegroundColor DarkCyan
    }
    $result = @(Invoke-QpAudit)[-1]
    Write-Host ''
    if ($result) { Open-AsUser $result.Report }
    Write-Host ''
    Write-Host "  Questions or feedback: $($info.BrandUrl)  |  $($info.BrandEmail)" -ForegroundColor DarkCyan
    Read-Host '  Press Enter to close'
    exit
}

# ------------------------------------------------------------------ window
# The accessibility improvements .NET has added since 4.7.1 (screen readers hearing status changes,
# better keyboard focus, tooltips that also appear for the keyboard) are only on for apps that ask.
# PowerShell doesn't, so Quietpane asks here - before the window's code is loaded, or it's too late.
foreach ($switch in 'Switch.UseLegacyAccessibilityFeatures', 'Switch.UseLegacyAccessibilityFeatures.2',
                    'Switch.UseLegacyAccessibilityFeatures.3', 'Switch.UseLegacyToolTipDisplay') {
    try { [AppContext]::SetSwitch($switch, $false) } catch { }
}
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# Two things Windows has to be told before the first window exists, and neither changes anything on
# this PC. First: this app's own name, so the taskbar groups it on its own and shows the KomodoWorks
# emblem instead of PowerShell's icon. Second: that the window can draw at the screen's real
# resolution - without it Windows stretches the window on a scaled display, which looks blurry and
# can push the buttons off the bottom of a laptop screen.
if (-not $SelfTest) {
    try {
        Add-Type -Namespace Quietpane -Name Shell -MemberDefinition @'
[DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string appId);
[DllImport("user32.dll")] public static extern int SetProcessDPIAware();
'@
        [void][Quietpane.Shell]::SetCurrentProcessExplicitAppUserModelID($info.AppId)
        [void][Quietpane.Shell]::SetProcessDPIAware()
    } catch { }
}

# KomodoWorks palette (from komodoworks.com): bg #FAF6EC, anchor #0F1B1C, accent #FFB627,
# secondary #1FA187 / readable #117A68, error #A83232. Muted text is #66706F, the lightest grey that
# still passes WCAG AA (4.5:1) on the cream background. Headings Fraunces, body Sora
# (falls back to Georgia / Segoe UI when those fonts are not installed - no web fonts are downloaded).
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Quietpane - by KomodoWorks" Width="1100" Height="780" MinWidth="760" MinHeight="480"
        WindowStartupLocation="CenterScreen" Background="#FAF6EC" FontFamily="Sora, Segoe UI" Foreground="#0F1B1C">
  <Window.Resources>
    <SolidColorBrush x:Key="Anchor" Color="#0F1B1C"/>
    <SolidColorBrush x:Key="Accent" Color="#FFB627"/>
    <SolidColorBrush x:Key="Teal" Color="#117A68"/>
    <SolidColorBrush x:Key="Line" Color="#E6DFCC"/>
    <SolidColorBrush x:Key="Card" Color="#FFFDF8"/>

    <!-- Where the keyboard is: a clear teal outline, shown only while you use the keyboard. -->
    <Style x:Key="FocusRing">
      <Setter Property="Control.Template">
        <Setter.Value>
          <ControlTemplate>
            <Rectangle Margin="-4" Stroke="#117A68" StrokeThickness="2.5" RadiusX="3" RadiusY="3" SnapsToDevicePixels="True"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="FocusRingInset">
      <Setter Property="Control.Template">
        <Setter.Value>
          <ControlTemplate>
            <Rectangle Margin="2" Stroke="#117A68" StrokeThickness="2.5" SnapsToDevicePixels="True"/>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="FocusVisualStyle" Value="{StaticResource FocusRing}"/>
    </Style>
    <Style TargetType="Expander">
      <Setter Property="FocusVisualStyle" Value="{StaticResource FocusRing}"/>
    </Style>

    <Style TargetType="Button">
      <Setter Property="Foreground" Value="#0F1B1C"/>
      <Setter Property="Background" Value="#FFFDF8"/>
      <Setter Property="BorderBrush" Value="#0F1B1C"/>
      <Setter Property="BorderThickness" Value="1.5"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{StaticResource FocusRing}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" Padding="{TemplateBinding Padding}" SnapsToDevicePixels="True">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#EFE7D3"/></Trigger>
        <Trigger Property="IsPressed" Value="True"><Setter Property="Background" Value="#E6DCC3"/></Trigger>
        <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
      </Style.Triggers>
    </Style>

    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#FFB627"/>
      <Setter Property="BorderBrush" Value="#FFB627"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="Background" Value="#FFC75A"/></Trigger>
        <Trigger Property="IsPressed" Value="True"><Setter Property="Background" Value="#F0A416"/></Trigger>
      </Style.Triggers>
    </Style>

    <Style TargetType="TabItem">
      <Setter Property="Foreground" Value="#4B5B5C"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{StaticResource FocusRing}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="Bd" Background="Transparent" BorderBrush="Transparent" BorderThickness="0,0,0,3" Padding="14,9,14,7" Margin="0,0,2,0">
              <ContentPresenter ContentSource="Header" HorizontalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="#117A68"/>
                <Setter Property="Foreground" Value="#0F1B1C"/>
                <Setter Property="FontWeight" Value="SemiBold"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#EFE7D3"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="Hyperlink">
      <Setter Property="Foreground" Value="#FFB627"/>
      <Setter Property="TextDecorations" Value="None"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True"><Setter Property="TextDecorations" Value="Underline"/></Trigger>
        <Trigger Property="IsKeyboardFocused" Value="True"><Setter Property="TextDecorations" Value="Underline"/></Trigger>
      </Style.Triggers>
    </Style>
  </Window.Resources>

  <DockPanel>
    <!-- Header -->
    <Border DockPanel.Dock="Top" Background="#0F1B1C" Padding="20,12">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <Image x:Name="HeaderLogo" Width="48" Height="48" Margin="0,0,14,0" VerticalAlignment="Center" RenderOptions.BitmapScalingMode="HighQuality"
               AutomationProperties.Name="Quietpane emblem"/>
        <StackPanel Grid.Column="1" VerticalAlignment="Center">
          <TextBlock Text="Quietpane" Foreground="#FAF6EC" FontSize="25" FontWeight="SemiBold" FontFamily="Fraunces, Georgia"/>
          <TextBlock Foreground="#C9C2B0" FontSize="12.5" TextWrapping="Wrap" Margin="0,2,0,0"
                     Text="Switch off tracking, remove bloat, free up space. Nothing is collected and nothing leaves this PC."/>
        </StackPanel>
        <StackPanel Grid.Column="2" VerticalAlignment="Center" HorizontalAlignment="Right">
          <TextBlock HorizontalAlignment="Right" Foreground="#C9C2B0" FontSize="12.5">
            <Run Text="Developed by "/><Hyperlink x:Name="LinkHeader" FontWeight="SemiBold">KomodoWorks.com</Hyperlink>
          </TextBlock>
          <TextBlock HorizontalAlignment="Right" Foreground="#8FA3A0" FontSize="11.5" Margin="0,3,0,0" Text="Free - open source - no tracking"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- Brand strip (bottom edge) -->
    <Border DockPanel.Dock="Bottom" Background="#0F1B1C" Padding="16,6">
      <TextBlock HorizontalAlignment="Center" Foreground="#C9C2B0" FontSize="12">
        <Run Text="Developed by "/><Hyperlink x:Name="LinkFooter" FontWeight="SemiBold">KomodoWorks.com</Hyperlink>
        <Run Text="   |   "/><Hyperlink x:Name="LinkPrivacy">Privacy</Hyperlink>
        <Run Text="   |   "/><Hyperlink x:Name="LinkTerms">Terms</Hyperlink>
        <Run Text="   |   "/><Hyperlink x:Name="LinkContact">Contact</Hyperlink>
        <Run x:Name="VersionRun" Text="   |   v1.0.0   |   No data leaves this PC"/>
      </TextBlock>
    </Border>

    <!-- Action bar -->
    <Border DockPanel.Dock="Bottom" Background="#FFFDF8" BorderBrush="#E6DFCC" BorderThickness="0,1,0,0" Padding="16,10">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBlock x:Name="StatusLine" VerticalAlignment="Center" Foreground="#4B5B5C" TextTrimming="CharacterEllipsis"
                   AutomationProperties.LiveSetting="Polite">
          <Run x:Name="Status" Text="Starting..."/><Run Text="    "/><Hyperlink x:Name="LinkDetails" Foreground="#117A68">Show details</Hyperlink>
        </TextBlock>
        <StackPanel x:Name="AdvancedButtons" Grid.Column="1" Orientation="Horizontal">
          <Button x:Name="BtnRecommended" Content="Select recommended" Margin="0,0,8,0"/>
          <Button x:Name="BtnNone" Content="Select none" Margin="0,0,8,0"/>
          <Button x:Name="BtnPreview" Content="Preview (no changes)" Margin="0,0,8,0"/>
          <Button x:Name="BtnApply" Content="Apply selected" Style="{StaticResource Primary}" Padding="20,7"/>
        </StackPanel>
      </Grid>
    </Border>

    <!-- Content -->
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="*"/>
        <RowDefinition Height="6"/>
        <RowDefinition x:Name="LogRow" Height="0"/>
      </Grid.RowDefinitions>
      <TabControl x:Name="Tabs" Margin="14,12,14,4" Padding="0" Background="#FFFDF8" BorderBrush="#E6DFCC" BorderThickness="1"/>
      <GridSplitter x:Name="LogSplitter" Grid.Row="1" HorizontalAlignment="Stretch" Background="Transparent" Visibility="Collapsed"/>
      <TextBox x:Name="LogBox" Grid.Row="2" Margin="14,0,14,12" IsReadOnly="True" FontFamily="Consolas" FontSize="12"
               AutomationProperties.Name="Details: what Quietpane has done"
               VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" TextWrapping="NoWrap"
               Background="#0F1B1C" Foreground="#FAF6EC" BorderThickness="0" Padding="10,8"/>
    </Grid>
  </DockPanel>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))

# Fit the screen it actually opens on. On a small or scaled laptop display a fixed size would push
# the buttons along the bottom out of sight.
try {
    $work = [System.Windows.SystemParameters]::WorkArea
    if ($work.Width -gt 200 -and $window.Width -gt ($work.Width - 40)) { $window.Width = [math]::Max(760, $work.Width - 40) }
    if ($work.Height -gt 200 -and $window.Height -gt ($work.Height - 40)) { $window.Height = [math]::Max(480, $work.Height - 40) }
} catch { }

# Started at sign-in: wait on the taskbar without taking the focus, and do nothing until clicked.
if ($Minimized -and -not $SelfTest) { $window.WindowState = 'Minimized'; $window.ShowActivated = $false }

# A mistake inside the window must never take the whole app down with it: say what happened, write it
# to the details log, and carry on. Nothing on the PC is changed by an error here.
$window.Dispatcher.add_UnhandledException({
    param($sender, $e)
    $e.Handled = $true
    try {
        $ui.LogBox.AppendText(('[{0}] ERROR   {1}' -f (Get-Date -Format 'HH:mm:ss'), $e.Exception.Message) + [Environment]::NewLine)
        Set-Busy $false 'Something went wrong - Quietpane is still running.'
        [void][System.Windows.MessageBox]::Show(
            "Something went wrong inside Quietpane:`n`n$($e.Exception.Message)`n`nThe app is still running and nothing on your PC was changed by this. There is more under `"Show details`" at the bottom.",
            'Quietpane')
    } catch { }
})

$ui = @{}
foreach ($n in 'Tabs', 'LogBox', 'Status', 'BtnRecommended', 'BtnNone', 'BtnPreview', 'BtnApply', 'HeaderLogo',
               'LinkHeader', 'LinkFooter', 'LinkPrivacy', 'LinkTerms', 'LinkContact', 'VersionRun',
               'LinkDetails', 'AdvancedButtons', 'LogRow', 'LogSplitter', 'StatusLine') { $ui[$n] = $window.FindName($n) }
# Screen readers hear the status line whenever it changes ("Reading the current state...", "All done").
# It is spoken by name, so the name follows the text.
function Send-StatusToScreenReader {
    try {
        [System.Windows.Automation.AutomationProperties]::SetName($ui.StatusLine, [string]$ui.Status.Text)
        $peer = [System.Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($ui.StatusLine)
        if ($peer) { $peer.RaiseAutomationEvent([System.Windows.Automation.Peers.AutomationEvents]::LiveRegionChanged) }
    } catch { }
}
try {
    $statusWatch = [System.ComponentModel.DependencyPropertyDescriptor]::FromProperty([System.Windows.Documents.Run]::TextProperty, [System.Windows.Documents.Run])
    $statusWatch.AddValueChanged($ui.Status, { Send-StatusToScreenReader })
} catch { }
# What the engine does straight from this window (shortcuts, starting at sign-in) goes in the details
# log too. Background jobs have their own log line, set up in Start-Work.
Set-QpLogSink { param($line) try { $ui.LogBox.AppendText($line + [Environment]::NewLine) } catch { } }

$brushConv = New-Object System.Windows.Media.BrushConverter
$thickConv = New-Object System.Windows.ThicknessConverter
function Get-Brush([string]$Hex) { $brushConv.ConvertFromString($Hex) }
function Get-Thick([string]$Value) { $thickConv.ConvertFromString($Value) }

function Get-Bitmap([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    $bi = New-Object System.Windows.Media.Imaging.BitmapImage
    $bi.BeginInit()
    $bi.UriSource = New-Object System.Uri($Path)
    $bi.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bi.EndInit()
    $bi.Freeze()
    return $bi
}
$logo = Get-Bitmap $info.LogoPath
if ($logo) { $ui.HeaderLogo.Source = $logo; $window.Icon = $logo }
# The .ico holds every size Windows asks for (title bar, Alt+Tab, taskbar), so each one stays sharp.
try { $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]$info.IconPath, 'None', 'OnLoad') } catch { }
$ui.VersionRun.Text = "   |   v$($info.Version)   |   No data leaves this PC"

function New-Text {
    param([string]$Text, [double]$Size = 13, [string]$Weight = 'Normal', [string]$Color = '#0F1B1C', [string]$Margin = '0,0,0,6', [string]$Font = '')
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text
    $tb.FontSize = $Size
    $tb.TextWrapping = 'Wrap'
    $tb.FontWeight = [System.Windows.FontWeights]::$Weight
    $tb.Foreground = Get-Brush $Color
    $tb.Margin = Get-Thick $Margin
    if ($Font) { $tb.FontFamily = New-Object System.Windows.Media.FontFamily($Font) }
    return $tb
}

function New-Button([string]$Text, [string]$Margin = '0,0,8,0', [switch]$Primary) {
    $b = New-Object System.Windows.Controls.Button
    $b.Content = $Text
    $b.Margin = Get-Thick $Margin
    if ($Primary) { $b.Style = $window.FindResource('Primary') }
    return $b
}

function New-TabPage {
    param([string]$Header, [string]$Key, [string]$Intro)
    $tab = New-Object System.Windows.Controls.TabItem
    $tab.Header = $Header
    $tab.Tag = $Key
    $sv = New-Object System.Windows.Controls.ScrollViewer
    $sv.VerticalScrollBarVisibility = 'Auto'
    # The page itself can take the keyboard, so arrow keys and Page Down scroll it - and shows it has.
    $sv.FocusVisualStyle = $window.FindResource('FocusRingInset')
    [System.Windows.Automation.AutomationProperties]::SetName($sv, "$Header page")
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = Get-Thick '20,16,20,16'
    if ($Intro) { [void]$sp.Children.Add((New-Text $Intro 13 'Normal' '#4B5B5C' '0,0,0,10')) }
    $sv.Content = $sp
    $tab.Content = $sv
    [void]$ui.Tabs.Items.Add($tab)
    return $sp
}

function New-GroupHeader([string]$Text) { New-Text $Text 16 'SemiBold' '#117A68' '0,18,0,0' 'Fraunces, Georgia' }

function Set-MoreInfo($Element, [string]$Text) {
    <#
        The longer explanation, kept one step away so the window stays calm: it appears when you point
        at the thing or Tab to it, and screen readers read it as the thing's help text.
    #>
    if (-not $Element -or -not $Text) { return }
    $tip = New-Object System.Windows.Controls.TextBlock
    $tip.Text = $Text; $tip.TextWrapping = 'Wrap'; $tip.MaxWidth = 440
    $Element.ToolTip = $tip
    [System.Windows.Controls.ToolTipService]::SetShowDuration($Element, 30000)
    [System.Windows.Automation.AutomationProperties]::SetHelpText($Element, $Text)
}

$script:Options = @{}
foreach ($k in 'privacy', 'devices', 'extensions', 'vendors', 'apps', 'startup', 'cleanup') { $script:Options[$k] = New-Object System.Collections.ArrayList }

function Add-Option {
    <#
        One tick box. -Short is the few words shown under it; the full -Description then waits one hover
        away. Without -Short, the description is shown as it is.
    #>
    param($Panel, [string]$Key, [string]$Id, [string]$Title, [string]$Description, [bool]$Recommended, [string]$Short = '')
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Tag = $Id
    $cb.Margin = Get-Thick '0,10,0,0'
    $cb.VerticalContentAlignment = 'Center'
    $label = New-Text $Title 13.5 'SemiBold' '#0F1B1C' '2,0,0,0'
    $cb.Content = $label
    # Keep the Apply button's count honest as things are ticked and unticked.
    $cb.Add_Checked({ Update-TickCount })
    $cb.Add_Unchecked({ Update-TickCount })
    [void]$Panel.Children.Add($cb)
    $shown = if ($Short) { $Short } else { $Description }
    if ($shown) {
        $desc = New-Text $shown 12.5 'Normal' '#4B5B5C' '22,2,0,0'
        [void]$Panel.Children.Add($desc)
        if ($Short -and $Description -and $Description -ne $Short) { Set-MoreInfo $cb $Description; Set-MoreInfo $desc $Description }
    }
    [void]$script:Options[$Key].Add([pscustomobject]@{ Id = $Id; CheckBox = $cb; Recommended = $Recommended; Label = $label; Title = $Title; Status = 'Unknown' })
}

# ------------------------------------------------------------------ tabs
# 0. Home - the one-click screen for everyone
$homePanel = New-TabPage 'Home' 'home' ''
[void]$homePanel.Children.Add((New-Text 'Make this PC yours again.' 28 'SemiBold' '#0F1B1C' '0,4,0,6' 'Fraunces, Georgia'))
[void]$homePanel.Children.Add((New-Text 'One click switches off tracking and ads, clears out unwanted apps and frees up space. You can put it all back.' 14.5 'Normal' '#4B5B5C' '0,0,0,18'))

function New-Card([string]$Title) {
    $b = New-Object System.Windows.Controls.Border
    # Narrow enough that all five cards stay on one row even when a scrollbar appears.
    $b.Width = 186
    $b.MinHeight = 108
    $b.Padding = Get-Thick '14,12'
    $b.Margin = Get-Thick '0,0,12,12'
    $b.Background = Get-Brush '#FAF6EC'
    $b.BorderBrush = Get-Brush '#E6DFCC'
    $b.BorderThickness = Get-Thick '1'
    $sp = New-Object System.Windows.Controls.StackPanel
    [void]$sp.Children.Add((New-Text $Title 11.5 'SemiBold' '#4B5B5C' '0,0,0,4'))
    $value = New-Text 'Checking...' 21 'SemiBold' '#0F1B1C' '0,0,0,2' 'Fraunces, Georgia'
    $caption = New-Text '' 12 'Normal' '#4B5B5C' '0'
    [void]$sp.Children.Add($value)
    [void]$sp.Children.Add($caption)
    $b.Child = $sp
    return [pscustomobject]@{ Border = $b; Value = $value; Caption = $caption }
}
$cards = New-Object System.Windows.Controls.WrapPanel
$script:CardTracking = New-Card 'TRACKING & ADS'
$script:CardApps     = New-Card 'UNNEEDED APPS'
$script:CardSpace    = New-Card 'SPACE TO FREE UP'
$script:CardBrands   = New-Card 'HARDWARE & BRANDS'
$script:CardAdware   = New-Card 'ADWARE CHECK'
foreach ($c in $script:CardTracking, $script:CardApps, $script:CardSpace, $script:CardBrands, $script:CardAdware) { [void]$cards.Children.Add($c.Border) }
$script:CardAdware.Value.Text = 'Not checked yet'
$script:CardAdware.Caption.Text = 'Takes about 2 minutes and changes nothing'
[void]$homePanel.Children.Add($cards)

# Things that switched themselves back on since last time - usually a Windows or driver update.
$script:BackPanel = New-Object System.Windows.Controls.Border
$script:BackPanel.Visibility = 'Collapsed'
$script:BackPanel.Margin = Get-Thick '0,0,12,12'
$script:BackPanel.Padding = Get-Thick '16,12'
$script:BackPanel.Background = Get-Brush '#FFF4DC'
$script:BackPanel.BorderBrush = Get-Brush '#FFB627'
$script:BackPanel.BorderThickness = Get-Thick '4,0,0,0'
$backStack = New-Object System.Windows.Controls.StackPanel
$script:BackTitle = New-Text '' 17 'SemiBold' '#0F1B1C' '0,0,0,4' 'Fraunces, Georgia'
$script:BackText = New-Text '' 13.5 'Normal' '#0F1B1C' '0,0,0,4'
$script:BackList = New-Text '' 12.5 'Normal' '#4B5B5C' '0,0,0,10'
$backButtons = New-Object System.Windows.Controls.WrapPanel
$btnPutBack = New-Button 'Switch them off again' -Primary
$btnThatWasMe = New-Button 'That was me - leave them'
foreach ($b in $btnPutBack, $btnThatWasMe) { $b.Margin = Get-Thick '0,0,10,0'; [void]$backButtons.Children.Add($b) }
foreach ($x in $script:BackTitle, $script:BackText, $script:BackList, $backButtons) { [void]$backStack.Children.Add($x) }
$script:BackPanel.Child = $backStack
[void]$homePanel.Children.Add($script:BackPanel)

# Two simple bars: how full the disk is, and how much memory is in use.
function New-Meter([string]$Title, [string]$FillColour) {
    $b = New-Object System.Windows.Controls.Border
    $b.Width = 294
    $b.MinHeight = 148
    $b.Padding = Get-Thick '14,12'
    $b.Margin = Get-Thick '0,0,12,12'
    $b.Background = Get-Brush '#FFFDF8'
    $b.BorderBrush = Get-Brush '#E6DFCC'
    $b.BorderThickness = Get-Thick '1'
    $sp = New-Object System.Windows.Controls.StackPanel
    [void]$sp.Children.Add((New-Text $Title 11.5 'SemiBold' '#4B5B5C' '0,0,0,4'))
    $value = New-Text 'Checking...' 21 'SemiBold' '#0F1B1C' '0,0,0,8' 'Fraunces, Georgia'
    [void]$sp.Children.Add($value)
    $track = New-Object System.Windows.Controls.Border
    $track.Height = 16
    $track.Width = 272
    $track.HorizontalAlignment = 'Left'
    $track.Background = Get-Brush '#EDE6D5'
    $track.CornerRadius = New-Object System.Windows.CornerRadius(8)
    $fill = New-Object System.Windows.Controls.Border
    $fill.Height = 16
    $fill.Width = 0
    $fill.HorizontalAlignment = 'Left'
    $fill.Background = Get-Brush $FillColour
    $fill.CornerRadius = New-Object System.Windows.CornerRadius(8)
    $track.Child = $fill
    [void]$sp.Children.Add($track)
    $caption = New-Text '' 12 'Normal' '#4B5B5C' '0,6,0,0'
    $delta = New-Text '' 13 'SemiBold' '#117A68' '0,4,0,0'
    $delta.Visibility = 'Collapsed'
    [void]$sp.Children.Add($caption)
    [void]$sp.Children.Add($delta)
    $b.Child = $sp
    return [pscustomobject]@{ Border = $b; Value = $value; Fill = $fill; Caption = $caption; Delta = $delta; TrackWidth = 272 }
}
# Two jobs, two sets of colour. Words are read close up and need contrast against the cream behind
# them, so the text set is the darker one; a bar is a big block and only has to be told apart from the
# other bars. Both were put through the palette checker rather than chosen by eye: the bar pair clears
# the colour-blindness separation it asks for (deutan 9.8, normal 25.5) and every text colour clears
# 4.5:1 on this background. The house green is a little grey for a chart colour by that checker's
# reckoning, and it stays anyway - it is the product's own colour, and no tile depends on it alone.
$script:BarColours = @{ ok = '#117A68'; high = '#A02020' }
#
# Live tiles: how hard the PC is working right now, and how warm it is.
#
# Every tile is built to exactly the same pattern - heading, one number, one bar, one line of plain
# words, one caption, one trend - and nothing may be added to one that the others don't have. That is
# the whole trick: four tiles the same shape can be compared at a glance, and four tiles of different
# heights and different numbers of lines have to be read one at a time. What used to hang off the
# bottom of a tile (which programs were busiest) now sits in one row beneath all four, because it was
# the same handful of programs repeated four times.
#
# The bar carries a mark at the point where that reading stops being ordinary, so "is 72% bad?" is
# answered by looking rather than by knowing. Colour only ever says how things stand - calm or serious -
# and never which tile it is, and the plain word beside it always says the same thing in text.
function New-LiveTile([string]$Title) {
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Width = 172
    $sp.Margin = Get-Thick '0,0,16,10'
    [void]$sp.Children.Add((New-Text $Title 11 'SemiBold' '#4B5B5C' '0,0,0,2'))
    $value = New-Text '...' 25 'SemiBold' '#0F1B1C' '0,0,0,7' 'Fraunces, Georgia'
    [void]$sp.Children.Add($value)
    $track = New-Object System.Windows.Controls.Border
    $track.Height = 10
    $track.Width = 156
    $track.HorizontalAlignment = 'Left'
    $track.Background = Get-Brush '#EDE6D5'
    $track.CornerRadius = New-Object System.Windows.CornerRadius(5)
    # A grid, so the mark can sit over the fill instead of beside it.
    $lane = New-Object System.Windows.Controls.Grid
    $fill = New-Object System.Windows.Controls.Border
    $fill.Height = 10
    $fill.Width = 0
    $fill.HorizontalAlignment = 'Left'
    $fill.Background = Get-Brush $script:BarColours.ok
    $fill.CornerRadius = New-Object System.Windows.CornerRadius(5)
    [void]$lane.Children.Add($fill)
    # "Where this stops being ordinary": a notch on the track, not a number to memorise.
    $mark = New-Object System.Windows.Controls.Border
    $mark.Width = 2; $mark.Height = 14
    $mark.HorizontalAlignment = 'Left'
    $mark.VerticalAlignment = 'Center'
    $mark.Background = Get-Brush '#8C9694'
    $mark.Visibility = 'Collapsed'
    [void]$lane.Children.Add($mark)
    $track.Child = $lane
    [void]$sp.Children.Add($track)
    # The bar is this second; the trend directly under it is the last two minutes, drawn the same width
    # and on the same nought-to-a-hundred scale, so the two read as one picture of the same thing.
    #
    # It sits here, above the words, on purpose. Everything below varies in length - one card is called
    # "RTX 4060 Laptop GPU" and another "NVMe Micron_2400E_MTFDKBA512QFM" - so anything placed after the
    # words lands at a different height in every tile, and four charts at four different heights cannot
    # be compared at a glance. Above them, all four line up exactly.
    $spark = New-Object System.Windows.Controls.Canvas
    $spark.Width = 156; $spark.Height = 26
    $spark.Margin = Get-Thick '0,5,0,0'
    $spark.HorizontalAlignment = 'Left'
    $spark.Visibility = 'Collapsed'
    [void]$sp.Children.Add($spark)
    $heat = New-Text '' 12.5 'SemiBold' '#117A68' '0,8,0,0'
    $caption = New-Text '' 11.5 'Normal' '#66706F' '0,2,0,0'
    $caption.TextWrapping = 'Wrap'
    # Kept for the one thing worth interrupting the pattern for: being held back to cool off.
    $extra = New-Text '' 11.5 'Normal' '#66706F' '0,4,0,0'
    $extra.TextWrapping = 'Wrap'
    $extra.Visibility = 'Collapsed'
    $delta = New-Text '' 12.5 'SemiBold' '#117A68' '0,4,0,0'
    $delta.Visibility = 'Collapsed'
    foreach ($x in $heat, $caption, $extra, $delta) { [void]$sp.Children.Add($x) }
    return [pscustomobject]@{ Border = $sp; Value = $value; Fill = $fill; Mark = $mark; Heat = $heat; Caption = $caption
        Extra = $extra; Delta = $delta; TrackWidth = 156; Spark = $spark; SparkColour = '#117A68' }
}

$meters = New-Object System.Windows.Controls.WrapPanel
$script:MeterSpace = New-Meter 'SPACE ON THIS PC' '#117A68'
[void]$meters.Children.Add($script:MeterSpace.Border)

$script:LivePanel = New-Object System.Windows.Controls.Border
$script:LivePanel.MinHeight = 148
$script:LivePanel.Padding = Get-Thick '14,12,0,10'
$script:LivePanel.Margin = Get-Thick '0,0,12,12'
$script:LivePanel.Background = Get-Brush '#FFFDF8'
$script:LivePanel.BorderBrush = Get-Brush '#E6DFCC'
$script:LivePanel.BorderThickness = Get-Thick '1'
$liveStack = New-Object System.Windows.Controls.StackPanel
[void]$liveStack.Children.Add((New-Text 'RIGHT NOW' 11.5 'SemiBold' '#4B5B5C' '0,0,0,6'))
# The answer first. Everything below it is the working.
$verdictRow = New-Object System.Windows.Controls.StackPanel
$verdictRow.Orientation = 'Horizontal'
$verdictRow.Margin = Get-Thick '0,0,0,2'
$script:VerdictDot = New-Object System.Windows.Shapes.Ellipse
$script:VerdictDot.Width = 11; $script:VerdictDot.Height = 11
$script:VerdictDot.VerticalAlignment = 'Center'
$script:VerdictDot.Margin = Get-Thick '0,0,8,0'
$script:VerdictDot.Fill = Get-Brush '#8C9694'
[void]$verdictRow.Children.Add($script:VerdictDot)
$script:VerdictText = New-Text 'Having a look...' 18 'SemiBold' '#0F1B1C' '0' 'Fraunces, Georgia'
$script:VerdictText.VerticalAlignment = 'Center'
[void]$verdictRow.Children.Add($script:VerdictText)
[void]$liveStack.Children.Add($verdictRow)
$script:VerdictWhy = New-Text '' 12.5 'Normal' '#4B5B5C' '19,0,0,12'
[void]$liveStack.Children.Add($script:VerdictWhy)
$liveTiles = New-Object System.Windows.Controls.WrapPanel
$script:TileCpu    = New-LiveTile 'PROCESSOR'
$script:TileGpu    = New-LiveTile 'GRAPHICS'
$script:TileMemory = New-LiveTile 'MEMORY'
$script:TileDisk   = New-LiveTile 'THE DRIVE'
foreach ($t in $script:TileCpu, $script:TileGpu, $script:TileMemory, $script:TileDisk) { [void]$liveTiles.Children.Add($t.Border) }
[void]$liveStack.Children.Add($liveTiles)
# One list for all four tiles. It used to be four lists of much the same programs.
$script:BusyStrip = New-Object System.Windows.Controls.StackPanel
$script:BusyStrip.Margin = Get-Thick '0,4,0,0'
$script:BusyHead = New-Text 'BUSIEST RIGHT NOW' 11 'SemiBold' '#4B5B5C' '0,0,0,4'
[void]$script:BusyStrip.Children.Add($script:BusyHead)
$script:BusyRows = New-Object System.Windows.Controls.StackPanel
[void]$script:BusyStrip.Children.Add($script:BusyRows)
Set-MoreInfo $script:BusyStrip 'The programs working your PC hardest this second, counted the way Task Manager counts them. A program near the top of this list while your PC feels slow is the one to look at first.'
[void]$liveStack.Children.Add($script:BusyStrip)
$script:LiveNote = New-Text 'Live, every 2 seconds. Nothing is recorded.' 11.5 'Normal' '#66706F' '0,10,0,0'
[void]$liveStack.Children.Add($script:LiveNote)
$script:LivePanel.Child = $liveStack
# The memory tile carries the "freed just now" note that the old memory bar used to.
$script:MeterMemory = $script:TileMemory
[void]$homePanel.Children.Add($meters)
$script:TotalsText = New-Text '' 13 'Normal' '#117A68' '2,0,0,10'
$script:TotalsText.Visibility = 'Collapsed'
[void]$homePanel.Children.Add($script:TotalsText)

$homeButtons = New-Object System.Windows.Controls.WrapPanel
$homeButtons.Margin = Get-Thick '0,6,0,0'
$btnOneClick = New-Button 'Quiet my PC now' -Primary
$btnOneClick.FontSize = 18
$btnOneClick.Padding = Get-Thick '36,14'
$btnOneClick.Margin = Get-Thick '0,0,12,8'
$btnHomeScan = New-Button 'Check for adware'
$btnHomeScan.FontSize = 15
$btnHomeScan.Padding = Get-Thick '22,14'
$btnHomeScan.Margin = Get-Thick '0,0,12,8'
[void]$homeButtons.Children.Add($btnOneClick)
[void]$homeButtons.Children.Add($btnHomeScan)
[void]$homePanel.Children.Add($homeButtons)
$homeHint = New-Text 'You''ll see every change before it happens.' 12.5 'Normal' '#4B5B5C' '0,6,0,0'
$howItsSafe = 'Settings can be undone, cleaned-up files go to your Recycle Bin, and removed apps can be reinstalled from the Microsoft Store.'
Set-MoreInfo $homeHint $howItsSafe
Set-MoreInfo $btnOneClick $howItsSafe
[void]$homePanel.Children.Add($homeHint)
$homeDisclaimer = New-Text 'A good start, not a guarantee. If your PC still feels wrong, also run a full antivirus scan.' 12.5 'Normal' '#9A6700' '0,8,0,0'
Set-MoreInfo $homeDisclaimer 'Quietpane tidies up the usual troublemakers, but no single tool can promise a PC is clean.'
[void]$homePanel.Children.Add($homeDisclaimer)

$script:ResultPanel = New-Object System.Windows.Controls.Border
$script:ResultPanel.Visibility = 'Collapsed'
$script:ResultPanel.Margin = Get-Thick '0,18,0,0'
$script:ResultPanel.Padding = Get-Thick '18,14'
$script:ResultPanel.Background = Get-Brush '#EAF5F1'
$script:ResultPanel.BorderBrush = Get-Brush '#117A68'
$script:ResultPanel.BorderThickness = Get-Thick '4,0,0,0'
$resultStack = New-Object System.Windows.Controls.StackPanel
$script:ResultTitle = New-Text '' 22 'SemiBold' '#117A68' '0,0,0,6' 'Fraunces, Georgia'
$script:ResultText = New-Text '' 14 'Normal' '#0F1B1C' '0,0,0,12'
$resultButtons = New-Object System.Windows.Controls.WrapPanel
$btnRestart = New-Button 'Restart now' -Primary
$btnUndoAll = New-Button 'Undo everything I just did'
$btnShowDetails = New-Button 'Show what changed'
foreach ($b in $btnRestart, $btnUndoAll, $btnShowDetails) { $b.Margin = Get-Thick '0,0,10,4'; [void]$resultButtons.Children.Add($b) }
[void]$resultStack.Children.Add($script:ResultTitle)
[void]$resultStack.Children.Add($script:ResultText)
[void]$resultStack.Children.Add($resultButtons)
$script:ResultPanel.Child = $resultStack
[void]$homePanel.Children.Add($script:ResultPanel)
$homeRather = New-Text 'Prefer to choose each item yourself? Use the tabs above - Preview changes nothing.' 12.5 'Normal' '#4B5B5C' '0,20,0,0'
[void]$homePanel.Children.Add($homeRather)

# The order people read Home in: how things stand, the one button (and what it just did), then space.
# The button stays in view without scrolling.
$homeTop = @($homePanel.Children)[0..1]
$homePanel.Children.Clear()
$meters.Margin = Get-Thick '0,20,0,0'
foreach ($x in @($homeTop) + @($cards, $script:BackPanel, $homeButtons, $homeHint, $script:ResultPanel, $meters, $script:TotalsText, $homeDisclaimer, $homeRather)) { [void]$homePanel.Children.Add($x) }

# 1. Health - how hard the PC is working, how warm it is, and how the battery and drive are holding up.
# Its own tab, so Home stays calm - and nothing here is read unless this tab is open.
$healthPanel = New-TabPage 'Health' 'health' 'How hard your PC is working, how warm it is, and how the battery and drive are doing.'
$script:LivePanel.Margin = Get-Thick '0,4,0,12'
[void]$healthPanel.Children.Add($script:LivePanel)
$healthCards = New-Object System.Windows.Controls.WrapPanel
# Laptops only: charge, plugged in or not, and how much the battery holds compared with when it was new.
$script:BatteryCard = New-Meter 'BATTERY' '#FFB627'
$script:BatteryHealthText = New-Text '' 12.5 'Normal' '#0F1B1C' '0,6,0,0'
[void]$script:BatteryCard.Border.Child.Children.Add($script:BatteryHealthText)
$script:BatteryCard.Border.Visibility = 'Collapsed'
# The drive Windows runs from: Windows' own verdict, how much of its rated life is used, and its heat.
$script:DriveCard = New-Meter 'THE DRIVE WINDOWS IS ON' '#117A68'
$script:DriveHeatText = New-Text '' 12.5 'SemiBold' '#117A68' '0,6,0,0'
[void]$script:DriveCard.Border.Child.Children.Add($script:DriveHeatText)
$script:DriveCard.Value.Text = 'Having a look...'
# Windows keeps its own record of how steady this PC has been. Almost nobody ever opens it.
$script:SteadyCard = New-Meter 'HOW IT HAS BEEN HOLDING UP' '#117A68'
$script:SteadyLines = New-Object System.Windows.Controls.StackPanel
$script:SteadyLines.Margin = Get-Thick '0,6,0,0'
[void]$script:SteadyCard.Border.Child.Children.Add($script:SteadyLines)
$script:SteadyCard.Value.Text = 'Having a look...'
foreach ($c in $script:BatteryCard, $script:DriveCard, $script:SteadyCard) { [void]$healthCards.Children.Add($c.Border) }
[void]$healthPanel.Children.Add($healthCards)

# What a whole session cost, for anyone who wants to know how their PC held up while they worked.
$script:SessionBox = New-Object System.Windows.Controls.Border
$script:SessionBox.Background = Get-Brush '#FFFDF8'
$script:SessionBox.BorderBrush = Get-Brush '#E6DFCC'
$script:SessionBox.BorderThickness = Get-Thick '1'
$script:SessionBox.Padding = Get-Thick '14,12'
$script:SessionBox.Margin = Get-Thick '0,0,12,12'
$sessionStack = New-Object System.Windows.Controls.StackPanel
[void]$sessionStack.Children.Add((New-Text 'THIS SESSION' 11.5 'SemiBold' '#4B5B5C' '0,0,0,6'))
$script:SessionHead = New-Text 'Quietpane can keep an eye on how your PC holds up while you work.' 13.5 'Normal' '#0F1B1C' '0,0,0,2'
[void]$sessionStack.Children.Add($script:SessionHead)
$script:SessionChart = New-Object System.Windows.Controls.StackPanel
[void]$sessionStack.Children.Add($script:SessionChart)
$script:SessionLines = New-Object System.Windows.Controls.StackPanel
$script:SessionLines.Margin = Get-Thick '0,10,0,0'
[void]$sessionStack.Children.Add($script:SessionLines)
$sessionButtons = New-Object System.Windows.Controls.StackPanel
$sessionButtons.Orientation = 'Horizontal'
$sessionButtons.Margin = Get-Thick '0,10,0,0'
$script:BtnSession = New-Button 'Watch this session'
$script:BtnSession.Add_Click({ Switch-SessionWatch })
[void]$sessionButtons.Children.Add($script:BtnSession)
# A session lives in this window and goes when it closes - unless you ask for it on paper.
$script:BtnSessionSave = New-Button 'Save it to my Desktop' '6,0,0,0'
$script:BtnSessionSave.Visibility = 'Collapsed'
Set-MoreInfo $script:BtnSessionSave 'Writes one page to your Desktop that you can keep, open without Quietpane, or send to whoever is asking why the PC is slow. It opens no connections and holds nothing but what was measured here.'
$script:BtnSessionSave.Add_Click({ Save-SessionReport })
[void]$sessionButtons.Children.Add($script:BtnSessionSave)
[void]$sessionStack.Children.Add($sessionButtons)
$sessionNote = New-Text 'It watches only while Quietpane is open, and forgets everything when you close it.' 11.5 'Normal' '#66706F' '0,8,0,0'
Set-MoreInfo $sessionNote 'Nothing is installed, nothing is scheduled and nothing is written down: the record lives in this window and goes when the window goes. It keeps reading while Quietpane is minimised, which is the whole point, and checks about every 10 seconds while you are not looking at this tab.'
[void]$sessionStack.Children.Add($sessionNote)
$script:SessionBox.Child = $sessionStack
# Above the battery and drive: those change over months, this is about the afternoon you are having.
[void]$healthPanel.Children.Insert(2, $script:SessionBox)

# 1. Safety scan - Microsoft Defender's detections plus Quietpane's own checks
$scanPanel = New-TabPage 'Safety scan' 'scan' ('Asks Microsoft Defender what it has found, and looks for the tricks adware uses. Looking changes nothing.')
Set-MoreInfo $scanPanel.Children[0] 'Odd startup entries, hidden tasks, browser add-ons and tampered programs. Threat names come from Defender; anything Quietpane spots itself is marked as its own check - a warning sign, not proof.'
$scanButtons = New-Object System.Windows.Controls.StackPanel
$scanButtons.Orientation = 'Horizontal'
$scanButtons.Margin = Get-Thick '0,0,0,10'
$btnScan = New-Button 'Check this PC' -Primary
$btnScanDeep = New-Button 'Check and ask Defender to scan'
$btnOpenReport = New-Button 'Open last report'
$btnOpenReport.IsEnabled = $false
# Stop stays enabled while everything else is greyed out - it is the one button a busy app must keep.
$btnStopScan = New-Button 'Stop'
$btnStopScan.Visibility = 'Collapsed'
$btnStopScan.ToolTip = 'Stop looking. Nothing on your PC is changed either way.'
foreach ($b in $btnScan, $btnScanDeep, $btnOpenReport, $btnStopScan) { [void]$scanButtons.Children.Add($b) }
[void]$scanPanel.Children.Add($scanButtons)
$scanSummary = New-Text 'No check yet.' 15 'SemiBold' '#0F1B1C' '0,6,0,6' 'Fraunces, Georgia'
[void]$scanPanel.Children.Add($scanSummary)
$script:ScanProgress = New-Text '' 12.5 'Normal' '#4B5B5C' '0,0,0,6'
[void]$scanPanel.Children.Add($script:ScanProgress)

# What happened, in full, once the check has finished: looked at, found, dealt with, what next.
$script:SummaryPanel = New-Object System.Windows.Controls.Border
$script:SummaryPanel.Visibility = 'Collapsed'
$script:SummaryPanel.Background = Get-Brush '#EAF5F1'
$script:SummaryPanel.BorderBrush = Get-Brush '#117A68'
$script:SummaryPanel.BorderThickness = Get-Thick '4,0,0,0'
$script:SummaryPanel.Padding = Get-Thick '16,12'
$script:SummaryPanel.Margin = Get-Thick '0,2,0,12'
$script:SummaryStack = New-Object System.Windows.Controls.StackPanel
$script:SummaryPanel.Child = $script:SummaryStack
[void]$scanPanel.Children.Add($script:SummaryPanel)

# Severity doughnut: colour, label and count, so it never depends on colour alone.
# Each is dark enough for white text on it to pass WCAG AA (Low was a lighter grey that didn't).
$script:SevColours = [ordered]@{ Critical = '#7B1D1D'; High = '#A83232'; Medium = '#9A6700'; Low = '#6E695C'; Info = '#117A68' }
$script:SevMeaning = @{ Critical = 'act now'; High = 'act on it'; Medium = 'worth a look'; Low = 'minor'; Info = 'just so you know' }
$script:SevCounts = [ordered]@{ Critical = 0; High = 0; Medium = 0; Low = 0; Info = 0 }
$script:SevFilter = 'All'
$script:ScanFindings = @()

$script:ChartPanel = New-Object System.Windows.Controls.Border
$script:ChartPanel.Visibility = 'Collapsed'
$script:ChartPanel.Background = Get-Brush '#FFFDF8'
$script:ChartPanel.BorderBrush = Get-Brush '#E6DFCC'
$script:ChartPanel.BorderThickness = Get-Thick '1'
$script:ChartPanel.Padding = Get-Thick '16,14'
$script:ChartPanel.Margin = Get-Thick '0,4,0,12'
$chartRow = New-Object System.Windows.Controls.StackPanel
$chartRow.Orientation = 'Horizontal'
$script:ChartCanvas = New-Object System.Windows.Controls.Canvas
$script:ChartCanvas.Width = 172; $script:ChartCanvas.Height = 172
$script:ChartCanvas.Margin = Get-Thick '0,0,22,0'
[void]$chartRow.Children.Add($script:ChartCanvas)
$script:LegendPanel = New-Object System.Windows.Controls.StackPanel
$script:LegendPanel.VerticalAlignment = 'Center'
$script:LegendPanel.MinWidth = 300
[void]$chartRow.Children.Add($script:LegendPanel)
$script:ChartPanel.Child = $chartRow
[void]$scanPanel.Children.Add($script:ChartPanel)

$script:FindingsPanel = New-Object System.Windows.Controls.StackPanel
[void]$scanPanel.Children.Add($script:FindingsPanel)

# Whatever Quietpane is holding in quarantine, with a way back out.
$script:QuarantineBox = New-Object System.Windows.Controls.Expander
$script:QuarantineBox.Header = New-Text 'In quarantine' 14.5 'SemiBold' '#117A68' '0' 'Fraunces, Georgia'
$script:QuarantineBox.Margin = Get-Thick '0,16,0,0'
$script:QuarantineBox.Visibility = 'Collapsed'
$script:QuarantinePanel = New-Object System.Windows.Controls.StackPanel
$script:QuarantinePanel.Margin = Get-Thick '8,6,0,8'
$script:QuarantineBox.Content = $script:QuarantinePanel
[void]$scanPanel.Children.Add($script:QuarantineBox)
[void]$scanPanel.Children.Add((New-Text 'A good start, not a guarantee. If your PC still feels wrong, also run a full antivirus scan.' 12.5 'Normal' '#9A6700' '0,14,0,0'))

# 2. Privacy & telemetry - one collapsed section per group, so nothing shouts at you
function New-Section([string]$Header) {
    $ex = New-Object System.Windows.Controls.Expander
    $ex.Header = New-Text $Header 14.5 'SemiBold' '#117A68' '0' 'Fraunces, Georgia'
    $ex.Margin = Get-Thick '0,8,0,0'
    $ex.IsExpanded = $false
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = Get-Thick '8,2,0,10'
    $ex.Content = $sp
    return [pscustomobject]@{ Expander = $ex; Content = $sp }
}
$privacyPanel = New-TabPage 'Privacy' 'privacy' ('What your PC shares, and the tracking and ads you can switch off. Security and Windows Update are never touched.')

# Add-ons see more of your browsing than anything else on this PC, so they come first.
$script:AddonSection = New-Section 'Your browser add-ons'
$script:AddonSection.Expander.IsExpanded = $true
$addonIntro = New-Text 'What each one is allowed to read. Tick any you don''t want.' 12.5 'Normal' '#4B5B5C' '0,2,0,2'
Set-MoreInfo $addonIntro 'Read from the browser''s own files: the add-on''s manifest says what it may do, and the browser''s settings say whether it is on. Switching one off is a policy under your own settings telling the browser not to load it - the browser then says an administrator blocked it, which is you, and Undo takes that away again. The browser picks it up on its own; close it and open it again to see it straight away.'
[void]$script:AddonSection.Content.Children.Add($addonIntro)
$script:AddonList = New-Object System.Windows.Controls.StackPanel
[void]$script:AddonList.Children.Add((New-Text 'Looking at your browsers...' 13 'Normal' '#4B5B5C'))
[void]$script:AddonSection.Content.Children.Add($script:AddonList)
[void]$privacyPanel.Children.Add($script:AddonSection.Expander)

$script:DeviceSection = New-Section 'Who used your camera, microphone and location'
[void]$script:DeviceSection.Content.Children.Add((New-Text 'Tick an app to switch it off - the same switch as in Settings.' 12.5 'Normal' '#4B5B5C' '0,2,0,2'))
$script:DeviceList = New-Object System.Windows.Controls.StackPanel
[void]$script:DeviceList.Children.Add((New-Text 'Looking at who used them...' 13 'Normal' '#4B5B5C'))
[void]$script:DeviceSection.Content.Children.Add($script:DeviceList)
[void]$privacyPanel.Children.Add($script:DeviceSection.Expander)

# Live while it is open, and asleep the rest of the time.
$script:NetSection = New-Section 'What''s talking to the internet right now'
$netIntro = New-Text 'Programs connected right now, and where to. Most of it is normal. Nothing is blocked.' 12.5 'Normal' '#4B5B5C' '0,2,0,6'
Set-MoreInfo $netIntro 'Updates, syncing, your browser and games all connect. This is here so you can spot anything you don''t recognise.'
[void]$script:NetSection.Content.Children.Add($netIntro)
$script:NetList = New-Object System.Windows.Controls.StackPanel
[void]$script:NetList.Children.Add((New-Text 'Having a look...' 13 'Normal' '#4B5B5C'))
[void]$script:NetSection.Content.Children.Add($script:NetList)
$netNote = New-Text 'Quietpane makes no connections of its own.' 11.5 'Normal' '#66706F' '0,10,0,0'
Set-MoreInfo $netNote 'This is Windows'' own list, named from the addresses Windows has already looked up. Programs that use QUIC (some browsers and games) may not appear, because Windows doesn''t record where those go.'
[void]$script:NetSection.Content.Children.Add($netNote)
[void]$privacyPanel.Children.Add($script:NetSection.Expander)

# The tab reads in two parts: what is happening on this PC, then the settings you can change.
[void]$privacyPanel.Children.Add((New-Text 'Settings you can switch off' 15 'SemiBold' '#0F1B1C' '0,22,0,2' 'Fraunces, Georgia'))
[void]$privacyPanel.Children.Add((New-Text 'Tick what you want, then Preview or Apply. Point at one to learn more.' 12.5 'Normal' '#4B5B5C' '0,0,0,2'))

foreach ($g in @((Get-QpCatalog privacy).Items | ForEach-Object { $_.Group } | Select-Object -Unique)) {
    $items = @((Get-QpCatalog privacy).Items | Where-Object { $_.Group -eq $g })
    $sec = New-Section ('{0}   ({1} settings)' -f $g, $items.Count)
    foreach ($item in $items) {
        Add-Option -Panel $sec.Content -Key 'privacy' -Id $item.Id -Title $item.Title -Description $item.Description -Recommended ([bool]$item.Recommended) -Short ([string]$item.Short)
    }
    [void]$privacyPanel.Children.Add($sec.Expander)
}

# 3. Telemetry - the brand and hardware software that came with this PC
$vendorPanel = New-TabPage 'Telemetry' 'vendors' ('')
$vendorIntroText = New-Text 'Background extras from the companies that made your PC, and what they report. Drivers are never touched, and the apps still work.' 13.5 'Normal' '#4B5B5C' '0,0,0,12'
Set-MoreInfo $vendorIntroText 'The laptop maker, the graphics chip, the processor: most PCs arrive with helpers from each, and many quietly report home. Only what is actually on this PC is listed.'
[void]$vendorPanel.Children.Add($vendorIntroText)
$script:VendorIntro = New-Text 'Having a look at what came with this PC...' 13 'SemiBold' '#0F1B1C' '0,0,0,6'
[void]$vendorPanel.Children.Add($script:VendorIntro)
$script:VendorList = New-Object System.Windows.Controls.StackPanel
[void]$vendorPanel.Children.Add($script:VendorList)

# 4. Apps - what starts when you sign in, and apps you could remove
$appsPanel = New-TabPage 'Apps' 'apps' ('What starts when you sign in, and apps you never asked for. Tick, then Preview or Apply.')

$script:StartupSection = New-Section 'Starts when you sign in'
$script:StartupSection.Expander.IsExpanded = $true
[void]$script:StartupSection.Content.Children.Add((New-Text 'Switched off the way Task Manager does it - the program still opens when you start it.' 12.5 'Normal' '#4B5B5C' '0,2,0,2'))
$script:StartupList = New-Object System.Windows.Controls.StackPanel
[void]$script:StartupList.Children.Add((New-Text 'Looking at what starts when you sign in...' 13 'Normal' '#4B5B5C'))
[void]$script:StartupSection.Content.Children.Add($script:StartupList)
[void]$appsPanel.Children.Add($script:StartupSection.Expander)

$script:RemoveSection = New-Section 'Apps you could remove'
$script:RemoveSection.Expander.IsExpanded = $true
$appsNote = New-Text 'Essentials like the Store, Camera and Photos are never listed. Removed apps can be reinstalled from the Store.' 12.5 'Normal' '#4B5B5C' '0,2,0,6'
Set-MoreInfo $appsNote 'Never on this list: the Store, Camera, Photos, Calculator, Notepad, Paint, Snipping Tool and anything driver-related.'
[void]$script:RemoveSection.Content.Children.Add($appsNote)
$script:DeprovisionCb = New-Object System.Windows.Controls.CheckBox
$script:DeprovisionCb.Content = New-Text 'Also keep them off new user accounts' 12.5 'Normal' '#0F1B1C' '2,0,0,0'
Set-MoreInfo $script:DeprovisionCb 'Stops removed apps being installed again for anyone who gets a new account on this PC.'
$script:DeprovisionCb.IsChecked = $true
$script:DeprovisionCb.Margin = Get-Thick '0,0,0,8'
[void]$script:RemoveSection.Content.Children.Add($script:DeprovisionCb)
$script:AppsList = New-Object System.Windows.Controls.StackPanel
[void]$script:AppsList.Children.Add((New-Text 'Looking for installed apps...' 13 'Normal' '#4B5B5C'))
[void]$script:RemoveSection.Content.Children.Add($script:AppsList)
[void]$appsPanel.Children.Add($script:RemoveSection.Expander)

# 5. Clean-up
$cleanupPanel = New-TabPage 'Free up space' 'cleanup' ('Leftovers nobody needs, like temporary files and old installers. They go to your Recycle Bin. Close your browsers first.')
$script:CleanupList = New-Object System.Windows.Controls.StackPanel
[void]$script:CleanupList.Children.Add((New-Text 'Measuring sizes...' 13 'Normal' '#4B5B5C'))
[void]$cleanupPanel.Children.Add($script:CleanupList)

# Where the space went: only when asked, because adding up a whole drive takes a few seconds.
$script:SpaceSection = New-Section 'Where your space went'
$script:SpaceSection.Expander.IsExpanded = $true
$script:SpaceSection.Expander.Margin = Get-Thick '0,22,0,0'
[void]$script:SpaceSection.Content.Children.Add((New-Text 'Your biggest folders and files. Click a folder to look inside.' 12.5 'Normal' '#4B5B5C' '0,2,0,8'))
$spaceButtons = New-Object System.Windows.Controls.StackPanel
$spaceButtons.Orientation = 'Horizontal'
$script:SpaceDrive = New-Object System.Windows.Controls.ComboBox
$script:SpaceDrive.Margin = Get-Thick '0,0,8,0'
[System.Windows.Automation.AutomationProperties]::SetName($script:SpaceDrive, 'Drive to look at')
$script:SpaceDrive.MinWidth = 70
foreach ($d in @([IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady })) { [void]$script:SpaceDrive.Items.Add($d.Name) }
$script:SpaceDrive.SelectedItem = @($script:SpaceDrive.Items | Where-Object { $_ -like "$env:SystemDrive*" })[0]
if ($script:SpaceDrive.Items.Count -lt 2) { $script:SpaceDrive.Visibility = 'Collapsed' }
$btnSpaceLook = New-Button 'Look' -Primary
$btnSpaceStop = New-Button 'Stop'
$btnSpaceStop.Visibility = 'Collapsed'
$btnSpaceStop.ToolTip = 'Stop looking. Nothing on your PC is changed either way.'
$btnSpaceBack = New-Button 'Back'
$btnSpaceBack.Visibility = 'Collapsed'
foreach ($b in $script:SpaceDrive, $btnSpaceLook, $btnSpaceStop, $btnSpaceBack) { [void]$spaceButtons.Children.Add($b) }
[void]$script:SpaceSection.Content.Children.Add($spaceButtons)
$script:SpaceStatus = New-Text '' 12.5 'Normal' '#4B5B5C' '0,8,0,0'
$script:SpaceCrumb = New-Text '' 14 'SemiBold' '#0F1B1C' '0,10,0,2'
$script:SpaceBanner = New-Text '' 12.5 'Normal' '#117A68' '0,0,0,4'
$script:SpaceRows = New-Object System.Windows.Controls.StackPanel
$script:SpaceFilesHead = New-Text 'Your biggest files' 14 'SemiBold' '#0F1B1C' '0,18,0,0'
$script:SpaceFilesNote = New-Text 'Only files that are yours to move.' 12.5 'Normal' '#4B5B5C' '0,0,0,4'
Set-MoreInfo $script:SpaceFilesNote 'Big game and program files are in the folders above, each with where to remove it properly.'
$script:SpaceFiles = New-Object System.Windows.Controls.StackPanel
# The easy wins, above the folder list: the room most people can clear without thinking about it.
$script:SpaceWinsHead = New-Text 'Worth clearing first' 14 'SemiBold' '#0F1B1C' '0,16,0,0'
$script:SpaceWinsNote = New-Text 'Go by the date on the file, not by when it was last opened.' 12.5 'Normal' '#4B5B5C' '0,0,0,2'
Set-MoreInfo $script:SpaceWinsNote 'Windows does note when a file was last opened, but anything that reads it updates that too - your antivirus, Windows Search, a backup - so on most PCs every file looks as though it was opened this morning. Quietpane goes by the date written on the file instead.'
$script:SpaceWins = New-Object System.Windows.Controls.StackPanel
foreach ($e in $script:SpaceStatus, $script:SpaceWinsHead, $script:SpaceWinsNote, $script:SpaceWins, $script:SpaceCrumb, $script:SpaceBanner, $script:SpaceRows, $script:SpaceFilesHead, $script:SpaceFilesNote, $script:SpaceFiles) { [void]$script:SpaceSection.Content.Children.Add($e) }
foreach ($e in $script:SpaceWinsHead, $script:SpaceWinsNote, $script:SpaceCrumb, $script:SpaceBanner, $script:SpaceFilesHead, $script:SpaceFilesNote) { $e.Visibility = 'Collapsed' }
[void]$cleanupPanel.Children.Add($script:SpaceSection.Expander)

# 6. Undo
$undoPanel = New-TabPage 'Undo' 'undo' ('Every change is saved as a restore point. Pick one to put it back.')
Set-MoreInfo $undoPanel.Children[0] 'Settings go back exactly as they were. Cleaned-up files are waiting in your Recycle Bin, and removed apps come back from the Microsoft Store.'
$script:UndoList = New-Object System.Windows.Controls.ListBox
$script:UndoList.MinHeight = 160
[System.Windows.Automation.AutomationProperties]::SetName($script:UndoList, 'Restore points, newest first')
$script:UndoList.Margin = Get-Thick '0,6,0,8'
$script:UndoList.BorderBrush = Get-Brush '#E6DFCC'
[void]$undoPanel.Children.Add($script:UndoList)
$undoButtons = New-Object System.Windows.Controls.StackPanel
$undoButtons.Orientation = 'Horizontal'
$btnUndo = New-Button 'Undo selected restore point' -Primary
$btnUndoRefresh = New-Button 'Refresh list'
[void]$undoButtons.Children.Add($btnUndo)
[void]$undoButtons.Children.Add($btnUndoRefresh)
[void]$undoPanel.Children.Add($undoButtons)

# 7. About, privacy & terms
$aboutPanel = New-TabPage 'About' 'about' ''
$aboutHead = New-Object System.Windows.Controls.StackPanel
$aboutHead.Orientation = 'Horizontal'
$aboutHead.Margin = Get-Thick '0,0,0,12'
if ($logo) {
    $img = New-Object System.Windows.Controls.Image
    $img.Source = $logo; $img.Width = 72; $img.Height = 72; $img.Margin = Get-Thick '0,0,16,0'
    [void]$aboutHead.Children.Add($img)
}
$aboutTitle = New-Object System.Windows.Controls.StackPanel
$aboutTitle.VerticalAlignment = 'Center'
[void]$aboutTitle.Children.Add((New-Text "Quietpane $($info.Version)" 24 'SemiBold' '#0F1B1C' '0,0,0,2' 'Fraunces, Georgia'))
[void]$aboutTitle.Children.Add((New-Text 'Developed by KomodoWorks - an independent technology studio in Dublin, Ireland.' 13 'Normal' '#4B5B5C' '0'))
[void]$aboutHead.Children.Add($aboutTitle)
[void]$aboutPanel.Children.Add($aboutHead)

[void]$aboutPanel.Children.Add((New-GroupHeader 'Our promise'))
# One short line each; point at a line for the whole of it.
foreach ($pair in @(
        @('Collects nothing - no accounts, tracking or ads.',
          'No accounts, analytics, telemetry, crash reports, ads, cookies or tracking of any kind.'),
        @('Connects to nothing - links open only when you click them.',
          'The app makes no network requests at all.'),
        @('Changes nothing without asking, and keeps a restore point.',
          'Every change is shown first and confirmed, and settings go into a restore point you can undo.'),
        @('Tidying up uses your Recycle Bin. Anything that can''t be undone says so first.',
          'Scheduled tasks are switched off, not deleted. Three things can''t be undone - removing an app (the Microsoft Store has it), uninstalling a brand extra, and deleting a threat for good - and the app says so before you confirm.'),
        @('Hides nothing - plain-text code you can read. No installer.',
          'Plain-text PowerShell you can read line by line, plus three small pieces of C# - for the graphics temperature, adding up folder sizes, and making shortcuts. It only copies itself to Program Files if you add shortcuts or start it when you sign in.'),
        @('Free and open source (MIT). Not tied to Microsoft or any PC maker.',
          'MIT License. Not affiliated with Microsoft, NVIDIA, Intel, AMD, Google or any PC maker.'))) {
    $t = New-Text ('-  ' + $pair[0]) 13 'Normal' '#0F1B1C' '4,4,0,0'
    Set-MoreInfo $t $pair[1]
    [void]$aboutPanel.Children.Add($t)
}

$aboutButtons = New-Object System.Windows.Controls.WrapPanel
$aboutButtons.Margin = Get-Thick '0,16,0,8'
$btnSite = New-Button 'Visit KomodoWorks.com' -Primary
$btnMail = New-Button "Email $($info.BrandEmail)"
$btnRepo = New-Button 'Source code on GitHub'
$btnData = New-Button 'Open this app''s data folder'
foreach ($b in $btnSite, $btnMail, $btnRepo, $btnData) { $b.Margin = Get-Thick '0,0,8,8'; [void]$aboutButtons.Children.Add($b) }
[void]$aboutPanel.Children.Add($aboutButtons)

# The two ways to reach Quietpane without hunting for the folder again.
[void]$aboutPanel.Children.Add((New-GroupHeader 'Quietpane on this PC'))
$btnShortcut = New-Button 'Add to Start menu and desktop' '0,8,0,0'
$btnShortcut.HorizontalAlignment = 'Left'
[void]$aboutPanel.Children.Add($btnShortcut)
$script:SignInBox = New-Object System.Windows.Controls.CheckBox
$script:SignInBox.Margin = Get-Thick '0,14,0,0'
$script:SignInBox.VerticalContentAlignment = 'Center'
$script:SignInBox.Content = New-Text 'Start Quietpane when I sign in' 13.5 'SemiBold' '#0F1B1C' '2,0,0,0'
[void]$aboutPanel.Children.Add($script:SignInBox)
[void]$aboutPanel.Children.Add((New-Text 'It waits on the taskbar and does nothing until you click it.' 12.5 'Normal' '#4B5B5C' '22,2,0,0'))
# Only makes sense with the one above, so it sits under it, indented, and waits until that is ticked.
$script:WatchBox = New-Object System.Windows.Controls.CheckBox
$script:WatchBox.Margin = Get-Thick '22,10,0,0'
$script:WatchBox.VerticalContentAlignment = 'Center'
$script:WatchBox.IsEnabled = $false
$script:WatchBox.Opacity = 0.55   # looks as unavailable as it is, until the box above is ticked
$script:WatchBox.Content = New-Text 'Also tell me if Windows switches things back on' 13.5 'SemiBold' '#0F1B1C' '2,0,0,0'
$script:WatchBox.ToolTip = 'Tick "Start Quietpane when I sign in" first.'
[System.Windows.Controls.ToolTipService]::SetShowOnDisabled($script:WatchBox, $true)
[void]$aboutPanel.Children.Add($script:WatchBox)
$watchNote = New-Text 'Checks once as you sign in, and badges the taskbar icon if anything came back.' 12.5 'Normal' '#4B5B5C' '44,2,0,0'
Set-MoreInfo $watchNote 'About a second of work, just after you sign in. If nothing came back, you won''t notice it at all.'
[void]$aboutPanel.Children.Add($watchNote)
$placeNote = New-Text 'Both use Quietpane''s own copy, so you can move the folder you unzipped.' 12.5 'Normal' '#4B5B5C' '0,12,0,6'
Set-MoreInfo $placeNote 'The copy lives in Program Files. To keep Quietpane on the taskbar, right-click it in the Start menu and choose "Pin to taskbar".'
Set-MoreInfo $btnShortcut 'To keep Quietpane on the taskbar afterwards, right-click it in the Start menu and choose "Pin to taskbar".'
[void]$aboutPanel.Children.Add($placeNote)

function Get-DocText([string]$File) {
    $p = Join-Path $PSScriptRoot $File
    if (-not (Test-Path $p)) { return "$File was not found next to the app. It is available in the GitHub repository." }
    $t = Get-Content -LiteralPath $p -Raw
    $t = $t -replace '\*\*', '' -replace '(?m)^#{1,6}\s*', '' -replace '\[([^\]]+)\]\(([^)]+)\)', '$1 ($2)'
    return $t.Trim()
}
function New-DocExpander([string]$Header, [string]$File) {
    $ex = New-Object System.Windows.Controls.Expander
    $ex.Header = New-Text $Header 15 'SemiBold' '#117A68' '0' 'Fraunces, Georgia'
    $ex.Margin = Get-Thick '0,10,0,0'
    $tb = New-Object System.Windows.Controls.TextBox
    $tb.Text = Get-DocText $File
    $tb.IsReadOnly = $true
    $tb.TextWrapping = 'Wrap'
    $tb.BorderThickness = Get-Thick '0'
    $tb.Background = Get-Brush '#FAF6EC'
    $tb.Padding = Get-Thick '12,10'
    $tb.FontSize = 12.5
    $tb.Margin = Get-Thick '0,6,0,0'
    [System.Windows.Automation.AutomationProperties]::SetName($tb, $Header)
    $ex.Content = $tb
    return $ex
}
$script:PrivacyExpander = New-DocExpander 'Privacy Policy' 'PRIVACY.md'
$script:TermsExpander = New-DocExpander 'Terms of Use' 'TERMS.md'
$script:LicenseExpander = New-DocExpander 'License (MIT)' 'LICENSE'
$script:SecurityExpander = New-DocExpander 'Security & genuine copies' 'SECURITY.md'
foreach ($e in $script:PrivacyExpander, $script:TermsExpander, $script:LicenseExpander, $script:SecurityExpander) { [void]$aboutPanel.Children.Add($e) }

$script:ActionButtons = @($ui.BtnRecommended, $ui.BtnNone, $ui.BtnPreview, $ui.BtnApply, $btnScan, $btnUndo, $btnUndoRefresh, $btnOneClick, $btnHomeScan, $btnUndoAll, $btnRestart, $btnPutBack, $btnThatWasMe, $btnSpaceLook, $btnSpaceBack)

# ------------------------------------------------------------------ links
function Show-Doc($expander) {
    $ui.Tabs.SelectedIndex = $ui.Tabs.Items.Count - 1
    $expander.IsExpanded = $true
    $expander.BringIntoView()
}
$ui.LinkHeader.Add_Click({ Open-AsUser $info.BrandUrl })
$ui.LinkFooter.Add_Click({ Open-AsUser $info.BrandUrl })
$ui.LinkContact.Add_Click({ Open-AsUser "mailto:$($info.BrandEmail)?subject=Quietpane" })
$ui.LinkPrivacy.Add_Click({ Show-Doc $script:PrivacyExpander })
$ui.LinkTerms.Add_Click({ Show-Doc $script:TermsExpander })
function Update-PlaceControls {
    # The button and the tick box always show how things really are. The one button does both jobs,
    # so there is only ever one thing to click.
    try {
        $s = Test-QpShortcuts
        $btnShortcut.Content = if ($s.StartMenu -or $s.Desktop) { 'Remove from Start menu and desktop' } else { 'Add to Start menu and desktop' }
        $task = Get-QpSignInTask
        $on = [bool]($task -and "$($task.State)" -ne 'Disabled')
        $script:SignInBox.IsChecked = $on
        $script:WatchBox.IsEnabled = $on
        $script:WatchBox.Opacity = $(if ($on) { 1.0 } else { 0.55 })
        $script:WatchBox.ToolTip = $(if ($on) { $null } else { 'Tick "Start Quietpane when I sign in" first.' })
        $script:WatchBox.IsChecked = ($on -and (Test-QpTaskWatches $task))
    } catch { }
}
# Taken away while this copy is the one open: it goes to the Recycle Bin once the window closes.
$script:RemoveCopyOnClose = $false
function Set-CopyFollowUp($Result) {
    if ($Result.Copy -eq 'Later') { $script:RemoveCopyOnClose = $true }
    elseif ($Result.Ok -and -not $Result.Copy) { $script:RemoveCopyOnClose = $false }   # added again: keep it
}
$btnShortcut.Add_Click({
    if (Test-Busy) { return }
    $s = Test-QpShortcuts
    try {
        if ($s.StartMenu -or $s.Desktop) {
            $msg = "Remove Quietpane from your Start menu and desktop?`n`nThe shortcuts go to your Recycle Bin."
            if ([System.Windows.MessageBox]::Show($msg, 'Quietpane', 'YesNo', 'Question') -ne 'Yes') { return }
            $r = Remove-QpShortcuts
        } else {
            $r = New-QpShortcuts
        }
        Set-CopyFollowUp $r
        [void][System.Windows.MessageBox]::Show($r.Note, 'Quietpane')
    } catch {
        [void][System.Windows.MessageBox]::Show("That did not work: $($_.Exception.Message)", 'Quietpane')
    }
    Update-PlaceControls
})
# Click, not Checked: only a person ticking the box changes anything, never the window updating it.
$script:SignInBox.Add_Click({
    if (Test-Busy) { Update-PlaceControls; return }
    try {
        $r = if ($script:SignInBox.IsChecked) { Enable-QpSignInStart } else { Disable-QpSignInStart }
        Set-CopyFollowUp $r
        # The tick itself says it worked; only a problem, or something now in the Recycle Bin, needs words.
        if (-not $r.Ok -or $r.Copy -in 'Recycled', 'Later', 'Failed') { [void][System.Windows.MessageBox]::Show($r.Note, 'Quietpane') }
        else { $ui.Status.Text = $r.Note }
    } catch {
        [void][System.Windows.MessageBox]::Show("That did not work: $($_.Exception.Message)", 'Quietpane')
    }
    Update-PlaceControls
})
$script:WatchBox.Add_Click({
    if (Test-Busy) { Update-PlaceControls; return }
    try {
        # The sign-in task carries this choice, so changing it means setting the task up again.
        $r = Enable-QpSignInStart -Watch:([bool]$script:WatchBox.IsChecked)
        if (-not $r.Ok) { [void][System.Windows.MessageBox]::Show($r.Note, 'Quietpane') }
        elseif ($script:WatchBox.IsChecked) { $ui.Status.Text = $r.Note }
        else { $ui.Status.Text = 'Quietpane will no longer check when you sign in. It still starts on the taskbar.' }
    } catch {
        [void][System.Windows.MessageBox]::Show("That did not work: $($_.Exception.Message)", 'Quietpane')
    }
    Update-PlaceControls
})

$btnSite.Add_Click({ Open-AsUser $info.BrandUrl })
$btnRepo.Add_Click({ Open-AsUser $info.RepoUrl })
$btnMail.Add_Click({ Open-AsUser "mailto:$($info.BrandEmail)?subject=Quietpane" })
$btnData.Add_Click({
    if (Test-Path $info.DataRoot) { Open-AsUser $info.DataRoot }
    else { [void][System.Windows.MessageBox]::Show('Nothing saved yet. Restore points show up here after your first change.', 'Quietpane') }
})

# ------------------------------------------------------------------ background worker
$script:Sync = [hashtable]::Synchronized(@{ Queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'; Result = $null; Progress = $null; Cancel = $false })
$script:Job = $null
$script:FirstLoad = $true
$script:LastReport = $null
$script:LastRestorePoint = $null
$script:HomeCounts = $null
$script:LogVisible = $false
$script:ScanRunning = $false
$script:ScanStarted = Get-Date
$script:ScanSeconds = 0
$script:LastScanResult = $null
# What has actually been done to findings since the last check, for the summary at the end.
$script:ActionTally = [ordered]@{ Removed = 0; Quarantined = 0; Recycled = 0; Deleted = 0; Allowed = 0; Failed = 0 }

function Select-Tab([string]$Tag) {
    # Tabs are found by name, not position, so adding a tab never sends a button to the wrong place.
    foreach ($t in $ui.Tabs.Items) { if ([string]$t.Tag -eq $Tag) { $ui.Tabs.SelectedItem = $t; return } }
}

function Update-TickCount {
    <# The Apply button says how much it is about to do, so nothing is a surprise. #>
    try {
        $n = 0
        foreach ($k in (Get-TabOptionKeys)) { $n += @($script:Options[$k] | Where-Object { $_.CheckBox.IsChecked }).Count }
        $ui.BtnApply.Content = if ($n -gt 0) { "Apply $n selected" } else { 'Apply selected' }
    } catch { }
}

function Update-Buttons {
    $key = [string]$ui.Tabs.SelectedItem.Tag
    $optionTab = $key -in 'privacy', 'vendors', 'apps', 'cleanup'
    $idle = -not $script:Job
    # The pick-and-choose buttons only appear on the tabs where they do something.
    $ui.AdvancedButtons.Visibility = if ($optionTab) { 'Visible' } else { 'Collapsed' }
    if ($optionTab) { Update-TickCount }
    foreach ($b in $ui.BtnRecommended, $ui.BtnNone, $ui.BtnPreview, $ui.BtnApply) { $b.IsEnabled = ($optionTab -and $idle) }
    foreach ($b in $btnScan, $btnUndo, $btnUndoRefresh, $btnOneClick, $btnHomeScan, $btnUndoAll, $btnRestart, $btnPutBack, $btnThatWasMe, $btnSpaceLook, $btnSpaceBack) { $b.IsEnabled = $idle }
    $btnUndoAll.IsEnabled = $idle -and [bool]$script:LastRestorePoint
    $btnOpenReport.IsEnabled = [bool]$script:LastReport
}

function Set-Busy([bool]$Busy, [string]$Text) {
    $ui.Status.Text = $Text
    if ($Busy) {
        foreach ($b in $script:ActionButtons) { $b.IsEnabled = $false }
        $window.Cursor = [System.Windows.Input.Cursors]::AppStarting
    } else {
        $window.Cursor = $null
        Update-Buttons
    }
}

function Test-Busy {
    <# One job at a time. Says so on screen, so a button never looks like it did nothing. #>
    if (-not $script:Job) { return $false }
    $ui.Status.Text = 'Something is already running - give it a moment, then try again.'
    return $true
}

function Start-Work {
    param([scriptblock]$Work, [hashtable]$Params = @{}, [scriptblock]$OnDone, [string]$StatusText = 'Working...')
    if (Test-Busy) { return }
    $script:Sync.Result = $null
    $script:Sync.Progress = $null
    $script:Sync.Cancel = $false
    $rs = [runspacefactory]::CreateRunspace()
    $rs.ApartmentState = 'STA'
    $rs.ThreadOptions = 'ReuseThread'
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('Sync', $script:Sync)
    $rs.SessionStateProxy.SetVariable('ModulePath', $modulePath)
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $wrapper = {
        param($WorkText, $Params)
        try {
            Import-Module $ModulePath -Force
            Set-QpLogSink { param($line) $Sync.Queue.Enqueue($line) }
            # Where the work says how far it has got, and how it asks whether Stop has been pressed.
            Set-QpProgressSink { param($p) $Sync.Progress = $p }
            Set-QpCancelCheck { [bool]$Sync.Cancel }
            $Sync.Result = & ([scriptblock]::Create($WorkText)) @Params
        } catch {
            $Sync.Queue.Enqueue(('[{0}] ERROR   {1}' -f (Get-Date -Format 'HH:mm:ss'), $_.Exception.Message))
        }
    }
    [void]$ps.AddScript($wrapper.ToString()).AddArgument($Work.ToString()).AddArgument($Params)
    $script:Job = @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke(); OnDone = $OnDone }
    Set-Busy $true $StatusText
    Set-TimerQuick
}

# ------------------------------------------------------------------ live readings
# A small reader of its own, separate from Start-Work, so the Home tiles never block a button. It only
# reads while Home is on screen and the window isn't minimised; the rest of the time it sleeps. That
# also matters on gaming laptops: asking the graphics card how it is doing shouldn't keep it awake.
$script:Live = [hashtable]::Synchronized(@{ Reading = $null; Seq = 0; Active = $false; Slow = $false; Stop = $false; Health = $null; HealthSeq = 0; Net = $null; NetSeq = 0; NetActive = $false
    Wake = New-Object System.Threading.AutoResetEvent $false })   # rings the reader awake the moment it is needed
$script:SessionWatch = $null
$script:SessionLast = $null
$script:SessionLastWatch = $null
$script:SessionShownAt = [datetime]::MinValue
$script:AlertBadge = $false
$script:LiveWasActive = $false
$script:NetSeqShown = 0
$script:LiveSeqShown = 0
$script:HealthSeqShown = 0
$script:LiveJob = $null

function Start-LiveSampler {
    if ($script:LiveJob) { return }
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('Live', $script:Live)
    $rs.SessionStateProxy.SetVariable('ModulePath', $modulePath)
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        Import-Module $ModulePath -Force
        $monitor = $null
        $healthAt = [datetime]::MinValue
        $netAt = [datetime]::MinValue
        while (-not $Live.Stop) {
            # Who is talking to the internet: only while that section is open, and only every 5 seconds.
            if ($Live.NetActive -and ((Get-Date) - $netAt).TotalSeconds -ge 5) {
                try { $Live.Net = Get-QpConnections; $Live.NetSeq = $Live.NetSeq + 1 } catch { }
                $netAt = Get-Date
            }
            if ($Live.Active) {
                # A reading that goes wrong must never stop the ones after it.
                try {
                    # Nothing is set up until the Health tab is first opened.
                    if (-not $monitor) { $monitor = New-QpLiveMonitor; Start-Sleep -Milliseconds 1000 }   # load is measured between two moments
                    $Live.Reading = Get-QpLiveReading -Monitor $monitor
                    $Live.Seq = $Live.Seq + 1
                } catch { $monitor = $null }
                # Battery and drive health change slowly: read on opening, then every five minutes.
                if (((Get-Date) - $healthAt).TotalMinutes -ge 5) {
                    try {
                        # Free space is here too: it is what the "drive is filling up" warning needs, and
                        # it changes far too slowly to be worth asking about every two seconds.
                        $free = $null
                        try {
                            $d = New-Object IO.DriveInfo ($env:SystemDrive + '\')
                            if ($d.TotalSize -gt 0) { $free = 100 * $d.AvailableFreeSpace / $d.TotalSize }
                        } catch { }
                        $Live.Health = @{ Battery = Get-QpBatteryHealth; Drive = Get-QpDriveHealth; Steady = Get-QpReliability; FreePct = $free }
                        $Live.HealthSeq = $Live.HealthSeq + 1
                    } catch { }
                    $healthAt = Get-Date
                }
                # Two seconds while you are watching the tiles; ten while it is only keeping the record.
                $ticks = if ($Live.Slow) { 50 } else { 10 }
                for ($i = 0; $i -lt $ticks -and -not $Live.Stop; $i++) { Start-Sleep -Milliseconds 200 }
            } else {
                # Nothing to read: sleep until the window rings, rather than checking in every moment.
                [void]$Live.Wake.WaitOne(5000)
            }
        }
    }.ToString())
    $script:LiveJob = @{ PS = $ps; RS = $rs; Handle = $ps.BeginInvoke() }
}

function Stop-LiveSampler {
    if (-not $script:LiveJob) { return }
    $script:Live.Stop = $true
    try { [void]$script:Live.Wake.Set() } catch { }   # wake it, so it notices straight away
    $job = $script:LiveJob
    $script:LiveJob = $null
    try { [void]$job.Handle.AsyncWaitHandle.WaitOne(1500) } catch { }
    try { $job.PS.Dispose(); $job.RS.Dispose() } catch { }
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(150)
# The clock only runs quickly while there is something to watch - a job, the Health readings or the
# internet list. Otherwise it slows right down, so a Quietpane that is just sitting there costs nothing.
function Set-TimerQuick { if ($timer.Interval.TotalMilliseconds -ne 150) { $timer.Interval = [TimeSpan]::FromMilliseconds(150) } }
$timer.Add_Tick({
    $line = $null
    $got = $false
    while ($script:Sync.Queue.TryDequeue([ref]$line)) { $ui.LogBox.AppendText($line + [Environment]::NewLine); $got = $true }
    if ($got) { $ui.LogBox.ScrollToEnd() }
    if ($script:Job -and $script:ScanRunning) { Update-ScanProgress }
    if ($script:Job -and $script:SpaceRunning) { Update-SpaceProgress }
    # Readings are taken while the Health tab is showing - and, if you asked it to watch the session,
    # while you are somewhere else as well, but then only every ten seconds.
    $onHealth = ([string]$ui.Tabs.SelectedItem.Tag -eq 'health') -and ($window.WindowState -ne 'Minimized')
    if ($script:AlertBadge -and $window.WindowState -ne 'Minimized') { Clear-AlertBadge }
    $script:Live.Active = $onHealth -or ($null -ne $script:SessionWatch)
    $script:Live.Slow = (-not $onHealth) -and ($null -ne $script:SessionWatch)
    $script:Live.NetActive = ([string]$ui.Tabs.SelectedItem.Tag -eq 'privacy') -and $script:NetSection.Expander.IsExpanded -and ($window.WindowState -ne 'Minimized')
    $liveNow = $script:Live.Active -or $script:Live.NetActive
    if ($liveNow -and -not $script:LiveWasActive) { [void]$script:Live.Wake.Set() }
    $script:LiveWasActive = $liveNow
    if ($script:Live.NetSeq -ne $script:NetSeqShown) {
        $script:NetSeqShown = $script:Live.NetSeq
        try { Update-NetList $script:Live.Net } catch { }   # a reading must never be able to break the window
    }
    if ($script:Live.HealthSeq -ne $script:HealthSeqShown) {
        $script:HealthSeqShown = $script:Live.HealthSeq
        try { $script:BatteryHealth = $script:Live.Health.Battery; Update-DriveCard $script:Live.Health.Drive } catch { }
        try { Update-SteadyCard $script:Live.Health.Steady } catch { }
    }
    if ($script:Live.Seq -ne $script:LiveSeqShown) {
        $script:LiveSeqShown = $script:Live.Seq
        # The record is kept whether or not the tab is in front: that is what makes it a session.
        if ($script:SessionWatch) {
            try {
                [void](Add-QpSessionSample -Watch $script:SessionWatch -Reading $script:Live.Reading)
                $free = if ($script:Live.Health) { $script:Live.Health.FreePct } else { $null }
                Show-SessionAlerts (Update-QpSessionAlerts -Watch $script:SessionWatch -Reading $script:Live.Reading -FreePct $free)
            } catch { }
        }
        try { Update-LiveTiles $script:Live.Reading } catch { }   # a reading must never be able to break the window
    }
    if ($script:SessionWatch -and ((Get-Date) - $script:SessionShownAt).TotalSeconds -ge 2) { try { Update-SessionCard } catch { } }
    if ($script:Job -and $script:Job.Handle.IsCompleted) {
        $job = $script:Job
        $script:Job = $null
        try { [void]$job.PS.EndInvoke($job.Handle) } catch { $ui.LogBox.AppendText("ERROR: $($_.Exception.Message)" + [Environment]::NewLine) }
        $job.PS.Dispose()
        $job.RS.Dispose()
        # Each job runs in its own worker that is thrown away afterwards; hand its memory back now rather
        # than whenever .NET gets round to it, so the app stays small between jobs.
        [GC]::Collect()
        while ($script:Sync.Queue.TryDequeue([ref]$line)) { $ui.LogBox.AppendText($line + [Environment]::NewLine) }
        $ui.LogBox.ScrollToEnd()
        Set-Busy $false 'All done - nothing running.'
        if ($job.OnDone) { & $job.OnDone $script:Sync.Result }
    }
    $wanted = if ($script:Job -or $script:Live.Active -or $script:Live.NetActive) { 150 } elseif ($window.WindowState -eq 'Minimized') { 2000 } else { 750 }
    if ($timer.Interval.TotalMilliseconds -ne $wanted) { $timer.Interval = [TimeSpan]::FromMilliseconds($wanted) }
})

# ------------------------------------------------------------------ refresh state from the PC
function Set-OptionStatus($opt, [string]$Status) {
    $opt.Status = $Status
    switch ($Status) {
        'Applied'       { $opt.Label.Text = "$($opt.Title)   [already applied]"; $opt.Label.Foreground = Get-Brush '#117A68' }
        'Partial'       { $opt.Label.Text = "$($opt.Title)   [partly applied]";  $opt.Label.Foreground = Get-Brush '#9A6700' }
        'NotApplicable' { $opt.Label.Text = "$($opt.Title)   [not on this PC]";  $opt.Label.Foreground = Get-Brush '#66706F' }
        default         { $opt.Label.Text = $opt.Title;                          $opt.Label.Foreground = Get-Brush '#0F1B1C' }
    }
}

function Select-Recommended([string]$Key) {
    foreach ($o in $script:Options[$Key]) {
        $o.CheckBox.IsChecked = ($o.Recommended -and $o.Status -notin 'Applied', 'NotApplicable')
    }
}

function Update-FromState($state) {
    if (-not $state) {
        $ui.Status.Text = 'Could not read this PC. Press "Show details" to see why, then try again.'
        return
    }
    $script:LastState = $state
    # Each part draws on its own: a part that cannot be drawn must not stop the rest appearing.
    function Show-Part([string]$What, [scriptblock]$Body) {
        try { & $Body } catch { $ui.LogBox.AppendText(('[{0}] WARN    Could not show {1}: {2}' -f (Get-Date -Format 'HH:mm:ss'), $What, $_.Exception.Message) + [Environment]::NewLine) }
    }
    foreach ($o in $script:Options['privacy']) { Set-OptionStatus $o ([string]$state.Privacy[$o.Id]) }
    Show-Part 'the brand extras' { Update-VendorTab @($state.Vendors) }
    Show-Part 'what starts at sign-in' { Update-StartupList @($state.Startup | Where-Object { $_ }) $state.SignIn }
    Show-Part 'camera, microphone and location use' { Update-DeviceList @($state.Devices | Where-Object { $_ }) }
    Show-Part 'your browser add-ons' { Update-AddonList @($state.Addons | Where-Object { $_ }) }
    if (@($state.Problems).Count) {
        $ui.Status.Text = 'Some of this PC could not be read: ' + (@($state.Problems) -join ', ') + '. The rest is up to date.'
    }
    $script:AppsList.Children.Clear()
    $script:Options['apps'].Clear()
    $apps = @($state.Apps | Where-Object { $_ })
    $script:RemoveSection.Expander.Header = New-Text ('Apps you could remove   ({0} found)' -f $apps.Count) 14.5 'SemiBold' '#117A68' '0' 'Fraunces, Georgia'
    if ($apps.Count -eq 0) { [void]$script:AppsList.Children.Add((New-Text 'No known bloat apps found on this PC.' 13 'SemiBold' '#117A68')) }
    foreach ($a in $apps) { Add-Option -Panel $script:AppsList -Key 'apps' -Id $a.Name -Title $a.Title -Short $a.Description -Description ('{0}  (Windows calls it {1}.)' -f $a.Description, $a.Name) -Recommended ([bool]$a.Recommended) }
    $script:CleanupList.Children.Clear()
    $script:Options['cleanup'].Clear()
    foreach ($c in @($state.Cleanup | Where-Object { $_ })) {
        $title = '{0}   ({1})' -f $c.Title, (Format-QpBytes $c.SizeBytes)
        Add-Option -Panel $script:CleanupList -Key 'cleanup' -Id $c.Id -Title $title -Description $c.Description -Recommended ([bool]$c.Recommended)
        if ($c.SizeBytes -le 0) {
            $last = $script:Options['cleanup'][$script:Options['cleanup'].Count - 1]
            Set-OptionStatus $last 'NotApplicable'
            $last.Label.Text = "$title   [nothing to clean]"
        }
    }
    Show-Part 'the restore points' { Update-UndoList @($state.Restore) }
    Show-Part 'the quarantine' { Update-QuarantineList }
    Show-Part 'the Home cards' { Update-HomeCards $state }
    # What switched itself back on since last time. Skipped in self-test, which must change nothing,
    # and skipped when part of the read failed: a part that came back empty would look like things
    # switching themselves back on, and that would be a lie.
    if (-not $SelfTest -and -not @($state.Problems).Count) {
        $drift = $null
        try { $drift = Update-QpQuietNote -State $state -Accept:$script:AcceptQuiet } catch { }
        $script:AcceptQuiet = $false
        Update-CameBack $drift
    }
    if ($script:FirstLoad) {
        foreach ($k in 'privacy', 'devices', 'extensions', 'vendors', 'apps', 'startup', 'cleanup') { Select-Recommended $k }
        $script:FirstLoad = $false
    } else {
        foreach ($k in 'devices', 'extensions', 'apps', 'startup', 'cleanup', 'vendors') { Select-Recommended $k }
        foreach ($o in $script:Options['privacy']) { if ($o.Status -in 'Applied', 'NotApplicable') { $o.CheckBox.IsChecked = $false } }
    }
}

$script:CameBack = $null
$script:LastState = $null

function New-BadgeImage([int]$Count) {
    # A small amber circle with the number in it, drawn here rather than shipped as a picture.
    $g = New-Object System.Windows.Controls.Grid
    $g.Width = 32; $g.Height = 32
    $dot = New-Object System.Windows.Shapes.Ellipse
    $dot.Fill = Get-Brush '#FFB627'; $dot.Stroke = Get-Brush '#0F1B1C'; $dot.StrokeThickness = 2
    [void]$g.Children.Add($dot)
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = if ($Count -gt 9) { '9+' } else { "$Count" }
    $t.FontFamily = 'Segoe UI'; $t.FontWeight = 'Bold'; $t.FontSize = $(if ($Count -gt 9) { 14 } else { 19 })
    $t.Foreground = Get-Brush '#0F1B1C'; $t.HorizontalAlignment = 'Center'; $t.VerticalAlignment = 'Center'
    [void]$g.Children.Add($t)
    $size = [System.Windows.Size]::new(32, 32)
    $g.Measure($size); $g.Arrange([System.Windows.Rect]::new($size)); $g.UpdateLayout()
    $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap(32, 32, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($g)
    $bmp.Freeze()
    return $bmp
}

function Update-TaskbarBadge($d) {
    <#
        While something that switched itself back on is waiting for you, Quietpane's taskbar icon carries
        a small badge with the number, and the window's name says what it is - which is also what a
        screen reader reads for the taskbar button. Dealt with, both go back to normal.
    #>
    try {
        if (-not $window.TaskbarItemInfo) { $window.TaskbarItemInfo = New-Object System.Windows.Shell.TaskbarItemInfo }
        if ($d -and $d.Count) {
            $what = if ($d.Count -eq 1) { '1 thing switched itself back on' } else { "$($d.Count) things switched themselves back on" }
            $window.TaskbarItemInfo.Overlay = New-BadgeImage ([int]$d.Count)
            $window.TaskbarItemInfo.Description = "Quietpane: $what"
            $window.Title = "Quietpane - $what"
        } else {
            $window.TaskbarItemInfo.Overlay = $null
            $window.TaskbarItemInfo.Description = ''
            $window.Title = 'Quietpane - by KomodoWorks'
        }
    } catch { }
}

function Update-CameBack($d) {
    <# The "welcome back" panel: what switched itself back on, since when, and the likely reason. #>
    $script:CameBack = $d
    Update-TaskbarBadge $d
    if (-not $d -or -not $d.Count) { $script:BackPanel.Visibility = 'Collapsed'; return }
    $settings = @($d.Privacy).Count + @($d.Vendors).Count
    $what = @()
    if ($settings) { $what += $(if ($settings -eq 1) { '1 setting' } else { "$settings settings" }) }
    if (@($d.Apps).Count) { $what += $(if (@($d.Apps).Count -eq 1) { '1 app' } else { "$(@($d.Apps).Count) apps" }) }
    if (@($d.Startup).Count) { $what += $(if (@($d.Startup).Count -eq 1) { '1 startup item' } else { "$(@($d.Startup).Count) startup items" }) }
    $whatText = ($what -join ', ') -replace ', ([^,]+)$', ' and $1'
    $script:BackTitle.Text = if ($d.Count -eq 1) { 'Welcome back - one thing switched itself back on' } else { "Welcome back - $($d.Count) things switched themselves back on" }
    $since = if ($d.Since) { ' since {0}' -f $d.Since.ToString('d MMMM') } else { '' }
    $why = if ($d.WindowsUpdated) { " Windows has updated in between, $($d.WindowsChange), which is the usual reason." } else { ' Updates to Windows or to your apps are the usual reason.' }
    $script:BackText.Text = "$whatText came back on$since.$why"
    $names = @(@($d.Privacy) + @($d.Vendors) + @($d.Apps) + @($d.Startup) | ForEach-Object { if ($_.Title) { $_.Title } else { $_.Id } })
    $script:BackList.Text = ($names | Select-Object -First 8) -join ', '
    if ($names.Count -gt 8) { $script:BackList.Text += (' and {0} more' -f ($names.Count - 8)) }
    $script:BackPanel.Visibility = 'Visible'
}

$btnPutBack.Add_Click({
    $d = $script:CameBack
    if (-not $d -or -not $d.Count) { return }
    $msg = "Switch these off again?`n`n" + ((@(@($d.Privacy) + @($d.Vendors) + @($d.Apps) + @($d.Startup)) | ForEach-Object { '  - ' + $(if ($_.Title) { $_.Title } else { $_.Id }) }) -join "`n") + "`n`nOnly these change, a restore point is saved first, and Undo puts them back."
    if ([System.Windows.MessageBox]::Show($msg, 'Quietpane', 'YesNo', 'Question') -ne 'Yes') { return }
    $ui.LogBox.AppendText([Environment]::NewLine)
    $params = @{
        PrivacyIds = @($d.Privacy | ForEach-Object { $_.Id }); VendorIds = @($d.Vendors | ForEach-Object { $_.Id })
        AppNames = @($d.Apps | ForEach-Object { $_.Id }); StartupIds = @($d.Startup | ForEach-Object { $_.Id })
    }
    Start-Work -StatusText 'Switching them off again...' -Params $params -Work {
        param($PrivacyIds, $VendorIds, $AppNames, $StartupIds)
        Invoke-QpPutBack -PrivacyIds $PrivacyIds -VendorIds $VendorIds -AppNames $AppNames -StartupIds $StartupIds
    } -OnDone { Update-StateAfterChange }
})

$btnThatWasMe.Add_Click({
    # Your call: the note starts afresh from how things are now, and nothing is changed.
    if ($script:LastState) { try { [void](Update-QpQuietNote -State $script:LastState -Accept) } catch { } }
    Update-CameBack $null
})

function Update-StartupList($items, $signIn) {
    <#
        Only what is switched on can be ticked, worst first: what Windows timed at sign-in, then what is
        using the most memory. Everything else is summed up in a line, so the list stays short: what's
        already off, what's always left on (and why), and what a policy controls.
    #>
    $script:StartupList.Children.Clear()
    $script:Options['startup'].Clear()
    $costs = @{}
    foreach ($c in @($signIn.Costs | Where-Object { $_ })) { $costs[[string]$c.Id] = $c }
    $on     = @($items | Where-Object { $_.On -and -not $_.Keep -and -not $_.Locked } |
        Sort-Object -Property @{ Expression = { [double]($costs[[string]$_.Id].WindowsSeconds) }; Descending = $true },
                              @{ Expression = { [int]($costs[[string]$_.Id].MemoryMB) }; Descending = $true }, Name)
    $off    = @($items | Where-Object { -not $_.On -and -not $_.Keep } | Sort-Object Name)
    $kept   = @($items | Where-Object { $_.Keep })
    $locked = @($items | Where-Object { $_.Locked -and $_.On -and -not $_.Keep })
    $script:StartupSection.Expander.Header = New-Text ('Starts when you sign in   ({0} on, {1} off)' -f ($on.Count + @($kept | Where-Object On).Count + $locked.Count), ($off.Count + @($kept | Where-Object { -not $_.On }).Count)) 14.5 'SemiBold' '#117A68' '0' 'Fraunces, Georgia'
    if (-not $on.Count) { [void]$script:StartupList.Children.Add((New-Text 'Nothing extra starts when you sign in.' 13 'SemiBold' '#117A68' '0,8,0,0')) }
    else {
        # What this is costing you, measured: memory in use now, and Windows' own timing where it has one.
        $mb = (@($on | ForEach-Object { $costs[[string]$_.Id] } | Where-Object { $_ -and $_.Running }) | Measure-Object -Property MemoryMB -Sum).Sum
        if ($mb) { [void]$script:StartupList.Children.Add((New-Text ('Together they are using {0} right now.' -f (Format-QpBytes ([double]$mb * 1MB))) 12.5 'SemiBold' '#0F1B1C' '0,8,0,0')) }
        $boot = $signIn.Record.Boot
        if ($boot) {
            $line = 'Windows timed your last restart at {0} seconds, {1}.' -f $boot.Seconds, (Format-QpWhen $boot.When)
            $t = New-Text $line 12.5 'Normal' '#4B5B5C' '0,2,0,0'
            Set-MoreInfo $t ('{0} seconds to the desktop, then {1} more finishing off in the background. Windows only times a full restart - not waking from sleep - so this can be weeks old.' -f $boot.ToDesktopSeconds, $boot.AfterDesktopSeconds)
            [void]$script:StartupList.Children.Add($t)
        }
    }
    foreach ($i in $on) {
        $bits = @()
        if ($i.Note) { $bits += $i.Note }
        if ($i.Missing) { $bits += 'The program it points to is gone, so this does nothing - switching it off just tidies up.' }
        $who = if ($i.Publisher) { "From $($i.Publisher)." } else { 'The publisher isn''t recorded.' }
        if ($i.Everyone) { $who += ' Starts for everyone who uses this PC.' }
        $bits += $who
        if ($i.Command) { $bits += $i.Command }
        $cost = $costs[[string]$i.Id]
        Add-Option -Panel $script:StartupList -Key 'startup' -Id $i.Id -Title $i.Name -Recommended $false `
            -Short (Format-QpSignInCost $cost) -Description ($bits -join ' ')
    }
    if ($locked.Count) {
        [void]$script:StartupList.Children.Add((New-Text ('Set by a policy on this PC, so they stay as they are: ' + (($locked | ForEach-Object { $_.Name }) -join ', ') + '.') 12.5 'Normal' '#4B5B5C' '0,12,0,0'))
    }
    if ($off.Count) {
        [void]$script:StartupList.Children.Add((New-Text ('Already off: ' + (($off | ForEach-Object { $_.Name }) -join ', ') + '.') 12.5 'Normal' '#66706F' '0,12,0,0'))
    }
    $keptOn = @($kept | Where-Object On)
    if ($keptOn.Count) {
        $t = New-Text ('Always left on: ' + (($keptOn | ForEach-Object { $_.Name }) -join ', ') + '. Windows or your drivers need these.') 12.5 'Normal' '#66706F' '0,6,0,0'
        $t.ToolTip = ($keptOn | ForEach-Object { "$($_.Name): $($_.KeepWhy)" }) -join "`n"
        [void]$script:StartupList.Children.Add($t)
    }
    # Something important switched off by someone else: say so kindly, and leave the choice with them.
    foreach ($k in @($kept | Where-Object { -not $_.On })) {
        [void]$script:StartupList.Children.Add((New-Text ('{0} is switched off at sign-in. {1} If that wasn''t on purpose, turn it back on in Task Manager > Startup apps.' -f $k.Name, $k.KeepWhy) 12.5 'Normal' '#9A6700' '0,6,0,0'))
    }
}

function Update-AddonList($addons) {
    <#
        One line per add-on, the ones that see the most first: what it may read, whether it is on, and
        when it arrived. The browser's own parts are summed up in a line instead of filling the list.
    #>
    $script:AddonList.Children.Clear()
    $script:Options['extensions'].Clear()
    $all = @($addons | Where-Object { $_ })
    # The ones that see the most, first, whatever order they arrived in.
    $rank = @{ 'Everything' = 0; 'Watching' = 1; 'Ordinary' = 2 }
    $yours = @($all | Where-Object { -not $_.BuiltIn } |
        Sort-Object @{ Expression = { $rank[[string]$_.Reach.Level] } }, @{ Expression = { -not $_.On } }, Name)
    $parts = @($all | Where-Object { $_.BuiltIn })
    $wide = @($yours | Where-Object { $_.On -and $_.Reach.Everywhere })
    $sum = if (-not $yours.Count) { 'none of your own' }
           elseif ($wide.Count -eq 1) { '{0}, 1 reads every site' -f $yours.Count }
           elseif ($wide.Count) { '{0}, {1} read every site' -f $yours.Count, $wide.Count }
           else { '{0}, none reads every site' -f $yours.Count }
    $script:AddonSection.Expander.Header = New-Text ("Your browser add-ons   ($sum)") 14.5 'SemiBold' $(if ($wide.Count) { '#9A6700' } else { '#117A68' }) '0' 'Fraunces, Georgia'
    if (-not $all.Count) {
        [void]$script:AddonList.Children.Add((New-Text 'No browser that Quietpane knows about is installed here.' 13 'Normal' '#4B5B5C' '0,6,0,0'))
        return
    }
    if (-not $yours.Count) {
        [void]$script:AddonList.Children.Add((New-Text 'You have no add-ons of your own - only the parts your browsers came with.' 13 'SemiBold' '#117A68' '0,6,0,0'))
    }
    foreach ($e in $yours) {
        $where = if ($e.Profile) { '{0}, {1}' -f $e.Browser, $e.Profile } else { $e.Browser }
        $title = '{0}   ({1})' -f $e.Name, $where
        $more = @("$($e.Source).")
        if (@($e.Reach.Can).Count -gt 1) { $more += 'It also ' + ((@($e.Reach.Can) | Select-Object -Skip 1) -join ', and ') + '.' }
        if (@($e.Reach.Sites).Count) { $more += 'Sites: ' + (@($e.Reach.Sites) -join ', ') + '.' }
        if ($e.Reach.Unnamed) { $more += '{0} other permission(s) Quietpane has no plain words for.' -f $e.Reach.Unnamed }
        if ($e.PolicyRoot) { $more += 'Ticking it tells the browser not to load it. The browser will say an administrator blocked it, which is you, and Undo takes that away.' }
        $more += "Id: $($e.ExtId)."
        Add-Option -Panel $script:AddonList -Key 'extensions' -Id $e.Id -Title $title -Recommended $false `
            -Short (Format-QpExtensionUse $e) -Description ($more -join ' ')
        $opt = $script:Options['extensions'][$script:Options['extensions'].Count - 1]
        if ($e.Blocked) {
            Set-OptionStatus $opt 'NotApplicable'
            $opt.Label.Text = "$title   [switched off already]"
        } elseif ($e.Locked) {
            Set-OptionStatus $opt 'NotApplicable'
            $opt.Label.Text = "$title   [a policy on this PC decides]"
        } elseif (-not $e.PolicyRoot) {
            Set-OptionStatus $opt 'NotApplicable'
            $opt.Label.Text = "$title   [switch this off in $($e.Browser) itself]"
        }
    }
    if ($parts.Count) {
        $names = @($parts | ForEach-Object { '{0} ({1})' -f $_.Name, $_.Browser })
        $t = New-Text ('{0} more are part of the browsers themselves, like their PDF viewer and their store.' -f $parts.Count) 12.5 'Normal' '#66706F' '0,12,0,0'
        Set-MoreInfo $t ($names -join "`n")
        [void]$script:AddonList.Children.Add($t)
    }
}

$script:DesktopSwitchNote = @{
    webcam     = 'video calls in your browser, Zoom, Teams and Discord'
    microphone = 'calls, voice chat in games and voice typing in your browser'
    location   = 'maps and weather sites in your browser'
}
function Update-DeviceList($devices) {
    <#
        One short block per device: a tick box for each Store app allowed to use it, what else used it
        and when, and Windows' single switch for all desktop programs. Everything else is one line.
    #>
    $script:DeviceList.Children.Clear()
    $script:Options['devices'].Clear()
    $users = @{}; $live = @()
    foreach ($d in @($devices | Where-Object { $_ })) {
        $apps = @($d.Apps | Where-Object { $_ })
        $used = @($apps | Where-Object { $_.LastUsed })
        foreach ($u in $used) { $users[$u.Name] = $true }
        if (@($used | Where-Object { $_.InUse }).Count) { $live += $d.Name }
        [void]$script:DeviceList.Children.Add((New-Text ($d.Name.Substring(0, 1).ToUpper() + $d.Name.Substring(1)) 14 'SemiBold' '#0F1B1C' '0,14,0,0'))
        if (-not $d.PcOn) { [void]$script:DeviceList.Children.Add((New-Text "Switched off for the whole PC, so nothing can use the $($d.Name) right now." 12.5 'Normal' '#117A68' '0,2,0,0')) }
        elseif (-not $d.UserOn) { [void]$script:DeviceList.Children.Add((New-Text "Switched off for your account, so none of your apps can use the $($d.Name) right now." 12.5 'Normal' '#117A68' '0,2,0,0')) }

        # Store apps have a switch each. While the device is off altogether there's nothing to switch.
        $open = $d.PcOn -and $d.UserOn
        $switchable = @($apps | Where-Object { $open -and $_.Type -eq 'App' -and -not $_.Locked -and $_.Setting -eq 'Allow' })
        foreach ($a in $switchable) {
            $when = if ($a.InUse) { "Using the $($d.Name) right now." } elseif ($a.LastUsed) { "Last used it $(Format-QpWhen $a.LastUsed)." } else { 'Allowed to, but has never used it.' }
            Add-Option -Panel $script:DeviceList -Key 'devices' -Id $a.Id -Title $a.Name -Description $when -Recommended $false
            $script:Options['devices'][$script:Options['devices'].Count - 1].CheckBox.ToolTip = "Store app: $($a.Path)"
        }

        # Desktop programs and Windows' own apps: listed, because Windows gives them no switch of their own.
        $others = @($used | Where-Object { $_.Type -eq 'Desktop' -or $_.Locked -or -not $open })
        if ($others.Count) {
            $shown = @($others | Select-Object -First 6 | ForEach-Object {
                $w = if ($_.InUse) { 'right now' } else { Format-QpWhen $_.LastUsed }
                if ($_.Missing) { $w += ', since moved or removed' }
                "$($_.Name) ($w)"
            })
            $more = if ($others.Count -gt 6) { " and $($others.Count - 6) more" } else { '' }
            $lead = if (@($switchable | Where-Object { $_.LastUsed }).Count) { 'Also used by' } else { 'Used by' }
            $t = New-Text ("$lead " + ($shown -join ', ') + "$more.") 12.5 'Normal' '#4B5B5C' '0,8,0,0'
            $t.ToolTip = ($others | ForEach-Object { "$($_.Name): $($_.Path)" }) -join "`n"
            [void]$script:DeviceList.Children.Add($t)
        }
        $desktop = @($used | Where-Object { $_.Type -eq 'Desktop' -and $_.Name -ne 'Windows itself' })
        if ($open -and $d.DesktopOn -and $desktop.Count) {
            Add-Option -Panel $script:DeviceList -Key 'devices' -Id $d.DesktopId -Title "Stop all desktop programs using the $($d.Name)" -Recommended $false `
                -Short ('Covers every one - {0} too.' -f $script:DesktopSwitchNote[$d.Kind]) `
                -Description ("Windows can't stop one desktop program at a time, so this covers every one of them - {0} too. Leave it unticked if you use those." -f $script:DesktopSwitchNote[$d.Kind])
        } elseif (-not $d.DesktopOn) {
            [void]$script:DeviceList.Children.Add((New-Text "Desktop programs are already blocked from the $($d.Name)." 12.5 'Normal' '#66706F' '0,6,0,0'))
        }

        $asks = @($apps | Where-Object { $open -and $_.Type -eq 'App' -and $_.Asks })
        if ($asks.Count) { [void]$script:DeviceList.Children.Add((New-Text ('Will ask you first: ' + (($asks | ForEach-Object { $_.Name }) -join ', ') + '.') 12.5 'Normal' '#66706F' '0,6,0,0')) }
        $off = @($apps | Where-Object { $_.Type -eq 'App' -and $_.Setting -eq 'Deny' })
        if ($off.Count) { [void]$script:DeviceList.Children.Add((New-Text ('Already switched off: ' + (($off | ForEach-Object { $_.Name }) -join ', ') + '.') 12.5 'Normal' '#66706F' '0,6,0,0')) }
        if (-not $apps.Count) { [void]$script:DeviceList.Children.Add((New-Text 'Nothing has used it or asked to.' 12.5 'Normal' '#66706F' '0,4,0,0')) }
    }
    $sum = if ($live.Count) { ($live -join ' and ') + ' in use right now' } elseif ($users.Count -eq 1) { '1 app has used them' } else { "$($users.Count) apps have used them" }
    $script:DeviceSection.Expander.Header = New-Text ("Who used your camera, microphone and location   ($sum)") 14.5 'SemiBold' $(if ($live.Count) { '#9A6700' } else { '#117A68' }) '0' 'Fraunces, Georgia'
}

function Update-NetList($c) {
    <# One line per program: what it is, how many connections, and where they go. #>
    $script:NetList.Children.Clear()
    if (-not $c) { [void]$script:NetList.Children.Add((New-Text 'Having a look...' 13 'Normal' '#4B5B5C')); return }
    $programs = @($c.Programs | Where-Object { $_ })
    $count = if ($programs.Count -eq 1) { '1 program' } else { "$($programs.Count) programs" }
    $script:NetSection.Expander.Header = New-Text ("What's talking to the internet right now   ($count)") 14.5 'SemiBold' '#117A68' '0' 'Fraunces, Georgia'
    if (-not $programs.Count) {
        [void]$script:NetList.Children.Add((New-Text 'Nothing has a connection open at the moment.' 13 'SemiBold' '#117A68' '0,4,0,0'))
    }
    foreach ($p in $programs) {
        $conns = if ($p.Count -eq 1) { '1 connection' } else { "$($p.Count) connections" }
        $head = New-Text ('{0}   -   {1}' -f $p.Name, $conns) 13.5 'SemiBold' '#0F1B1C' '0,10,0,0'
        $head.ToolTip = $(if ($p.Path) { $p.Path } else { "Process $($p.ProcessId)" })
        [void]$script:NetList.Children.Add($head)
        $shown = @($p.Destinations | Select-Object -First 3 | ForEach-Object { $_.Text })
        $more = @($p.Destinations).Count - $shown.Count
        $line = 'To ' + ($shown -join ', ') + $(if ($more -gt 0) { " and $more more" } else { '' }) + '.'
        if ($p.Owners.Count) { $line += ' ' + (($p.Owners | Select-Object -First 3) -join ', ') + '.' }
        [void]$script:NetList.Children.Add((New-Text $line 12.5 'Normal' '#4B5B5C' '0,1,0,0'))
        if ($p.Reporting.Count) {
            [void]$script:NetList.Children.Add((New-Text ('Includes ' + (($p.Reporting | Select-Object -First 2) -join '; ') + '. Judged by the name alone, so it is a hint, not proof.') 12 'Normal' '#9A6700' '0,1,0,0'))
        }
    }
    if ($c.LocalOnly.Count) {
        [void]$script:NetList.Children.Add((New-Text ('Talking only on your own network, not the internet: ' + (($c.LocalOnly | Select-Object -First 6) -join ', ') + '.') 12 'Normal' '#66706F' '0,12,0,0'))
    }
}

# ------------------------------------------------------------------ where the space went
$script:SpaceRunning = $false
$script:SpaceStarted = Get-Date
$script:SpaceResult = $null
$script:SpaceCurrent = $null
$script:SpacePending = $null
$script:SpaceMoved = [int64]0
$script:SpaceAdviceCache = @{}
$script:GridLength = New-Object System.Windows.GridLengthConverter

$script:SpaceStops = $null
function Test-SpaceNearProgram($Node) {
    <#
        Does this hold a program's own files, or sit inside a folder that does? Your main folders are
        where you keep things, so a program somewhere inside one doesn't tie up everything else in it.
    #>
    if (-not $script:SpaceStops) {
        $userDir = [Environment]::GetFolderPath('UserProfile')
        $stops = New-Object System.Collections.ArrayList
        foreach ($f in 'Desktop', 'MyDocuments', 'MyMusic', 'MyPictures', 'MyVideos', 'UserProfile') { [void]$stops.Add([Environment]::GetFolderPath($f)) }
        foreach ($f in 'Downloads', 'OneDrive', 'Saved Games') { [void]$stops.Add((Join-Path $userDir $f)) }
        foreach ($f in (Split-Path $userDir -Parent), $env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial) { if ($f) { [void]$stops.Add($f) } }
        $script:SpaceStops = @($stops | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') })
    }
    if (-not $Node.IsFile -and $Node.ContainsProgram) { return $true }
    $x = $Node.Parent
    while ($x -and $x.Parent) {
        if ($script:SpaceStops -contains $x.Path.TrimEnd('\')) { return $false }
        if ($x.ContainsProgram) { return $true }
        $x = $x.Parent
    }
    return $false
}

function Get-SpaceAdvice($Node) {
    $key = [string]$Node.Path
    if (-not $script:SpaceAdviceCache.ContainsKey($key)) {
        $script:SpaceAdviceCache[$key] = Get-QpSpaceAdvice -Path $key -Installed $script:SpaceResult.Installed -NearProgram (Test-SpaceNearProgram $Node)
    }
    return $script:SpaceAdviceCache[$key]
}

function New-SpaceRow {
    <# One line: the name (click a folder to look inside), a bar and size, then Open and Recycle Bin. #>
    param($Node, [int64]$Of, [string]$Name, [string]$Sub, [int64]$Size)
    $g = New-Object System.Windows.Controls.Grid
    $g.Margin = Get-Thick '0,7,0,0'
    foreach ($w in '*', '176', '92', '190') { $c = New-Object System.Windows.Controls.ColumnDefinition; $c.Width = $script:GridLength.ConvertFromString($w); [void]$g.ColumnDefinitions.Add($c) }
    $left = New-Object System.Windows.Controls.StackPanel
    $left.VerticalAlignment = 'Center'
    $title = New-Object System.Windows.Controls.TextBlock
    $title.FontSize = 13.5
    $title.TextTrimming = 'CharacterEllipsis'
    if ($Node -and -not $Node.IsFile -and $Node.Children.Count -gt 0) {
        $link = New-Object System.Windows.Documents.Hyperlink
        [void]$link.Inlines.Add($Name)
        $link.Foreground = Get-Brush '#117A68'
        $link.Tag = $Node
        $link.ToolTip = 'Look inside'
        $link.Add_Click({ $script:SpaceCurrent = $this.Tag; Show-SpaceLevel })
        [void]$title.Inlines.Add($link)
    } else { $title.Text = $Name }
    [void]$left.Children.Add($title)
    if ($Sub) { [void]$left.Children.Add((New-Text $Sub 11.5 'Normal' '#66706F' '0,1,0,0')) }
    [void]$g.Children.Add($left)

    $track = New-Object System.Windows.Controls.Border
    $track.Width = 160; $track.Height = 8; $track.HorizontalAlignment = 'Left'; $track.VerticalAlignment = 'Center'
    $track.Background = Get-Brush '#E6DFCC'
    $fill = New-Object System.Windows.Controls.Border
    $fill.HorizontalAlignment = 'Left'
    $fill.Background = Get-Brush '#1FA187'
    $fill.Width = [math]::Max([double]2, [double]160 * [math]::Min([double]1, [double]$Size / [math]::Max([double]1, [double]$Of)))
    $track.Child = $fill
    [System.Windows.Controls.Grid]::SetColumn($track, 1)
    [void]$g.Children.Add($track)

    $sz = New-Text (Format-QpBytes $Size) 13 'SemiBold' '#0F1B1C' '0,0,12,0'
    $sz.TextAlignment = 'Right'; $sz.VerticalAlignment = 'Center'
    [System.Windows.Controls.Grid]::SetColumn($sz, 2)
    [void]$g.Children.Add($sz)

    if ($Node) {
        $buttons = New-Object System.Windows.Controls.StackPanel
        $buttons.Orientation = 'Horizontal'; $buttons.VerticalAlignment = 'Center'
        $open = New-Button 'Open' '0,0,6,0'
        $open.Tag = $Node
        $open.ToolTip = $Node.Path
        $open.Add_Click({ Open-SpaceItem $this.Tag })
        [void]$buttons.Children.Add($open)
        $a = Get-SpaceAdvice $Node
        if ($a.CanRecycle) {
            if ($script:SpaceResult.BinLimit -gt 0 -and $Node.Size -le $script:SpaceResult.BinLimit) {
                $bin = New-Button 'Recycle Bin' '0'
                $bin.Tag = $Node
                $bin.Add_Click({ Move-SpaceItem $this.Tag })
                [void]$buttons.Children.Add($bin)
            } else {
                $big = New-Text 'Too big for the bin' 11.5 'Normal' '#9A6700' '0'
                $big.VerticalAlignment = 'Center'
                $big.ToolTip = "Bigger than your Recycle Bin can hold, so Windows would delete it for good. Quietpane won't. If you're sure, delete it yourself in File Explorer."
                [void]$buttons.Children.Add($big)
            }
        } elseif ($a.Why) { $title.ToolTip = $a.Why }
        [System.Windows.Controls.Grid]::SetColumn($buttons, 3)
        [void]$g.Children.Add($buttons)
    }
    return $g
}

function Open-SpaceItem($Node) {
    # File Explorer opens as you, not as administrator. A file is shown highlighted in its folder.
    if (-not (Test-Path -LiteralPath $Node.Path)) { [void][System.Windows.MessageBox]::Show('It is not there any more. Look again to bring the list up to date.', 'Quietpane'); return }
    if ($Node.IsFile) { Start-Process -FilePath 'explorer.exe' -ArgumentList "/select,`"$($Node.Path)`"" } else { Open-AsUser $Node.Path }
}

function Show-SpaceLevel {
    <# The folder you're looking at: its biggest parts first, the rest summed up in one line. #>
    $r = $script:SpaceResult; $n = $script:SpaceCurrent
    if (-not $r -or -not $n) { return }
    $script:SpaceRows.Children.Clear()
    $isRoot = [object]::ReferenceEquals($n, $r.Tree)
    $parts = New-Object System.Collections.ArrayList
    $x = $n
    while ($x) { $parts.Insert(0, $(if ($x.Parent) { $x.Name } else { $x.Path.TrimEnd('\') })); $x = $x.Parent }
    $script:SpaceCrumb.Text = $parts -join '  >  '
    $script:SpaceCrumb.Visibility = 'Visible'
    $btnSpaceBack.Visibility = if ($isRoot) { 'Collapsed' } else { 'Visible' }
    # Inside a place Quietpane won't move (a game, a program), say once where to remove it properly.
    $banner = ''
    if (-not $isRoot) { $a = Get-SpaceAdvice $n; if (-not $a.CanRecycle -and $a.Why -notmatch 'Open it to pick') { $banner = $a.Why } }
    $script:SpaceBanner.Text = $banner
    $script:SpaceBanner.Visibility = if ($banner) { 'Visible' } else { 'Collapsed' }

    $of = if ($isRoot) { $r.Used } else { $n.Size }
    $items = New-Object System.Collections.ArrayList
    foreach ($c in $n.Children) { [void]$items.Add([pscustomobject]@{ Node = $c; Size = [int64]$c.Size }) }
    if ($isRoot -and $r.Hidden -gt 0) { [void]$items.Add([pscustomobject]@{ Node = $null; Size = $r.Hidden }) }
    $sorted = @($items | Sort-Object Size -Descending)
    foreach ($i in ($sorted | Select-Object -First 15)) {
        if (-not $i.Node) {
            [void]$script:SpaceRows.Children.Add((New-SpaceRow -Node $null -Of $of -Name $r.HiddenLabel -Sub 'Windows itself, its restore points, and files no one is allowed to look at' -Size $i.Size))
            continue
        }
        $c = $i.Node
        $a = Get-SpaceAdvice $c
        $sub = if ($a.Note -and -not $banner) { $a.Note }
               elseif ($c.IsFile) { 'Changed ' + (Format-QpWhen $c.Modified) }
               else { '{0:N0} files' -f $c.Files }
        [void]$script:SpaceRows.Children.Add((New-SpaceRow -Node $c -Of $of -Name $c.Name -Sub $sub -Size $c.Size))
    }
    $restCount = [int64]$n.OtherCount + @($sorted | Select-Object -Skip 15).Count
    $restSize = [int64]$n.OtherSize + [int64](($sorted | Select-Object -Skip 15 | Measure-Object -Property Size -Sum).Sum)
    if ($restCount -gt 0) {
        [void]$script:SpaceRows.Children.Add((New-SpaceRow -Node $null -Of $of -Name ('{0:N0} smaller items' -f $restCount) -Sub 'Each under 50 MB' -Size $restSize))
    }
}

function Show-SpaceWins {
    <#
        The easy wins, biggest first: the ones that are yours to move carry a button, and the ones only
        Windows can clear say where to do it. Each row can show exactly which files it means.
    #>
    $script:SpaceWins.Children.Clear()
    $wins = @($script:SpaceResult.Wins | Where-Object { $_ })
    $script:SpaceWinsHead.Visibility = 'Visible'
    $script:SpaceWinsNote.Visibility = 'Visible'
    if (-not $wins.Count) {
        [void]$script:SpaceWins.Children.Add((New-Text 'Nothing obvious to clear - no old installers, no forgotten downloads.' 12.5 'Normal' '#117A68' '0,6,0,0'))
        return
    }
    foreach ($w in $wins) {
        $card = New-Object System.Windows.Controls.Border
        $card.Background = Get-Brush '#FAF6EC'
        $card.BorderBrush = Get-Brush '#E6DFCC'
        $card.BorderThickness = Get-Thick '1'
        $card.Padding = Get-Thick '12,10'
        $card.Margin = Get-Thick '0,8,0,0'
        $sp = New-Object System.Windows.Controls.StackPanel

        $top = New-Object System.Windows.Controls.Grid
        foreach ($width in '*', '110') { $c = New-Object System.Windows.Controls.ColumnDefinition; $c.Width = $script:GridLength.ConvertFromString($width); [void]$top.ColumnDefinitions.Add($c) }
        $name = New-Text $w.Title 13.5 'SemiBold' '#0F1B1C' '0'
        [void]$top.Children.Add($name)
        $size = New-Text (Format-QpBytes $w.Bytes) 14 'SemiBold' '#117A68' '0'
        $size.TextAlignment = 'Right'
        [System.Windows.Controls.Grid]::SetColumn($size, 1)
        [void]$top.Children.Add($size)
        [void]$sp.Children.Add($top)

        $short = New-Text $w.Short 12.5 'Normal' '#4B5B5C' '0,3,0,0'
        Set-MoreInfo $short $w.Why
        [void]$sp.Children.Add($short)
        if ($w.Truncated) { [void]$sp.Children.Add((New-Text 'There may be more - Quietpane stopped looking after 20 seconds.' 11.5 'Normal' '#9A6700' '0,3,0,0')) }

        if ($w.CanRecycle -and $w.Count -gt 0) {
            $list = New-Object System.Windows.Controls.StackPanel
            $list.Visibility = 'Collapsed'
            $list.Margin = Get-Thick '0,6,0,0'
            foreach ($i in @($w.Items | Select-Object -First 12)) {
                $line = New-Text ('{0}   -   {1}, changed {2}' -f $i.Name, (Format-QpBytes $i.Bytes), (Format-QpWhen $i.When)) 12 'Normal' '#4B5B5C' '0,2,0,0'
                $line.ToolTip = $i.Path
                [void]$list.Children.Add($line)
            }
            if ($w.Count -gt 12) { [void]$list.Children.Add((New-Text ('and {0} more' -f ($w.Count - 12)) 12 'Normal' '#66706F' '0,2,0,0')) }

            $buttons = New-Object System.Windows.Controls.StackPanel
            $buttons.Orientation = 'Horizontal'
            $buttons.Margin = Get-Thick '0,8,0,0'
            $show = New-Button 'Show me which' '0,0,6,0'
            $show.Tag = $list
            $show.Add_Click({
                $panel = $this.Tag
                $panel.Visibility = if ($panel.Visibility -eq 'Visible') { 'Collapsed' } else { 'Visible' }
                $this.Content = if ($panel.Visibility -eq 'Visible') { 'Hide the list' } else { 'Show me which' }
            })
            [void]$buttons.Children.Add($show)
            $move = New-Button ('Move {0} to the Recycle Bin' -f $w.Count) '0'
            $move.Tag = $w
            $move.Add_Click({ Move-SpaceWin $this.Tag })
            [void]$buttons.Children.Add($move)
            [void]$sp.Children.Add($buttons)
            [void]$sp.Children.Add($list)
        } elseif ($w.Advice) {
            [void]$sp.Children.Add((New-Text $w.Advice 12.5 'Normal' '#9A6700' '0,6,0,0'))
        }
        $card.Child = $sp
        [void]$script:SpaceWins.Children.Add($card)
    }
}

function Move-SpaceWin($Win) {
    <# Everything in one suggestion, to the Recycle Bin, in a single restore point. #>
    if (Test-Busy) { return }
    $msg = "Move {0} file(s) to the Recycle Bin?`n`n{1}`n{2} in all.`n`nThey stay in the bin until you empty it, so you can still put them back." -f $Win.Count, $Win.Title, (Format-QpBytes $Win.Bytes)
    if ([System.Windows.MessageBox]::Show($msg, 'Quietpane', 'YesNo', 'Question') -ne 'Yes') { return }
    $ui.LogBox.AppendText([Environment]::NewLine)
    Set-LogVisible $true
    Start-Work -StatusText "Moving $($Win.Title.ToLower()) to the Recycle Bin..." -Params @{ Win = $Win } -Work {
        param($Win)
        Invoke-QpEasyWin -Win $Win
    } -OnDone {
        param($r)
        $r = @($r | Where-Object { $_ -and $_.PSObject.Properties['Moved'] })[-1]
        if (-not $r) { return }
        $script:SpaceMoved += [int64]$r.Bytes
        try { Update-UndoList @(Get-QpRestorePoints) } catch { }
        # Everything on screen was measured before that, so the drive is added up again.
        if ($r.Moved -gt 0) { Start-SpaceScan -Keep } else { Set-SpaceStatus }
    }
}

function Show-SpaceFiles {
    <# Your ten biggest files that are yours to move - not game or program files, which have their own way out. #>
    $script:SpaceFiles.Children.Clear()
    $files = New-Object System.Collections.ArrayList
    $stack = New-Object System.Collections.Stack
    $stack.Push($script:SpaceResult.Tree)
    while ($stack.Count) { $x = $stack.Pop(); foreach ($c in $x.Children) { if ($c.IsFile) { [void]$files.Add($c) } else { $stack.Push($c) } } }
    $shown = 0
    foreach ($f in @($files | Sort-Object Size -Descending)) {
        if (-not (Get-SpaceAdvice $f).CanRecycle) { continue }
        $where = Split-Path $f.Path -Parent
        if ($where.Length -gt 60) { $where = $where.Substring(0, 3) + '...' + $where.Substring($where.Length - 50) }
        [void]$script:SpaceFiles.Children.Add((New-SpaceRow -Node $f -Of $script:SpaceResult.Used -Name $f.Name -Sub ("In $where  -  changed $(Format-QpWhen $f.Modified)") -Size $f.Size))
        if (++$shown -ge 10) { break }
    }
    if (-not $shown) { [void]$script:SpaceFiles.Children.Add((New-Text 'None of your own files is bigger than 50 MB. Nice and tidy.' 12.5 'Normal' '#117A68' '0,6,0,0')) }
    $script:SpaceFilesHead.Visibility = 'Visible'
    $script:SpaceFilesNote.Visibility = 'Visible'
}

function Set-SpaceStatus {
    $r = $script:SpaceResult
    $text = '{0}  {1} used of {2}, {3} free. Looked at {4:N0} files in {5} s.' -f $r.Root.TrimEnd('\'), (Format-QpBytes $r.Used), (Format-QpBytes $r.Total), (Format-QpBytes $r.Free), $r.Files, [math]::Max(1, $r.Seconds)
    if ($r.Cloud -gt 0) { $text += " Another $(Format-QpBytes $r.Cloud) is online-only in OneDrive, taking no room here." }
    if ($script:SpaceMoved -gt 0) { $text += " Moved to the Recycle Bin: $(Format-QpBytes $script:SpaceMoved). The room comes back when you empty the bin." }
    $script:SpaceStatus.Text = $text
}

function Update-SpaceProgress {
    $secs = [int]((Get-Date) - $script:SpaceStarted).TotalSeconds
    $clock = '{0}:{1:00}' -f [int][math]::Floor($secs / 60), ($secs % 60)
    if ($script:Sync.Cancel) { $script:SpaceStatus.Text = "Stopping...   |   $clock"; return }
    $p = $script:Sync.Progress
    if (-not $p) { $script:SpaceStatus.Text = "Adding up folder sizes...   |   $clock"; return }
    $obj = [string]$p.Object
    if ($obj.Length -gt 70) { $obj = '...' + $obj.Substring($obj.Length - 67) }
    $script:SpaceStatus.Text = 'Looked in {0:N0} folders   |   {1}   |   {2}' -f $p.Scanned, $clock, $obj
}

function Start-SpaceScan {
    # -Keep carries the "moved to the Recycle Bin" total over a fresh look, after a tidy-up.
    param([switch]$Keep)
    if (Test-Busy) { return }
    $root = if ($script:SpaceDrive.SelectedItem) { [string]$script:SpaceDrive.SelectedItem } else { $env:SystemDrive + '\' }
    $script:SpaceRunning = $true
    $script:SpaceStarted = Get-Date
    if (-not $Keep) { $script:SpaceMoved = [int64]0 }
    $script:SpaceAdviceCache = @{}
    $btnSpaceStop.Visibility = 'Visible'
    $btnSpaceStop.IsEnabled = $true
    $script:SpaceStatus.Text = 'Adding up folder sizes...'
    # The clean-up sizes are already measured on this tab, so they are handed over rather than measured again.
    $cleanup = @()
    if ($script:LastState -and $script:LastState.Cleanup) { $cleanup = @($script:LastState.Cleanup | Where-Object { $_ }) }
    Start-Work -StatusText 'Adding up folder sizes...' -Params @{ Root = $root; Cleanup = $cleanup } -Work {
        param($Root, $Cleanup)
        $s = Get-QpSpaceUse -Root $Root
        $wins = @()
        if (-not $s.Cancelled) { $wins = @(Get-QpEasyWins -Space $s -Cleanup @($Cleanup | Where-Object { $_ })) }
        $s | Add-Member -NotePropertyName Wins -NotePropertyValue $wins -Force
        $s
    } -OnDone {
        param($r)
        $r = @($r | Where-Object { $_ -and $_.PSObject.Properties['Tree'] })[-1]
        $script:SpaceRunning = $false
        $btnSpaceStop.Visibility = 'Collapsed'
        if (-not $r -or $r.Cancelled) {
            $script:SpaceStatus.Text = $(if ($r) { 'Stopped. Nothing was changed.' } else { 'Could not look at that drive.' })
            return
        }
        $script:SpaceResult = $r
        $script:SpaceCurrent = $r.Tree
        Set-SpaceStatus
        Show-SpaceWins
        Show-SpaceLevel
        Show-SpaceFiles
    }
}

function Move-SpaceItem($Node) {
    if (Test-Busy) { return }
    $what = if ($Node.IsFile) { 'this file' } else { 'this folder and everything in it' }
    $msg = "Move $what to the Recycle Bin?`n`n$($Node.Path)`n$(Format-QpBytes $Node.Size)`n`nIt stays in the bin until you empty it, so you can still put it back."
    $a = Get-SpaceAdvice $Node
    if ($a.Note) { $msg += "`n`n$($a.Note)" }
    if ([System.Windows.MessageBox]::Show($msg, 'Quietpane', 'YesNo', 'Question') -ne 'Yes') { return }
    $script:SpacePending = $Node
    $ui.LogBox.AppendText([Environment]::NewLine)
    Start-Work -StatusText "Moving $($Node.Name) to the Recycle Bin..." -Params @{ Path = [string]$Node.Path; Size = [int64]$Node.Size; Near = [bool](Test-SpaceNearProgram $Node) } -Work {
        param($Path, $Size, $Near)
        Invoke-QpSpaceRecycle -Path $Path -SizeBytes $Size -NearProgram $Near
    } -OnDone {
        param($r)
        $r = @($r | Where-Object { $_ -and $_.PSObject.Properties['Ok'] })[-1]
        $n = $script:SpacePending
        $script:SpacePending = $null
        if ($r -and $r.Ok -and $n) {
            # Off the list and out of every total above it, without adding up the whole drive again.
            $p = $n.Parent
            if ($p) { [void]$p.Children.Remove($n) }
            while ($p) { $p.Size -= $n.Size; $p = $p.Parent }
            $script:SpaceMoved += [int64]$n.Size
            Set-SpaceStatus
            Show-SpaceLevel
            Show-SpaceFiles
            try { Update-UndoList @(Get-QpRestorePoints) } catch { }
        } elseif ($r -and $r.Note) {
            [void][System.Windows.MessageBox]::Show($r.Note, 'Quietpane')
        }
    }
}

$btnSpaceLook.Add_Click({ Start-SpaceScan })
$btnSpaceStop.Add_Click({ $script:Sync.Cancel = $true; $btnSpaceStop.IsEnabled = $false })
$btnSpaceBack.Add_Click({ if ($script:SpaceCurrent -and $script:SpaceCurrent.Parent) { $script:SpaceCurrent = $script:SpaceCurrent.Parent; Show-SpaceLevel } })

function Update-VendorTab($vendors) {
    # The Telemetry tab is built fresh each time: it only ever shows what is really on this PC.
    $script:VendorList.Children.Clear()
    $script:Options['vendors'].Clear()
    $script:JunkBoxes = New-Object System.Collections.ArrayList
    $vendors = @($vendors | Where-Object { $_ })
    if ($vendors.Count -eq 0) {
        $script:VendorIntro.Text = 'Nothing to do here - no brand software that Quietpane recognises.'
        return
    }
    $open = (@($vendors | ForEach-Object { $_.Open }) | Measure-Object -Sum).Sum
    $names = ($vendors | ForEach-Object { $_.Name }) -join ', '
    $script:VendorIntro.Text = if ($open -gt 0) {
        'Found software from {0}. There are {1} background thing(s) still switched on.' -f $names, $open
    } else {
        'Found software from {0}. Everything Quietpane can switch off is already off.' -f $names
    }
    foreach ($v in $vendors) {
        $head = if ($v.Open -gt 0) { '{0} - {1} still switched on' -f $v.Name, $v.Open } else { '{0} - all quiet' -f $v.Name }
        $sec = New-Section $head
        $sec.Expander.IsExpanded = ($v.Open -gt 0)
        if ($v.Note) { [void]$sec.Content.Children.Add((New-Text $v.Note 12.5 'Normal' '#4B5B5C' '0,0,0,6')) }
        foreach ($item in $v.Items) {
            Add-Option -Panel $sec.Content -Key 'vendors' -Id $item.Id -Title $item.Title -Description $item.Description -Recommended $item.Recommended
            Set-OptionStatus $script:Options['vendors'][$script:Options['vendors'].Count - 1] $item.Status
        }
        if ($v.Junk.Count) {
            [void]$sec.Content.Children.Add((New-Text 'Extras you could remove (optional)' 13 'SemiBold' '#0F1B1C' '0,14,0,2' 'Fraunces, Georgia'))
            [void]$sec.Content.Children.Add((New-Text 'Ordinary programs, not drivers. Removing can''t be undone, but the maker''s website has them.' 12.5 'Normal' '#4B5B5C' '0,0,0,4'))
            foreach ($j in $v.Junk) {
                $cb = New-Object System.Windows.Controls.CheckBox
                $cb.Margin = Get-Thick '0,8,0,0'
                $cb.VerticalContentAlignment = 'Center'
                $cb.Content = New-Text $j.Name 13.5 'SemiBold' '#0F1B1C' '2,0,0,0'
                [void]$sec.Content.Children.Add($cb)
                [void]$sec.Content.Children.Add((New-Text $j.Why 12.5 'Normal' '#4B5B5C' '22,2,0,0'))
                [void]$script:JunkBoxes.Add([pscustomobject]@{ Key = $j.Key; Name = $j.Name; CheckBox = $cb })
            }
            $btnJunk = New-Button 'Remove the ticked extras'
            $btnJunk.Margin = Get-Thick '0,10,0,0'
            $btnJunk.Add_Click({ Remove-TickedExtras })
            [void]$sec.Content.Children.Add($btnJunk)
        }
        [void]$script:VendorList.Children.Add($sec.Expander)
    }
}

function Remove-TickedExtras {
    if (Test-Busy) { return }
    $picked = @($script:JunkBoxes | Where-Object { $_.CheckBox.IsChecked })
    if ($picked.Count -eq 0) { [void][System.Windows.MessageBox]::Show('Tick the ones you want gone first.', 'Quietpane'); return }
    $list = ($picked | ForEach-Object { '  - ' + $_.Name }) -join [Environment]::NewLine
    $msg = "These programs will be removed using their own uninstallers:`n`n$list`n`n" +
           "This one CANNOT be undone by Quietpane. You can install them again from the maker's website any time.`n`n" +
           "Each uninstaller may show its own window. Go ahead?"
    if ([System.Windows.MessageBox]::Show($msg, 'Quietpane', 'YesNo', 'Warning') -ne 'Yes') { return }
    $keys = @($picked | ForEach-Object { $_.Key })
    $ui.LogBox.AppendText([Environment]::NewLine)
    Set-LogVisible $true
    Start-Work -StatusText 'Removing the extras you picked...' -Params @{ Keys = $keys } -Work { param($Keys) Invoke-QpVendorUninstall -Keys $Keys } -OnDone { Update-StateAfterChange }
}

function Update-HomeCards($state) {
    # Same rules as Get-QpRecommendedPlan in the engine: recommended items that are not done yet.
    $priv = @($script:Options['privacy'] | Where-Object { $_.Recommended -and $_.Status -in 'NotApplied', 'Partial' }).Count
    $apps = @($state.Apps | Where-Object { $_ -and $_.Recommended }).Count
    $bytes = [int64](@($state.Cleanup | Where-Object { $_ -and $_.Recommended -and $_.SizeBytes -gt 0 }) | Measure-Object -Property SizeBytes -Sum).Sum
    $vendors = @($state.Vendors | Where-Object { $_ })
    $brandOpen = [int](@($vendors | ForEach-Object { @($_.Items | Where-Object { $_.Recommended -and $_.Status -ne 'Applied' }).Count }) | Measure-Object -Sum).Sum
    $brandNames = ($vendors | ForEach-Object { $_.Name }) -join ', '
    $script:HomeCounts = [pscustomobject]@{ Privacy = $priv; Apps = $apps; Bytes = $bytes; Brands = $brandOpen; BrandNames = $brandNames; Total = $priv + $apps + [int]($bytes -gt 0) + [int]($brandOpen -gt 0) }

    $good = Get-Brush '#117A68'; $todo = Get-Brush '#0F1B1C'
    if ($priv) { $script:CardTracking.Value.Text = "$priv to switch off"; $script:CardTracking.Value.Foreground = $todo; $script:CardTracking.Caption.Text = 'Telemetry, ads and tips' }
    else { $script:CardTracking.Value.Text = 'All set'; $script:CardTracking.Value.Foreground = $good; $script:CardTracking.Caption.Text = 'Tracking and ads are already off' }
    if ($apps) { $script:CardApps.Value.Text = "$apps to remove"; $script:CardApps.Value.Foreground = $todo; $script:CardApps.Caption.Text = 'Pre-installed and promoted apps' }
    else { $script:CardApps.Value.Text = 'None found'; $script:CardApps.Value.Foreground = $good; $script:CardApps.Caption.Text = 'No known bloat apps on this PC' }
    # Startup is never part of one-click (what you want at sign-in is personal), so just point to it.
    $starting = @($state.Startup | Where-Object { $_ -and $_.On -and -not $_.Keep -and -not $_.Locked }).Count
    if ($starting) { $script:CardApps.Caption.Text += ('. {0} start when you sign in - see Apps' -f $starting) }
    if ($bytes -gt 0) { $script:CardSpace.Value.Text = Format-QpBytes $bytes; $script:CardSpace.Value.Foreground = $todo; $script:CardSpace.Caption.Text = 'Temp files, crash dumps, old installers' }
    else { $script:CardSpace.Value.Text = 'Nothing to clean'; $script:CardSpace.Value.Foreground = $good; $script:CardSpace.Caption.Text = 'Already tidy' }
    if ($vendors.Count) {
        $script:CardBrands.Border.Visibility = 'Visible'
        if ($brandOpen) { $script:CardBrands.Value.Text = "$brandOpen to quieten"; $script:CardBrands.Value.Foreground = $todo }
        else { $script:CardBrands.Value.Text = 'All quiet'; $script:CardBrands.Value.Foreground = $good }
        $script:CardBrands.Caption.Text = $brandNames
    } else {
        $script:CardBrands.Border.Visibility = 'Collapsed'
    }
    if ($script:HomeCounts.Total -eq 0) { $btnOneClick.Content = 'Your PC looks quiet' } else { $btnOneClick.Content = 'Quiet my PC now' }
    Update-Meters
}

function Set-MeterFill($meter, [double]$Ratio) {
    if ($Ratio -lt 0) { $Ratio = 0 } elseif ($Ratio -gt 1) { $Ratio = 1 }
    $meter.Fill.Width = [Math]::Max(6, [Math]::Round($meter.TrackWidth * $Ratio))
}

function Update-Meters {
    $u = Get-QpSystemUsage
    if ($u.DiskTotal -gt 0) {
        $script:MeterSpace.Value.Text = '{0} free' -f (Format-QpBytes $u.DiskFree)
        $script:MeterSpace.Caption.Text = 'of {0} on drive {1} - {2}% full' -f (Format-QpBytes $u.DiskTotal), $u.Drive, [int](100 * $u.DiskUsed / $u.DiskTotal)
        Set-MeterFill $script:MeterSpace ($u.DiskUsed / $u.DiskTotal)
    }
    if ($u.MemTotal -gt 0) { Set-MemoryTile $u.MemUsed $u.MemTotal }
    $t = Get-QpTotals
    if ($t.SpaceFreedBytes -gt 0 -or $t.MemoryFreedBytes -gt 0) {
        $parts = @()
        if ($t.SpaceFreedBytes -gt 0) { $parts += '{0} of space' -f (Format-QpBytes $t.SpaceFreedBytes) }
        if ($t.MemoryFreedBytes -gt 0) { $parts += '{0} of memory' -f (Format-QpBytes $t.MemoryFreedBytes) }
        $script:TotalsText.Text = 'Quietpane has freed ' + ($parts -join ' and ') + ' on this PC so far.'
        $script:TotalsText.Visibility = 'Visible'
    } else {
        $script:TotalsText.Visibility = 'Collapsed'
    }
}

function Get-ShortName([string]$Name) {
    # "13th Gen Intel(R) Core(TM) i7-13620H" -> "Intel Core i7-13620H"; "NVIDIA GeForce RTX 4060 Laptop GPU" -> "RTX 4060 Laptop GPU"
    $n = $Name -replace '\((R|TM)\)', '' -replace '^\s*\d+(st|nd|rd|th) Gen\s+', '' -replace '\s+CPU\s+@.*$', '' -replace '\s+with Radeon Graphics$', ''
    $n = $n -replace '^NVIDIA GeForce\s+', '' -replace '\s{2,}', ' '
    return $n.Trim()
}

function Set-MemoryTile([double]$Used, [double]$Total, $PromisedPct = $null) {
    <#
        Memory in the same shape as the others: a number, a bar, a plain word, a caption.

        Where the others have a temperature, memory has the figure that actually explains a PC grinding
        to a halt - how much Windows has promised out to programs, which fills up before the memory
        chips do. It used to sit in a row of three bare percentages at the bottom of the panel, where it
        meant nothing to anybody. Here it is the thing that decides the word.
    #>
    if ($Total -le 0) { return }
    $t = $script:TileMemory
    $pct = 100 * $Used / $Total
    $t.Value.Text = '{0:N0}%' -f $pct
    Set-MeterFill $t ($Used / $Total)
    Set-TileMark $t 0.9
    # Whichever is under more pressure decides the word, because either one can be what runs out.
    $worst = @(@($pct, $PromisedPct) | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ } | Sort-Object -Descending)[0]
    $word, $level = if ($worst -ge 90) { 'nearly full', 'high' } elseif ($worst -ge 80) { 'filling up', 'warn' } else { 'plenty free', 'ok' }
    $t.Heat.Text = $word
    Set-TileState $t $level
    $caption = '{0} of {1} in use' -f (Format-QpBytes $Used), (Format-QpBytes $Total)
    if ($null -ne $PromisedPct) { $caption += [Environment]::NewLine + ('{0}% promised to programs' -f $PromisedPct) }
    $t.Caption.Text = $caption
    $t.Heat.ToolTip = 'Memory in use is what the chips are holding. Promised is what Windows has undertaken to find if every program asks at once - it runs out first, and when it does the PC starts crawling however much memory is fitted.'
}

$script:HeatColours = @{ ok = '#117A68'; warn = '#9A6700'; high = '#A83232'; none = '#66706F' }
function Set-HeatText($Block, $Celsius, $MaxC, [bool]$Stuck, [string]$Tip) {
    # Number and word together, so heat never depends on colour alone.
    $deg = [char]0x00B0
    $dot = [char]0x00B7
    $h = Get-QpHeatWord -Celsius $Celsius -MaxC $MaxC
    if ($null -eq $Celsius) {
        $Block.Text = 'temperature not shared'
        $Block.Foreground = Get-Brush $script:HeatColours.none
    } elseif ($Stuck) {
        $Block.Text = '{0:N0}{1}C {2} sensor not updating' -f $Celsius, $deg, $dot
        $Block.Foreground = Get-Brush $script:HeatColours.none
        $Tip = 'This number has not changed at all for a while, so this PC''s sensor probably isn''t live. Treat it as unknown.'
    } else {
        $Block.Text = '{0:N0}{1}C {2} {3}' -f $Celsius, $deg, $dot, $h.Word
        $Block.Foreground = Get-Brush $script:HeatColours[$h.Level]
    }
    $Block.ToolTip = $Tip
}

function Set-TileState($Tile, [string]$Level) {
    <#
        How this one reading stands, in two places at once: the bar turns red when something is actually
        wrong, and the line under it is coloured to match. Neither is ever alone - the line always says
        the same thing in words, so none of this depends on seeing colour.
    #>
    if (-not $Level) { $Level = 'none' }
    $Tile.Fill.Background = Get-Brush $(if ($Level -eq 'high') { $script:BarColours.high } else { $script:BarColours.ok })
    $Tile.Heat.Foreground = Get-Brush $script:HeatColours[$Level]
}

function Set-TileMark($Tile, $Ratio) {
    <# The notch on the track where this reading stops being ordinary. Hidden where there is no such point. #>
    if ($null -eq $Ratio) { $Tile.Mark.Visibility = 'Collapsed'; return }
    $r = [double]$Ratio
    if ($r -le 0 -or $r -ge 1) { $Tile.Mark.Visibility = 'Collapsed'; return }
    $Tile.Mark.Margin = Get-Thick ('{0},0,0,0' -f [math]::Round($Tile.TrackWidth * $r))
    $Tile.Mark.Visibility = 'Visible'
}

function Show-BusyStrip($r) {
    <#
        One row of the programs working this PC hardest, drawn once for the whole panel.

        Each tile used to carry its own list, which meant the same three programs written out four
        times in four small columns - most of the reading on the tab, and none of it new. Merged, the
        processor and the graphics card are asked the same question and the loudest answer wins, so a
        game that is hammering the graphics card appears once with its real figure.
    #>
    $script:BusyRows.Children.Clear()
    $all = @()
    foreach ($p in @($r.CpuTop)) { if ($p) { $all += [pscustomobject]@{ Name = [string]$p.Name; Pct = [double]$p.Pct; What = 'processor' } } }
    foreach ($g in @($r.Gpus)) { foreach ($p in @($g.Top)) { if ($p) { $all += [pscustomobject]@{ Name = [string]$p.Name; Pct = [double]$p.Pct; What = 'graphics' } } } }
    # The same program can be busy on both; it is one program, so it is shown once, at its loudest.
    $top = @($all | Where-Object { $_.Name } | Group-Object Name | ForEach-Object {
            $best = @($_.Group | Sort-Object Pct -Descending)[0]
            [pscustomobject]@{ Name = $_.Name; Pct = $best.Pct; What = $best.What }
        } | Sort-Object Pct -Descending | Select-Object -First 3)
    if (-not $top.Count) { $script:BusyStrip.Visibility = 'Collapsed'; return }
    $script:BusyStrip.Visibility = 'Visible'
    foreach ($p in $top) {
        $row = New-Object System.Windows.Controls.StackPanel
        $row.Orientation = 'Horizontal'
        $row.Margin = Get-Thick '0,0,0,3'
        $name = New-Text (Get-ShortName $p.Name) 12 'Normal' '#0F1B1C' '0'
        $name.Width = 190
        $name.TextTrimming = 'CharacterEllipsis'
        $name.VerticalAlignment = 'Center'
        [void]$row.Children.Add($name)
        # A bar on the same scale for all three, so the gap between first and third is visible.
        $track = New-Object System.Windows.Controls.Border
        $track.Height = 8; $track.Width = 120
        $track.Background = Get-Brush '#EDE6D5'
        $track.CornerRadius = New-Object System.Windows.CornerRadius(4)
        $track.VerticalAlignment = 'Center'
        $bar = New-Object System.Windows.Controls.Border
        $bar.Height = 8
        $bar.Width = [math]::Max(4, [math]::Round(120 * [math]::Min(100, [math]::Max(0, $p.Pct)) / 100))
        $bar.HorizontalAlignment = 'Left'
        $bar.Background = Get-Brush $script:BarColours.ok
        $bar.CornerRadius = New-Object System.Windows.CornerRadius(4)
        $track.Child = $bar
        [void]$row.Children.Add($track)
        $what = if ($p.What -eq 'graphics') { 'the graphics card' } else { 'the processor' }
        $fig = New-Text ('{0:N0}% of {1}' -f $p.Pct, $what) 12 'Normal' '#4B5B5C' '10,0,0,0'
        $fig.VerticalAlignment = 'Center'
        [void]$row.Children.Add($fig)
        [void]$script:BusyRows.Children.Add($row)
    }
}

$script:BatteryHealth = $null   # how much the battery holds compared with new - read by the Health tab
function Update-BatteryCard($Live) {
    <# Charge and power every reading; how much it holds compared with new whenever that's been read. #>
    $c = $script:BatteryCard
    if (-not $Live) { $c.Border.Visibility = 'Collapsed'; return }   # a desktop, or a battery that isn't saying
    $c.Value.Text = '{0}%' -f $Live.Percent
    Set-MeterFill $c ($Live.Percent / 100)
    $c.Caption.Text = if ($Live.Charging) { 'Charging' } elseif ($Live.PluggedIn) { 'Plugged in' } else { 'On battery' }
    # What the cell itself says it is giving or taking, and how long that leaves. Worked out from the
    # charge in the battery and the draw just measured - Windows' own guess is not used, because on
    # mains it is a made-up number.
    if ($null -ne $Live.Watts) {
        $power = '{0:N1} W {1}' -f $Live.Watts, $(if ($Live.Direction -eq 'charging') { 'going in' } else { 'right now' })
        if ($Live.MinutesLeft) { $power += ', about {0} left at this rate' -f (Format-QpSpan ($Live.MinutesLeft * 60)) }
        $c.Caption.Text = $c.Caption.Text + ' - ' + $power
    }
    $h = $script:BatteryHealth
    if ($h) {
        $t = $script:BatteryHealthText
        $t.Text = 'Holds {0}% of what it did when new' -f $h.Percent
        $t.Foreground = Get-Brush $(if ($h.Percent -lt 60) { $script:HeatColours.warn } else { '#0F1B1C' })
        $tip = "Built to hold {0} Wh; it holds {1} Wh now. Every battery slowly loses capacity with age - below about 80% you may notice it runs out sooner. That's wear, not a fault." -f $h.DesignWh, $h.FullWh
        if ($h.Cycles) { $tip += " It has been through about $($h.Cycles) charge cycles." }
        $t.ToolTip = $tip
        $t.Visibility = 'Visible'
    } else {
        $script:BatteryHealthText.Visibility = 'Collapsed'
    }
    $c.Border.Visibility = 'Visible'
}

$script:DriveLast = $null   # the last drive reading, so the live drive tile can show its temperature
$script:DriveRead = $false  # whether the drive has been asked yet at all - "not yet" is not "nothing to say"
function Update-DriveCard($d) {
    <#
        How the drive is holding up over its life - the slow story. How busy and how warm it is this
        second is the drive tile's job, up with the other live readings.
    #>
    $script:DriveLast = $d
    $script:DriveRead = $true
    $c = $script:DriveCard
    $track = $c.Fill.Parent
    if (-not $d) {
        $c.Value.Text = 'Not shared'
        $c.Caption.Text = 'Windows did not say how this drive is doing.'
        $track.Visibility = 'Collapsed'; $script:DriveHeatText.Visibility = 'Collapsed'
        return
    }
    $dot = [char]0x00B7
    if ($d.Health -and $d.Health -ne 'Healthy') {
        $c.Value.Text = 'Needs attention'
        $c.Value.Foreground = Get-Brush $script:HeatColours.high
        $c.Caption.Text = 'Windows reports a problem with this drive. Back up your files soon.'
    } else {
        $c.Value.Text = 'Healthy'
        $c.Value.Foreground = Get-Brush '#117A68'
        $c.Caption.Text = if ($null -ne $d.WearPct) { '{0} {1} {2}% of its rated life used' -f $d.Media, $dot, $d.WearPct } else { "$($d.Media)".Substring(0, 1).ToUpper() + "$($d.Media)".Substring(1) }
    }
    # The bar is how much of its rated life the drive has used - only when the drive says.
    if ($null -ne $d.WearPct) { Set-MeterFill $c ([math]::Min(100, $d.WearPct) / 100); $track.Visibility = 'Visible' } else { $track.Visibility = 'Collapsed' }
    # How long it has been running, and how much has been written to it: the two figures that say
    # whether "4% used" is a new drive or a hard-worked one.
    $lines = @()
    if ($d.PowerOnHours) { $lines += 'Switched on for about {0:N0} hours' -f $d.PowerOnHours }
    if ($d.BytesWritten) { $lines += '{0} written to it so far' -f (Format-QpBytes $d.BytesWritten) }
    if ($lines.Count) {
        $script:DriveHeatText.Text = $lines -join [Environment]::NewLine
        $script:DriveHeatText.Foreground = Get-Brush '#66706F'
        $script:DriveHeatText.FontWeight = 'Normal'
        $script:DriveHeatText.Visibility = 'Visible'
    } else {
        $script:DriveHeatText.Visibility = 'Collapsed'
    }
    $tip = "$($d.Name). 'Healthy' is Windows' own verdict on the drive."
    if ($null -ne $d.WearPct) { $tip += ' Rated life is what the maker promises for writing data; under 100% is within that.' }
    if ($d.FromDrive) { $tip += ' These figures come from the drive itself rather than from Windows, which on many PCs reports the same made-up numbers for ever.' }
    $c.Border.ToolTip = $tip
}

# The last two minutes of each tile, kept in the window and nowhere else.
$script:LiveHistory = New-Object System.Collections.ArrayList
$script:LiveHistoryMax = 60

function Draw-Sparkline($Canvas, $Values, [string]$Colour, [double]$Max = 100) {
    <#
        A plain trend line under a number: no axes, no grid, no labels. The line is quiet grey so the
        number stays the loud thing, and the newest reading carries a dot in the tile's own colour, with
        a ring in the surface colour so it stays visible where it meets the line.
    #>
    $Canvas.Children.Clear()
    $vals = @($Values | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
    if ($vals.Count -lt 2) { $Canvas.Visibility = 'Collapsed'; return }
    $Canvas.Visibility = 'Visible'
    $w = [double]$Canvas.Width; $h = [double]$Canvas.Height
    $top = 3.0; $bottom = $h - 3.0        # room for the dot at either extreme
    $ceiling = [math]::Max(1.0, [double]$Max)
    $points = New-Object System.Windows.Media.PointCollection
    for ($i = 0; $i -lt $vals.Count; $i++) {
        $x = if ($vals.Count -eq 1) { $w } else { $w * $i / ($vals.Count - 1) }
        $y = $bottom - (($bottom - $top) * [math]::Min(1.0, [math]::Max(0.0, $vals[$i] / $ceiling)))
        $points.Add((New-Object System.Windows.Point($x, $y)))
    }
    # A wash under the line, so a low flat reading reads as a low band rather than a stray underline.
    $area = New-Object System.Windows.Shapes.Polygon
    $fillPoints = New-Object System.Windows.Media.PointCollection
    foreach ($pt in $points) { $fillPoints.Add($pt) }
    $fillPoints.Add((New-Object System.Windows.Point($points[$points.Count - 1].X, $bottom)))
    $fillPoints.Add((New-Object System.Windows.Point($points[0].X, $bottom)))
    $area.Points = $fillPoints
    # Kept faint. The bar above is the headline; a wash any stronger reads as a second, louder bar,
    # which is what a memory tile sitting at three-quarters full used to look like.
    $wash = (Get-Brush $Colour).Clone()
    $wash.Opacity = 0.10
    $area.Fill = $wash
    [void]$Canvas.Children.Add($area)
    $line = New-Object System.Windows.Shapes.Polyline
    $line.Points = $points
    $line.Stroke = Get-Brush '#8C9694'     # de-emphasised: the trend, not the headline
    $line.StrokeThickness = 2
    $line.StrokeLineJoin = 'Round'
    $line.StrokeStartLineCap = 'Round'
    $line.StrokeEndLineCap = 'Round'
    [void]$Canvas.Children.Add($line)
    $last = $points[$points.Count - 1]
    $dot = New-Object System.Windows.Shapes.Ellipse
    $dot.Width = 8; $dot.Height = 8
    $dot.Fill = Get-Brush $Colour
    $dot.Stroke = Get-Brush '#FFFDF8'      # a ring in the surface colour, so it never merges with the line
    $dot.StrokeThickness = 2
    [System.Windows.Controls.Canvas]::SetLeft($dot, $last.X - 4)
    [System.Windows.Controls.Canvas]::SetTop($dot, $last.Y - 4)
    [void]$Canvas.Children.Add($dot)
}

function Update-Sparklines($r) {
    <# One reading onto the end of each tile's trend. Kept in memory only, and only the last two minutes. #>
    if (-not $r) { return }
    $gpu = @($r.Gpus) | Select-Object -First 1
    [void]$script:LiveHistory.Add([pscustomobject]@{
        Cpu = $r.CpuUsage
        Gpu = $(if ($gpu) { $gpu.Usage } else { $null })
        Mem = $(if ($r.MemTotal -gt 0 -and $null -ne $r.MemUsed) { 100 * $r.MemUsed / $r.MemTotal } else { $null })
        Disk = $r.DiskBusyPct
    })
    while ($script:LiveHistory.Count -gt $script:LiveHistoryMax) { $script:LiveHistory.RemoveAt(0) }
    $h = @($script:LiveHistory)
    Draw-Sparkline $script:TileCpu.Spark    @($h | ForEach-Object { $_.Cpu })  $script:TileCpu.SparkColour
    Draw-Sparkline $script:TileGpu.Spark    @($h | ForEach-Object { $_.Gpu })  $script:TileGpu.SparkColour
    Draw-Sparkline $script:TileMemory.Spark @($h | ForEach-Object { $_.Mem })  $script:TileMemory.SparkColour
    Draw-Sparkline $script:TileDisk.Spark   @($h | ForEach-Object { $_.Disk }) $script:TileDisk.SparkColour
    foreach ($t in $script:TileCpu, $script:TileGpu, $script:TileMemory, $script:TileDisk) {
        Set-MoreInfo $t.Spark ('The last {0} readings, about two minutes, on the same nought-to-a-hundred scale as the bar above. The line is quiet on purpose - the number is the thing to read.' -f $h.Count)
    }
}

# How hot it was, as one colour getting darker and one bar getting taller. Two encodings of the same
# thing, so it still reads without colour vision, and a legend names each step in words as well.
# Checked with the palette validator: one hue (14 degrees of spread), lightness steps of 0.06 or more,
# and the palest step still clears the card it sits on.
$script:SessionBandColours = @{
    quiet   = '#CFAB60'
    hot     = '#AB7409'
    veryhot = '#5E3A03'
    gap     = '#E6DFCC'
}
$script:SessionBandHeights = @{ quiet = 8; hot = 15; veryhot = 22; gap = 0 }
# Being held back to cool off is a different measurement, so it gets its own thin row underneath
# rather than pretending to be a fourth level of heat.
$script:SessionHeldColour = '#7B1D1D'

function Draw-SessionTimeline($Panel, $Watch) {
    <#
        The session end to end: one column per slice of time, coloured by the worst the PC got in it.
        Worst, not average, because an average hides the very spell this exists to show. A slice nobody
        watched stays the colour of the track, so a gap looks like a gap.
    #>
    $Panel.Children.Clear()
    if (-not $Watch) { return }
    $bands = @(Get-QpSessionBands -Watch $Watch -Columns 96)
    if (-not $bands.Count) { return }
    # The heat row: a column per slice, growing taller and darker as it got hotter, on a quiet track.
    $strip = New-Object System.Windows.Controls.StackPanel
    $strip.Orientation = 'Horizontal'
    $strip.Margin = Get-Thick '0,8,0,0'
    # No track behind it: a stretch nobody watched is simply empty, which is what it means, and it
    # cannot then be mistaken for the palest step of the heat scale.
    $strip.Height = 22
    foreach ($b in $bands) {
        $cell = New-Object System.Windows.Controls.Border
        $cell.Width = 5
        $cell.Height = $script:SessionBandHeights[[string]$b.Heat]
        $cell.VerticalAlignment = 'Bottom'
        if ($cell.Height -gt 0) { $cell.Background = Get-Brush $script:SessionBandColours[[string]$b.Heat] }
        [void]$strip.Children.Add($cell)
    }
    [System.Windows.Automation.AutomationProperties]::SetName($strip, 'How hot the PC was, from the start of the session to the end')
    [void]$Panel.Children.Add($strip)
    # The second row: when the processor was being held back to cool off.
    if (@($bands | Where-Object { $_.Held }).Count) {
        $held = New-Object System.Windows.Controls.StackPanel
        $held.Orientation = 'Horizontal'
        $held.Margin = Get-Thick '0,2,0,0'
        foreach ($b in $bands) {
            $cell = New-Object System.Windows.Controls.Border
            $cell.Width = 5; $cell.Height = 6
            if ($b.Held) { $cell.Background = Get-Brush $script:SessionHeldColour }
            [void]$held.Children.Add($cell)
        }
        [System.Windows.Automation.AutomationProperties]::SetName($held, 'When the processor was held back to cool off')
        [void]$Panel.Children.Add($held)
    }
    $from = Get-QpStamp 'HH:mm' ([datetime]$Watch.Started)
    $to = if ($Watch.Ended) { Get-QpStamp 'HH:mm' ([datetime]$Watch.Ended) } else { 'now' }
    $axis = New-Object System.Windows.Controls.Grid
    foreach ($width in '*', 'Auto') { $c = New-Object System.Windows.Controls.ColumnDefinition; $c.Width = $script:GridLength.ConvertFromString($width); [void]$axis.ColumnDefinitions.Add($c) }
    $left = New-Text $from 11 'Normal' '#66706F' '0,3,0,0'
    $right = New-Text $to 11 'Normal' '#66706F' '0,3,0,0'
    [System.Windows.Controls.Grid]::SetColumn($right, 1)
    [void]$axis.Children.Add($left); [void]$axis.Children.Add($right)
    $axis.Width = $bands.Count * 5
    $axis.HorizontalAlignment = 'Left'
    [void]$Panel.Children.Add($axis)

    # The legend: only what this session actually had, each with its word beside its colour.
    $seen = @($bands | ForEach-Object { $_.Heat } | Select-Object -Unique)
    $legend = New-Object System.Windows.Controls.WrapPanel
    $legend.Margin = Get-Thick '0,6,0,0'
    function Add-Key([string]$Colour, [string]$Word, [int]$Height) {
        $item = New-Object System.Windows.Controls.StackPanel
        $item.Orientation = 'Horizontal'
        $item.Margin = Get-Thick '0,0,14,0'
        $key = New-Object System.Windows.Controls.Border
        $key.Width = 11; $key.Height = $Height
        # "Not watched" is drawn as nothing, so its key is an empty outline rather than a colour.
        if ($Colour) { $key.Background = Get-Brush $Colour }
        else { $key.BorderBrush = Get-Brush '#B9C0BE'; $key.BorderThickness = Get-Thick '1' }
        $key.VerticalAlignment = 'Center'
        $key.Margin = Get-Thick '0,0,5,0'
        [void]$item.Children.Add($key)
        [void]$item.Children.Add((New-Text $Word 11.5 'Normal' '#4B5B5C' '0'))
        [void]$legend.Children.Add($item)
    }
    foreach ($state in 'veryhot', 'hot', 'quiet', 'gap') {
        if ($seen -notcontains $state) { continue }
        $word = @($bands | Where-Object { $_.Heat -eq $state })[0].Word
        $colour = if ($state -eq 'gap') { '' } else { $script:SessionBandColours[$state] }
        # The key is the height of its own column, so the legend shows the shape as well as the colour.
        Add-Key $colour $word ([math]::Max(9, $script:SessionBandHeights[$state]))
    }
    if (@($bands | Where-Object { $_.Held }).Count) { Add-Key $script:SessionHeldColour 'held back to cool off' 6 }
    [void]$Panel.Children.Add($legend)
}

# The three numbers that used to run along the bottom of the panel - promised memory, processor speed
# and disk busy - are no longer a line of their own. Each has gone to the tile it belongs to: promised
# memory decides the memory tile's word, disk busy is now a tile in its own right, and processor speed
# is only ever mentioned when something is actually holding the processor back, which is the only
# moment it tells you anything. Three bare percentages in a row told nobody anything at all.

function Update-SteadyCard($r) {
    <#
        Windows' own record of how steady this PC has been: its score out of ten, what has crashed, and
        how long the PC has been awake. Where Windows has kept no score, the card says so.
    #>
    $c = $script:SteadyCard
    $script:SteadyLines.Children.Clear()
    if (-not $r -or -not $r.Available) {
        $c.Value.Text = 'Not scored'
        $c.Caption.Text = "Windows hasn't kept a record on this PC"
        Set-MeterFill $c 0
        return
    }
    if ($null -ne $r.Score) {
        $c.Value.Text = '{0:N1} / 10' -f $r.Score
        $c.Caption.Text = $r.Word + $(if ($r.ScoreWhen) { ', as of ' + (Format-QpWhen $r.ScoreWhen) } else { '' })
        Set-MeterFill $c ([double]$r.Score / 10)
        $c.Value.Foreground = Get-Brush $(if ($r.Score -lt 7) { $script:HeatColours.warn } else { '#0F1B1C' })
    } else {
        $c.Value.Text = 'Not scored'
        $c.Caption.Text = "Windows hasn't worked out a score yet"
        Set-MeterFill $c 0
    }
    Set-MoreInfo $c.Border ("Windows' own score, out of ten, from the record behind Reliability Monitor. It drops on a day something crashed and climbs back as quiet days pass, so it is a shape over weeks rather than a verdict on today. What crashed is read from the event log for the last {0} days; Windows Update and installer entries are left out, because an update that installed is not a problem." -f $r.Days)

    $lines = @()
    $broke = [int]$r.Crashes + [int]$r.Hangs
    if ($broke -eq 0) {
        $lines += "Nothing has crashed in $($r.Days) days."
    } else {
        $what = if ($broke -eq 1) { '1 program stopped working' } else { "$broke programs stopped working" }
        $worst = @($r.Programs | Select-Object -First 1)
        $line = "$what in $($r.Days) days"
        if ($worst -and $worst[0].Count -gt 1) { $line += ', most often ' + $worst[0].Name } elseif ($worst) { $line += ', including ' + $worst[0].Name }
        $lines += $line + '.'
    }
    if ($r.SuddenStops -gt 0) {
        $lines += $(if ($r.SuddenStops -eq 1) { 'The PC stopped without warning once.' } else { "The PC stopped without warning $($r.SuddenStops) times." })
    }
    if ($r.BlueScreens -gt 0) { $lines += "$($r.BlueScreens) blue screen(s)." }
    if ($r.Uptime) { $lines += 'Awake for {0}.' -f (Format-QpSpan ([double]$r.Uptime.TotalSeconds)) }
    foreach ($line in $lines) {
        $t = New-Text $line 12 'Normal' '#4B5B5C' '0,2,0,0'
        if ($line -match 'without warning|blue screen') { $t.Foreground = Get-Brush $script:HeatColours.warn }
        [void]$script:SteadyLines.Children.Add($t)
    }
}

function Show-SessionAlerts($alerts) {
    <#
        Something worth interrupting for, said once. It goes on the status line, and onto the taskbar
        icon while the window is out of sight - unless a "came back" badge is already there, which is
        about a choice you made and outranks a passing warm spell.
    #>
    $alerts = @($alerts | Where-Object { $_ })
    if (-not $alerts.Count) { return }
    $ui.Status.Text = $alerts[0].Text
    [System.Windows.Automation.AutomationProperties]::SetName($ui.Status, $ui.Status.Text)
    $ui.LogBox.AppendText(('[{0}] WARN    {1}' -f (Get-Date -Format 'HH:mm:ss'), $alerts[0].Text) + [Environment]::NewLine)
    if ($window.WindowState -eq 'Minimized' -and -not ($script:CameBack -and $script:CameBack.Count)) {
        try {
            if (-not $window.TaskbarItemInfo) { $window.TaskbarItemInfo = New-Object System.Windows.Shell.TaskbarItemInfo }
            $n = @($script:SessionWatch.Alerts).Count
            $window.TaskbarItemInfo.Overlay = New-BadgeImage ([int]$n)
            $window.TaskbarItemInfo.Description = 'Quietpane: ' + $alerts[0].Text
            $window.Title = 'Quietpane - ' + $alerts[0].Text
            $script:AlertBadge = $true
        } catch { }
    }
}

function Clear-AlertBadge {
    <# You have seen it, so the badge goes - putting back the "came back" one if that is waiting. #>
    if (-not $script:AlertBadge) { return }
    $script:AlertBadge = $false
    Update-TaskbarBadge $script:CameBack
}

function Update-SessionCard {
    <# The session card: what has been watched so far, in the same words as the summary at the end. #>
    $script:SessionShownAt = Get-Date
    $script:SessionLines.Children.Clear()
    Draw-SessionTimeline $script:SessionChart $(if ($script:SessionWatch) { $script:SessionWatch } else { $script:SessionLastWatch })
    # There is something worth writing up once there are two readings to compare.
    $enough = ($script:SessionWatch -and $script:SessionWatch.Samples -ge 2) -or ($script:SessionLastWatch -and $script:SessionLastWatch.Samples -ge 2)
    $script:BtnSessionSave.Visibility = if ($enough) { 'Visible' } else { 'Collapsed' }
    if (-not $script:SessionWatch) {
        $script:BtnSession.Content = 'Watch this session'
        $script:SessionHead.Text = 'Quietpane can keep an eye on how your PC holds up while you work.'
        $script:SessionHead.FontWeight = 'Normal'
        if ($script:SessionLast) {
            foreach ($line in @($script:SessionLast.Lines)) { [void]$script:SessionLines.Children.Add((New-Text $line 12.5 'Normal' '#4B5B5C' '0,2,0,0')) }
            $script:SessionHead.Text = $script:SessionLast.Headline
            $script:SessionHead.FontWeight = 'SemiBold'
        }
        return
    }
    $s = Get-QpSessionSummary -Watch $script:SessionWatch
    $script:BtnSession.Content = 'Stop watching'
    $script:SessionHead.Text = $s.Headline
    $script:SessionHead.FontWeight = 'SemiBold'
    # Anything worth interrupting for, at the top, in the colour that matches how much it matters.
    foreach ($a in @($script:SessionWatch.Alerts)) {
        $t = New-Text ('{0}   ({1})' -f $a.Text, (Get-QpStamp 'HH:mm' $a.At)) 12.5 'SemiBold' $script:HeatColours[$a.Level] '0,2,0,0'
        [void]$script:SessionLines.Children.Add($t)
    }
    foreach ($line in @($s.Lines)) { [void]$script:SessionLines.Children.Add((New-Text $line 12.5 'Normal' '#4B5B5C' '0,2,0,0')) }
}

function Switch-SessionWatch {
    <# Starts or stops the session record. Nothing is written down either way. #>
    if ($script:SessionWatch) {
        $script:SessionLastWatch = Stop-QpSessionWatch -Watch $script:SessionWatch
        $script:SessionLast = Get-QpSessionSummary -Watch $script:SessionLastWatch
        $script:SessionWatch = $null
        Clear-AlertBadge
        $ui.Status.Text = 'Stopped watching. ' + $script:SessionLast.Headline
    } else {
        $script:SessionWatch = New-QpSessionWatch -IntervalSeconds 10
        $script:SessionLast = $null
        $script:SessionLastWatch = $null
        [void]$script:Live.Wake.Set()   # start reading now rather than at the next turn of the loop
        $ui.Status.Text = 'Watching how this PC holds up. It stops when you close Quietpane.'
    }
    Update-SessionCard
}

function Save-SessionReport {
    <# One page on the Desktop, and then opened, so a session can outlive the window. #>
    if (Test-Busy) { return }
    $watch = if ($script:SessionWatch) { $script:SessionWatch } else { $script:SessionLastWatch }
    if (-not $watch -or $watch.Samples -lt 2) {
        [void][System.Windows.MessageBox]::Show('There is nothing to write up yet. Give it a minute of watching first.', 'Quietpane')
        return
    }
    $steady = if ($script:Live.Health) { $script:Live.Health.Steady } else { $null }
    $ui.LogBox.AppendText([Environment]::NewLine)
    Start-Work -StatusText 'Writing up this session...' -Params @{ Watch = $watch; Steady = $steady } -Work {
        param($Watch, $Steady)
        Save-QpSessionReport -Watch $Watch -Steady $Steady
    } -OnDone {
        param($r)
        $path = @($r | Where-Object { $_ -is [string] -and $_ -like '*.html' })[-1]
        if (-not $path) { return }
        $ui.Status.Text = 'Saved to your Desktop: ' + (Split-Path $path -Leaf)
        Open-AsUser $path
    }
}

function Update-LiveTiles($r) {
    <#
        Paints one reading onto the verdict, the four tiles and the busiest row.

        Each tile answers one question and says how it stands in words. Anything this PC doesn't share
        is shown as "not shared", never as a zero - a zero looks like an answer.
    #>
    if (-not $r) { return }
    Update-Sparklines $r
    Show-BusyStrip $r
    $deg = [char]0x00B0
    $dot = [char]0x00B7

    $v = Get-QpLiveVerdict -Reading $r
    $script:VerdictText.Text = $v.Text
    $script:VerdictText.Foreground = Get-Brush $(if ($v.Level -eq 'ok' -or $v.Level -eq 'none') { '#0F1B1C' } else { $script:HeatColours[$v.Level] })
    $script:VerdictDot.Fill = Get-Brush $script:HeatColours[$v.Level]
    $script:VerdictWhy.Text = $v.Why
    $script:VerdictWhy.Visibility = if ($v.Why) { 'Visible' } else { 'Collapsed' }

    # PROCESSOR - how hard it is working, and how warm it got doing it.
    $t = $script:TileCpu
    if ($null -ne $r.CpuUsage) { $t.Value.Text = '{0:N0}%' -f $r.CpuUsage; Set-MeterFill $t ($r.CpuUsage / 100) } else { $t.Value.Text = 'not shared'; Set-MeterFill $t 0 }
    Set-TileMark $t 0.8
    $t.Caption.Text = Get-ShortName $r.CpuName
    Update-BatteryCard $r.Battery
    $zone = if ($r.CpuTempSource) { " ($($r.CpuTempSource))" } else { '' }
    Set-HeatText $t.Heat $r.CpuTempC $null ([bool]$r.CpuTempStuck) ("From Windows' own thermal sensor$zone. On some PCs that is the processor itself, on others a sensor close to it, so treat it as a guide. Laptops often run hot when busy - it's only a worry if it stays very hot while the PC is doing nothing.")
    Set-TileState $t (Get-QpHeatWord -Celsius $(if ($r.CpuTempStuck) { $null } else { $r.CpuTempC })).Level
    # Windows holding the processor back to cool it: the moment a game suddenly stutters for no reason.
    # The only thing allowed to break the tiles' shape, because it is the only one worth stopping for.
    if ($r.CpuThrottled) {
        $t.Extra.Text = 'Held back to cool off - running at {0:N0}% of its speed' -f $r.CpuLimitPct
        $t.Extra.Foreground = Get-Brush $script:HeatColours.warn
        $t.Extra.FontWeight = 'SemiBold'
        $t.Extra.ToolTip = 'Windows is holding the processor back to shed heat, so things can feel slower until it cools. Common on laptops during games. Clear vents and a hard, flat surface help. Slowing down done inside the chip itself is not visible to Windows, so this cannot catch every case.'
        $t.Extra.Visibility = 'Visible'
    } else {
        $t.Extra.Visibility = 'Collapsed'
    }

    # GRAPHICS - the same two questions, plus what its own memory is doing, which used to be a tile of
    # its own and almost never had anything to say.
    $gpus = @($r.Gpus)
    $g = $gpus | Select-Object -First 1
    $t = $script:TileGpu
    if ($g) {
        $t.Value.Text = '{0:N0}%' -f $g.Usage
        Set-MeterFill $t ($g.Usage / 100)
        Set-TileMark $t 0.8
        $t.Caption.Text = Get-ShortName $g.Name
        $tip = if ($g.TempMaxC) { "From the graphics driver - the same reading Task Manager shows. The driver says this card is built for up to {0:N0}{1}C." -f $g.TempMaxC, $deg } else { 'From the graphics driver - the same reading Task Manager shows.' }
        if ($null -eq $g.TempC -and -not $g.Discrete) { $tip = 'Built-in graphics share the processor''s cooling, so the driver doesn''t report its own temperature.' }
        elseif ($null -eq $g.TempC) { $tip = 'The driver isn''t sharing a temperature right now. On laptops the graphics card often sleeps when it isn''t needed.' }
        Set-HeatText $t.Heat $g.TempC $g.TempMaxC $false $tip
        Set-TileState $t (Get-QpHeatWord -Celsius $g.TempC -MaxC $g.TempMaxC).Level
        $bits = @()
        if ($g.Discrete -and $g.DedicatedTotal -gt 0) { $bits += 'Video memory {0:N0}% of {1}' -f (100 * $g.DedicatedUsed / $g.DedicatedTotal), (Format-QpBytes $g.DedicatedTotal) }
        elseif ($g.SharedTotal -gt 0) { $bits += 'Video memory {0:N0}%, borrowed from memory' -f (100 * $g.SharedUsed / $g.SharedTotal) }
        # Gaming laptops have two: say how busy the other one is, quietly.
        $other = $gpus | Select-Object -Skip 1 -First 1
        if ($other) { $bits += 'Also {0}: {1:N0}%' -f (Get-ShortName $other.Name), $other.Usage }
        $t.Extra.Text = $bits -join "`n"
        $t.Extra.Foreground = Get-Brush '#66706F'; $t.Extra.FontWeight = 'Normal'
        $t.Extra.Visibility = if ($bits.Count) { 'Visible' } else { 'Collapsed' }
    } else {
        $t.Value.Text = 'not shared'
        $t.Caption.Text = 'This PC keeps no graphics figures.'
        $t.Heat.Text = ''
        $t.Extra.Visibility = 'Collapsed'
        Set-MeterFill $t 0; Set-TileMark $t $null
    }

    if ($null -ne $r.MemUsed) { Set-MemoryTile $r.MemUsed $r.MemTotal $r.CommitPct }

    # THE DRIVE - how busy it is, and how warm. A drive flat out while the processor idles is what
    # "slow" almost always turns out to be, and it had no tile at all before.
    $t = $script:TileDisk
    if ($null -ne $r.DiskBusyPct) {
        $t.Value.Text = '{0:N0}%' -f $r.DiskBusyPct
        Set-MeterFill $t ($r.DiskBusyPct / 100)
        Set-TileMark $t 0.9
        $t.Caption.Text = 'of the time reading or writing'
    } else {
        $t.Value.Text = 'not shared'
        $t.Caption.Text = 'This PC keeps no figure for it.'
        Set-MeterFill $t 0; Set-TileMark $t $null
    }
    $d = $script:DriveLast
    if ($d -and $null -ne $d.TempC) {
        $h = Get-QpHeatWord -Celsius $d.TempC -Kind Drive
        $t.Heat.Text = '{0}{1}C {2} {3}' -f $d.TempC, $deg, $dot, $h.Word
        Set-TileState $t $h.Level
        $t.Heat.ToolTip = $(if ($d.FromDrive) { 'Asked of the drive itself, so it moves with what the drive is doing.' } else { "Windows' own figure for this drive. Some storage drivers report the same number whatever is happening, so treat it as a guide." })
    } elseif (-not $script:DriveRead) {
        $t.Heat.Text = 'asking the drive...'
        Set-TileState $t 'none'
    } else {
        $t.Heat.Text = 'temperature not shared'
        Set-TileState $t 'none'
    }
    # Which drive it is stays on the card below, where its make and model can be read without wrapping
    # a tile to three lines and knocking the row out of line.
    $t.Extra.Visibility = 'Collapsed'
}

function Show-MeterGains([int64]$SpaceFreed, [int64]$MemoryFreed) {
    # Green notes under each bar, showing what the run just gave back.
    if ($SpaceFreed -gt 0) {
        $script:MeterSpace.Delta.Text = '+{0} freed just now (in your Recycle Bin)' -f (Format-QpBytes $SpaceFreed)
        $script:MeterSpace.Delta.Visibility = 'Visible'
    } else { $script:MeterSpace.Delta.Visibility = 'Collapsed' }
    if ($MemoryFreed -gt 0) {
        $script:MeterMemory.Delta.Text = '+{0} of memory freed - a restart frees more' -f (Format-QpBytes $MemoryFreed)
    } else {
        $script:MeterMemory.Delta.Text = 'Memory is unchanged for now - a restart frees more'
    }
    $script:MeterMemory.Delta.Visibility = 'Visible'
}

function Set-LogVisible([bool]$Visible) {
    $ui.LogRow.Height = if ($Visible) { New-Object System.Windows.GridLength(170) } else { New-Object System.Windows.GridLength(0) }
    $ui.LogSplitter.Visibility = if ($Visible) { 'Visible' } else { 'Collapsed' }
    $ui.LinkDetails.Inlines.Clear()
    $ui.LinkDetails.Inlines.Add($(if ($Visible) { 'Hide details' } else { 'Show details' }))
    $script:LogVisible = $Visible
}

# One pass over the PC, sharing its slow lookups (see Get-QpState). Health is read by its own tab.
$script:ReadState = { Get-QpState }

function Update-State {
    Start-Work -StatusText 'Reading the current state of this PC...' -Work $script:ReadState -OnDone { param($s) Update-FromState $s }
}

$script:AcceptQuiet = $false
$script:RestoreLabels = @{
    'one-click' = 'Quiet my PC now'; 'privacy' = 'Privacy settings'; 'brands' = 'Brand extras'
    'apps' = 'Apps removed'; 'startup' = 'Startup items'; 'cleanup' = 'Clean-up'; 'space' = 'Moved to the Recycle Bin'
    'devices' = 'Camera, microphone and location'; 'shortcuts' = 'Shortcuts'; 'came-back' = 'Switched off again'
}
function Format-RestoreName([string]$Name) {
    <# "20260921-180721-one-click" reads as "Today 18:07 - Quiet my PC now". #>
    if ($Name -notmatch '^(\d{8})-(\d{6})-(.+)$') { return $Name }
    $label = $script:RestoreLabels[$matches[3]]
    if (-not $label) { $label = $matches[3] }
    try {
        $when = [datetime]::ParseExact($matches[1] + $matches[2], 'yyyyMMddHHmmss', [Globalization.CultureInfo]::InvariantCulture)
        $days = ((Get-Date).Date - $when.Date).Days
        $day = if ($days -eq 0) { 'Today' } elseif ($days -eq 1) { 'Yesterday' } else { $when.ToString('d MMMM', [Globalization.CultureInfo]::InvariantCulture) }
        return '{0} {1}   -   {2}' -f $day, $when.ToString('HH:mm'), $label
    } catch { return $Name }
}
function Update-UndoList($points) {
    $script:UndoList.Items.Clear()
    foreach ($r in @($points | Where-Object { $_ })) {
        $li = New-Object System.Windows.Controls.ListBoxItem
        $li.Content = '{0}   -   {1} change(s){2}' -f (Format-RestoreName $r.Name), $r.Changes, $(if ($r.Undone) { '   (already undone)' } else { '' })
        $li.Tag = $r.Path
        $li.ToolTip = $r.Path
        [void]$script:UndoList.Items.Add($li)
    }
    if ($script:UndoList.Items.Count -eq 0) { [void]$script:UndoList.Items.Add('No restore points yet.') }
}

function Update-StateAfterChange {
    # After something you did yourself (Apply, one-click, Undo...), the "came back" note starts afresh,
    # so your own choices are never reported as things that switched themselves back on.
    $script:AcceptQuiet = $true
    # The Undo list is quick to read, so it's brought up to date straight away rather than after the
    # full re-read - the new restore point is there the moment you look.
    try { Update-UndoList @(Get-QpRestorePoints) } catch { }
    Update-State
}

# ------------------------------------------------------------------ actions
function Get-SelectedIds([string]$Key) {
    @($script:Options[$Key] | Where-Object { $_.CheckBox.IsChecked } | ForEach-Object { $_.Id })
}

function Invoke-Selected([bool]$Preview) {
    if (Test-Busy) { return }
    $key = [string]$ui.Tabs.SelectedItem.Tag
    $ids = Get-SelectedIds $key
    # The Apps tab holds two lists: startup items and apps to remove. One Apply does both.
    $startupIds = if ($key -eq 'apps') { @(Get-SelectedIds 'startup') } else { @() }
    # Likewise the Privacy tab: the settings, the apps allowed to use the camera, microphone or location,
    # and the browser add-ons.
    $deviceIds = if ($key -eq 'privacy') { @(Get-SelectedIds 'devices') } else { @() }
    $addonIds = if ($key -eq 'privacy') { @(Get-SelectedIds 'extensions') } else { @() }
    if ($ids.Count -eq 0 -and $startupIds.Count -eq 0 -and $deviceIds.Count -eq 0 -and $addonIds.Count -eq 0) { [void][System.Windows.MessageBox]::Show('Pick at least one thing first.', 'Quietpane'); return }
    if (-not $Preview) {
        $msg = switch ($key) {
            'privacy' {
                $line = "Go ahead with the $($ids.Count + $deviceIds.Count + $addonIds.Count) ticked item(s)?`n`nA restore point is saved first, so you can undo this from the Undo tab."
                if ($addonIds.Count) { $line += "`n`nFor the $($addonIds.Count) add-on(s): the browser will say an administrator blocked them. That administrator is you, and Undo puts them back." }
                $line
            }
            'apps'    {
                $parts = @()
                if ($startupIds.Count) { $parts += "stop $($startupIds.Count) thing(s) starting when you sign in - they still open when you start them, and Undo turns them back on" }
                if ($ids.Count) { $parts += "remove $($ids.Count) app(s) - the Microsoft Store has them if you want them back" }
                "Shall I " + ($parts -join ",`nand ") + "?"
            }
            'cleanup' { "Move the ticked items to the Recycle Bin?`n`nNothing is deleted for good - you empty the bin yourself when you are happy." }
            default   { "Go ahead with the $($ids.Count) ticked item(s)?`n`nA restore point is saved first, so you can undo this from the Undo tab." }
        }
        if ([System.Windows.MessageBox]::Show($msg, 'Quietpane', 'YesNo', 'Question') -ne 'Yes') { return }
    }
    $ui.LogBox.AppendText([Environment]::NewLine)
    Set-LogVisible $true   # preview/apply results are shown in the details log
    $after = if ($Preview) { $null } else { { Update-StateAfterChange } }
    $verb = if ($Preview) { 'Previewing' } else { 'Applying' }
    switch ($key) {
        'privacy' {
            Start-Work -StatusText "$verb privacy changes..." -Params @{ Ids = $ids; Devices = $deviceIds; Addons = $addonIds; Preview = $Preview } -OnDone $after -Work {
                param($Ids, $Devices, $Addons, $Preview)
                # An empty list arrives as $null, and @($null).Count is 1 - so count real entries only.
                $Ids = @($Ids | Where-Object { $_ }); $Devices = @($Devices | Where-Object { $_ }); $Addons = @($Addons | Where-Object { $_ })
                if ($Ids.Count) { Invoke-QpPrivacy -Ids $Ids -Preview:$Preview }
                if ($Devices.Count) { Invoke-QpDeviceAccess -Ids $Devices -Preview:$Preview }
                if ($Addons.Count) { Invoke-QpExtension -Ids $Addons -Preview:$Preview }
            }
        }
        'vendors' { Start-Work -StatusText "$verb brand and hardware changes..." -Params @{ Ids = $ids; Preview = $Preview } -OnDone $after -Work { param($Ids, $Preview) Invoke-QpVendor -Ids $Ids -Preview:$Preview } }
        'apps'    {
            $dep = [bool]$script:DeprovisionCb.IsChecked
            Start-Work -StatusText "$verb apps and startup changes..." -Params @{ Ids = $ids; Startup = $startupIds; Preview = $Preview; Deprovision = $dep } -OnDone $after -Work {
                param($Ids, $Startup, $Preview, $Deprovision)
                # An empty list arrives as $null, and @($null).Count is 1 - so count real entries only.
                $Startup = @($Startup | Where-Object { $_ }); $Ids = @($Ids | Where-Object { $_ })
                if ($Startup.Count) { Invoke-QpStartup -Ids $Startup -Preview:$Preview }
                if ($Ids.Count) { Invoke-QpRemoveApps -Names $Ids -Preview:$Preview -Deprovision:$Deprovision }
            }
        }
        'cleanup' { Start-Work -StatusText "$verb clean-up..." -Params @{ Ids = $ids; Preview = $Preview } -OnDone $after -Work { param($Ids, $Preview) Invoke-QpCleanup -Ids $Ids -Preview:$Preview } }
    }
}

$ui.BtnPreview.Add_Click({ Invoke-Selected $true })
$ui.BtnApply.Add_Click({ Invoke-Selected $false })
function Get-TabOptionKeys {
    # The Apps and Privacy tabs carry two lists; every other tab carries one.
    $tag = [string]$ui.Tabs.SelectedItem.Tag
    if ($tag -eq 'apps') { return @('startup', 'apps') }
    if ($tag -eq 'privacy') { return @('extensions', 'devices', 'privacy') }
    return @($tag)
}
$ui.BtnRecommended.Add_Click({ foreach ($k in Get-TabOptionKeys) { Select-Recommended $k } })
$ui.BtnNone.Add_Click({ foreach ($k in Get-TabOptionKeys) { foreach ($o in $script:Options[$k]) { $o.CheckBox.IsChecked = $false } } })

function Draw-SeverityChart {
    <# A doughnut drawn with arcs. Each slice is also a row in the legend, with its name and count. #>
    $script:ChartCanvas.Children.Clear()
    $cx = 86.0; $cy = 86.0; $r = 64.0; $thick = 24.0
    $total = 0; foreach ($k in $script:SevCounts.Keys) { $total += [int]$script:SevCounts[$k] }
    $ring = New-Object System.Windows.Shapes.Ellipse
    $ring.Width = $r * 2; $ring.Height = $r * 2
    $ring.Stroke = Get-Brush '#EDE6D5'; $ring.StrokeThickness = $thick; $ring.Fill = $null
    [System.Windows.Controls.Canvas]::SetLeft($ring, $cx - $r); [System.Windows.Controls.Canvas]::SetTop($ring, $cy - $r)
    [void]$script:ChartCanvas.Children.Add($ring)
    if ($total -gt 0) {
        $angle = -90.0
        foreach ($k in $script:SevCounts.Keys) {
            $n = [int]$script:SevCounts[$k]
            if ($n -le 0) { continue }
            $sweep = 360.0 * $n / $total
            if ($sweep -ge 359.99) {
                $full = New-Object System.Windows.Shapes.Ellipse
                $full.Width = $r * 2; $full.Height = $r * 2
                $full.Stroke = Get-Brush $script:SevColours[$k]; $full.StrokeThickness = $thick; $full.Fill = $null
                [System.Windows.Controls.Canvas]::SetLeft($full, $cx - $r); [System.Windows.Controls.Canvas]::SetTop($full, $cy - $r)
                [void]$script:ChartCanvas.Children.Add($full)
                break
            }
            $a1 = $angle * [Math]::PI / 180.0
            $a2 = ($angle + $sweep) * [Math]::PI / 180.0
            $p1 = [System.Windows.Point]::new($cx + $r * [Math]::Cos($a1), $cy + $r * [Math]::Sin($a1))
            $p2 = [System.Windows.Point]::new($cx + $r * [Math]::Cos($a2), $cy + $r * [Math]::Sin($a2))
            $fig = New-Object System.Windows.Media.PathFigure
            $fig.StartPoint = $p1
            $arc = New-Object System.Windows.Media.ArcSegment
            $arc.Point = $p2
            $arc.Size = [System.Windows.Size]::new($r, $r)
            $arc.SweepDirection = 'Clockwise'
            $arc.IsLargeArc = ($sweep -gt 180)
            [void]$fig.Segments.Add($arc)
            $geo = New-Object System.Windows.Media.PathGeometry
            [void]$geo.Figures.Add($fig)
            $path = New-Object System.Windows.Shapes.Path
            $path.Data = $geo
            $path.Stroke = Get-Brush $script:SevColours[$k]
            $path.StrokeThickness = $thick
            $path.ToolTip = '{0}: {1}' -f $k, $n
            [void]$script:ChartCanvas.Children.Add($path)
            $angle += $sweep
        }
    }
    $centre = New-Object System.Windows.Controls.StackPanel
    $centre.Width = 96
    [void]$centre.Children.Add((New-Text "$total" 30 'SemiBold' '#0F1B1C' '0' 'Fraunces, Georgia'))
    [void]$centre.Children.Add((New-Text $(if ($total -eq 1) { 'finding' } else { 'findings' }) 12 'Normal' '#4B5B5C' '0'))
    foreach ($c in $centre.Children) { $c.TextAlignment = 'Center' }
    [System.Windows.Controls.Canvas]::SetLeft($centre, $cx - 48); [System.Windows.Controls.Canvas]::SetTop($centre, $cy - 26)
    [void]$script:ChartCanvas.Children.Add($centre)
    # The chart in words, for anyone who can't see it. The buttons beside it say the same, one by one.
    $spoken = @(foreach ($k in $script:SevCounts.Keys) { '{0} {1}' -f $k, [int]$script:SevCounts[$k] }) -join ', '
    [System.Windows.Automation.AutomationProperties]::SetName($script:ChartCanvas, ('Findings chart: {0} in all. {1}.' -f $total, $spoken))

    $script:LegendPanel.Children.Clear()
    $allBtn = New-Object System.Windows.Controls.Button
    $allBtn.Content = New-Text $('Show everything ({0})' -f $total) 13 'SemiBold' '#0F1B1C' '0'
    $allBtn.Margin = Get-Thick '0,0,0,6'; $allBtn.Padding = Get-Thick '10,4'
    $allBtn.HorizontalContentAlignment = 'Left'; $allBtn.HorizontalAlignment = 'Left'
    $allBtn.Add_Click({ $script:SevFilter = 'All'; Show-Findings })
    [void]$script:LegendPanel.Children.Add($allBtn)
    foreach ($k in $script:SevCounts.Keys) {
        $n = [int]$script:SevCounts[$k]
        $row = New-Object System.Windows.Controls.Button
        $row.Margin = Get-Thick '0,1,0,1'; $row.Padding = Get-Thick '6,3'
        $row.HorizontalContentAlignment = 'Left'; $row.HorizontalAlignment = 'Left'
        $row.Background = $null; $row.BorderThickness = Get-Thick '0'
        $row.Cursor = 'Hand'
        $row.IsEnabled = ($n -gt 0)
        $row.Opacity = $(if ($n -gt 0) { 1.0 } else { 0.45 })
        $row.Tag = $k
        $inner = New-Object System.Windows.Controls.StackPanel
        $inner.Orientation = 'Horizontal'
        $key = New-Object System.Windows.Shapes.Rectangle
        $key.Width = 13; $key.Height = 13; $key.Fill = Get-Brush $script:SevColours[$k]
        $key.Margin = Get-Thick '0,0,8,0'; $key.VerticalAlignment = 'Center'
        [void]$inner.Children.Add($key)
        [void]$inner.Children.Add((New-Text ('{0} - {1}' -f $k, $script:SevMeaning[$k]) 13 'Normal' '#0F1B1C' '0,0,10,0'))
        [void]$inner.Children.Add((New-Text "$n" 13 'SemiBold' '#0F1B1C' '0'))
        $row.Content = $inner
        $row.ToolTip = "Show only $k findings"
        # Its content is a colour and two numbers, so say in words what it is and does.
        [System.Windows.Automation.AutomationProperties]::SetName($row, ('{0}: {1} finding{2} - {3}. Show only these.' -f $k, $n, $(if ($n -eq 1) { '' } else { 's' }), $script:SevMeaning[$k]))
        $row.Add_Click({ $script:SevFilter = [string]$this.Tag; Show-Findings })
        [void]$script:LegendPanel.Children.Add($row)
    }
}

function Show-ChoiceDialog {
    <# A small window offering several ways forward, safest first. Returns the chosen key, or $null. #>
    param([string]$Title, [string]$Message, [object[]]$Options)
    $dlg = New-Object System.Windows.Window
    $dlg.Title = $Title
    $dlg.SizeToContent = 'WidthAndHeight'
    $dlg.WindowStartupLocation = 'CenterOwner'
    $dlg.ResizeMode = 'NoResize'
    $dlg.Background = Get-Brush '#FAF6EC'
    if ($window -and $window.IsVisible) { $dlg.Owner = $window }
    if ($window) { $dlg.Icon = $window.Icon }
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Margin = Get-Thick '22,18'
    $sp.MaxWidth = 560
    [void]$sp.Children.Add((New-Text $Message 13.5 'Normal' '#0F1B1C' '0,0,0,14'))
    $script:ChoiceResult = $null
    foreach ($o in $Options) {
        $b = if ($o.Primary) { New-Button $o.Label -Primary } else { New-Button $o.Label }
        $b.Margin = Get-Thick '0,0,0,4'
        $b.Padding = Get-Thick '16,10'
        $b.HorizontalContentAlignment = 'Left'
        $b.HorizontalAlignment = 'Stretch'
        $b.Tag = $o.Key
        $b.Add_Click({ $script:ChoiceResult = [string]$this.Tag; $script:ChoiceDialog.Close() })
        [void]$sp.Children.Add($b)
        if ($o.Note) { [void]$sp.Children.Add((New-Text $o.Note 12 'Normal' '#4B5B5C' '4,0,0,10')) }
    }
    $cancel = New-Button 'Cancel'
    $cancel.Margin = Get-Thick '0,6,0,0'
    $cancel.Add_Click({ $script:ChoiceResult = $null; $script:ChoiceDialog.Close() })
    [void]$sp.Children.Add($cancel)
    $dlg.Content = $sp
    $script:ChoiceDialog = $dlg
    # Keyboard: Esc means Cancel, and the first choice - always the safest - starts with the focus.
    $dlg.Add_PreviewKeyDown({ param($s, $e) if ($e.Key -eq 'Escape') { $e.Handled = $true; $script:ChoiceResult = $null; $script:ChoiceDialog.Close() } })
    $firstChoice = @($sp.Children | Where-Object { $_ -is [System.Windows.Controls.Button] })[0]
    if ($firstChoice) { $dlg.Add_ContentRendered({ [void]$firstChoice.Focus() }.GetNewClosure()) }
    [void]$dlg.ShowDialog()
    return $script:ChoiceResult
}

function Test-FindingActionable($f) {
    <#
        Whether there is anything left to do about a finding. Anything with a real file behind it can
        be acted on; findings about settings and signs are information only. "Failed" still counts:
        if an attempt did not work, the thing is still there to try again.
    #>
    if (-not $f) { return $false }
    # A card holding several files is actionable while any one of them still is.
    if ($f.PSObject.Properties['Items'] -and @($f.Items).Count) { return [bool](@($f.Items | Where-Object { Test-FindingActionable $_ }).Count) }
    if ($f.Status -notin 'Detected', 'Allowed', 'Failed') { return $false }
    if ($f.Source -eq 'Microsoft Defender') { return $true }
    return [bool]($f.Path -and (Test-Path -LiteralPath $f.Path -PathType Leaf))
}

function Get-FindingById([string]$Id) {
    # Findings, and the files listed under grouped ones.
    foreach ($f in @($script:ScanFindings)) {
        if ($f.Id -eq $Id) { return $f }
        if ($f.PSObject.Properties['Items']) { foreach ($i in @($f.Items)) { if ($i.Id -eq $Id) { return $i } } }
    }
    return $null
}

$script:StatusWords = @{ Quarantined = 'In quarantine'; Removed = 'Removed'; Allowed = 'Left in place'; Failed = 'Last try didn''t work' }
function New-FindingButtons($f, [switch]$Compact) {
    # Remove it (which asks how), Quarantine, and - for a whole finding - Leave it for now.
    $btns = New-Object System.Windows.Controls.WrapPanel
    $remove = New-Button 'Remove it'
    $remove.Tag = $f.Id
    $remove.Add_Click({ Invoke-FindingAction ([string]$this.Tag) 'Choose' })
    $quar = New-Button 'Quarantine'
    $quar.Tag = $f.Id
    Set-MoreInfo $quar 'Moves it somewhere it can''t run. You can put it back from this tab.'
    $quar.Add_Click({ Invoke-FindingAction ([string]$this.Tag) 'Quarantine' })
    $set = @($quar, $remove)
    if (-not $Compact) {
        $leave = New-Button 'Leave it for now'
        $leave.Tag = $f.Id
        $leave.Add_Click({ Invoke-FindingAction ([string]$this.Tag) 'Allow' })
        $set += $leave
    }
    foreach ($x in $set) {
        $x.Margin = Get-Thick '0,0,8,0'
        if ($Compact) { $x.Padding = Get-Thick '10,3' }
        [void]$btns.Children.Add($x)
    }
    return $btns
}

function New-FindingCard($f) {
    $b = New-Object System.Windows.Controls.Border
    $b.Background = Get-Brush '#FFFDF8'
    $b.BorderBrush = Get-Brush '#E6DFCC'
    $b.BorderThickness = Get-Thick '1,1,1,1'
    $b.Margin = Get-Thick '0,0,0,10'
    $b.Padding = Get-Thick '14,12'
    $sp = New-Object System.Windows.Controls.StackPanel
    $head = New-Object System.Windows.Controls.StackPanel
    $head.Orientation = 'Horizontal'
    $chip = New-Object System.Windows.Controls.Border
    $chip.Background = Get-Brush $script:SevColours[$f.Severity]
    $chip.Padding = Get-Thick '8,2'; $chip.Margin = Get-Thick '0,0,10,0'; $chip.VerticalAlignment = 'Center'
    $chipText = New-Text ($f.Severity.ToUpper()) 11 'SemiBold' '#FFFDF8' '0'
    $chip.Child = $chipText
    [void]$head.Children.Add($chip)
    [void]$head.Children.Add((New-Text $f.Title 16 'SemiBold' '#0F1B1C' '0' 'Fraunces, Georgia'))
    [void]$sp.Children.Add($head)
    # Who found it, in plain words; the rest of the fine print is under Technical details.
    $by = if ($f.Source -eq 'Microsoft Defender') { 'Found by Microsoft Defender' } else { 'Quietpane''s own check - a warning sign, not proof' }
    if ($f.Status -and $script:StatusWords[[string]$f.Status]) { $by += '   |   ' + $script:StatusWords[[string]$f.Status] }
    [void]$sp.Children.Add((New-Text $by 12 'Normal' '#4B5B5C' '0,6,0,0'))
    if ($f.What -and $f.What -ne $f.Title) { [void]$sp.Children.Add((New-Text $f.What 13.5 'Normal' '#0F1B1C' '0,8,0,0')) }
    if ($f.Why -and $f.Why -ne $f.Technical) { [void]$sp.Children.Add((New-Text $f.Why 13 'Normal' '#4B5B5C' '0,4,0,0')) }
    $grouped = $f.PSObject.Properties['Items'] -and @($f.Items).Count
    if ($f.Path -and -not $grouped) { [void]$sp.Children.Add((New-Text ('Where: ' + $f.Path) 12.5 'Normal' '#4B5B5C' '0,6,0,0')) }
    if ($f.Recommended) { [void]$sp.Children.Add((New-Text $f.Recommended 13 'SemiBold' '#117A68' '0,6,0,0')) }

    if ($grouped) {
        # A row per file, each with its own buttons (or what happened to it).
        foreach ($i in @($f.Items)) {
            $row = New-Object System.Windows.Controls.StackPanel
            $row.Margin = Get-Thick '0,8,0,0'
            $name = New-Text $i.Title 13 'SemiBold' '#0F1B1C' '0'
            Set-MoreInfo $name $i.Path
            [void]$row.Children.Add($name)
            [void]$row.Children.Add((New-Text (Split-Path $i.Path -Parent) 11.5 'Normal' '#66706F' '0,0,0,4'))
            if (Test-FindingActionable $i) { [void]$row.Children.Add((New-FindingButtons $i -Compact)) }
            elseif ($script:StatusWords[[string]$i.Status]) { [void]$row.Children.Add((New-Text $script:StatusWords[[string]$i.Status] 12.5 'SemiBold' '#117A68' '0')) }
            [void]$sp.Children.Add($row)
        }
    } elseif (Test-FindingActionable $f) {
        $btns = New-FindingButtons $f
        $btns.Margin = Get-Thick '0,10,0,0'
        [void]$sp.Children.Add($btns)
    }
    $fine = @()
    if ($f.Technical) { $fine += $f.Technical }
    if ($f.Confidence) { $fine += "How sure: $($f.Confidence)" + $(if ($f.Category) { "   |   $($f.Category)" } else { '' }) }
    if ($f.Sha256) { $fine += "SHA256: $($f.Sha256)" }
    if ($fine.Count) {
        $ex = New-Object System.Windows.Controls.Expander
        $ex.Header = New-Text 'Technical details' 12.5 'SemiBold' '#4B5B5C' '0'
        $ex.Margin = Get-Thick '0,8,0,0'
        $tech = New-Text ($fine -join "`n") 12 'Normal' '#4B5B5C' '0,6,0,0'
        $tech.FontFamily = New-Object System.Windows.Media.FontFamily('Consolas, Courier New')
        $ex.Content = $tech
        [void]$sp.Children.Add($ex)
    }
    $b.Child = $sp
    return $b
}

function Show-Findings {
    $script:FindingsPanel.Children.Clear()
    $list = @($script:ScanFindings)
    if ($script:SevFilter -ne 'All') { $list = @($list | Where-Object { $_.Severity -eq $script:SevFilter }) }
    if (-not $list.Count) {
        $msg = if ($script:SevFilter -eq 'All') { 'Nothing was found.' } else { "Nothing at $($script:SevFilter) level." }
        [void]$script:FindingsPanel.Children.Add((New-Text $msg 13.5 'SemiBold' '#117A68' '0,4,0,0'))
        return
    }
    $rank = @{ Critical = 0; High = 1; Medium = 2; Low = 3; Info = 4 }
    $shown = @($list | Sort-Object { $rank[$_.Severity] } | Select-Object -First 60)
    $heading = if ($script:SevFilter -eq 'All') { 'What we found' } else { "$($script:SevFilter) findings" }
    [void]$script:FindingsPanel.Children.Add((New-Text $heading 16 'SemiBold' '#117A68' '0,4,0,8' 'Fraunces, Georgia'))
    # Buttons only appear where there is a file left to act on. Say so once, rather than leaving
    # people wondering why a finding has no buttons.
    if (-not @($shown | Where-Object { Test-FindingActionable $_ }).Count) {
        [void]$script:FindingsPanel.Children.Add((New-Text 'None of these are files to remove. Each one says what to do.' 12.5 'Normal' '#4B5B5C' '0,0,0,8'))
    }
    foreach ($f in $shown) { [void]$script:FindingsPanel.Children.Add((New-FindingCard $f)) }
    if ($list.Count -gt $shown.Count) {
        [void]$script:FindingsPanel.Children.Add((New-Text ('...and {0} more in the full report.' -f ($list.Count - $shown.Count)) 12.5 'Normal' '#4B5B5C' '0,4,0,0'))
    }
}

function Invoke-FindingAction([string]$Id, [string]$Action) {
    if (Test-Busy) { return }   # ask nothing we cannot then carry out
    $f = Get-FindingById $Id
    if (-not $f) { return }
    $where = if ($f.Path) { "`n$($f.Path)" } else { '' }
    $force = $false
    if ($Action -eq 'Allow') {
        $msg = "Leave this on your PC?`n`n$($f.Title)$where`n`nIt stays exactly where it is and may still be a risk. Quietpane will keep showing it, and your antivirus is not changed in any way."
        if ([System.Windows.MessageBox]::Show($msg, 'Quietpane', 'YesNo', 'Warning') -ne 'Yes') { return }
    } elseif ($Action -eq 'Quarantine') {
        $msg = "Move this into Quietpane's quarantine?`n`n$($f.Title)$where`n`nThe file is moved somewhere it cannot run, and you can put it back from this tab whenever you like."
        if ([System.Windows.MessageBox]::Show($msg, 'Quietpane', 'YesNo', 'Question') -ne 'Yes') { return }
    } elseif ($Action -eq 'Choose') {
        $options = @()
        if ($f.Source -eq 'Microsoft Defender') {
            $options += @{ Key = 'Defender'; Label = 'Let Microsoft Defender handle it'; Primary = $true; Note = 'The safest choice. Defender keeps its own copy, and Windows Security can put it back.' }
        }
        $options += @{ Key = 'Quarantine'; Label = 'Quarantine it with Quietpane'; Primary = ($f.Source -ne 'Microsoft Defender'); Note = 'Moved somewhere it cannot run. You can restore it from this tab.' }
        $options += @{ Key = 'RecycleBin'; Label = 'Move it to the Recycle Bin'; Note = 'Stays on your PC until you empty the bin.' }
        # Quietpane's own checks can be wrong, so say so where it matters most.
        $deleteNote = if ($f.Source -eq 'Microsoft Defender') { 'Gone for good. Quietpane cannot undo this one.' } else { 'Gone for good - only if you''re sure. Quietpane''s checks can be wrong.' }
        $options += @{ Key = 'Delete'; Label = 'Delete it permanently'; Note = $deleteNote }
        $chosen = Show-ChoiceDialog -Title 'Quietpane' -Message "What should happen to this?`n`n$($f.Title)$where" -Options $options
        if (-not $chosen) { return }
        $Action = $chosen
        if ($Action -eq 'Delete') {
            $msg = "Delete this file permanently?`n`n$($f.Path)`n`nThis cannot be undone by Quietpane. It does not go to the Recycle Bin and there is no restore. Quarantine is safer if you are unsure."
            if ([System.Windows.MessageBox]::Show($msg, 'Delete for good?', 'YesNo', 'Warning') -ne 'Yes') { return }
            $force = $true
        }
    }
    $ui.LogBox.AppendText([Environment]::NewLine)
    Set-LogVisible $true
    Start-Work -StatusText 'Dealing with it...' -Params @{ Finding = $f; Action = $Action; Force = $force } -Work { param($Finding, $Action, $Force) Invoke-QpRemediate -Finding $Finding -Action $Action -Force:$Force } -OnDone {
        param($r)
        $r = @($r)[-1]
        if ($r) {
            $f.Status = $r.Status
            [void][System.Windows.MessageBox]::Show($r.Note, 'Quietpane')
            Show-Findings
            Update-QuarantineList
            Add-ActionTally $r
        }
    }
}

function Update-QuarantineList {
    <# Everything Quietpane is currently holding, with a way back out. #>
    $items = @(Get-QpQuarantineItems)
    $script:QuarantinePanel.Children.Clear()
    if (-not $items.Count) {
        $script:QuarantineBox.Visibility = 'Collapsed'
        return
    }
    $script:QuarantineBox.Visibility = 'Visible'
    $script:QuarantineBox.Header = New-Text ('In quarantine ({0})' -f $items.Count) 14.5 'SemiBold' '#117A68' '0' 'Fraunces, Georgia'
    [void]$script:QuarantinePanel.Children.Add((New-Text 'Moved where they can''t run - still on this PC until you delete them.' 12.5 'Normal' '#4B5B5C' '0,0,0,8'))
    foreach ($i in $items) {
        $row = New-Object System.Windows.Controls.Border
        $row.BorderBrush = Get-Brush '#E6DFCC'; $row.BorderThickness = Get-Thick '0,0,0,1'
        $row.Padding = Get-Thick '0,8'
        $sp = New-Object System.Windows.Controls.StackPanel
        [void]$sp.Children.Add((New-Text $i.FileName 13.5 'SemiBold' '#0F1B1C' '0'))
        [void]$sp.Children.Add((New-Text ('{0}   |   was at {1}   |   quarantined {2}' -f $(if ($i.ThreatName) { $i.ThreatName } else { 'Quietpane check' }), $i.OriginalPath, $i.QuarantinedAt) 12 'Normal' '#4B5B5C' '0,2,0,0'))
        $btns = New-Object System.Windows.Controls.WrapPanel
        $btns.Margin = Get-Thick '0,6,0,0'
        $restore = New-Button 'Put it back'
        $restore.Tag = $i.Id
        $restore.Add_Click({ Invoke-QuarantineAction ([string]$this.Tag) 'Restore' })
        $del = New-Button 'Delete for good'
        $del.Tag = $i.Id
        $del.Add_Click({ Invoke-QuarantineAction ([string]$this.Tag) 'Delete' })
        foreach ($x in $restore, $del) { $x.Margin = Get-Thick '0,0,8,0'; [void]$btns.Children.Add($x) }
        [void]$sp.Children.Add($btns)
        $row.Child = $sp
        [void]$script:QuarantinePanel.Children.Add($row)
    }
}

function Invoke-QuarantineAction([string]$Id, [string]$What) {
    if (Test-Busy) { return }   # ask nothing we cannot then carry out
    $item = @(Get-QpQuarantineItems | Where-Object { $_.Id -eq $Id }) | Select-Object -First 1
    if (-not $item) { return }
    if ($What -eq 'Restore') {
        $msg = "Put this file back where it was?`n`n$($item.FileName)`nback to: $($item.OriginalPath)`n`nIf it really was a threat, it will be a threat again. Your antivirus may catch it straight away."
        if ([System.Windows.MessageBox]::Show($msg, 'Quietpane', 'YesNo', 'Warning') -ne 'Yes') { return }
        Start-Work -StatusText 'Putting it back...' -Params @{ Id = $Id } -Work { param($Id) Restore-QpQuarantineItem -Id $Id } -OnDone {
            param($r); $r = @($r)[-1]
            if ($r) { [void][System.Windows.MessageBox]::Show($r.Note, 'Quietpane') }
            Update-QuarantineList
        }
    } else {
        $msg = "Delete this permanently?`n`n$($item.FileName)`nfrom: $($item.OriginalPath)`n`nThis cannot be undone. The file does not go to the Recycle Bin and cannot be restored afterwards."
        if ([System.Windows.MessageBox]::Show($msg, 'Delete for good?', 'YesNo', 'Warning') -ne 'Yes') { return }
        Start-Work -StatusText 'Deleting it...' -Params @{ Id = $Id } -Work { param($Id) Remove-QpQuarantineItem -Id $Id -Force } -OnDone {
            param($r); $r = @($r)[-1]
            if ($r) { [void][System.Windows.MessageBox]::Show($r.Note, 'Quietpane') }
            Update-QuarantineList
        }
    }
}

function Update-ScanProgress {
    <# While a check runs: which step, what it is looking at, how much it has seen, how long so far. #>
    $secs = [int]((Get-Date) - $script:ScanStarted).TotalSeconds
    $clock = '{0}:{1:00}' -f [int][math]::Floor($secs / 60), ($secs % 60)
    if ($script:Sync.Cancel) { $script:ScanProgress.Text = "Stopping as soon as it is safe to...   |   $clock"; return }
    $p = $script:Sync.Progress
    if (-not $p) { $script:ScanProgress.Text = "Getting started...   |   $clock"; return }
    $bits = @()
    if ([int]$p.Of -gt 0) { $bits += 'Step {0} of {1}: {2}' -f $p.Step, $p.Of, $p.Stage } elseif ($p.Stage) { $bits += [string]$p.Stage }
    if ($p.Object) { $bits += [string]$p.Object }
    if ([int]$p.Scanned -gt 0) { $bits += '{0:N0} things looked at' -f [int]$p.Scanned }
    if ([int]$p.Found -gt 0) { $bits += '{0} worth attention so far' -f [int]$p.Found }
    $bits += $clock
    $script:ScanProgress.Text = $bits -join '   |   '
}

function Update-ScanSummary {
    <# The panel at the end of a check. Wording comes from the engine, so the log agrees with the window. #>
    if (-not $script:LastScanResult) { $script:SummaryPanel.Visibility = 'Collapsed'; return }
    $r = $script:LastScanResult
    # Something that failed to be dealt with is still there, so it still counts as outstanding.
    $outstanding = @($script:ScanFindings | Where-Object { $_.Severity -in 'Critical', 'High' -and $_.Status -in 'Detected', 'Failed' }).Count
    $s = New-QpScanSummary -Counts $r.Counts -Tally $script:ActionTally -Scanned ([int]$r.Scanned) `
        -Seconds ([int]$script:ScanSeconds) -Outstanding $outstanding -IsAdmin (Test-IsAdmin) -Cancelled ([bool]$r.Cancelled)
    $script:SummaryStack.Children.Clear()
    [void]$script:SummaryStack.Children.Add((New-Text 'How it went' 16 'SemiBold' '#117A68' '0,0,0,6' 'Fraunces, Georgia'))
    foreach ($l in $s.Lines) { [void]$script:SummaryStack.Children.Add((New-Text $l 13.5 'Normal' '#0F1B1C' '0,0,0,3')) }
    [void]$script:SummaryStack.Children.Add((New-Text $s.NextStep 13.5 'SemiBold' '#117A68' '0,8,0,0'))
    $script:SummaryPanel.Visibility = 'Visible'
}

function Add-ActionTally($r) {
    <# Keeps count of what has been done to findings since this check started. #>
    if (-not $r) { return }
    $key = ''
    if ($r.Status -eq 'Failed') { $key = 'Failed' }
    elseif ($r.Action -eq 'Allow') { $key = 'Allowed' }
    elseif ($r.Action -eq 'Quarantine') { $key = 'Quarantined' }
    elseif ($r.Action -eq 'RecycleBin') { $key = 'Recycled' }
    elseif ($r.Action -eq 'Delete') { $key = 'Deleted' }
    elseif ($r.Action -eq 'Defender') { $key = 'Removed' }
    if ($key) { $script:ActionTally[$key] = [int]$script:ActionTally[$key] + 1 }
    Update-ScanSummary
}

function Start-SafetyScan([bool]$AskDefender = $false) {
    if (Test-Busy) { return }
    $ui.LogBox.AppendText([Environment]::NewLine)
    $script:ScanStarted = Get-Date
    $script:ScanRunning = $true
    $script:LastScanResult = $null
    foreach ($k in @($script:ActionTally.Keys)) { $script:ActionTally[$k] = 0 }
    $script:SummaryPanel.Visibility = 'Collapsed'
    $btnStopScan.Visibility = 'Visible'
    $btnStopScan.IsEnabled = $true
    $scanSummary.Text = 'Having a look around...'
    $script:ScanProgress.Text = if ($AskDefender) { 'Asking Microsoft Defender to scan first. This can take a few minutes - Stop works at any point.' } else { 'Getting started...' }
    $script:CardAdware.Value.Text = 'Checking...'
    $script:CardAdware.Caption.Text = 'Nothing is changed while we look'
    Start-Work -StatusText 'Looking for threats and problems (nothing is changed)...' -Params @{ Deep = $AskDefender } -Work {
        param($Deep)
        if ($Deep) { Invoke-QpThreatScan -Type Quick | Out-Null }
        Invoke-QpAudit
    } -OnDone {
        param($r)
        $r = @($r | Where-Object { $_ -and $_.PSObject.Properties['Report'] })[-1]
        $script:ScanRunning = $false
        $btnStopScan.Visibility = 'Collapsed'
        $script:ScanSeconds = [int]((Get-Date) - $script:ScanStarted).TotalSeconds
        if ($r -and $r.Cancelled) {
            $script:LastScanResult = $r
            $script:ScanFindings = @()
            $script:ChartPanel.Visibility = 'Collapsed'
            $script:FindingsPanel.Children.Clear()
            $scanSummary.Text = 'Stopped. Nothing on your PC was changed.'
            $script:ScanProgress.Text = ''
            $script:CardAdware.Value.Text = 'Stopped'
            $script:CardAdware.Value.Foreground = Get-Brush '#0F1B1C'
            $script:CardAdware.Caption.Text = 'Run the check again when you have a few minutes'
            Update-ScanSummary
            Update-Buttons
            return
        }
        if ($r -and $r.Report) {
            $script:LastReport = $r.Report
            $script:LastScanResult = $r
            $script:ScanFindings = @($r.Findings)
            foreach ($k in @($script:SevCounts.Keys)) { $script:SevCounts[$k] = [int]$r.Counts[$k] }
            $script:SevFilter = 'All'
            $script:ChartPanel.Visibility = 'Visible'
            Draw-SeverityChart
            Show-Findings
            Update-ScanSummary
            $secs = $script:ScanSeconds
            $scanSummary.Text = ('Looked at {0:N0} things in {1} seconds, and found {2} worth reporting.' -f [int]$r.Scanned, $secs, $r.Total)
            $worst = @('Critical', 'High', 'Medium', 'Low', 'Info') | Where-Object { [int]$r.Counts[$_] -gt 0 } | Select-Object -First 1
            $script:ScanProgress.Text = if ($r.Defender -and $r.Defender.Note) { $r.Defender.Note } else { 'The full report also opened in your browser and is saved on your Desktop.' }
            if ($worst -in 'Critical', 'High') {
                $script:CardAdware.Value.Text = ('{0} to deal with' -f ([int]$r.Critical + [int]$r.High))
                $script:CardAdware.Value.Foreground = Get-Brush '#A83232'
                $script:CardAdware.Caption.Text = 'Open the Safety scan tab'
            } else {
                $script:CardAdware.Value.Text = 'Nothing serious'
                $script:CardAdware.Value.Foreground = Get-Brush '#117A68'
                $script:CardAdware.Caption.Text = ('{0} thing(s) worth a look' -f ([int]$r.Medium + [int]$r.Low))
            }
            Open-AsUser $r.Report
            Update-Buttons
        } else {
            $scanSummary.Text = 'The check did not finish. Click "Show details" at the bottom to see why.'
            $script:ScanProgress.Text = ''
            $script:CardAdware.Value.Text = 'Did not finish'
        }
    }
}
$btnStopScan.Add_Click({
    # Stop is a request, not a kill: the check finishes the step it is on and then stops cleanly.
    $script:Sync.Cancel = $true
    $btnStopScan.IsEnabled = $false
    $script:ScanProgress.Text = 'Stopping as soon as it is safe to...'
})
$btnScan.Add_Click({ Start-SafetyScan $false })
$btnScanDeep.Add_Click({ Start-SafetyScan $true })
$btnHomeScan.Add_Click({ Select-Tab 'scan'; Start-SafetyScan $false })

# ---- One click
function Show-HomeResult($r) {
    $r = @($r)[-1]
    $script:ResultPanel.Visibility = 'Visible'
    if (-not $r) {
        $script:ResultTitle.Text = 'Something went wrong'
        $script:ResultText.Text = 'Click "Show details" at the bottom to see what happened. Anything that was changed can be undone in the Undo tab.'
        return
    }
    if ($r.Nothing) {
        $script:ResultTitle.Text = 'Already clean!'
        $script:ResultText.Text = 'This PC already has every recommended setting. Nothing needed changing.'
        $btnRestart.Visibility = 'Collapsed'; $btnUndoAll.Visibility = 'Collapsed'
        return
    }
    $lines = @()
    if ($r.Settings)      { $lines += "Switched off $($r.Settings) tracking and ads setting(s)." }
    if (@($r.BrandsQuieted).Count) { $lines += ('Quietened the extras from {0}. Their apps still work.' -f (@($r.BrandsQuieted) -join ', ')) }
    if ($r.AppsRemoved)   { $lines += "Removed $($r.AppsRemoved) unneeded app(s)." }
    if ($r.BytesFreed -gt 0) { $lines += "Freed about $(Format-QpBytes $r.BytesFreed) of space - it is in your Recycle Bin, empty it whenever you like." }
    if ($r.MemoryFreed -gt 0) { $lines += "Memory in use dropped by about $(Format-QpBytes $r.MemoryFreed)." }
    $lines += ''
    $lines += 'Restart your PC to finish. Changed your mind? "Undo everything" restores settings; cleared files stay in your Recycle Bin, and removed apps reinstall from the Microsoft Store.'
    Show-MeterGains ([int64]$r.BytesFreed) ([int64]$r.MemoryFreed)
    $script:ResultTitle.Text = 'All done!'
    $script:ResultText.Text = $lines -join [Environment]::NewLine
    $script:LastRestorePoint = $r.RestorePoint
    $btnRestart.Visibility = 'Visible'; $btnUndoAll.Visibility = 'Visible'
    Update-Buttons
}

$btnOneClick.Add_Click({
    $s = $script:HomeCounts
    if ($s -and $s.Total -eq 0) {
        [void][System.Windows.MessageBox]::Show('Your PC is already in great shape. Nothing left for me to do.', 'Quietpane')
        return
    }
    $lines = @()
    if ($s.Privacy) { $lines += "  - switch off $($s.Privacy) tracking and ads setting(s)" }
    if ($s.Brands)  { $lines += ('  - quieten {0} background item(s) from {1}' -f $s.Brands, $s.BrandNames) }
    if ($s.Apps)    { $lines += "  - remove $($s.Apps) unneeded app(s)" }
    if ($s.Bytes -gt 0) { $lines += "  - free about $(Format-QpBytes $s.Bytes) (files go to your Recycle Bin)" }
    $msg = "Here is what I will do:`n`n" + ($lines -join "`n") + "`n`nAll of it can be undone afterwards. Close your games and browsers first, please.`n`nShall I go ahead?"
    if ([System.Windows.MessageBox]::Show($msg, 'Quietpane', 'YesNo', 'Question') -ne 'Yes') { return }
    $script:ResultPanel.Visibility = 'Collapsed'
    $ui.LogBox.AppendText([Environment]::NewLine)
    Start-Work -StatusText 'Cleaning your PC... this usually takes less than a minute.' -Work { Invoke-QpRecommended } -OnDone { param($r) Show-HomeResult $r; Update-StateAfterChange }
})

$btnRestart.Add_Click({
    if ([System.Windows.MessageBox]::Show('Restart now? Save anything you have open first.', 'Quietpane', 'YesNo', 'Question') -ne 'Yes') { return }
    Start-Process -FilePath 'shutdown.exe' -ArgumentList '/r', '/t', '5' -WindowStyle Hidden
})

$btnUndoAll.Add_Click({
    if (-not $script:LastRestorePoint) { return }
    if ([System.Windows.MessageBox]::Show('Put everything back exactly as it was before you pressed "Quiet my PC now"?', 'Quietpane', 'YesNo', 'Question') -ne 'Yes') { return }
    $ui.LogBox.AppendText([Environment]::NewLine)
    Start-Work -StatusText 'Putting everything back...' -Params @{ Path = $script:LastRestorePoint } -Work { param($Path) Invoke-QpUndo -Path $Path } -OnDone {
        param($result)
        $r = Get-UndoResult $result
        if ($r.Failed) {
            # Say so, and keep the button: whatever didn't come back can be tried again.
            $script:ResultTitle.Text = 'Most things are back - a few are not'
            $script:ResultText.Text = "$($r.Failed) change(s) could not be put back; everything else is as it was. Press Undo everything to try those again, or see Show details for what Windows said."
        } else {
            $script:ResultTitle.Text = 'Everything is back as it was'
            $script:ResultText.Text = "All settings were restored. Files are still in your Recycle Bin, and removed apps can be reinstalled from the Microsoft Store.`nRestart your PC to finish."
            $script:LastRestorePoint = $null
            $btnUndoAll.Visibility = 'Collapsed'
            $script:MeterSpace.Delta.Visibility = 'Collapsed'
            $script:MeterMemory.Delta.Visibility = 'Collapsed'
        }
        Update-StateAfterChange
    }
})

function Get-UndoResult($Result) {
    # What Invoke-QpUndo reported; anything unexpected counts as "couldn't tell", never as success.
    $r = @($Result) | Where-Object { $_ -and $_.PSObject.Properties['Failed'] } | Select-Object -Last 1
    if ($r) { return $r }
    return [pscustomobject]@{ Restored = 0; Failed = 1; Readable = $false }
}

$btnShowDetails.Add_Click({ Set-LogVisible $true })
$ui.LinkDetails.Add_Click({ Set-LogVisible (-not $script:LogVisible) })
$btnOpenReport.Add_Click({ if ($script:LastReport) { Open-AsUser $script:LastReport } })

$btnUndoRefresh.Add_Click({ Update-State })
$btnUndo.Add_Click({
    $sel = $script:UndoList.SelectedItem
    if (-not ($sel -is [System.Windows.Controls.ListBoxItem])) { [void][System.Windows.MessageBox]::Show('Pick a restore point from the list first.', 'Quietpane'); return }
    if ([System.Windows.MessageBox]::Show("Undo all changes from:`n$($sel.Content)?", 'Quietpane', 'YesNo', 'Question') -ne 'Yes') { return }
    $ui.LogBox.AppendText([Environment]::NewLine)
    Set-LogVisible $true
    Start-Work -StatusText 'Undoing...' -Params @{ Path = [string]$sel.Tag } -Work { param($Path) Invoke-QpUndo -Path $Path } -OnDone {
        param($result)
        $r = Get-UndoResult $result
        Update-StateAfterChange
        if ($r.Failed) {
            [void][System.Windows.MessageBox]::Show("$($r.Failed) change(s) could not be put back; everything else is as it was.`n`nThe restore point stays in the list, so you can try again. The details below say what Windows said.", 'Quietpane')
        }
    }
})

$ui.Tabs.Add_SelectionChanged({
    param($s, $e)
    if ($e.OriginalSource -eq $ui.Tabs) { Update-Buttons; Set-TimerQuick }
})
# F5 reads the PC again, as in most Windows apps. (If something is already running, the status line says so.)
$window.Add_PreviewKeyDown({ param($s, $e) if ($e.Key -eq 'F5') { $e.Handled = $true; Update-State } })

$window.Add_Closing({
    param($s, $e)
    if ($script:Job) {
        if ([System.Windows.MessageBox]::Show('Something is still running. Close anyway?', 'Quietpane', 'YesNo', 'Warning') -ne 'Yes') { $e.Cancel = $true; return }
    }
    $timer.Stop()
    Stop-LiveSampler
})

$ui.Tabs.SelectedIndex = 0

# ------------------------------------------------------------------ self-test / snapshot
function Get-UnnamedControls {
    <#
        Every control you can reach with the keyboard that a screen reader would have no name for. Used
        by the self-test, so a control added later without a name is caught rather than shipped.
    #>
    $found = New-Object System.Collections.ArrayList
    $stack = New-Object System.Collections.Stack
    $stack.Push($window)
    while ($stack.Count) {
        $el = $stack.Pop()
        $reachable = ($el -is [System.Windows.Controls.Primitives.ButtonBase] -or $el -is [System.Windows.Controls.Expander] -or
                      $el -is [System.Windows.Controls.TabItem] -or $el -is [System.Windows.Controls.ComboBox] -or
                      $el -is [System.Windows.Controls.ListBox] -or $el -is [System.Windows.Controls.TextBox] -or
                      ($el -is [System.Windows.Controls.ScrollViewer] -and $el.Focusable))
        if ($reachable) {
            $name = ''
            try { $name = [System.Windows.Automation.Peers.UIElementAutomationPeer]::CreatePeerForElement($el).GetName() } catch { }
            if (-not "$name".Trim()) { [void]$found.Add($el.GetType().Name) }
        } elseif ($el -is [System.Windows.Documents.Hyperlink]) {
            $name = ''
            try { $name = [System.Windows.Automation.Peers.ContentElementAutomationPeer]::CreatePeerForElement($el).GetName() } catch { }
            if (-not "$name".Trim()) { [void]$found.Add('Hyperlink') }
        }
        foreach ($child in [System.Windows.LogicalTreeHelper]::GetChildren($el)) { if ($child -is [System.Windows.DependencyObject]) { $stack.Push($child) } }
    }
    return @($found)
}
function Get-TabWords {
    <#
        How many words each tab shows - its text, labels and buttons, not the details log. Used by the
        self-test (QP_WORDS=1) to keep the window from filling up with words again.
    #>
    foreach ($tab in $ui.Tabs.Items) {
        $words = 0
        $stack = New-Object System.Collections.Stack
        $stack.Push($tab.Content)
        while ($stack.Count) {
            $el = $stack.Pop()
            $text = ''
            if ($el -is [System.Windows.Controls.TextBlock] -and $el.Visibility -eq 'Visible') { $text = $el.Text }
            elseif ($el -is [System.Windows.Controls.ContentControl] -and $el.Content -is [string]) { $text = $el.Content }
            elseif ($el -is [System.Windows.Controls.HeaderedContentControl] -and $el.Header -is [string]) { $text = $el.Header }
            if ($el -is [System.Windows.Controls.TextBox]) { $text = '' }   # the policy documents, read on demand
            $words += @("$text" -split '\s+' | Where-Object { $_ -match '\w' }).Count
            if ($el -is [System.Windows.UIElement] -and $el.Visibility -ne 'Visible') { continue }
            foreach ($child in [System.Windows.LogicalTreeHelper]::GetChildren($el)) { if ($child -is [System.Windows.DependencyObject]) { $stack.Push($child) } }
        }
        '{0}={1}' -f $tab.Header, $words
    }
}
function Test-FindingCards {
    <#
        A Medium file, a Low file, one card holding two files, and a setting. Every file gets Quarantine
        and Remove; the setting gets neither. Returns how many Quarantine buttons were drawn (4 is right)
        and how many controls on those cards have no name. The test files are its own, in Temp.
    #>
    $dir = Join-Path $env:TEMP ('qp-cards-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void][IO.Directory]::CreateDirectory($dir)
    try {
        $files = foreach ($n in 'one.exe', 'two.exe', 'three.exe', 'four.exe') { $p = Join-Path $dir $n; [IO.File]::WriteAllText($p, 'test'); $p }
        $medium = New-QpFinding -Severity Medium -Title 'Medium file' -Path $files[0] -Confidence Heuristic
        $low = New-QpFinding -Severity Low -Title 'Low file' -Path $files[1] -Confidence Heuristic
        $group = New-QpFinding -Severity Medium -Title '2 unsigned programs' -Confidence Heuristic
        $group | Add-Member -NotePropertyName Items -NotePropertyValue @((New-QpFinding -Severity Medium -Title 'three.exe' -Path $files[2]), (New-QpFinding -Severity Medium -Title 'four.exe' -Path $files[3]))
        $setting = New-QpFinding -Severity Medium -Title 'A proxy is configured' -Confidence Heuristic
        $script:ScanFindings = @($medium, $low, $group, $setting)
        $script:SevFilter = 'All'
        Show-Findings
        $quarantine = 0
        $stack = New-Object System.Collections.Stack
        $stack.Push($script:FindingsPanel)
        while ($stack.Count) {
            $el = $stack.Pop()
            if ($el -is [System.Windows.Controls.Button] -and $el.Content -eq 'Quarantine') { $quarantine++ }
            foreach ($child in [System.Windows.LogicalTreeHelper]::GetChildren($el)) { if ($child -is [System.Windows.DependencyObject]) { $stack.Push($child) } }
        }
        return [pscustomobject]@{ Quarantine = $quarantine; Unnamed = @(Get-UnnamedControls).Count }
    } finally {
        [IO.Directory]::Delete($dir, $true)   # the four test files made above
        $script:ScanFindings = @()
        $script:FindingsPanel.Children.Clear()
    }
}
function Test-SignInCosts {
    <#
        Three startup programs with known costs: one Windows timed, one heavy, one not running. The
        worst must come first, each line must say its cost, and the total must add up.
    #>
    $items = @(
        [pscustomobject]@{ Id = 'a'; Name = 'Idle helper'; On = $true; Keep = $false; Locked = $false; Publisher = 'Test'; Command = 'a.exe'; Note = ''; Missing = $false; Everyone = $false },
        [pscustomobject]@{ Id = 'b'; Name = 'Heavy app'; On = $true; Keep = $false; Locked = $false; Publisher = 'Test'; Command = 'b.exe'; Note = ''; Missing = $false; Everyone = $false },
        [pscustomobject]@{ Id = 'c'; Name = 'Slow starter'; On = $true; Keep = $false; Locked = $false; Publisher = 'Test'; Command = 'c.exe'; Note = ''; Missing = $false; Everyone = $false }
    )
    $signIn = [pscustomobject]@{
        Times = [pscustomobject]@{ Logon = (Get-Date); Boot = (Get-Date) }
        Record = [pscustomobject]@{ Boot = [pscustomobject]@{ When = (Get-Date).AddDays(-2); Seconds = 35.5; ToDesktopSeconds = 18.5; AfterDesktopSeconds = 17 }; Slow = @{}; Stale = $false }
        Costs = @(
            [pscustomobject]@{ Id = 'a'; Name = 'Idle helper'; Running = $false; MemoryMB = 0; Copies = 0; StartedAfterSeconds = $null; WindowsSeconds = $null; WindowsWhen = $null },
            [pscustomobject]@{ Id = 'b'; Name = 'Heavy app'; Running = $true; MemoryMB = 500; Copies = 2; StartedAfterSeconds = 6.5; WindowsSeconds = $null; WindowsWhen = $null },
            [pscustomobject]@{ Id = 'c'; Name = 'Slow starter'; Running = $true; MemoryMB = 80; Copies = 1; StartedAfterSeconds = 2; WindowsSeconds = 3.2; WindowsWhen = (Get-Date).AddDays(-2) }
        )
    }
    Update-StartupList $items $signIn
    $order = @($script:Options['startup'] | ForEach-Object { $_.Title }) -join ','
    $text = @()
    foreach ($child in $script:StartupList.Children) { if ($child -is [System.Windows.Controls.TextBlock]) { $text += $child.Text } }
    $all = $text -join ' | '
    $result = '{0}; total line: {1}; restart line: {2}; windows timing: {3}; copies: {4}' -f $order,
        [bool]($all -match 'using 580\.0 MB right now'), [bool]($all -match 'timed your last restart at 35\.5 seconds'),
        [bool]($all -match 'Windows timed it at 3.2 seconds'), [bool]($all -match 'in 2 copies')
    $script:StartupList.Children.Clear()
    $script:Options['startup'].Clear()
    return $result
}
function New-TestAddon($Name, $Browser, $On, $BuiltIn, $Perms, $Policy, $Blocked = $false) {
    [pscustomobject]@{
        Id = "$Browser|Default|$Name"; ExtId = 'abcdefghijklmnopabcdefghijklmnop'; Browser = $Browser; BrowserKey = $Browser.ToLower()
        Profile = ''; Name = $Name; Version = '1.0'; On = $On; BuiltIn = $BuiltIn; Locked = $false; Blocked = $Blocked; BlockedByMe = $Blocked
        Source = 'You added it yourself'; Reach = (Get-QpExtensionReach -Permissions $Perms); Added = (Get-Date).AddDays(-400)
        Folder = ''; PolicyRoot = $Policy
    }
}
function Test-AddonList {
    <#
        Four add-ons: one that reads every site, one that only works on two, one that is part of the
        browser, and a Firefox one Quietpane cannot switch off. The widest reach must come first, the
        browser's own parts must not fill the list, and Firefox must say where to do it instead.
    #>
    $addons = @(
        (New-TestAddon 'Docs Offline' 'Edge' $false $false @('https://docs.google.com/*', 'https://drive.google.com/*') 'HKCU:\SOFTWARE\Policies\Microsoft\Edge'),
        (New-TestAddon 'Coupon Helper' 'Edge' $true $false @('<all_urls>', 'webRequest', 'history', 'storage') 'HKCU:\SOFTWARE\Policies\Microsoft\Edge'),
        (New-TestAddon 'Edge PDF Viewer' 'Edge' $true $true @('tabs') 'HKCU:\SOFTWARE\Policies\Microsoft\Edge'),
        (New-TestAddon 'Old Toolbar' 'Firefox' $true $false @('<all_urls>') '')
    )
    Update-AddonList $addons
    $order = @($script:Options['extensions'] | ForEach-Object { ($_.Title -split '   ')[0] }) -join ','
    $text = @()
    foreach ($child in $script:AddonList.Children) {
        if ($child -is [System.Windows.Controls.TextBlock]) { $text += $child.Text }
        elseif ($child -is [System.Windows.Controls.CheckBox] -and $child.Content -is [System.Windows.Controls.TextBlock]) { $text += $child.Content.Text }
    }
    $all = ($text -join ' | ') + ' | ' + [string]$script:AddonSection.Expander.Header.Text
    $result = '{0}; reads every site: {1}; count: {2}; parts summed up: {3}; firefox: {4}' -f $order,
        [bool]($all -match 'Reads and changes everything on every site you visit'), [bool]($all -match '3, 2 read every site'),
        [bool]($all -match '1 more are part of the browsers themselves'), [bool]($all -match 'switch this off in Firefox itself')
    $script:AddonList.Children.Clear()
    $script:Options['extensions'].Clear()
    return $result
}
function Test-SpaceWins {
    <#
        Three suggestions drawn into the real window: one to move, one only Windows can clear, and one
        that had to stop looking. The ones you can act on get a button; the other says where to go.
    #>
    $before = $script:SpaceResult
    $script:SpaceResult = [pscustomobject]@{ Wins = @(
        [pscustomobject]@{ Id = 'installers'; Title = 'Installers you have already used'; Short = '3 of them, the newest from 7 March.'
            Why = 'An installer is only needed once.'; Bytes = [int64]3670016; Count = 3; CanRecycle = $true; Advice = ''; Truncated = $true
            Items = @(
                [pscustomobject]@{ Path = 'C:\Users\Someone\Downloads\setup.exe'; Name = 'setup.exe'; Bytes = [int64]2097152; When = (Get-Date).AddDays(-200) },
                [pscustomobject]@{ Path = 'C:\Users\Someone\Downloads\office.msi'; Name = 'office.msi'; Bytes = [int64]1048576; When = (Get-Date).AddDays(-700) },
                [pscustomobject]@{ Path = 'C:\Users\Someone\Desktop\driver.exe'; Name = 'driver.exe'; Bytes = [int64]524288; When = (Get-Date).AddDays(-400) }
            ) },
        [pscustomobject]@{ Id = 'windows.old'; Title = 'Your previous version of Windows'; Short = 'Kept after a Windows upgrade so you could go back.'
            Why = 'Windows removes this by itself.'; Bytes = [int64]12884901888; Count = 0; CanRecycle = $false; Truncated = $false
            Advice = 'Remove it in Settings > System > Storage > Temporary files, which does it safely. Quietpane will not touch it.'; Items = @() }
    ) }
    Show-SpaceWins
    $text = @()
    $buttons = @()
    $stack = New-Object System.Collections.Stack
    $stack.Push($script:SpaceWins)
    while ($stack.Count) {
        $el = $stack.Pop()
        # Anything hidden is skipped, so this is what a person actually sees on the card.
        if ($el -is [System.Windows.UIElement] -and $el.Visibility -ne 'Visible') { continue }
        if ($el -is [System.Windows.Controls.TextBlock]) { $text += $el.Text }
        if ($el -is [System.Windows.Controls.Button]) { $buttons += [string]$el.Content }
        foreach ($child in [System.Windows.LogicalTreeHelper]::GetChildren($el)) { if ($child -is [System.Windows.DependencyObject]) { $stack.Push($child) } }
    }
    $all = $text -join ' | '
    $result = 'rows: {0}; move button: {1}; size: {2}; windows only: {3}; stopped looking: {4}; files hidden: {5}' -f
        $script:SpaceWins.Children.Count, [bool]($buttons -contains 'Move 3 to the Recycle Bin'), [bool]($all -match '12\.00 GB'),
        [bool]($all -match 'Settings > System > Storage'), [bool]($all -match 'stopped looking after 20 seconds'),
        [bool]($all -notmatch 'setup\.exe')
    $script:SpaceWins.Children.Clear()
    $script:SpaceResult = $before
    return $result
}
function Test-SessionCard {
    <#
        A made-up session drawn into the real card: a quiet start, a hot spell that was held back, and a
        stretch where the PC slept. The card must name the worst of it, count the minutes, and own up to
        the gap - and the extra vitals line must show the three numbers the tiles have no room for.
    #>
    $t0 = (Get-Date).AddMinutes(-41)
    function New-Sample($mins, $cpu, $temp, $throttled, $speed, $commit, $mem, $top) {
        [pscustomobject]@{
            At = $t0.AddMinutes($mins); CpuUsage = $cpu; CpuTempC = $temp; CpuThrottled = $throttled; SpeedPct = $speed
            CpuTempSource = 'TZ'; CpuTempStuck = $false; CpuLimitPct = $(if ($throttled) { 61 } else { 100 }); CpuName = 'Test processor'
            CommitPct = $commit; CommitUsed = [double]24GB; CommitLimit = [double]27GB; MemUsed = [double]$mem; MemTotal = [double]16GB
            DiskBusyPct = 26; DiskQueue = 0.8; SpeedMhz = 2400
            CpuTop = @([pscustomobject]@{ Name = $top; Pct = $cpu }); Gpus = @(); Battery = $null
        }
    }
    $script:SessionWatch = New-QpSessionWatch -IntervalSeconds 10 -Now $t0
    [void](Add-QpSessionSample -Watch $script:SessionWatch -Reading (New-Sample 0 12 55 $false 100 40 3GB 'Windows Explorer'))
    # Seven readings ten seconds apart: over a minute very hot and held back, so both are worth saying.
    foreach ($i in 1..7) { [void](Add-QpSessionSample -Watch $script:SessionWatch -Reading (New-Sample (0.166 * $i) 96 96 $true 61 91 14GB 'A game')) }
    [void](Add-QpSessionSample -Watch $script:SessionWatch -Reading (New-Sample 40 20 60 $false 100 45 4GB 'A game'))
    # An alert that has to fire (memory at 91%) and the same one again, which must not fire twice.
    $hot = New-Sample 40 20 60 $false 100 91 4GB 'A game'
    $raised = @(Update-QpSessionAlerts -Watch $script:SessionWatch -Reading $hot -FreePct 4)
    $again = @(Update-QpSessionAlerts -Watch $script:SessionWatch -Reading $hot -FreePct 4)
    Show-SessionAlerts $raised
    Update-SessionCard
    $head = [string]$script:SessionHead.Text
    $lines = @(foreach ($child in $script:SessionLines.Children) { if ($child -is [System.Windows.Controls.TextBlock]) { $child.Text } }) -join ' | '
    $button = [string]$script:BtnSession.Content
    Switch-SessionWatch   # stop it again: the self-test must leave nothing running
    $after = [string]$script:BtnSession.Content
    $canSave = [string]$script:BtnSessionSave.Visibility
    # The timeline, as drawn: how many columns, and how many of them the gap swallowed.
    $bands = @(Get-QpSessionBands -Watch $script:SessionLastWatch -Columns 96)
    $legend = @($script:SessionChart.Children | Where-Object { $_ -is [System.Windows.Controls.WrapPanel] })
    $drawn = '{0} columns, {1} a gap, {2} held back, {3} legend words' -f $bands.Count,
        @($bands | Where-Object { $_.Heat -eq 'gap' }).Count,
        @($bands | Where-Object { $_.Held }).Count,
        $(if ($legend.Count) { $legend[0].Children.Count } else { 0 })
    # The report itself, built but never written to disk: the self-test changes nothing.
    $html = New-QpSessionReportHtml -Watch $script:SessionLastWatch
    $script:SessionWatch = $null; $script:SessionLast = $null; $script:SessionLastWatch = $null
    Update-SessionCard
    '{0}; very hot: {1}; held back: {2}; gap owned up to: {3}; busiest: {4}; stops: {5}; alerts: {6}; said once: {7}; report: {8}; timeline: {9}' -f
        $button, [bool]($head -match 'It ran very hot for'), [bool]($lines -match 'Held back to cool off for \d+ seconds, once'),
        [bool]($lines -match 'One stretch went unwatched'), [bool]($lines -match 'Busiest: A game'),
        [bool]($after -eq 'Watch this session'),
        (@($raised | ForEach-Object { $_.Id }) -join ','), ($again.Count -eq 0),
        ('{0} offered, {1} characters, {2} scripts' -f $canSave, $html.Length, [regex]::Matches($html, '<script').Count),
        $drawn
}
function Test-SteadyCard {
    <#
        Windows' own steadiness record, drawn into the real card: a scored PC, then one where Windows has
        kept nothing, which must say so rather than show a zero.
    #>
    Update-SteadyCard ([pscustomobject]@{
        Score = 8.5; ScoreWhen = (Get-Date).AddHours(-1); Word = 'mostly steady'; Days = 30
        Crashes = 7; Hangs = 1; BlueScreens = 0; SuddenStops = 2; Available = $true
        Programs = @([pscustomobject]@{ Name = 'DCv2'; Count = 3 }); Uptime = [timespan]::FromHours(3)
    })
    $scored = '{0} | {1} | {2}' -f $script:SteadyCard.Value.Text, $script:SteadyCard.Caption.Text,
        ((@(foreach ($c in $script:SteadyLines.Children) { $c.Text }) -join ' / '))
    Update-SteadyCard ([pscustomobject]@{ Score = $null; Word = 'not scored'; Days = 30; Crashes = 0; Hangs = 0
        BlueScreens = 0; SuddenStops = 0; Available = $false; Programs = @(); Uptime = $null })
    $blank = '{0} | {1}' -f $script:SteadyCard.Value.Text, $script:SteadyCard.Caption.Text
    'score: {0}; crashes named: {1}; sudden stops: {2}; awake: {3}; unscored says so: {4}' -f
        [bool]($scored -match '8\.5 / 10'), [bool]($scored -match '8 programs stopped working in 30 days, most often DCv2'),
        [bool]($scored -match 'stopped without warning 2 times'), [bool]($scored -match 'Awake for 3 hours'),
        [bool]($blank -match "Not scored .* hasn't kept a record")
}
function Test-LiveTiles {
    <#
        The live panel, drawn twice into the real window.

        First a PC in trouble - hot, held back, nearly out of memory, with a game on top - which has to
        reach the one verdict that matters most rather than the biggest number. Then a PC that shares
        almost nothing, which has to say "not shared" in every empty place instead of drawing a zero,
        because a zero looks like an answer.
    #>
    $busy = [pscustomobject]@{
        CpuName = 'Test processor'; CpuUsage = 96; CpuTempC = 97; CpuTempStuck = $false; CpuTempSource = 'TZ'
        CpuThrottled = $true; CpuLimitPct = 61; SpeedPct = 61; SpeedMhz = 1400
        CpuTop = @([pscustomobject]@{ Name = 'A game'; Pct = 74 }, [pscustomobject]@{ Name = 'Windows Explorer'; Pct = 6 })
        MemUsed = [double]14GB; MemTotal = [double]16GB; CommitPct = 93; CommitUsed = [double]25GB; CommitLimit = [double]27GB
        DiskBusyPct = 44; DiskQueue = 1.2; Battery = $null
        Gpus = @([pscustomobject]@{ Name = 'Test card'; Usage = 88; TempC = 71; TempMaxC = 95; Discrete = $true
                DedicatedUsed = [double]6GB; DedicatedTotal = [double]8GB; SharedUsed = 0; SharedTotal = 0
                Top = @([pscustomobject]@{ Name = 'A game'; Pct = 88 }) })
    }
    Update-DriveCard ([pscustomobject]@{ Name = 'Test SSD'; Media = 'SSD'; Health = 'Healthy'; WearPct = 4
            TempC = 47; WarnAtC = 87; PowerOnHours = 861; BytesWritten = [int64]9TB; FromDrive = $true })
    Update-LiveTiles $busy
    $hot = '{0} | {1} | {2} | {3} | {4} | {5}' -f $script:VerdictText.Text, $script:TileCpu.Value.Text, $script:TileCpu.Extra.Text,
        $script:TileMemory.Heat.Text, $script:TileDisk.Heat.Text, $script:TileGpu.Extra.Text
    # The card below the tiles: the slow story, which is where the drive's hours and writing live.
    $card = '{0} | {1} | {2}' -f $script:DriveCard.Value.Text, $script:DriveCard.Caption.Text, $script:DriveHeatText.Text
    # The busiest row: one line per program, and a game busy on both chips counted once, at its loudest.
    $rows = @(foreach ($row in $script:BusyRows.Children) { (@(foreach ($c in $row.Children) { if ($c -is [System.Windows.Controls.TextBlock]) { $c.Text } }) -join ' ') })
    $merged = '{0} rows: {1}' -f $rows.Count, ($rows -join ' / ')

    $bare = [pscustomobject]@{
        CpuName = 'Test processor'; CpuUsage = 4; CpuTempC = $null; CpuTempStuck = $false; CpuThrottled = $false
        CpuTop = @(); MemUsed = [double]4GB; MemTotal = [double]16GB; CommitPct = $null
        DiskBusyPct = $null; Gpus = @(); Battery = $null
    }
    Update-DriveCard $null
    Update-LiveTiles $bare
    $quiet = '{0} | {1} | {2} | {3}' -f $script:VerdictText.Text, $script:TileGpu.Value.Text, $script:TileDisk.Value.Text, $script:TileMemory.Heat.Text
    'verdict worst first: {0}; held back named: {1}; memory word: {2}; drive heat: {3}; video memory folded in: {4}; {5}; drive life: {6}; calm: {7}; nothing invented: {8}' -f
        [bool]($hot -match 'held back to cool off'), [bool]($hot -match 'running at 61%'),
        [bool]($hot -match 'nearly full'), [bool]($hot -match '47.C'), [bool]($hot -match 'Video memory 75%'),
        $merged,
        [bool](($card -match '4% of its rated life used') -and ($card -match '861 hours') -and ($card -match 'written to it')),
        [bool]($quiet -match 'calm'),
        [bool](($quiet -match 'not shared') -and ($quiet -notmatch '\| 0%'))
}

function Test-Badge {
    # The taskbar badge draws and clears again.
    Update-TaskbarBadge ([pscustomobject]@{ Count = 3 })
    $drawn = $null -ne $window.TaskbarItemInfo.Overlay -and $window.Title -like '*3 things*'
    Update-TaskbarBadge $null
    return ($drawn -and $null -eq $window.TaskbarItemInfo.Overlay -and $window.Title -eq 'Quietpane - by KomodoWorks')
}

if ($SelfTest) {
    # A PC with nothing on it at all: every part of the window has to cope with empty lists and with
    # a part that could not be read, rather than leaving a blank tab behind.
    if ($env:QP_EMPTYSTATE) {
        Update-FromState @{
            Privacy = @{}; Vendors = @(); Apps = @(); Startup = @(); Devices = @(); Addons = @(); Cleanup = @(); Restore = @()
            Problems = @('the brand extras')
        }
        Update-NetList $null
        Update-NetList ([pscustomobject]@{ Programs = @(); LocalOnly = @(); Internet = 0; At = (Get-Date) })
        Show-Findings
        Update-TickCount
        $unnamed = @(Get-UnnamedControls)
        '{0} tabs, empty state drawn OK, unnamed controls: {1} {2}, status: {3}' -f $ui.Tabs.Items.Count, $unnamed.Count, ($unnamed -join ','), $ui.Status.Text
        return
    }
    if ($env:QP_WORDS) {
        # Words per tab, with this PC's real state drawn in (read-only, as the snapshot does).
        Update-FromState (& $script:ReadState)
        'words: ' + ((Get-TabWords) -join ', ')
        return
    }
    if ($Snapshot) {
        Update-FromState (& $script:ReadState)
        $ui.LogBox.Text = "[12:00:00] STEP    Quietpane $($info.Version) - Developed by KomodoWorks.com`r`n[12:00:01] OK      Ready."
        $ui.Status.Text = 'Ready when you are.'
        $ui.Tabs.SelectedIndex = $SnapshotTab
        if ($SnapshotTab -eq ($ui.Tabs.Items.Count - 1)) { $script:PrivacyExpander.IsExpanded = $true }
        if ([string]$ui.Tabs.SelectedItem.Tag -eq 'health') {
            # Real readings for the picture. The slow ones are read first, so the tiles have the drive's
            # temperature to show, and then several live ones a second apart, so the trends have a shape
            # rather than being a single dot.
            $monitor = New-QpLiveMonitor
            $script:BatteryHealth = Get-QpBatteryHealth
            Update-DriveCard (Get-QpDriveHealth)
            Update-SteadyCard (Get-QpReliability)
            foreach ($i in 1..8) {
                Start-Sleep -Milliseconds 1000
                Update-LiveTiles (Get-QpLiveReading -Monitor $monitor)
            }
        }
        Update-Buttons
        $root = $window.Content
        $size = [System.Windows.Size]::new([double]$window.Width, [double]$window.Height - 40)
        $root.Measure($size)
        $root.Arrange([System.Windows.Rect]::new($size))
        $root.UpdateLayout()
        $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap([int]$size.Width, [int]$size.Height, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
        $bg = New-Object System.Windows.Media.DrawingVisual
        $dc = $bg.RenderOpen(); $dc.DrawRectangle((Get-Brush '#FAF6EC'), $null, [System.Windows.Rect]::new($size)); $dc.Close()
        $rtb.Render($bg)
        $rtb.Render($root)
        $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
        $fs = [IO.File]::Create($Snapshot); $enc.Save($fs); $fs.Close()
    }
    $iconSizes = if ($window.Icon.Decoder) { @($window.Icon.Decoder.Frames).Count } else { 0 }
    $unnamed = @(Get-UnnamedControls)
    $cards = Test-FindingCards
    '{0} tabs, {1} privacy items, logo loaded: {2}, icon sizes: {3}, unnamed controls: {4} {5}, badge: {6}, finding quarantine buttons: {7} (unnamed {8}), window built OK' -f $ui.Tabs.Items.Count, $script:Options['privacy'].Count, [bool]$logo, $iconSizes, $unnamed.Count, ($unnamed -join ','), $(if (Test-Badge) { 'OK' } else { 'failed' }), $cards.Quarantine, $cards.Unnamed
    'sign-in costs: ' + (Test-SignInCosts)
    'add-ons: ' + (Test-AddonList)
    'easy wins: ' + (Test-SpaceWins)
    'live tiles: ' + (Test-LiveTiles)
    'session: ' + (Test-SessionCard)
    'holding up: ' + (Test-SteadyCard)
    return
}

# ------------------------------------------------------------------ first run notice
$acceptFile = Join-Path $info.DataRoot 'welcome-accepted.txt'
function Show-Welcome {
    if (Test-Path $acceptFile) { return $true }
    $msg = "Hello, and welcome to Quietpane $($info.Version).`n`n" +
           "Nothing leaves this PC, and nothing changes until you press a button.`n" +
           "Settings you change can be undone, and cleaned-up files go to the Recycle Bin.`n" +
           "Anything that can't be undone tells you so before you confirm it.`n" +
           "It is free, open source, and comes with no warranty - use it on PCs that are yours to look after.`n`n" +
           "The full privacy policy and terms are in the About tab. Sound good?"
    if ([System.Windows.MessageBox]::Show($window, $msg, 'Quietpane', 'YesNo', 'Information') -ne 'Yes') { return $false }
    try {
        New-Item -ItemType Directory -Path $info.DataRoot -Force | Out-Null
        Set-Content -Path $acceptFile -Value ("Welcome notice acknowledged {0} (version {1})" -f (Get-Date).ToString('s'), $info.Version)
    } catch { }
    return $true
}

$script:FirstShown = $false
$script:LastReadAt = $null
function Start-FirstRead {
    # In the background, the first read of the PC. Before it: shortcuts and the sign-in start always open
    # Quietpane's own copy, so keep that copy current and point back any shortcut that still opens a
    # folder that may have moved (it does nothing if you have neither). After it, the About tab's button
    # and tick boxes are filled in, once that is settled.
    Start-Work -StatusText 'Reading the current state of this PC...' -Work {
        try { [void](Sync-QpInstall) } catch { Write-QpLog "Could not check the shortcuts: $($_.Exception.Message)" 'WARN' }
        Get-QpState
    } -OnDone {
        param($s)
        Update-FromState $s; Update-PlaceControls; $script:LastReadAt = Get-Date
        # The sign-in check is done and nobody has opened the window: back to doing nothing at all.
        if (-not $script:FirstShown) { $timer.Stop() }
    }
}
function Start-FirstShow {
    if ($script:FirstShown) { return }
    $script:FirstShown = $true
    if (-not (Show-Welcome)) { $window.Close(); return }
    $ui.LogBox.AppendText(('Quietpane {0} - Developed by KomodoWorks.com. Started {1}. Administrator: {2}. This app makes no network connections.' -f $info.Version, (Get-QpStamp 'yyyy-MM-dd HH:mm'), (Test-IsAdmin)) + [Environment]::NewLine)
    if (-not $timer.IsEnabled) { $timer.Start() }
    # A check made at sign-in a few minutes ago is still fresh, and one may still be under way;
    # otherwise read the PC now.
    $fresh = $script:LastReadAt -and ((Get-Date) - $script:LastReadAt).TotalMinutes -lt 10
    if (-not $script:Job -and -not $fresh) { Start-FirstRead }
    Start-LiveSampler
}
function Start-SignInCheck {
    <#
        Started at sign-in with "tell me if Windows switches things back on": read the PC once, quietly,
        exactly as opening Quietpane would. If anything came back, Update-CameBack puts the badge on the
        taskbar icon; if nothing did, nothing shows at all. Never before the welcome has been accepted.
    #>
    if (-not (Test-Path $acceptFile)) { return }
    if (-not $timer.IsEnabled) { $timer.Start() }
    Start-FirstRead
}
$window.Add_ContentRendered({ Start-FirstShow })
if ($Minimized -and $Watch) { $window.Add_Loaded({ Start-SignInCheck }) }
# Opened minimised at sign-in, Windows never sends ContentRendered - so start the first time it is opened.
$window.Add_StateChanged({ if ($window.WindowState -ne 'Minimized') { Start-FirstShow }; Set-TimerQuick })
# Opened minimised at sign-in, even the clock waits until Quietpane is first opened.
if (-not $Minimized) { $timer.Start() }
[void]$window.ShowDialog()
Stop-LiveSampler   # in case the window went away without Closing firing
if ($script:RemoveCopyOnClose) { try { [void](Start-QpCopyRemoval) } catch { } }
