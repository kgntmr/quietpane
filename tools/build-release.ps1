#Requires -Version 5.1
<#
    Builds the user-friendly download: dist\Quietpane.zip

    Layout inside the zip (only four things at the top, so nobody gets lost):
        Quietpane\
            Start Quietpane.cmd
            Safety scan only.cmd
            HOW TO USE.txt
            App files - no need to open\    (the app, its policies and license - plain text, readable;
                                             it has its own working start files in case someone opens it)

    The zip contains exactly the files in this repository - nothing is compiled or added.
    Prints the SHA256 checksum to publish with the release.
#>
param([string]$OutDir = (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist'))

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$work = Join-Path $env:TEMP ('Qp-build-' + (Get-Date -Format 'yyyyMMddHHmmss'))
$stage = Join-Path $work 'Quietpane'
$app = Join-Path $stage 'App files - no need to open'
New-Item -ItemType Directory -Force -Path $app | Out-Null

# Top level: only what a person needs to see
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'release\Start Quietpane.cmd') -Destination $stage
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'release\Safety scan only.cmd') -Destination $stage
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'release\HOW TO USE.txt') -Destination $stage

# App files folder: the program, its own start files and its documents
foreach ($f in 'Start Quietpane.cmd', 'Safety scan only.cmd', 'Quietpane.ps1', 'README.md', 'TRUST.md', 'PRIVACY.md', 'TERMS.md', 'SECURITY.md', 'LICENSE') {
    Copy-Item -LiteralPath (Join-Path $repo $f) -Destination $app
}
foreach ($d in 'src', 'assets', 'docs') {
    Copy-Item -LiteralPath (Join-Path $repo $d) -Destination $app -Recurse
}
Get-ChildItem -Path $app -Recurse -Filter '*.png' | Where-Object { $_.Name -like 'screenshot*' } | ForEach-Object { Remove-Item -LiteralPath $_.FullName }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$zip = Join-Path $OutDir 'Quietpane.zip'
if (Test-Path $zip) { Remove-Item -LiteralPath $zip }
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
# Write entries by hand so paths use forward slashes, as the ZIP standard requires
# (works in Windows Explorer and every other unzip tool).
$stream = [System.IO.File]::Open($zip, [System.IO.FileMode]::CreateNew)
$archive = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    Get-ChildItem -Path $stage -Recurse -File | Sort-Object FullName | ForEach-Object {
        $entry = 'Quietpane/' + $_.FullName.Substring($stage.Length + 1).Replace('\', '/')
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $_.FullName, $entry, [System.IO.Compression.CompressionLevel]::Optimal)
    }
} finally {
    $archive.Dispose()
    $stream.Dispose()
}

$hash = (Get-FileHash -Path $zip -Algorithm SHA256).Hash
$size = (Get-Item $zip).Length
Write-Host ("Built {0}  ({1:N0} KB)" -f $zip, ($size / 1KB))
Write-Host "SHA256: $hash"
[pscustomobject]@{ Zip = $zip; SizeBytes = $size; Sha256 = $hash; Staging = $stage }
