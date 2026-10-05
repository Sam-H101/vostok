# Native Windows build

`scripts/windows/` builds the exe with the same VS2008 toolchain directly on Windows,
without Wine. It compiles much faster than under Wine, which makes it the quick route to a
runnable `survarium-dx11-win32-gold.exe`.

It does not replace the Linux workflow. The Nix flake still provides the toolchain,
vcproj2ninja still generates the build graph under Wine, and scores, the ledger and the
README block still come only from `python3 -m vostok build`. Every measured commit is
built there. The native objects are not compared against the target.

## Layout

Two checkouts of the same branch:

- **WSL checkout** (e.g. `~/vostok` in a WSL2 distro): where you edit, commit and run
  `vostok build`. It owns the Nix store, the Wine prefix and the ninja graph.
- **Native tree** (any Windows path): a second clone that mirrors the WSL checkout, junctioned
  to `C:\survarium`. That path is required: retail objects record `c:\survarium\sources`,
  so the graph is rewritten to that root.

Generated state stays under the gitignored `binaries/` of the native tree:
`binaries\windows\toolchain` (the staged toolchain, about 1 GiB; set
`VOSTOK_WIN_TOOLCHAIN` to keep it elsewhere), `binaries\windows\logs`, and the build
outputs in `binaries\Win32`.

## Setup (once)

Prerequisites:

- Windows 10/11 with Git for Windows.
- A WSL2 distro whose checkout has completed `nix develop` and one `python3 -m vostok build`.
  That build gives it `binaries.prebuilt/`, the `vostok-toolchain` out-link and `binaries/ninja/`.

```powershell
git clone -c core.autocrlf=false https://github.com/srp-survarium/vostok F:\vostok-win
cd F:\vostok-win
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\setup.ps1 -Distro <distro> -WslRepo ~/vostok
```

`core.autocrlf=false` keeps the sources byte-identical to the WSL checkout, so `sync.ps1` can
apply its patches. `setup.ps1` runs four steps and skips any whose output already exists:

1. copies the dereferenced `vostok-toolchain` store path into `binaries\windows\toolchain`
2. copies `binaries.prebuilt`
3. creates the `C:\survarium` junction (no admin rights needed; `-Force` repoints an existing one)
4. adds the WSL checkout as the `wsl` git remote

## The loop

```powershell
# in WSL: edit, commit (or leave uncommitted), and after a .vcproj or #include change
#         regenerate the graph: python3 -m vostok build  (or python3 -m vostok.build.ninja_regen)
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\sync.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\build.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\windows\deploy.ps1 -GameDir <game>\binaries\win32
```

- **`sync.ps1`** mirrors the WSL checkout into the native tree.
  - It checks out the WSL branch tip, applies the uncommitted diff under `sources/`, and copies untracked source files.
  - It then copies `binaries/ninja`, rewriting Wine's `Z:<wsl repo>` root to `C:\survarium`; it writes only the graph files whose contents changed.
  - It discards the previous sync's changes, and refuses if anything else in the native tree is uncommitted (`-Force` discards that too).
  - `-SourcesOnly` or `-GraphOnly` runs one half.
- **`build.ps1`** runs the toolchain's `ninja.exe` with the same PATH/INCLUDE/LIB that `vostok tool toolchain` puts in the Wine registry.
  - It prints `native build: rc=… min steps= errors= link stalls= log=` and exits with ninja's status.
  - `-Clean` runs `ninja -t clean` first; `-Target` builds another ninja target.
- **`deploy.ps1`** copies the exe into a game install as `survarium_rebuilt.exe`, next to the retail exe.
  - It also copies the PDB under its linked name, so crash reports symbolize.
  - Run it with `-no_splash_screen -client=<host:port>`.
  - Add `-autologin[=name:password]`, a dev-only switch in `login_menu.cpp`, to sign in without clicking.

## Caveats

- **Header dependencies come from the graph.** vcproj2ninja's header scan records each
  TU's includes as implicit inputs. A new `#include` only takes effect after the graph is
  regenerated in WSL and re-synced. If a build looks stale, rebuild with `build.ps1 -Clean`.
- **The LTCG link can stall.**
  - VS2008's code generator (`c2.dll`) sometimes waits forever on a stale handle: Windows has already reused that handle value for a thread-pool IoCompletion object.
  - `link.exe` then sits at "Generating code" with no CPU use.
  - `build.ps1` kills a link that makes no CPU progress for `-StallSeconds` (90) and reruns ninja, up to `-Attempts` (3). Only the link step reruns.
  - `relink.ps1` reruns just the exe link with `/ERRORREPORT:NONE` and prints its CPU every 30 s, for when you want to look at the link directly.
- **mspdbsrv.** `build.ps1` stops the toolchain's `mspdbsrv.exe` when it finishes, so the
  next build does not inherit a server that holds stale PDB handles.
