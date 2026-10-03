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

    The ZIP contains the release-selected repository files unchanged - nothing is compiled or added.
    Its entry order and metadata are fixed so the same source produces the same bytes.
    The build verifies that source-file timestamps cannot change the ZIP hash.
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
$checksum = Join-Path $OutDir 'Quietpane.zip.sha256'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

# ZIP metadata must not depend on checkout time, locale or source-file timestamps.
# Stored (uncompressed) entries avoid compressor-version differences between Windows machines.
$zipTime = [DateTimeOffset]'2000-01-01T00:00:00Z'

function New-QpDeterministicZip([string]$SourceRoot, [string]$Destination) {
    if (Test-Path $Destination) { Remove-Item -LiteralPath $Destination }

    [string[]]$entries = @(Get-ChildItem -Path $SourceRoot -Recurse -File | ForEach-Object {
        'Quietpane/' + $_.FullName.Substring($SourceRoot.Length + 1).Replace('\', '/')
    })
    [Array]::Sort($entries, [StringComparer]::Ordinal)

    $stream = [System.IO.File]::Open($Destination, [System.IO.FileMode]::CreateNew)
    $archive = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($entryName in $entries) {
            $relative = $entryName.Substring('Quietpane/'.Length).Replace('/', '\')
            $source = Join-Path $SourceRoot $relative
            $entry = $archive.CreateEntry($entryName, [System.IO.Compression.CompressionLevel]::NoCompression)
            $entry.LastWriteTime = $zipTime
            $entry.ExternalAttributes = 0

            $input = [System.IO.File]::OpenRead($source)
            $output = $entry.Open()
            try {
                $input.CopyTo($output)
            } finally {
                $output.Dispose()
                $input.Dispose()
            }
        }
    } finally {
        $archive.Dispose()
        $stream.Dispose()
    }
}

New-QpDeterministicZip -SourceRoot $stage -Destination $zip
$hash = (Get-FileHash -Path $zip -Algorithm SHA256).Hash

# Prove that source timestamps cannot leak into the archive. The second build uses the
# same bytes after deliberately changing every staged file's timestamp.
$probeTime = [DateTime]'2031-01-01T00:00:00Z'
$i = 0
Get-ChildItem -Path $stage -Recurse -File | ForEach-Object {
    $_.LastWriteTimeUtc = $probeTime.AddMinutes($i)
    $i++
}
$verifyZip = Join-Path $work 'Quietpane.verify.zip'
New-QpDeterministicZip -SourceRoot $stage -Destination $verifyZip
$verifyHash = (Get-FileHash -Path $verifyZip -Algorithm SHA256).Hash
if ($verifyHash -ne $hash) {
    throw "Release build is not reproducible: first SHA256 $hash, verification SHA256 $verifyHash"
}
Remove-Item -LiteralPath $verifyZip -Force

[System.IO.File]::WriteAllText($checksum, "$hash  Quietpane.zip`r`n", [System.Text.Encoding]::ASCII)
$size = (Get-Item $zip).Length
Write-Host ("Built {0}  ({1:N0} KB)" -f $zip, ($size / 1KB))
Write-Host "SHA256: $hash"
Write-Host "Reproducibility check: passed"
[pscustomobject]@{ Zip = $zip; Checksum = $checksum; SizeBytes = $size; Sha256 = $hash; Staging = $stage }
