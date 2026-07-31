#!/usr/bin/env bash
#
# Build OpenModelica from source on Apple Silicon macOS.
#
# Usage:  ./build.sh [options]
# Run    ./build.sh --help   for the full option list.
#
set -euo pipefail

# ---------------------------------------------------------------- settings ---

OM_VERSION="v1.27.0"          # git tag to build; "master" for the dev branch
GENERATOR="Unix Makefiles"    # upstream tests this; --ninja switches it
BUILD_TYPE="Release"
JOBS="$(sysctl -n hw.ncpu)"

WITH_GUI=1                    # OMEdit / OMPlot / OMShell (needs Qt 6)
WITH_FORTRAN=1                # gfortran from Homebrew gcc
WITH_OPTIMIZATION=1           # Ipopt dynamic optimization (implies Fortran)
WITH_CPP_RUNTIME=1            # C++ simulation runtime (needs Boost)
WITH_COLPACK=0                # see the ColPack note below
SKIP_DEPS=0
CLEAN=0
RECONFIGURE=0

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$ROOT/src"
BUILD_DIR="$ROOT/build_cmake"
INSTALL_DIR="$ROOT/install"
LOG_DIR="$ROOT/logs"

BREW_FORMULAE=(
  cmake ninja autoconf automake libtool pkg-config
  gcc boost ccache openjdk libomp
  readline gettext expat flex bison
)
BREW_GUI_FORMULAE=( qt open-scene-graph )

# ------------------------------------------------------------------- usage ---

usage() {
  cat <<'EOF'
Build OpenModelica from source on Apple Silicon macOS.

  ./build.sh [options]

Options:
  --version <tag>   Git tag/branch to build          (default: v1.27.0)
  --jobs <n>        Parallel build jobs              (default: all cores)
  --ninja           Use the Ninja generator instead of Unix Makefiles
  --debug           CMAKE_BUILD_TYPE=Debug           (default: Release)

  --no-gui          Skip OMEdit/OMPlot/OMShell; build only the omc compiler
  --no-fortran      Disable Fortran (also disables optimization)
  --no-optimization Disable Ipopt-based dynamic optimization
  --no-cpp-runtime  Disable the C++ simulation runtime
  --with-colpack    Build the vendored ColPack graph-colouring library. Off by
                    default: nothing in this release actually calls it, and it
                    needs OpenMP, which Apple clang does not ship.
  --minimal         Upstream's conservative Apple Silicon profile:
                    equivalent to --no-gui --no-fortran --no-optimization

  --skip-deps       Don't touch Homebrew, assume deps are present
  --reconfigure     Re-run cmake configure even if the build dir exists
  --clean           Delete build_cmake/ and install/ before building
  -h, --help        Show this help

Artifacts land in ./install/bin (omc, OMEdit.app, ...). Logs go to ./logs.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)         OM_VERSION="$2"; shift 2 ;;
    --jobs)            JOBS="$2"; shift 2 ;;
    --ninja)           GENERATOR="Ninja"; shift ;;
    --debug)           BUILD_TYPE="Debug"; shift ;;
    --no-gui)          WITH_GUI=0; shift ;;
    --no-fortran)      WITH_FORTRAN=0; WITH_OPTIMIZATION=0; shift ;;
    --no-optimization) WITH_OPTIMIZATION=0; shift ;;
    --no-cpp-runtime)  WITH_CPP_RUNTIME=0; shift ;;
    --with-colpack)    WITH_COLPACK=1; shift ;;
    --minimal)         WITH_GUI=0; WITH_FORTRAN=0; WITH_OPTIMIZATION=0; shift ;;
    --skip-deps)       SKIP_DEPS=1; shift ;;
    --reconfigure)     RECONFIGURE=1; shift ;;
    --clean)           CLEAN=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ------------------------------------------------------------------ output ---

BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'; RST=$'\033[0m'
step() { printf '\n%s==> %s%s\n' "$BOLD" "$*" "$RST"; }
patched() { printf '    %spatched%s %s\n' "$GRN" "$RST" "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%s    warning: %s%s\n' "$RED" "$*" "$RST"; }
die()  { printf '\n%serror: %s%s\n' "$RED" "$*" "$RST" >&2; exit 1; }

# ----------------------------------------------------------- preconditions ---

[[ "$(uname -s)" == "Darwin" ]] || die "this script is macOS-only"
[[ "$(uname -m)" == "arm64" ]]  || warn "not arm64 — flags are tuned for Apple Silicon"
command -v brew >/dev/null      || die "Homebrew is required: https://brew.sh"
xcode-select -p >/dev/null 2>&1 || die "Xcode CLT missing — run: xcode-select --install"

BREW_PREFIX="$(brew --prefix)"

# Upstream's macOS notes: a polluted PATH (conda, /usr/local shims, other
# toolchains) causes "building for macOS-arm64 but linking x86_64" failures.
# Rebuild PATH from Homebrew + the system only.
export PATH="$BREW_PREFIX/opt/bison/bin:$BREW_PREFIX/opt/flex/bin:$BREW_PREFIX/bin:$BREW_PREFIX/sbin:/usr/bin:/bin:/usr/sbin:/sbin"

mkdir -p "$LOG_DIR"

# --------------------------------------------------------------------- 1/5 ---

if (( SKIP_DEPS )); then
  step "1/5  Dependencies (skipped)"
else
  step "1/5  Installing Homebrew dependencies"
  formulae=( "${BREW_FORMULAE[@]}" )
  (( WITH_GUI )) && formulae+=( "${BREW_GUI_FORMULAE[@]}" )

  missing=()
  for f in "${formulae[@]}"; do
    brew list --formula --versions "$f" >/dev/null 2>&1 || missing+=( "$f" )
  done

  if (( ${#missing[@]} )); then
    info "installing: ${missing[*]}"
    brew install "${missing[@]}" 2>&1 | tee "$LOG_DIR/01-brew.log"
  else
    info "all present"
  fi
fi

# JDK: Homebrew's openjdk is keg-only, so point JAVA_HOME at it explicitly.
if [[ -d "$BREW_PREFIX/opt/openjdk/libexec/openjdk.jdk/Contents/Home" ]]; then
  export JAVA_HOME="$BREW_PREFIX/opt/openjdk/libexec/openjdk.jdk/Contents/Home"
  export PATH="$JAVA_HOME/bin:$PATH"
fi

GFORTRAN=""
if (( WITH_FORTRAN )); then
  GFORTRAN="$(command -v gfortran || true)"
  [[ -z "$GFORTRAN" && -x "$BREW_PREFIX/opt/gcc/bin/gfortran" ]] && GFORTRAN="$BREW_PREFIX/opt/gcc/bin/gfortran"
  if [[ -z "$GFORTRAN" ]]; then
    warn "gfortran not found — continuing with Fortran disabled"
    WITH_FORTRAN=0; WITH_OPTIMIZATION=0
  else
    info "gfortran: $GFORTRAN"
  fi
fi

# ColPack is a graph-colouring library used to compress sparse Jacobians. It is
# the single reason this build needs OpenMP, and it is the only thing that fails
# to compile here: its SMPGC sources include <omp.h> unconditionally, which
# Apple clang does not ship, and they call std::random_shuffle, which C++17
# removed and libc++ (unlike libstdc++) genuinely does not provide.
#
# It is also dead weight in this release. OM_OMC_ENABLE_COLPACK only ever gates
# a link and an OMC_HAVE_COLPACK define; that define is never tested by any
# #ifdef, and no ColPack symbol is referenced anywhere outside ColPack itself.
# So it is compiled, linked, and never called -- turning it off costs nothing
# and removes both failures at the source.
#
# --with-colpack still builds it, for which OpenMP has to be supplied by hand.
# Note that this deliberately passes the header and runtime but *not* -fopenmp:
# -fopenmp would also switch on OpenMP in OpenModelica's own solvers, where
# clang enforces default(none) far more strictly than GCC (dassl.c,
# ida_solver.c, jacobianSymbolical.c all fail to compile). Those parallel paths
# have never been exercised on macOS, since find_package(OpenMP) always failed
# there, so enabling them in a simulation tool risks data races.
#
# Be aware that ColPack built this way runs serially, and its SMPGC routines
# partition work into caller-supplied nT buckets indexed by omp_get_thread_num().
# With the pragmas ignored only bucket 0 is processed, so a caller passing nT > 1
# would get an incomplete colouring. Nothing calls it today, but that is why it
# is off by default rather than quietly built serial.
LIBOMP="$BREW_PREFIX/opt/libomp"
OMP_COMPILE_FLAGS=""
OMP_LINK_FLAGS=""
if (( WITH_COLPACK )); then
  if [[ -f "$LIBOMP/include/omp.h" ]]; then
    OMP_COMPILE_FLAGS="-I$LIBOMP/include -Wno-unknown-pragmas"
    OMP_LINK_FLAGS="-L$LIBOMP/lib -lomp"
    info "libomp: $LIBOMP (header + runtime only, no OpenMP codegen)"
  else
    warn "libomp not found — ColPack will fail on a missing omp.h"
  fi
fi

# --------------------------------------------------------------------- 2/5 ---

step "2/5  Fetching OpenModelica $OM_VERSION"

if (( CLEAN )); then
  info "removing build_cmake/ and install/"
  rm -rf "$BUILD_DIR" "$INSTALL_DIR"
fi

if [[ ! -d "$SRC_DIR/.git" ]]; then
  info "cloning (this pulls ~2 GB of submodules, give it a few minutes)"
  git clone --recurse-submodules --shallow-submodules \
      --branch "$OM_VERSION" --depth 1 \
      https://github.com/OpenModelica/OpenModelica.git "$SRC_DIR" \
      2>&1 | tee "$LOG_DIR/02-clone.log"
else
  info "reusing existing checkout at src/"
  git -C "$SRC_DIR" fetch --depth 1 origin "$OM_VERSION" 2>&1 | tee "$LOG_DIR/02-clone.log"
  git -C "$SRC_DIR" checkout -q FETCH_HEAD
  git -C "$SRC_DIR" submodule update --init --recursive --depth 1 \
      2>&1 | tee -a "$LOG_DIR/02-clone.log"
fi

info "HEAD: $(git -C "$SRC_DIR" rev-parse --short HEAD)"

# --- local patches ---------------------------------------------------------
#
# The bundled ColPack calls std::random_shuffle, which C++17 removed. The
# top-level CMakeLists sets CMAKE_CXX_STANDARD 17 for the whole tree, so this
# only bites on macOS: GCC's libstdc++ still ships random_shuffle in C++17
# mode, while Apple's libc++ genuinely removes it.
#
# Upstream fixed this in OMCompiler-3rdParty (std::shuffle with an explicit
# engine), but the submodule commit pinned by this release predates the fix.
# Bumping the whole submodule would pull in unrelated changes to sundials and
# the other vendored libraries, so apply just this change here. Idempotent:
# re-runs and fresh clones are both safe.
patch_colpack_random_shuffle() {
  local f found=0
  for f in "$SRC_DIR"/OMCompiler/3rdParty/ColPack/src/SMPGC/*.cpp; do
    [[ -f "$f" ]] || continue
    grep -q 'std::random_shuffle' "$f" || continue
    found=1
    python3 - "$f" <<'PY'
import re, sys

path = sys.argv[1]
src = open(path).read()

# std::shuffle needs <algorithm>; the engine needs <random>.
for header in ("<random>", "<algorithm>"):
    if f"#include {header}" not in src:
        src = re.sub(r'(#include\s+[<"][^>"]+[>"]\n)',
                     rf'\1#include {header}\n', src, count=1)

# Brace-scope the engine so the replacement stays a single statement and the
# name cannot collide with anything already in the enclosing function.
src = re.sub(
    r'std::random_shuffle\((.*?)\);',
    r'{ std::default_random_engine omc_rng(std::random_device{}()); '
    r'std::shuffle(\1, omc_rng); }',
    src)

open(path, "w").write(src)
PY
    patched "$(basename "$f") (random_shuffle -> shuffle)"
  done
  (( found )) || info "ColPack: random_shuffle patch already applied"
}

(( WITH_COLPACK )) && patch_colpack_random_shuffle

# --------------------------------------------------------------------- 3/5 ---

step "3/5  Configuring with CMake"

# Keg-only formulae need explicit hints; Qt and OSG are found via their opt dirs.
prefix_path="$BREW_PREFIX"
# libomp is deliberately absent here. It is keg-only, so leaving it out is what
# keeps find_package(OpenMP) failing, which is the stock macOS behaviour. Adding
# it makes OpenMP "found", and OMSICpp then defines USE_OPENMP for its Peer and
# CppDASSL solvers -- whose legacy CMake propagates OpenMP_CXX_FLAGS but never
# the include directory, so they include <omp.h> and cannot find it. ColPack
# gets the include path handed to it directly instead (see OMP_COMPILE_FLAGS).
for p in qt open-scene-graph expat readline gettext libiconv boost; do
  [[ -d "$BREW_PREFIX/opt/$p" ]] && prefix_path="$prefix_path;$BREW_PREFIX/opt/$p"
done

cmake_args=(
  -S "$SRC_DIR" -B "$BUILD_DIR"
  -G "$GENERATOR"
  -Wno-dev
  -DCMAKE_BUILD_TYPE="$BUILD_TYPE"
  -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR"
  # Upstream insists these be set explicitly on macOS, even for the defaults.
  -DCMAKE_C_COMPILER=clang
  -DCMAKE_CXX_COMPILER=clang++
  -DCMAKE_PREFIX_PATH="$prefix_path"
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
  -DCMAKE_C_FLAGS="$OMP_COMPILE_FLAGS"
  -DCMAKE_CXX_FLAGS="$OMP_COMPILE_FLAGS"
  -DCMAKE_EXE_LINKER_FLAGS="$OMP_LINK_FLAGS"
  -DCMAKE_SHARED_LINKER_FLAGS="$OMP_LINK_FLAGS"
  -DCMAKE_MODULE_LINKER_FLAGS="$OMP_LINK_FLAGS"
  -DOM_USE_CCACHE=ON
  -DOM_OMC_USE_LAPACK=ON        # satisfied by Apple's Accelerate framework
  -DOM_OMC_USE_CORBA=OFF
  -DOM_ENABLE_ENCRYPTION=OFF
  -DOM_OMC_ENABLE_COLPACK=$( (( WITH_COLPACK )) && echo ON || echo OFF )
)

# No OpenMP_* hints on purpose: find_package(OpenMP) should keep failing here,
# so the subprojects that check for it build their serial paths (see above).

if (( WITH_FORTRAN )); then
  cmake_args+=( -DOM_OMC_ENABLE_FORTRAN=ON -DCMAKE_Fortran_COMPILER="$GFORTRAN" )
else
  cmake_args+=( -DOM_OMC_ENABLE_FORTRAN=OFF )
fi

if (( WITH_OPTIMIZATION )); then
  cmake_args+=( -DOM_OMC_ENABLE_OPTIMIZATION=ON -DOM_OMC_ENABLE_MOO=ON )
else
  cmake_args+=( -DOM_OMC_ENABLE_OPTIMIZATION=OFF -DOM_OMC_ENABLE_MOO=OFF )
fi

cmake_args+=( -DOM_OMC_ENABLE_CPP_RUNTIME=$( (( WITH_CPP_RUNTIME )) && echo ON || echo OFF ) )

if (( WITH_GUI )); then
  cmake_args+=(
    -DOM_ENABLE_GUI_CLIENTS=ON
    -DOM_QT_MAJOR_VERSION=6
    -DOM_OMEDIT_ENABLE_TESTS=OFF
    -DOM_OMSHELL_ENABLE_TERMINAL=ON
  )
else
  cmake_args+=( -DOM_ENABLE_GUI_CLIENTS=OFF )
fi

info "profile: gui=$WITH_GUI fortran=$WITH_FORTRAN optimization=$WITH_OPTIMIZATION cpp-runtime=$WITH_CPP_RUNTIME colpack=$WITH_COLPACK"

if [[ -f "$BUILD_DIR/CMakeCache.txt" ]] && (( ! RECONFIGURE )); then
  info "build dir already configured (use --reconfigure to redo)"
else
  # --fresh wipes CMakeCache.txt first. Re-running cmake over an existing cache
  # only *adds* or *changes* entries, so a -D option that has been dropped since
  # the last run silently persists. That is not hypothetical: dropping the
  # OpenMP_* hints left them cached, find_package(OpenMP) kept succeeding, and
  # OMSICpp compiled with -fopenmp against a link line that no longer had -lomp.
  if [[ -f "$BUILD_DIR/CMakeCache.txt" ]]; then
    info "discarding the existing cache (--fresh)"
    cmake --fresh "${cmake_args[@]}" 2>&1 | tee "$LOG_DIR/03-configure.log"
  else
    cmake "${cmake_args[@]}" 2>&1 | tee "$LOG_DIR/03-configure.log"
  fi
fi

# --------------------------------------------------------------------- 4/5 ---

step "4/5  Building with $JOBS jobs"
info "expect 40-90 min on a first build; ccache makes reruns much faster"
echo

# Render CMake's "[ 42%] Building ..." chatter as a progress bar, while the
# unabridged output still goes to the log. Errors are printed through so a
# failure is never hidden behind the bar. Falls back to periodic plain lines
# when stdout is not a terminal (CI, or piping this script to a file).
progress_bar() {
  python3 -u -c '
import re, sys, time, shutil

pct, last, start, reported = 0, "", time.time(), -5
tty = sys.stdout.isatty()
PCT = re.compile(r"^\[\s*(\d+)%\]\s*(.*)")
BAD = re.compile(r"error:|Error [0-9]|FAILED|fatal error", re.I)

def width():
    return shutil.get_terminal_size((100, 20)).columns

def draw():
    w = width()
    bw = max(10, min(40, w - 44))
    fill = bw * pct // 100
    el = int(time.time() - start)
    head = "  [{}{}] {:3d}%  {:d}m{:02d}s  ".format(
        "#" * fill, "-" * (bw - fill), pct, el // 60, el % 60)
    sys.stdout.write("\r" + (head + last[: max(0, w - len(head) - 2)]).ljust(w - 1)[: w - 1])
    sys.stdout.flush()

def clear():
    if tty:
        sys.stdout.write("\r" + " " * (width() - 1) + "\r")

for raw in sys.stdin:
    line = raw.rstrip("\n")
    m = PCT.match(line)
    if m:
        pct, last = int(m.group(1)), m.group(2).strip()
        if tty:
            draw()
        elif pct >= reported + 5 or pct == 100:
            reported = pct
            el = int(time.time() - start)
            print("    {:3d}%  {:d}m{:02d}s  {}".format(pct, el // 60, el % 60, last))
    elif BAD.search(line):
        clear()
        print(line)
if tty:
    clear()
'
}

start=$SECONDS
set +e
cmake --build "$BUILD_DIR" --target install --parallel "$JOBS" 2>&1 \
  | tee "$LOG_DIR/04-build.log" \
  | progress_bar
build_rc=${PIPESTATUS[0]}
set -e
echo
info "build took $(( (SECONDS - start) / 60 )) min"

if (( build_rc != 0 )); then
  die "build failed (exit $build_rc) — full output in $LOG_DIR/04-build.log
    last errors:
$(grep -E 'error:|Error [0-9]|FAILED' "$LOG_DIR/04-build.log" | tail -5 | sed 's/^/      /')"
fi

# --------------------------------------------------------------------- 5/5 ---

step "5/5  Verifying"

OMC="$INSTALL_DIR/bin/omc"
[[ -x "$OMC" ]] || die "omc was not installed at $OMC"
info "omc: $("$OMC" --version)"

smoke="$(mktemp -d)"
trap 'rm -rf "$smoke"' EXIT
cat > "$smoke/Smoke.mo" <<'EOF'
model Smoke
  Real x(start = 1, fixed = true);
equation
  der(x) = -x;
end Smoke;
EOF
cat > "$smoke/run.mos" <<EOF
loadFile("$smoke/Smoke.mo"); getErrorString();
simulate(Smoke, stopTime = 1.0); getErrorString();
EOF

if (cd "$smoke" && "$OMC" run.mos) | tee "$LOG_DIR/05-smoke.log" | grep -q 'resultFile = "[^"]\+\.mat"'; then
  printf '\n%s==> OpenModelica %s built and simulating.%s\n' "$GRN" "$OM_VERSION" "$RST"
else
  warn "omc runs but the smoke simulation did not produce a result file"
  warn "see $LOG_DIR/05-smoke.log"
fi

cat <<EOF

${BOLD}Installed to${RST} $INSTALL_DIR

  Add to your shell profile:
    ${DIM}export OPENMODELICAHOME="$INSTALL_DIR"${RST}
    ${DIM}export PATH="$INSTALL_DIR/bin:\$PATH"${RST}
EOF
(( WITH_GUI )) && [[ -d "$INSTALL_DIR/bin/OMEdit.app" ]] && cat <<EOF
  Launch the GUI:
    ${DIM}open "$INSTALL_DIR/bin/OMEdit.app"${RST}
EOF
echo
