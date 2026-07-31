#!/usr/bin/env bash
#
# Remove what build.sh created. Nothing is deleted until you confirm.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHELL_RC="${ZDOTDIR:-$HOME}/.zshrc"
ENV_MARKER_BEGIN="# >>> openmodelica (managed by openmodelica-build) >>>"
ENV_MARKER_END="# <<< openmodelica <<<"

KEEP_SOURCE=0
BREW_DEPS=0
ASSUME_YES=0

BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'; RST=$'\033[0m'
step() { printf '\n%s==> %s%s\n' "$BOLD" "$*" "$RST"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%s    warning: %s%s\n' "$RED" "$*" "$RST"; }

usage() {
  cat <<'EOF'
Remove what build.sh created.

  ./uninstall.sh [options]

By default this removes the build tree (src/, build_cmake/, install/, logs/,
env.sh) and the block build.sh --setup-shell added to ~/.zshrc. build.sh and
the git history are never touched, so you can always rebuild.

Options:
  --keep-source   Keep src/ (the ~1.4 GB checkout), so a rebuild skips cloning
  --brew-deps     ALSO uninstall the Homebrew formulae build.sh installed.
                  Off by default: these are shared, and other software on this
                  machine may depend on them.
  -y, --yes       Don't ask for confirmation
  -h, --help      Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-source) KEEP_SOURCE=1; shift ;;
    --brew-deps)   BREW_DEPS=1; shift ;;
    -y|--yes)      ASSUME_YES=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ------------------------------------------------------- work out the plan ---

targets=()
for d in build_cmake install logs; do
  [[ -e "$ROOT/$d" ]] && targets+=( "$ROOT/$d" )
done
[[ -e "$ROOT/env.sh" ]] && targets+=( "$ROOT/env.sh" )
if (( ! KEEP_SOURCE )) && [[ -e "$ROOT/src" ]]; then
  targets+=( "$ROOT/src" )
fi

rc_has_block=0
if [[ -f "$SHELL_RC" ]] && grep -qF "$ENV_MARKER_BEGIN" "$SHELL_RC"; then
  rc_has_block=1
fi

step "This will remove"
if (( ${#targets[@]} )); then
  for t in "${targets[@]}"; do
    printf '    %-14s %s\n' "$(du -sh "$t" 2>/dev/null | cut -f1)" "$t"
  done
else
  info "(no build artifacts found)"
fi
(( rc_has_block )) && info "the openmodelica block in $SHELL_RC"
(( KEEP_SOURCE )) && info "${DIM}keeping src/ (--keep-source)${RST}"

if (( BREW_DEPS )); then
  warn "and these shared Homebrew formulae:"
  info "${DIM}qt open-scene-graph gcc boost libomp ccache openjdk${RST}"
  info "${DIM}flex bison expat readline gettext autoconf automake libtool${RST}"
  info "${DIM}cmake ninja pkg-config${RST}"
  warn "other software may depend on these"
fi

if (( ! ${#targets[@]} )) && (( ! rc_has_block )) && (( ! BREW_DEPS )); then
  info "nothing to do"
  exit 0
fi

if (( ! ASSUME_YES )); then
  printf '\n%sProceed? [y/N] %s' "$BOLD" "$RST"
  read -r reply
  [[ "$reply" =~ ^[Yy]$ ]] || { echo "aborted"; exit 1; }
fi

# ------------------------------------------------------------------ remove ---

if (( ${#targets[@]} )); then
  step "Removing build artifacts"
  for t in "${targets[@]}"; do
    rm -rf "$t"
    info "removed $(basename "$t")"
  done
fi

if (( rc_has_block )); then
  step "Cleaning $SHELL_RC"
  cp "$SHELL_RC" "$SHELL_RC.openmodelica-backup"
  tmp_rc="$(mktemp)"
  sed "/^${ENV_MARKER_BEGIN}$/,/^${ENV_MARKER_END}$/d" "$SHELL_RC" > "$tmp_rc"
  mv "$tmp_rc" "$SHELL_RC"
  info "removed the env block (backup: $SHELL_RC.openmodelica-backup)"
  info "run 'exec zsh' or open a new terminal for it to take effect"
fi

if (( BREW_DEPS )); then
  step "Uninstalling Homebrew formulae"
  # Not --force: brew refuses to remove anything another formula still needs,
  # which is the behaviour we want here.
  brew uninstall qt open-scene-graph gcc boost libomp ccache openjdk \
                 flex bison expat readline gettext autoconf automake libtool \
                 cmake ninja pkg-config 2>&1 | sed 's/^/    /' || \
    warn "some formulae were kept — they are still required by other packages"
fi

printf '\n%s==> Done.%s build.sh is untouched — re-run it to rebuild.\n\n' "$GRN" "$RST"
