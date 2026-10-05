# Native Windows build

`scripts/windows/` builds the exe with the same VS2008 toolchain directly on Windows,
without Wine. It compiles much faster than under Wine, which makes it the quick route to a
runnable `survarium-dx11-win32-gold.exe`.

It builds only. Scores, the ledger and the README block come only from `python3 -m vostok build`
(Linux/WSL with Nix): objdiff, the delinker and the PDB evidence tools are not part of it, and
the native objects are not compared against the target. Every measured commit is built there.

There are two ways to set it up:

- **Native**: no WSL. Setup downloads the toolchain and third-party libraries from the release
  archives `flake.nix` pins, and builds vcproj2ninja from the rev `flake.lock` pins. The graph is
  regenerated on Windows before every build. You edit and commit in this checkout.
- **WSL mirror**: a WSL checkout stays where you edit, commit and run `vostok build`; this
  checkout mirrors it (`sync.ps1`) and only builds.

Either way the checkout is junctioned to `C:\survarium`. That path is required: retail objects
record `c:\survarium\sources`, and the graph is rooted there (`paths.NATIVE_BUILD_ROOT`). Only one
checkout can own the junction at a time.

Generated state stays under the gitignored `binaries/`:

| Path | Contents |
|---|---|
| `binaries\windows\toolchain` | The staged toolchain, about 1 GiB. Set `VOSTOK_WIN_TOOLCHAIN` to keep it elsewhere. |
| `binaries\windows\vcproj2ninja`, `binaries\windows\rust` | Native mode: the generator, and the private nightly Rust that built it. |
| `binaries\windows\downloads` | Native mode: the hash-checked release archives. |
| `binaries\windows\logs` | Build logs. |
| `binaries\ninja`, `binaries\Win32` | The graph and the build outputs. |

## Native setup (once)

You need Windows 10/11, Git for Windows, Python 3.11+ on `PATH`, and about 10 GB free.

```powershell
git clone -c core.autocrlf=false https://github.com/srp-survarium/vostok F:\vostok
cd F:\vostok
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\setup.ps1 -Native
```

`core.autocrlf=false` keeps the sources byte-identical to the Linux checkouts. `setup.ps1 -Native`:

1. **Toolchain.** Downloads `vostok-toolchain-v0.100b.tar.xz` and checks it against the sha256 in
   `flake.nix`, then extracts it into `binaries\windows\toolchain`.
2. **Third-party libraries.** Downloads `vostok-libs-v0.100b-pc-only.zip` (also hash-checked) and
   stages it into `binaries.prebuilt` with `vostok.tool.libs`, the same step `nix develop` runs.
3. **vcproj2ninja.** Builds it at the `flake.lock` rev with `cargo install`.
   - The crate needs nightly Rust. Setup installs a private rustup under `binaries\windows\rust`
     (GNU host, so no Visual Studio is needed) and leaves your `PATH` and profile alone.
   - The GNU toolchain's own `dlltool` needs an assembler that rustup does not ship. Setup
     passes `-Cdlltool=` pointing at a copy of `llvm-ar` from `llvm-tools`, which works as a
     self-contained `dlltool`.
   - If the latest nightly breaks the build, pass `-RustToolchain nightly-YYYY-MM-DD`.
   - `-Vcproj2NinjaExe <exe>` uses an existing build instead.
4. **CRT, junction, graph.** Installs the VC90 CRT beside `cl.exe`, creates the junction, and
   generates the graph.

Each step is skipped when its output exists. `-Force` redoes them and repoints a junction owned by
another checkout. After `flake.lock` moves vcproj2ninja, `build.ps1` warns until you rerun
`setup.ps1 -Native -Force`.

## WSL-mirror setup (once)

You need a WSL2 distro whose checkout has completed `nix develop` and one
`python3 -m vostok build`. That build gives it `binaries.prebuilt/`, the `vostok-toolchain`
out-link and `binaries/ninja/`.

