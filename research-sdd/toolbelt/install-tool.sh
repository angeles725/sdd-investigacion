#!/usr/bin/env bash
# install-tool.sh — self-provisioning installer for the Research-SDD toolbelt.
# Idempotent, multi-manager, logs EVERYTHING to INSTALLED-TOOLS.md.
#
# Policy: AUTONOMOUS (incl. sudo). The loop may install needed tools without asking.
# Hard safety line (NOT about permission): only KNOWN recipes / OFFICIAL sources.
# Never pipe-to-shell from an unverified URL. sudo runs non-interactively (sudo -n);
# if it needs a password, the install is recorded as 'needs-approval' instead of hanging.
#
# Usage:
#   install-tool.sh <recipe>                 # install by known recipe name (idempotent)
#   install-tool.sh --check <cmd|path>       # available? exit 0/1 (no install)
#   install-tool.sh --list                   # list known recipes
#   install-tool.sh --log <tool> "<how>" <target> <status>  # record an external/manual install
#
# Recipes return: 0 installed/already-present · 3 needs-approval (sudo pw / manual) · 4 failed ·
#                 5 incompatible (target arch/format unsupported by the tool — fail-fast precheck).
#
# Compatibility precheck: recipes that only support some architectures (e.g. blutter = ARM64-only)
# accept an optional target binary as $2 (or env BLUTTER_TARGET) and exit 5 BEFORE any heavy
# build if the target's arch is unsupported. Lesson from EduVolt: blutter built a Dart VM for
# ~20 min before failing on x64 — the precheck turns that into a 5-second decline.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="$HERE/INSTALLED-TOOLS.md"
TARGET="${RESEARCH_TARGET:-?}"

have() { command -v "$1" >/dev/null 2>&1 || [ -x "$1" ]; }
ts()   { date -u +%FT%TZ; }

log() { # tool | how | status | notes
  [ -f "$LOG" ] || printf '# Installed tools log — Research-SDD\n\n> Append-only. Written by install-tool.sh. status: installed | already | needs-approval | failed\n\n| Tool | How | Status | Target | Date (UTC) | Notes |\n|---|---|---|---|---|---|\n' > "$LOG"
  printf '| %s | `%s` | %s | %s | %s | %s |\n' "$1" "$2" "$3" "$TARGET" "$(ts)" "${4:-}" >> "$LOG"
}

sudo_n() { # run sudo non-interactively; return 100 if a password would be required
  if sudo -n true 2>/dev/null; then sudo "$@"; else return 100; fi
}

case "${1:-}" in
  --check) shift; have "${1:?cmd}" && exit 0 || exit 1 ;;
  --list)  grep -oP '^\s+\K[a-z0-9_-]+(?=\)\s)' "$HERE/install-tool.sh" 2>/dev/null | sort -u; exit 0 ;;
  --log)   shift; log "${1:?tool}" "${2:?how}" "${4:?status}" "external/manual"; exit 0 ;;
esac

RECIPE="${1:?usage: install-tool.sh <recipe> | --check <cmd> | --list}"

# brew helper (user-space, no sudo)
brew_install() { have brew && { have "$2" && { log "$1" "brew (present)" already; return 0; }; brew install "$2" >/dev/null 2>&1 && { log "$1" "brew install $2" installed; return 0; } || return 4; } || return 4; }

