#!/bin/sh
# semut installer.
#
#   curl -fsSL https://raw.githubusercontent.com/rosdyana/semutjs/main/install.sh | sh
#   # or, from a clone:  sh install.sh
#
# What it does, in order:
#   1. checks for macOS 12+, git and the Xcode command-line tools (clang, xxd)
#   2. installs Tov (https://tov.sh) if `tov` isn't on PATH
#   3. gets the semut source: the checkout this script sits in, or a clone into
#      $SEMUT_DIR (default ~/.semut/src), updated if it is already there
#   4. links the `semut` CLI into $SEMUT_BIN (default ~/.local/bin)
#   5. builds the launcher once (cached in ~/Library/Caches/semut)
#
# Environment: SEMUT_REPO (git URL), SEMUT_DIR, SEMUT_BIN.
set -eu

REPO=${SEMUT_REPO:-https://github.com/rosdyana/semutjs}
DIR=${SEMUT_DIR:-$HOME/.semut/src}
BIN=${SEMUT_BIN:-$HOME/.local/bin}

say() { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
fail() { printf '\nsemut install: %s\n' "$*" >&2; exit 1; }

step "Checking prerequisites"
[ "$(uname -s)" = Darwin ] || fail "semut runs on macOS only (its launcher is AppKit + WKWebView)"
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 12 ] || fail "macOS 12 or newer is needed (this is $(sw_vers -productVersion))"
command -v git >/dev/null 2>&1 || fail "git is missing: run \`xcode-select --install\`, then run this again"
xcode-select -p >/dev/null 2>&1 && command -v clang >/dev/null 2>&1 \
  || fail "the Xcode command-line tools are missing: run \`xcode-select --install\`, then run this again"
command -v xxd >/dev/null 2>&1 || fail "xxd is missing (it ships with macOS's vim): reinstall the command-line tools"
say "macOS $(sw_vers -productVersion), $(clang --version | head -n 1)"

step "Checking Tov"
[ -x "$HOME/.cargo/bin/tov" ] && PATH="$HOME/.cargo/bin:$PATH"
if command -v tov >/dev/null 2>&1; then
  say "found $(command -v tov) ($(tov version 2>/dev/null || echo unknown version))"
else
  say "Tov not found; installing it (builds from source with Rust, a few minutes)..."
  if ! curl -fsSL https://tov.sh/install.sh | sh; then
    fail "Tov didn't build. If the error says \"\`if let\` guards are experimental\", your Rust is too old:
  rustup update stable
then run this installer again."
  fi
  PATH="$HOME/.cargo/bin:$PATH"
  # Tov's installer exits 0 even when cargo fails, so check for the binary.
  command -v tov >/dev/null 2>&1 || fail "Tov didn't build (see the cargo error above). If it says \"\`if let\` guards are experimental\", run \`rustup update stable\` and run this installer again."
fi

step "Getting semut"
here=$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)
if [ -n "$here" ] && [ -f "$here/semut" ] && [ -f "$here/native/launcher-macos.m" ]; then
  DIR=$here
  say "using this checkout: $DIR"
elif [ -d "$DIR/.git" ]; then
  say "updating $DIR"
  git -C "$DIR" pull -q --ff-only
else
  say "cloning $REPO into $DIR"
  mkdir -p "$(dirname "$DIR")"
  git clone -q --depth 1 "$REPO" "$DIR"
fi
chmod +x "$DIR/semut"

step "Linking the CLI"
mkdir -p "$BIN"
ln -sf "$DIR/semut" "$BIN/semut"
say "$BIN/semut -> $DIR/semut"

step "Building the launcher"
"$DIR/semut" launcher

say ""
say "semut is installed."
case ":$PATH:" in
  *":$BIN:"*) ;;
  *) say ""
     say "$BIN is not on your PATH. Add it (zsh):"
     say "  echo 'export PATH=\"$BIN:\$PATH\"' >> ~/.zshrc && source ~/.zshrc" ;;
esac
case ":$PATH:" in
  *":$HOME/.cargo/bin:"*) ;;
  *) say "Tov lives in ~/.cargo/bin; make sure that is on your PATH too (\`. \"\$HOME/.cargo/env\"\`)." ;;
esac
say ""
say "Next:"
say "  semut doctor          check everything is in place"
say "  semut new myapp && cd myapp && semut dev"
