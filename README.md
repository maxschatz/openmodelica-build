# OpenModelica on Apple Silicon

Reproducible source build of [OpenModelica](https://openmodelica.org) for macOS
on arm64. There are no official Apple Silicon binaries — upstream ships Windows
and Linux packages only — so the supported path on a Mac is either a Linux
container or a source build. This is the source build.

## Usage

```sh
./build.sh              # full build: omc + OMEdit
./build.sh --help       # all options
```

The script installs Homebrew dependencies, clones the release tag into `src/`,
configures CMake into `build_cmake/`, and installs into `install/`. Everything
it creates is gitignored; only the script is tracked.

First build takes roughly 40–90 minutes and ~15 GB of disk. `ccache` is enabled,
so re-runs after a failure are far quicker.

## After building

```sh
export OPENMODELICAHOME="$PWD/install"
export PATH="$PWD/install/bin:$PATH"

omc --version
open install/bin/OMEdit.app
```

## Build profiles

`--minimal` is upstream's conservative Apple Silicon recipe: compiler only, no
Fortran, no optimization. Use it if the full build breaks — it has the fewest
moving parts and is the configuration upstream documents for M-series Macs.

Individual switches (`--no-gui`, `--no-fortran`, `--no-optimization`,
`--no-cpp-runtime`) let you drop one component at a time instead.

## Notes on the macOS specifics

- **PATH is rebuilt** from Homebrew + system paths only. Upstream's macOS notes
  trace "building for macOS-arm64 but linking x86_64" errors to conda and other
  toolchains leaking into `PATH`.
- **Compilers are set explicitly** (`clang`/`clang++`) even though they're the
  defaults; CMake's macOS detection misbehaves otherwise.
- **LAPACK** comes from Apple's Accelerate framework, so no BLAS formula needed.
- **Qt 6** is used for the GUI clients. The old blocker on macOS was Qt 5's
  QtWebKit, which Homebrew dropped; OMEdit's move to Qt 6 removed that
  dependency.
- **gfortran** comes from Homebrew's `gcc`. Upstream's documented M1 recipe
  disables Fortran; this script enables it by default, since a working arm64
  gfortran is now available, and falls back if it isn't found.

## Version

Pinned to `v1.27.0` (July 2026). Override with `--version <tag>`, e.g.
`--version master` for the development branch.
