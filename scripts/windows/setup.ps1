# SPDX-License-Identifier: GPL-3.0-or-later
# One-time setup of a native Windows build tree. Two sources for the toolchain and libraries:
#
#   -Native  no WSL: download the release archives flake.nix pins (hash-checked), stage the libs
#            with vostok.tool.libs, and build vcproj2ninja at the flake.lock rev with a private
#            nightly Rust under binaries\windows\rust (or pass -Vcproj2Ninja <exe>). The ninja
#            graph is then regenerated natively by build.ps1. Needs Python 3.11+ and Git.
#   default  from a WSL checkout that already builds (`nix develop` + one `vostok build`): copy
#            its toolchain and binaries.prebuilt, and add it as the `wsl` remote sync.ps1 mirrors.
#
# Both then install the toolchain's VC90 CRT as a private assembly beside cl.exe (machines
# without the VC++ 2008 runtime cannot start it otherwise) and junction C:\survarium -> this
# checkout (the retail source root the objects record). Each step is skipped when its output
# already exists; -Force redoes the downloads/builds and repoints the junction.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\setup.ps1 -Native
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\setup.ps1 [-Distro vostok] [-WslRepo ~/vostok]
param([switch]$Native, [string]$Vcproj2NinjaExe = '', [string]$RustToolchain = 'nightly',
      [string]$Distro = 'vostok', [string]$WslRepo = '~/vostok', [switch]$Force)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
. "$PSScriptRoot\common.ps1"
$downloads = Join-Path $NativeDir 'downloads'
$prebuilt = Join-Path $RepoRoot 'binaries.prebuilt'

function Invoke-Exe([string]$Exe, [string[]]$Arguments) {
    # native tools report progress on stderr, which Windows PowerShell turns into error records
    $ErrorActionPreference = 'Continue'
    & $Exe @Arguments 2>&1 | ForEach-Object { Write-Host "    $_" }
    if ($LASTEXITCODE -ne 0) { throw "$Exe failed ($LASTEXITCODE)" }
}

function Get-Pinned([string]$Name) {
    # download a flake.nix release pin into binaries\windows\downloads and check its sha256
    $pin = Get-FlakePin $Name
    $file = Join-Path $downloads ($pin.Url -split '/')[-1]
    New-Item -ItemType Directory -Force $downloads | Out-Null
    if (-not (Test-Path $file) -or (Get-FileHash $file -Algorithm SHA256).Hash -ne $pin.Sha256) {
        Write-Host "  downloading $($pin.Url)"
        Invoke-Exe curl.exe @('-fsSL', '--retry', '3', '-o', $file, $pin.Url)
    }
    $hash = (Get-FileHash $file -Algorithm SHA256).Hash
    if ($hash -ne $pin.Sha256) { throw "$file sha256 $hash does not match flake.nix ($($pin.Sha256))" }
    $file
}

function Expand-Pinned([string]$Archive, [string]$Dest, [int]$Strip) {
    Invoke-Exe (Get-Python) @("$PSScriptRoot\unpack.py", $Archive, $Dest, $Strip)
}

function Build-Vcproj2Ninja {
    $pin = Get-LockedRev 'vcproj2ninja-src'
    if ($Vcproj2NinjaExe) {
        New-Item -ItemType Directory -Force (Split-Path $Vcproj2Ninja) | Out-Null
        Copy-Item $Vcproj2NinjaExe $Vcproj2Ninja -Force
        Set-Content (Join-Path $Vcproj2NinjaDir 'rev') $pin.Rev
        return "vcproj2ninja: copied $Vcproj2NinjaExe (assumed built at $($pin.Rev))"
    }
    # a private rustup (the crate needs nightly features): nothing touches the user's PATH or profile
    $rust = Join-Path $NativeDir 'rust'
    $env:RUSTUP_HOME = Join-Path $rust 'rustup'
    $env:CARGO_HOME  = Join-Path $rust 'cargo'
    $env:CARGO_TARGET_DIR = Join-Path $rust 'target'
    $cargo = Join-Path $env:CARGO_HOME 'bin\cargo.exe'
    if (-not (Test-Path $cargo)) {
        Write-Host "  installing a private nightly Rust into $rust"
        New-Item -ItemType Directory -Force $rust | Out-Null
        $init = Join-Path $rust 'rustup-init.exe'
        # the GNU host links with its bundled MinGW, so no Visual Studio install is needed
        Invoke-Exe curl.exe @('-fsSL', '--retry', '3', '-o', $init, 'https://static.rust-lang.org/rustup/dist/x86_64-pc-windows-gnu/rustup-init.exe')
        Invoke-Exe $init @('-y', '--no-modify-path', '--profile', 'minimal', '--default-host', 'x86_64-pc-windows-gnu', '--default-toolchain', $RustToolchain)
    }
    # windows-sys/getrandom raw-dylib imports need dlltool; the GNU toolchain's own one needs a
    # GNU assembler it does not ship. llvm-ar (llvm-tools) is LLVM's multi-call archiver and acts
    # as a self-contained dlltool when its file name says so.
    Invoke-Exe (Join-Path $env:CARGO_HOME 'bin\rustup.exe') @('toolchain', 'install', $RustToolchain, '--profile', 'minimal', '--component', 'llvm-tools')
    $sysroot = (& (Join-Path $env:CARGO_HOME 'bin\rustc.exe') "+$RustToolchain" --print sysroot | Out-String).Trim()
    $dlltool = Join-Path $rust 'llvm-dlltool.exe'
    Copy-Item "$sysroot\lib\rustlib\x86_64-pc-windows-gnu\bin\llvm-ar.exe" $dlltool -Force
    $env:CARGO_ENCODED_RUSTFLAGS = "-Cdlltool=$dlltool"
    Write-Host "  building vcproj2ninja $($pin.Rev)"
    Invoke-Exe $cargo @("+$RustToolchain", 'install', '--git', $pin.Url, '--rev', $pin.Rev, '--locked', '--force', '--root', $Vcproj2NinjaDir, 'vcproj2ninja')
    Remove-Item -Recurse -Force $env:CARGO_TARGET_DIR -ErrorAction SilentlyContinue   # ~1 GiB of build cache
    Set-Content (Join-Path $Vcproj2NinjaDir 'rev') $pin.Rev
    "vcproj2ninja: built at $($pin.Rev)"
}

