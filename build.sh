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
  gcc boost ccache openjdk
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

# --------------------------------------------------------------------- 3/5 ---

step "3/5  Configuring with CMake"

# Keg-only formulae need explicit hints; Qt and OSG are found via their opt dirs.
prefix_path="$BREW_PREFIX"
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
  -DOM_USE_CCACHE=ON
  -DOM_OMC_USE_LAPACK=ON        # satisfied by Apple's Accelerate framework
  -DOM_OMC_USE_CORBA=OFF
  -DOM_ENABLE_ENCRYPTION=OFF
)

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

info "profile: gui=$WITH_GUI fortran=$WITH_FORTRAN optimization=$WITH_OPTIMIZATION cpp-runtime=$WITH_CPP_RUNTIME"

if [[ -f "$BUILD_DIR/CMakeCache.txt" ]] && (( ! RECONFIGURE )); then
  info "build dir already configured (use --reconfigure to redo)"
else
  cmake "${cmake_args[@]}" 2>&1 | tee "$LOG_DIR/03-configure.log"
fi

# --------------------------------------------------------------------- 4/5 ---

step "4/5  Building with $JOBS jobs"
info "expect 40-90 min on a first build; ccache makes reruns much faster"

start=$SECONDS
cmake --build "$BUILD_DIR" --target install --parallel "$JOBS" \
    2>&1 | tee "$LOG_DIR/04-build.log"
info "build took $(( (SECONDS - start) / 60 )) min"

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
