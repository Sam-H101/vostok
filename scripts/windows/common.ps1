# SPDX-License-Identifier: GPL-3.0-or-later
# Shared settings for the native Windows build scripts (dot-sourced, not run directly).
#
# The tree must be reachable as C:\survarium: the retail objects record c:\survarium\sources,
# and the ninja graph is rewritten to that root. setup.ps1 makes it a junction to this checkout.

$BuildRoot  = 'C:\survarium'
$RepoRoot   = (Resolve-Path "$PSScriptRoot\..\..").Path
if ($RepoRoot.TrimEnd('\') -eq $BuildRoot) {
    # invoked through the junction: work with the real checkout path
    $RepoRoot = @((Get-Item $BuildRoot).Target)[0]
}
$NativeDir  = Join-Path $RepoRoot 'binaries\windows'
$Toolchain  = if ($env:VOSTOK_WIN_TOOLCHAIN) { $env:VOSTOK_WIN_TOOLCHAIN } else { Join-Path $NativeDir 'toolchain' }
$LogDir     = Join-Path $NativeDir 'logs'
$NinjaDir   = Join-Path $BuildRoot 'binaries\ninja'
$ExeTarget  = 'survarium_-_PC_-_DirectX_11'
$ExeDir     = Join-Path $BuildRoot 'binaries\Win32'

function Use-Toolchain {
    # the same PATH/INCLUDE/LIB that vostok.tool.toolchain writes into the Wine registry
    foreach ($d in 'msvc\VC\bin\cl.exe', 'ninja\ninja.exe', 'winsdk\Include', 'dxsdk\Include') {
        if (-not (Test-Path (Join-Path $Toolchain $d))) { throw "toolchain incomplete: $Toolchain\$d missing - run setup.ps1" }
    }
    $env:PATH    = "$Toolchain\msvc\VC\bin;$env:SystemRoot\system32;$env:SystemRoot"
    $env:INCLUDE = "$Toolchain\msvc\VC\include;$Toolchain\dxsdk\Include;$Toolchain\winsdk\Include"
    $env:LIB     = "$Toolchain\msvc\VC\lib;$Toolchain\dxsdk\Lib\x86;$Toolchain\winsdk\Lib"
}

function Assert-BuildRoot {
    $item = Get-Item $BuildRoot -ErrorAction SilentlyContinue
    if (-not $item) { throw "$BuildRoot does not exist - run setup.ps1" }
    $target = if ($item.LinkType) { @($item.Target)[0] } else { $item.FullName }
    if ((Resolve-Path $target).Path.TrimEnd('\') -ne $RepoRoot.TrimEnd('\')) {
        throw "$BuildRoot points at $target, not this checkout ($RepoRoot) - rerun setup.ps1 -Force"
    }
    if (-not (Test-Path (Join-Path $NinjaDir 'build.ninja'))) { throw "no ninja graph in $NinjaDir - run sync.ps1" }
}

function Get-WslPath([string]$Distro, [string]$Path) {
    # absolute Linux path of a WSL directory (expands ~)
    $p = (& wsl.exe -d $Distro -- bash -c "cd $Path && pwd -P" | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $p) { throw "cannot resolve $Path in WSL distro $Distro" }
    $p
}
