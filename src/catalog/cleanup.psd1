# Space clean-up targets for the "Clean up space" tab.
# Everything is moved to the Recycle Bin when it fits. An individually selected item that cannot fit
# is only deleted after Quietpane shows its exact path and size and the person confirms twice.
#
# Paths         environment variables and * wildcards allowed
# MinAgeHours   only items older than this are touched (protects files in use by running installers)
# RequiresClosed  process name that must not be running (for example a browser)

@{
    Items = @(
        @{
            Id = 'temp.user'; Title = 'Your temporary files'; Recommended = $true; MinAgeHours = 24
            Description = 'Leftovers from installers and apps. Only files older than 24 hours; anything in use is skipped.'
            Paths = @('%TEMP%')
        }
        @{
            Id = 'temp.windows'; Title = 'Windows temporary files'; Recommended = $true; MinAgeHours = 24
            Description = 'System temp folder. Only files older than 24 hours.'
            Paths = @('%WINDIR%\Temp')
        }
        @{
            Id = 'crashdumps'; Title = 'Crash dumps'; Recommended = $true
            Description = 'Memory dumps written when programs crash. Only useful to developers debugging a crash.'
            Paths = @('%LOCALAPPDATA%\CrashDumps')
        }
        @{
            Id = 'wer'; Title = 'Windows error report archive'; Recommended = $true
            Description = 'Old crash/problem reports queued or archived by Windows Error Reporting.'
            Paths = @('%ProgramData%\Microsoft\Windows\WER\ReportArchive', '%ProgramData%\Microsoft\Windows\WER\ReportQueue')
        }
        @{
            Id = 'nvidia.installer'; Title = 'NVIDIA App downloaded installers'; Recommended = $true
            Description = 'Update packages NVIDIA App already installed. Not needed afterwards.'
            Paths = @('%ProgramData%\NVIDIA Corporation\NVIDIA App\UpdateFramework\ota-artifacts')
        }
        @{
            Id = 'nvidia.shader'; Title = 'NVIDIA shader cache'; Recommended = $false
            Description = 'Pre-compiled graphics data for games. Safe to clear (no game files or saves), but each game stutters or loads slower the first time while it rebuilds.'
            Paths = @('%LOCALAPPDATA%\NVIDIA\DXCache', '%LOCALAPPDATA%\NVIDIA\GLCache')
        }
        @{
            Id = 'd3d.shader'; Title = 'DirectX shader cache'; Recommended = $false
            Description = 'Same idea as the NVIDIA shader cache, for DirectX. Rebuilds automatically.'
            Paths = @('%LOCALAPPDATA%\D3DSCache')
        }
        @{
            Id = 'browser.chrome'; Title = 'Chrome cache'; Recommended = $false; RequiresClosed = 'chrome'
            Description = 'Cached web files. Logins, history and bookmarks are NOT touched. Close Chrome first.'
            Paths = @('%LOCALAPPDATA%\Google\Chrome\User Data\*\Cache', '%LOCALAPPDATA%\Google\Chrome\User Data\*\Code Cache', '%LOCALAPPDATA%\Google\Chrome\User Data\*\GPUCache')
        }
        @{
            Id = 'browser.edge'; Title = 'Edge cache'; Recommended = $false; RequiresClosed = 'msedge'
            Description = 'Cached web files. Logins, history and favourites are NOT touched. Close Edge first.'
            Paths = @('%LOCALAPPDATA%\Microsoft\Edge\User Data\*\Cache', '%LOCALAPPDATA%\Microsoft\Edge\User Data\*\Code Cache', '%LOCALAPPDATA%\Microsoft\Edge\User Data\*\GPUCache')
        }
        @{
            Id = 'automation.cache'; Title = 'Automation and developer caches'; Recommended = $false; MinAgeHours = 24
            Description = 'Known cache folders are listed separately. Project folders and protected paths are never selected.'
            Paths = @('%USERPROFILE%\.cache', '%USERPROFILE%\.agent-browser')
        }
        @{
            Id = 'wu.download'; Title = 'Windows Update download cache'; Recommended = $false; MinAgeHours = 72
            Description = 'Already-installed update files. Windows downloads again anything it still needs.'
            Paths = @('%WINDIR%\SoftwareDistribution\Download')
        }
    )
}