case "$RECIPE" in
  blutter)
    # Dart/Flutter AOT (app.so) reverse engineering — worawit/blutter (official repo).
    # Full native dump compiles a Dart VM static lib from source matching the app's Dart
    # version, so it needs: cmake + ninja + a C++20 compiler (g++>=13 / clang>=16), the
    # capstone + icu C libs + pkg-config, and Python deps (capstone/pyelftools/requests).
    # Lesson folded in from EduVolt-Designer run: install these deps autonomously BEFORE
    # cloning, and use a venv (brew's Python is PEP-668 externally-managed; pip --user is blocked).
    DEST="$HOME/dev/blutter"
    mkdir -p "$HOME/dev"
    # --- compatibility precheck: blutter only supports ARM64. Fail fast on x64/x86 BEFORE building. ---
    TGT="${2:-${BLUTTER_TARGET:-}}"
    if [ -n "$TGT" ] && [ -e "$TGT" ]; then
      ARCH="$(file -b "$TGT" 2>/dev/null)"
      case "$ARCH" in
        *aarch64*|*arm64*) : ;;   # supported (*aarch64* already matches "ARM aarch64")
        *x86-64*|*x86_64*|*"Intel 80386"*|*PE32*)
          log blutter "compat precheck (file: ${ARCH:0:40})" incompatible "ARM64-only tool; target is x64/x86 -> NOT building (saves ~20min dead-end). Use strings/manual or an x64 Dart-AOT tool"
          echo "INCOMPATIBLE: blutter supports ARM64 only; target is not ARM64 ($ARCH)" >&2; exit 5 ;;
      esac
    fi
    # --- build deps (autonomous, user-space, no sudo; idempotent via have/brew) ---
    if have brew; then
      have cmake      || brew install cmake      >/dev/null 2>&1 || true
      have ninja      || brew install ninja       >/dev/null 2>&1 || true
      have dart       || brew install dart-sdk     >/dev/null 2>&1 || true
      have pkg-config || brew install pkg-config    >/dev/null 2>&1 || true
      brew install capstone icu4c >/dev/null 2>&1 || true   # C libs: no probe cmd; brew install is idempotent
    fi
    # --- clone (skip if already present) ---
    if [ ! -f "$DEST/blutter.py" ]; then
      if ! git clone --depth 1 https://github.com/worawit/blutter.git "$DEST" >/dev/null 2>&1; then
        log blutter "git clone worawit/blutter" failed "clone error"; exit 4
      fi
    fi
    # --- Python deps via dedicated venv (pip --user is blocked on brew Python: PEP 668) ---
    if [ ! -x "$DEST/.venv/bin/python" ]; then
      python3 -m venv "$DEST/.venv" >/dev/null 2>&1 || /usr/bin/python3 -m venv "$DEST/.venv" >/dev/null 2>&1 || true
    fi
    [ -x "$DEST/.venv/bin/pip" ] && "$DEST/.venv/bin/pip" install -q capstone pyelftools requests >/dev/null 2>&1 || true
    log blutter "brew(cmake ninja dart-sdk capstone icu4c pkg-config) + git clone worawit/blutter + venv(capstone pyelftools requests)" installed "$DEST; run via .venv: $DEST/.venv/bin/python $DEST/blutter.py <dir-with-app.so+libflutter.so> <out>"
    echo "$DEST/blutter.py"; exit 0 ;;

  jadx)      brew_install jadx jadx && exit 0 || { sudo_n apt-get install -y -q jadx >/dev/null 2>&1 && { log jadx "sudo apt jadx" installed; exit 0; } || { [ $? = 100 ] && { log jadx "sudo apt jadx" needs-approval "sudo password required"; exit 3; }; log jadx "jadx" failed; exit 4; }; } ;;
  apktool)   brew_install apktool apktool && exit 0 || { log apktool "brew apktool" failed; exit 4; } ;;
  pycdc)
    DEST="$HOME/dev/pycdc"
    if have "$DEST/pycdc"; then log pycdc "build (present)" already "$DEST"; echo "$DEST/pycdc"; exit 0; fi
    mkdir -p "$HOME/dev"
    if git clone --depth 1 https://github.com/zrax/pycdc.git "$DEST" >/dev/null 2>&1 && have cmake && ( cd "$DEST" && cmake . >/dev/null 2>&1 && make >/dev/null 2>&1 ); then
      log pycdc "git clone zrax/pycdc + cmake make" installed "$DEST"; echo "$DEST/pycdc"; exit 0
    else log pycdc "git clone zrax/pycdc + cmake" needs-approval "cmake/compiler missing or build failed"; exit 3; fi ;;
  uncompyle6) python3 -m pip install --user -q decompyle3 >/dev/null 2>&1 && { log uncompyle6 "pip --user decompyle3" installed; exit 0; } || { log uncompyle6 "pip decompyle3" failed; exit 4; } ;;
  yara)      brew_install yara yara && exit 0 || { log yara "brew yara" failed; exit 4; } ;;
  ilspycmd)  have ilspycmd || have "$HOME/.dotnet/tools/ilspycmd" && { log ilspycmd "dotnet tool (present)" already; exit 0; }; dotnet tool install -g ilspycmd >/dev/null 2>&1 && { log ilspycmd "dotnet tool install -g ilspycmd" installed; exit 0; } || { log ilspycmd "dotnet tool ilspycmd" failed; exit 4; } ;;

  *)
    # Unknown recipe: try a generic user-space install, never pipe-to-shell.
    if have brew && brew install "$RECIPE" >/dev/null 2>&1; then log "$RECIPE" "brew install $RECIPE (generic)" installed; exit 0
    elif sudo_n apt-get install -y -q "$RECIPE" >/dev/null 2>&1; then log "$RECIPE" "sudo apt $RECIPE (generic)" installed; exit 0
    else rc=$?; [ "$rc" = 100 ] && { log "$RECIPE" "sudo apt $RECIPE" needs-approval "sudo password required"; exit 3; }
         log "$RECIPE" "generic" failed "no known recipe; add one to tool-registry.md"; exit 4; fi ;;
esac
