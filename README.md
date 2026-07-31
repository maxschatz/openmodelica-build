# OpenModelica on Apple Silicon

Reproducible source build of [OpenModelica](https://openmodelica.org) for macOS
on arm64. There are no official Apple Silicon binaries — upstream ships Windows
and Linux packages only — so the supported path on a Mac is either a Linux
container or a source build. This is the source build.

Pinned to **v1.27.0** (July 2026).

## Install

Copy and paste this into a terminal:

```sh
git clone https://github.com/maxschatz/openmodelica-build.git
cd openmodelica-build
./build.sh --setup-shell
```

That's the whole thing. It installs the Homebrew dependencies, clones the
release, builds it, adds `omc` to your `PATH` in `~/.zshrc`, and finally
compiles and simulates a test model to prove the toolchain actually works.
Expect **40–90 minutes** and about **15 GB** of disk on a first run.

```
==> 4/5  Building with 12 jobs
    expect 40-90 min on a first build; ccache makes reruns much faster

  [###################---------------------]  47%  18m04s  Building Fortran object dmumps.F.o
```

Then open a new terminal and:

```sh
omc --version
open install/Applications/OMEdit.app
```

Drop `--setup-shell` if you would rather not have `~/.zshrc` touched; the script
writes a source-able `env.sh` either way.

### Requirements

- Apple Silicon Mac (M1 or newer)
- [Homebrew](https://brew.sh)
- Xcode Command Line Tools — `xcode-select --install`

Everything else is installed for you. Note the Command Line Tools are needed at
**runtime** too, not just to build: `omc` compiles generated C code every time
you simulate a model.

## Tested on

This was built and verified end to end on exactly this configuration:

| | |
| --- | --- |
| **Machine** | Apple **M4 Pro**, 12 cores, arm64 |
| **macOS** | **26.6** (build 25G72) |
| **OpenModelica** | **v1.27.0** → `omc v1.27.0-cmake` |
| **Date verified** | **2026-07-31** |

<details>
<summary>Full toolchain versions</summary>

| | |
| --- | --- |
| Apple clang | 21.0.0 (clang-2100.1.1.101) |
| Command Line Tools | 26.6.0.0.1781586589 |
| Homebrew | 6.0.13 |
| CMake | 4.4.1 |
| Qt | 6.11.1 |
| GCC (for gfortran) | 16.1.0 |
| Boost | 1.90.0 |
| OpenSceneGraph | 3.6.5 |
| OpenJDK | 26.0.2 |

</details>

Verification was not just "it compiled": `omc` ran a Modelica model through the
full pipeline — code generation, C compilation, simulation — producing a `.mat`
result with `The simulation finished successfully`, and OMEdit was launched and
confirmed to render, including the Documentation panel.

**Other configurations are untested.** Nothing here is Mac-model-specific, so
any Apple Silicon machine should behave identically, but newer macOS releases,
a different Xcode, or newer Homebrew Qt/GCC may shift things. The macOS source
patches in particular are matched against upstream's exact source text and will
fail loudly rather than silently produce a broken build if a future
OpenModelica release rewrites those blocks.

## Usage

```
./build.sh [options]
./build.sh --help
```

| Option | Effect |
| --- | --- |
| `--version <tag>` | Git tag/branch to build (default `v1.27.0`; `master` for dev) |
| `--jobs <n>` | Parallel build jobs (default: all cores) |
| `--ninja` | Use Ninja instead of Unix Makefiles |
| `--debug` | `CMAKE_BUILD_TYPE=Debug` |
| `--no-gui` | Compiler only — skip OMEdit/OMPlot/OMShell |
| `--no-fortran` | Disable Fortran (also disables optimization) |
| `--no-optimization` | Disable Ipopt dynamic optimization |
| `--no-cpp-runtime` | Disable the C++ simulation runtime |
| `--with-colpack` | Build the vendored ColPack (off by default — see below) |
| `--minimal` | Upstream's conservative Apple Silicon profile |
| `--skip-deps` | Don't touch Homebrew |
| `--reconfigure` | Re-run CMake even if the build dir exists |
| `--clean` | Delete `build_cmake/` and `install/` first |

Common cases:

```sh
./build.sh --no-gui                # just the omc compiler, fastest path
./build.sh --minimal               # most conservative, if the full build breaks
./build.sh --version master        # development branch
./build.sh --skip-deps --jobs 8    # rebuild after a failure, leave some cores free
```

Everything the script creates (`src/`, `build_cmake/`, `install/`, `logs/`) is
gitignored; only the script itself is tracked. Re-running is cheap — `ccache` is
enabled and the checkout is reused.

## After building

```sh
export OPENMODELICAHOME="$PWD/install"
export PATH="$PWD/install/bin:$PATH"

omc --version          # -> v1.27.0-cmake
open install/Applications/OMEdit.app
```

Add the two `export` lines to `~/.zshrc` to make it permanent.

Command-line tools land in `install/bin` (`omc`, `OMSimulator`,
`OMShell-terminal`, …); the Qt apps are `.app` bundles in
`install/Applications` (`OMEdit`, `OMNotebook`, `OMPlot`, `OMShell`).

## What gets built

All five submodules plus the in-tree tools:

| | |
| --- | --- |
| `omc` | the Modelica compiler |
| `OMEdit` | graphical modelling/simulation environment |
| `OMNotebook` | interactive notebook |
| `OMShell` | interactive shell |
| `OMPlot` | plotting |
| `OMSimulator` | FMI co-simulation |
| `OMParser`, `OMSens_Qt`, `OMOptim` | parser, sensitivity analysis, optimization |

## macOS-specific decisions

Two deliberate departures from upstream's documented M-series recipe, which
disables both the GUI and Fortran:

- **GUI is on.** The old blocker was Qt 5's QtWebKit, which Homebrew dropped.
  OMEdit has since moved to Qt 6, so the blocker is gone.
- **Fortran is on**, via Homebrew's `gcc`. It was disabled because arm64
  gfortran wasn't reliable; it now is. This is what enables Ipopt/MUMPS
  dynamic optimization.

Both fall back cleanly — use `--minimal` if either regresses.

Other specifics:

- **PATH is rebuilt** from Homebrew + system paths only. Upstream traces
  "building for macOS-arm64 but linking x86_64" errors to conda and other
  toolchains leaking into `PATH`.
- **Compilers are set explicitly** (`clang`/`clang++`) even though they're the
  defaults; CMake's macOS detection misbehaves otherwise.
- **LAPACK** comes from Apple's Accelerate framework, so no BLAS formula needed.

### ColPack is off by default

ColPack is a graph-colouring library used to compress sparse Jacobians (columns
that never share a nonzero row can be evaluated in one directional derivative).
It is the only component that fails to build on macOS, for two reasons:

1. Its SMPGC sources `#include <omp.h>` unconditionally. Apple clang ships no
   OpenMP runtime; Linux builds get the header free from GCC.
2. They call `std::random_shuffle`, removed in C++17. OpenModelica sets
   `CMAKE_CXX_STANDARD 17` tree-wide, and libc++ actually removes it, whereas
   libstdc++ still provides it in C++17 mode.

It is also **unused in this release**: `OM_OMC_ENABLE_COLPACK` only gates a link
and an `OMC_HAVE_COLPACK` define, that define is never tested by any `#ifdef`,
and no ColPack symbol is referenced anywhere outside ColPack itself. So it is
compiled, linked, and never called — turning it off costs nothing and removes
both failures at the source.

`--with-colpack` still builds it: the script then installs `libomp` and patches
`random_shuffle` to `std::shuffle`, matching the fix upstream already made in
`OMCompiler-3rdParty` (the submodule commit pinned by v1.27.0 predates it).
Note that it is built *without* `-fopenmp`, so it runs serially — see the
comments in `build.sh` for why, and for the caveat that its `nT`-bucket
partitioning would be incomplete if anything ever did call it that way.

### OMEdit's Documentation panel renders black

Fixed automatically by `build.sh`; recorded here because it is not obvious and
is worth reporting upstream.

OMEdit ships two WebEngine workarounds compiled in under `#ifdef Q_OS_WIN`,
both of which macOS also needs:

1. **`QSG_RHI_BACKEND=opengl`** (`OMEditGUI/main.cpp`). The 3D animation viewer
   is a `QOpenGLWidget` and OpenSceneGraph is OpenGL-only, so the top-level
   window composites with OpenGL — while Qt Quick defaults to Metal on macOS.
   The Documentation panel is a `QQuickWidget`, and it cannot obtain a `QRhi`
   from a window using a different graphics API, so it draws nothing:

   ```
   The top-level window is not using the expected graphics API for
   composition, 'OpenGL' is not compatible with this QQuickWidget
   QQuickWidget: Failed to get a QRhi from the top-level widget's window
   ```

2. **`--no-sandbox`** (`OMEditLIB/OMEditApplication.cpp`). Upstream's own
   comment says the sandbox "does not work with qt6-webengine".

The script patches both to apply on macOS too. Only the sandbox flag is taken
from the Windows block — its sibling `QTWEBENGINE_RESOURCES_PATH` /
`QTWEBENGINE_LOCALES_PATH` lines encode a Windows install layout that the macOS
framework already provides.

Setting these as environment variables works identically (`qputenv` does the
same thing), but patching the source is the better fix: an `Info.plist`
`LSEnvironment` entry only applies to LaunchServices launches (Finder,
Spotlight, `open`), leaving terminal launches broken, and a rebuild discards it.

`build.sh` also re-signs the `.app` bundles. The linker's ad-hoc signature is
invalidated when the install step adds bundle resources, and Chromium refuses to
spawn its renderer under a broken signature.

## Known upstream issue

[#15657](https://github.com/OpenModelica/OpenModelica/issues/15657) (Qt 6 +
Homebrew build failing at 20%) is **already fixed** in v1.27.0 — the fix,
[#15658](https://github.com/OpenModelica/OpenModelica/pull/15658), landed in
May 2026 and this release is from July. Only relevant if you build an older tag.