if ($Native) {
    # 1. toolchain
    if ((Test-Path "$Toolchain\msvc\VC\bin\cl.exe") -and -not $Force) { "toolchain: present at $Toolchain" } else {
        "toolchain: staging into $Toolchain"
        $archive = Get-Pinned 'vostok-toolchain'
        if (Test-Path $Toolchain) { Remove-Item -Recurse -Force $Toolchain }
        Expand-Pinned $archive $Toolchain 1
    }
    # 2. third-party libraries, staged exactly as `vostok tool libs` stages them from the nix package
    if ((Test-Path $prebuilt) -and -not $Force) { 'binaries.prebuilt: present' } else {
        'binaries.prebuilt: staging'
        $archive = Get-Pinned 'vostok-libs'
        $unpacked = Join-Path $NativeDir 'vostok-libs'
        if (Test-Path $unpacked) { Remove-Item -Recurse -Force $unpacked }
        Expand-Pinned $archive $unpacked 0
        Invoke-Vostok 'vostok.tool.libs' @((Join-Path $unpacked 'vostok-libs\sources'), $prebuilt)
        Remove-Item -Recurse -Force $unpacked
    }
    # 3. vcproj2ninja
    if ((Test-Path $Vcproj2Ninja) -and -not $Force -and -not $Vcproj2NinjaExe) { "vcproj2ninja: present" } else { Build-Vcproj2Ninja }
} else {
    $wslRepoAbs = Get-WslPath $Distro $WslRepo
    function ConvertTo-WslPath([string]$p) { (& wsl.exe -d $Distro -- wslpath -u ($p -replace '\\', '/') | Out-String).Trim() }
    function Invoke-Wsl([string]$cmd) {
        & wsl.exe -d $Distro -- bash -lc $cmd
        if ($LASTEXITCODE -ne 0) { throw "WSL command failed ($LASTEXITCODE): $cmd" }
    }
    # 1. toolchain: a dereferenced copy of the nix store path
    if (Test-Path "$Toolchain\msvc\VC\bin\cl.exe") { "toolchain: present at $Toolchain" } else {
        "toolchain: staging into $Toolchain (about 1 GiB)"
        $link = "$wslRepoAbs/binaries/nix-store/vostok-toolchain"
        Invoke-Wsl "cd '$wslRepoAbs' && { test -e '$link' || nix build .#vostok-toolchain --out-link '$link'; }"
        New-Item -ItemType Directory -Force $Toolchain | Out-Null
        Invoke-Wsl "cp -rL '$link/.' '$(ConvertTo-WslPath $Toolchain)/'"
    }
    # 2. prebuilt third-party libraries
    if (Test-Path $prebuilt) { 'binaries.prebuilt: present' } else {
        "binaries.prebuilt: copying from $wslRepoAbs"
        Invoke-Wsl "test -d '$wslRepoAbs/binaries.prebuilt' || { echo 'run python3 -m vostok tool libs in the WSL checkout first' >&2; exit 1; }"
        Invoke-Wsl "cp -r '$wslRepoAbs/binaries.prebuilt' '$(ConvertTo-WslPath $RepoRoot)/'"
    }
    # 3. the WSL checkout as a git remote (through the \\wsl.localhost share)
    $remote = "//wsl.localhost/$Distro$wslRepoAbs"
    $existing = & git -C $RepoRoot remote get-url wsl 2>$null
    if (-not $existing) { & git -C $RepoRoot remote add wsl $remote; "remote: added wsl -> $remote" }
    elseif ($existing -ne $remote) { "remote: wsl already points at $existing (expected $remote) - left unchanged" }
    else { "remote: wsl -> $remote" }
}

# private VC90 CRT: cl/c1xx/c2/link request Microsoft.VC90.CRT 9.0.21022.8, the redist's version
$crt = "$Toolchain\msvc\VC\bin\Microsoft.VC90.CRT"
if (-not (Test-Path $crt)) {
    Copy-Item -Recurse "$Toolchain\msvc\VC\redist\x86\Microsoft.VC90.CRT" $crt
    'crt: installed the VC90 CRT beside cl.exe'
}

# C:\survarium junction (a junction needs no admin rights; rmdir removes only the link)
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
& git -C $RepoRoot config core.autocrlf false

if ($Native) {
    Update-NinjaGraph | Out-Null
    "setup done. Next: scripts\windows\build.ps1"
} else {
    "setup done. Next: scripts\windows\sync.ps1, then scripts\windows\build.ps1"
}
