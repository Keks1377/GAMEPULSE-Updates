#requires -Version 5.1
<#
GAMEPULSE updater prototype: GitHub Releases, integrity check, protected data folders,
transactional file-copy with rollback. This does NOT add an auto-update button to existing EXE.
Release must contain GAMEPULSE_Studio_Windows_x64.zip and SHA256SUMS.txt.
#>
[CmdletBinding()]
param(
    [ValidateSet('Check','Install')][string]$Mode = 'Check',
    [string]$InstallDir = (Split-Path -Parent $PSScriptRoot)
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$repo = 'Keks1377/GAMEPULSE-Updates'
$zipAssetName = 'GAMEPULSE_Studio_Windows_x64.zip'
$hashAssetName = 'SHA256SUMS.txt'
$versionFileName = 'GAMEPULSE_VERSION.txt'
$protectedDirs = @('data','model','runtime','logs','backup_updates','WebView2UserData','UserData','EBWebView')
$work = $null

function Die([string]$why) { throw $why }
function Find-Asset($release, [string]$assetName) {
    $found = @($release.assets | Where-Object { $_.name -ceq $assetName })
    if ($found.Count -ne 1) { Die "Expected exactly one release asset: $assetName" }
    $url = [string]$found[0].browser_download_url
    $prefix = "https://github.com/$repo/releases/download/"
    if (-not $url.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)) {
        Die "Untrusted release asset URL: $url"
    }
    return $url
}
function Is-Protected([string]$relative) {
    $normalized = $relative.Replace('/','\')
    $first = @($normalized.Split('\'))[0]
    if ($first -in $protectedDirs) { return $true }
    if ($normalized -match '(^|\\)(\.env|.*\.user|.*\.key|.*\.pem)$') { return $true }
    return $false
}
try {
    $InstallDir = [IO.Path]::GetFullPath($InstallDir)
    if (-not (Test-Path -LiteralPath $InstallDir -PathType Container)) {
        Die "Installation folder not found: $InstallDir"
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $headers = @{
        'User-Agent' = 'GAMEPULSE-Updater/1.0'
        'Accept' = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
    }
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers $headers -TimeoutSec 25
    if ($release.draft -or $release.prerelease -or $release.tag_name -notmatch '^v([0-9]+\.[0-9]+\.[0-9]+)$') {
        Die 'Latest release is draft, prerelease, or has an unsupported version tag.'
    }
    $latest = [version]$Matches[1]
    $installedVersionFile = Join-Path $InstallDir $versionFileName
    $installed = [version]'0.0.0'
    if (Test-Path -LiteralPath $installedVersionFile) {
        $v = (Get-Content -LiteralPath $installedVersionFile -Raw -Encoding UTF8).Trim() -replace '^[vV]', ''
        if ($v -notmatch '^[0-9]+\.[0-9]+\.[0-9]+$') { Die "Invalid installed version: $v" }
        $installed = [version]$v
    }
    Write-Host "Installed: $installed | Latest stable: $latest"
    if ($latest -le $installed) { Write-Host 'No update available.'; exit 0 }
    $zipUrl = Find-Asset $release $zipAssetName
    $sumUrl = Find-Asset $release $hashAssetName
    if ($Mode -eq 'Check') {
        Write-Host "Update available: v$latest"
        Write-Host "Release page: $($release.html_url)"
        exit 0
    }
    $running = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -like 'GAMEPULSE_Studio*' -or $_.ProcessName -like 'GAMEPULSE_Engine*'
    })
    if ($running.Count -gt 0) { Die 'Close GAMEPULSE and stop autopilot before installing the update.' }
    $work = Join-Path ([IO.Path]::GetTempPath()) ('GAMEPULSE_update_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null
    $zipFile = Join-Path $work $zipAssetName
    $sumFile = Join-Path $work $hashAssetName
    Invoke-WebRequest -Uri $zipUrl -Headers $headers -OutFile $zipFile -UseBasicParsing -TimeoutSec 240
    Invoke-WebRequest -Uri $sumUrl -Headers $headers -OutFile $sumFile -UseBasicParsing -TimeoutSec 45
    $sumLines = @(Get-Content -LiteralPath $sumFile -Encoding UTF8)
    $quoted = [regex]::Escape($zipAssetName)
    $matching = @($sumLines | Where-Object { $_ -match ("(?i)^([a-f0-9]{64})\s+\*?" + $quoted + "$") })
    if ($matching.Count -ne 1) { Die 'Release checksum missing or ambiguous.' }
    $expected = [regex]::Match($matching[0],'^[a-fA-F0-9]{64}').Value.ToUpperInvariant()
    $actual = (Get-FileHash -LiteralPath $zipFile -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($actual -cne $expected) { Die 'SHA256 checksum mismatch. Installation cancelled.' }
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($zipFile)
    try {
        foreach ($entry in $archive.Entries) {
            $p = $entry.FullName.Replace('\','/')
            if ($p.StartsWith('/') -or $p -match '^[a-zA-Z]:' -or $p -match '(^|/)\.\.(/|$)' -or $p.Contains(':')) {
                Die "Unsafe ZIP entry: $p"
            }
        }
    } finally { $archive.Dispose() }
    $unpacked = Join-Path $work 'unpacked'
    Expand-Archive -LiteralPath $zipFile -DestinationPath $unpacked
    if (-not (Test-Path -LiteralPath (Join-Path $unpacked 'GAMEPULSE_Studio.exe') -PathType Leaf)) {
        Die 'Archive must contain GAMEPULSE_Studio.exe at its root.'
    }
    $backup = Join-Path $InstallDir ('backup_updates\v' + $installed.ToString() + '_before_v' + $latest.ToString())
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    $written = New-Object System.Collections.ArrayList
    try {
        $sources = @(Get-ChildItem -LiteralPath $unpacked -Recurse -File)
        foreach ($file in $sources) {
            $relative = $file.FullName.Substring($unpacked.Length).TrimStart('\','/')
            if (Is-Protected $relative) { continue }
            $dest = Join-Path $InstallDir $relative
            $old = Join-Path $backup $relative
            $existed = Test-Path -LiteralPath $dest -PathType Leaf
            if ($existed) {
                New-Item -ItemType Directory -Path (Split-Path -Parent $old) -Force | Out-Null
                Copy-Item -LiteralPath $dest -Destination $old -Force
            }
            [void]$written.Add(@{ Target=$dest; Old=$old; Existed=$existed })
            New-Item -ItemType Directory -Path (Split-Path -Parent $dest) -Force | Out-Null
            Copy-Item -LiteralPath $file.FullName -Destination $dest -Force
        }
        $versionOld = Join-Path $backup $versionFileName
        $hadVersion = Test-Path -LiteralPath $installedVersionFile -PathType Leaf
        if ($hadVersion) { Copy-Item -LiteralPath $installedVersionFile -Destination $versionOld -Force }
        [void]$written.Add(@{Target=$installedVersionFile;Old=$versionOld;Existed=$hadVersion})
        [IO.File]::WriteAllText($installedVersionFile, $latest.ToString(), [Text.UTF8Encoding]::new($false))
        Write-Host "Installed v$latest. Backups are in: $backup"
    } catch {
        $reason = $_
        for ($i = $written.Count-1; $i -ge 0; $i--) {
            $item = $written[$i]
            try {
                if ($item.Existed) { Copy-Item -LiteralPath $item.Old -Destination $item.Target -Force }
                elseif (Test-Path -LiteralPath $item.Target) { Remove-Item -LiteralPath $item.Target -Force }
            } catch { Write-Warning "Rollback failed for $($item.Target): $_" }
        }
        throw $reason
    }
} catch {
    Write-Error "GAMEPULSE updater: $_"
    exit 1
} finally {
    if ($work -and (Test-Path -LiteralPath $work)) {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}
