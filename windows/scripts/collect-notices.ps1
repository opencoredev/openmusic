# Runs in the Windows build machine after a Release publish (scripts/package-windows.sh calls it). Collects what
# THIRD-PARTY-NOTICES.txt is written from: for every package the app restored (obj\project.assets.json) and every
# runtime or targeting pack the publish drew on, its license and notice files, its .nuspec and the list of its files;
# and the list of files in the publish folder. Output goes to <checkout>\notices-src, replaced each run.
#   powershell -NoProfile -File C:\medley\<slot>\scripts\collect-notices.ps1 -Checkout C:\medley\<slot>
param([Parameter(Mandatory = $true)][string]$Checkout)
$ErrorActionPreference = 'Stop'
$assetsPath = Join-Path $Checkout 'src\OpenMusic.App\obj\project.assets.json'
$publish = Join-Path $Checkout 'publish'
$out = Join-Path $Checkout 'notices-src'
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
New-Item -ItemType Directory -Path $out | Out-Null

$assets = Get-Content $assetsPath -Raw | ConvertFrom-Json
$cache = @($assets.packageFolders.PSObject.Properties.Name)[0]
$packs = Join-Path $env:ProgramFiles 'dotnet\packs'

function Collect([string]$id, [string]$version, [string]$dir) {
    $dest = Join-Path $out "$id@$version"
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Get-ChildItem $dir -File | Where-Object { $_.Name -match '(?i)(licen[cs]e|notice)' -or $_.Extension -eq '.nuspec' } |
        Copy-Item -Destination $dest
    $root = (Resolve-Path $dir).Path.TrimEnd('\') + '\'
    $files = Get-ChildItem $dir -Recurse -File
    $names = @($files | ForEach-Object { $_.FullName.Substring($root.Length) })
    # A self-contained publish also unpacks files from the runtime MSIX packages a package carries.
    foreach ($msix in $files | Where-Object { $_.Extension -eq '.msix' }) {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($msix.FullName)
        try { $names += $zip.Entries | ForEach-Object { $msix.FullName.Substring($root.Length) + '!' + $_.FullName } }
        finally { $zip.Dispose() }
    }
    $names | Set-Content -Encoding UTF8 (Join-Path $dest 'files.txt')
}
Add-Type -AssemblyName System.IO.Compression.FileSystem

foreach ($lib in $assets.libraries.PSObject.Properties) {
    if ($lib.Value.type -ne 'package') { continue }
    $id, $version = $lib.Name -split '/', 2
    Collect $id $version (Join-Path $cache $lib.Value.path)
}
# Runtime, apphost and targeting packs: in the NuGet cache when downloaded for a self-contained publish, otherwise
# in the SDK's packs folder.
foreach ($framework in $assets.project.frameworks.PSObject.Properties) {
    foreach ($dep in $framework.Value.downloadDependencies) {
        $id = $dep.name
        $version = ($dep.version -replace '[\[\]\(\) ]', '' -split ',')[0]
        foreach ($dir in @((Join-Path $cache "$($id.ToLowerInvariant())\$version"), (Join-Path $packs "$id\$version"))) {
            if (Test-Path $dir) { Collect $id $version $dir; break }
        }
    }
}

$root = (Resolve-Path $publish).Path.TrimEnd('\') + '\'
Get-ChildItem $publish -Recurse -File | ForEach-Object { $_.FullName.Substring($root.Length) } |
    Set-Content -Encoding UTF8 (Join-Path $out 'publish-files.txt')
'collected ' + (Get-ChildItem $out -Directory).Count + ' packages'