```powershell
git clone -c core.autocrlf=false https://github.com/srp-survarium/vostok F:\vostok-win
cd F:\vostok-win
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\setup.ps1 -Distro <distro> -WslRepo ~/vostok
```

This copies the toolchain and `binaries.prebuilt` out of the WSL checkout, adds the WSL checkout as
the `wsl` remote, installs the CRT and creates the junction.

## The loop

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\sync.ps1     # WSL mirror only
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\build.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\deploy.ps1 -GameDir <game>\binaries\win32
```

- **`build.ps1`** builds the exe.
  - With vcproj2ninja installed, it first regenerates the graph (`vostok.build.ninja_regen`), as
    `vostok build` does. Only the graph files whose contents changed are rewritten, so new
    `#include`s and `.vcproj` edits take effect, and an unchanged tree rebuilds nothing.
  - It then runs the toolchain's `ninja.exe` with the same PATH/INCLUDE/LIB that `vostok tool
    toolchain` puts in the Wine registry.
  - It prints `native build: rc=… min steps= errors= link stalls= log=` and exits with ninja's status.
  - Options: `-Clean` runs `ninja -t clean` first; `-NoRegen` keeps the current graph; `-Target`
    builds another ninja target.
- **`sync.ps1`** (WSL mirror) mirrors the WSL checkout into this one.
  - It checks out the WSL branch tip, applies the uncommitted diff under `sources/`, and copies
    untracked source files.
  - It then copies `binaries/ninja`, rewriting Wine's `Z:<wsl repo>` root to `C:\survarium`.
  - It discards the previous sync's changes, and refuses if anything else here is uncommitted
    (`-Force` discards that too).
  - `-SourcesOnly` or `-GraphOnly` runs one half.
- **`deploy.ps1`** copies the exe into a game install as `survarium_rebuilt.exe`, next to the retail exe.
  - It also copies the PDB under its linked name, so crash reports symbolize.
  - Run it with `-no_splash_screen -client=<host:port>`.
  - Add `-autologin[=name:password]`, a dev-only switch in `login_menu.cpp`, to sign in without clicking.

## How the native graph differs from the Wine one

`vostok.build.ninja_regen` runs vcproj2ninja without `--wine` when it runs on Windows, against
`C:\survarium\sources\vostok v2.0.sln`. It applies the same retail corrections as under Wine: the
link library order, the sound archive member order, and the `c:/survarium/sources` compile
directory. It roots them at `C:/survarium` instead of `Z:<repo>`.

The graph is read and written as bytes, with universal-newline reads, so it stays LF on both
hosts. Apart from ninja pool names, which are derived from the root path, the native graph is
identical to a Wine graph rewritten to `C:\survarium`. The clangd inputs
(`compile_commands.json`) are not generated natively.

## Caveats

- **The LTCG link can stall.**
  - VS2008's code generator (`c2.dll`) sometimes waits forever on a stale handle: Windows has
    already reused that handle value for a thread-pool IoCompletion object.
  - `link.exe` then sits at "Generating code" with no CPU use.
  - `build.ps1` kills a link that makes no CPU progress for `-StallSeconds` (90) and reruns ninja,
    up to `-Attempts` (3). Only the link step reruns.
  - `relink.ps1` reruns just the exe link with `/ERRORREPORT:NONE` and prints its CPU every 30 s,
    for when you want to look at the link directly.
- **mspdbsrv.** `build.ps1` stops the toolchain's `mspdbsrv.exe` when it finishes, so the next
  build does not inherit a server that holds stale PDB handles.
- **VC90 CRT.** `cl.exe`, `c1xx.dll`, `c2.dll` and `link.exe` request `Microsoft.VC90.CRT`
  9.0.21022.8. Setup copies the toolchain's redist into `msvc\VC\bin` as a private assembly, so a
  machine without the VC++ 2008 runtime can still start them.
