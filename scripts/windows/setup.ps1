# SPDX-License-Identifier: GPL-3.0-or-later
# One-time setup of a native Windows build tree, from a WSL checkout that already builds
# (`nix develop` + `python3 -m vostok build` have run there at least once):
#
#   1. stage the VS2008/SDK toolchain from the flake's vostok-toolchain into binaries\windows\toolchain
#   2. copy binaries.prebuilt (the third-party blobs `vostok tool libs` staged)
#   3. junction C:\survarium -> this checkout (the retail source root the objects record)
#   4. add the WSL checkout as the `wsl` remote that sync.ps1 fetches from
#
# Each step is skipped when its output already exists. Run from Windows PowerShell:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\setup.ps1 [-Distro vostok] [-WslRepo ~/vostok]
param([string]$Distro = 'vostok', [string]$WslRepo = '~/vostok', [switch]$Force)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\common.ps1"

$wslRepoAbs = Get-WslPath $Distro $WslRepo
function ConvertTo-WslPath([string]$p) { (& wsl.exe -d $Distro -- wslpath -u ($p -replace '\\', '/') | Out-String).Trim() }
function Invoke-Wsl([string]$cmd) {
    & wsl.exe -d $Distro -- bash -lc $cmd
    if ($LASTEXITCODE -ne 0) { throw "WSL command failed ($LASTEXITCODE): $cmd" }
}

# 1. toolchain: a dereferenced copy of the nix store path (cl.exe, link.exe, c2.dll, SDKs, ninja.exe)
if (Test-Path "$Toolchain\msvc\VC\bin\cl.exe") {
    "toolchain: present at $Toolchain"
} else {
    "toolchain: staging into $Toolchain (about 1 GiB)"
    $link = "$wslRepoAbs/binaries/nix-store/vostok-toolchain"
    Invoke-Wsl "cd '$wslRepoAbs' && { test -e '$link' || nix build .#vostok-toolchain --out-link '$link'; }"
    New-Item -ItemType Directory -Force $Toolchain | Out-Null
    Invoke-Wsl "cp -rL '$link/.' '$(ConvertTo-WslPath $Toolchain)/'"
}

# 2. prebuilt third-party libraries
$prebuilt = Join-Path $RepoRoot 'binaries.prebuilt'
if (Test-Path $prebuilt) {
    "binaries.prebuilt: present"
} else {
    "binaries.prebuilt: copying from $wslRepoAbs"
    Invoke-Wsl "test -d '$wslRepoAbs/binaries.prebuilt' || { echo 'run python3 -m vostok tool libs in the WSL checkout first' >&2; exit 1; }"
    Invoke-Wsl "cp -r '$wslRepoAbs/binaries.prebuilt' '$(ConvertTo-WslPath $RepoRoot)/'"
}

# 3. C:\survarium junction (a junction needs no admin rights; rmdir removes only the link)
$item = Get-Item $BuildRoot -ErrorAction SilentlyContinue
if ($item -and -not $item.LinkType) { throw "$BuildRoot is a real directory - move it away first" }
if ($item -and (@($item.Target)[0].TrimEnd('\') -ne $RepoRoot.TrimEnd('\'))) {
    if (-not $Force) { throw "$BuildRoot points at $(@($item.Target)[0]); rerun with -Force to repoint it here" }
    cmd /c rmdir $BuildRoot
    $item = $null
}
if ($item) { "junction: $BuildRoot -> $RepoRoot" } else {
    cmd /c mklink /J $BuildRoot $RepoRoot | Out-Null
    if (-not (Test-Path $BuildRoot)) { throw "mklink /J $BuildRoot failed" }
    "junction: created $BuildRoot -> $RepoRoot"
}

# 4. the WSL checkout as a git remote (the file:// path goes through the \\wsl.localhost share)
$remote = "//wsl.localhost/$Distro$wslRepoAbs"
$existing = & git -C $RepoRoot remote get-url wsl 2>$null
if (-not $existing) { & git -C $RepoRoot remote add wsl $remote; "remote: added wsl -> $remote" }
elseif ($existing -ne $remote) { "remote: wsl already points at $existing (expected $remote) - left unchanged" }
else { "remote: wsl -> $remote" }
& git -C $RepoRoot config core.autocrlf false

"setup done. Next: scripts\windows\sync.ps1, then scripts\windows\build.ps1"
