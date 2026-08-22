#!/usr/bin/env bash
# Shared, source-only tool resolution for Research-SDD.
#
# Keep host-specific paths out of wrappers and keep environment changes local to
# the tool invocation. Callers may override every resolver through the existing
# JAVA_HOME, *_JAR, legacy decompiler, and Ghidra override variables.

rsdd_brew_prefix() {
  if [ -n "${RSDD_BREW_PREFIX:-}" ]; then
    printf '%s\n' "$RSDD_BREW_PREFIX"
  elif [ -n "${HOMEBREW_PREFIX:-}" ]; then
    printf '%s\n' "$HOMEBREW_PREFIX"
  elif command -v brew >/dev/null 2>&1; then
    brew --prefix 2>/dev/null
  elif [ -d /home/linuxbrew/.linuxbrew ]; then
    printf '%s\n' /home/linuxbrew/.linuxbrew
  fi
}

rsdd_java_21_usable() {
  local home="$1" out major
  [ -x "$home/bin/java" ] && [ -x "$home/bin/javap" ] || return 1
  out="$(rsdd_capture_probe "$home/bin/java" -version)" || return 1
  major="$(sed -nE '1{s/.*version "([0-9]+)(\.[0-9]+)?.*/\1/p;}' <<<"$out")"
  [ -n "$major" ] && [ "$major" -ge 21 ]
}

rsdd_resolve_java_home() {
  local brew candidate
  brew="$(rsdd_brew_prefix || true)"
  for candidate in \
    "${JAVA_HOME:-}" \
    "${RESEARCH_SDD_JAVA_HOME:-}" \
    "${brew:+$brew/opt/openjdk@21}" \
    /usr/lib/jvm/java-21-openjdk-amd64 \
    /usr/lib/jvm/java-21-openjdk; do
    [ -n "$candidate" ] && rsdd_java_21_usable "$candidate" && { printf '%s\n' "$candidate"; return 0; }
  done

  # Distro architecture suffixes differ. Resolve an installed Java 21 by its
  # executable rather than baking any suffix or version into the wrapper.
  for candidate in /usr/lib/jvm/java-21-openjdk-*; do
    [ -d "$candidate" ] && rsdd_java_21_usable "$candidate" && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

rsdd_resolve_java_jar() {
  local name="$1" env_name legacy_name value brew tool_home candidate
  case "$name" in
    vineflower) env_name=VINEFLOWER_JAR; legacy_name=VINEFLOWER ;;
    cfr)        env_name=CFR_JAR; legacy_name=CFR ;;
    procyon)    env_name=PROCYON_JAR; legacy_name=PROCYON ;;
    *) return 2 ;;
  esac
  # An explicit override is authoritative. Invalid/empty means unusable; never
  # hide a typo by falling through to a different installation.
  if [[ -v "$env_name" ]]; then
    value="${!env_name}"
    [ -f "$value" ] && { printf '%s\n' "$value"; return 0; }
    return 1
  fi
  if [[ -v "$legacy_name" ]]; then
    value="${!legacy_name}"
    [ -f "$value" ] && { printf '%s\n' "$value"; return 0; }
    return 1
  fi

  brew="$(rsdd_brew_prefix || true)"
  tool_home="${RESEARCH_SDD_TOOL_HOME:-$HOME/.local/share/research-sdd-tools}"
  case "$name" in
    vineflower)
      for candidate in \
        "$tool_home/java/vineflower.jar" \
        "${brew:+$brew/opt/vineflower/libexec/vineflower.jar}"; do
        [ -f "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
      done
      ;;
    cfr)
      candidate="$tool_home/java/cfr.jar"
      [ -f "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
      ;;
    procyon)
      candidate="$tool_home/java/procyon.jar"
      [ -f "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
      ;;
  esac
  return 1
}

rsdd_resolve_ghidra_home() {
  local brew candidate headless override
  if [[ -v ANALYZE_HEADLESS ]]; then
    [ -x "$ANALYZE_HEADLESS" ] || return 1
    [ "$(basename "$(dirname "$ANALYZE_HEADLESS")")" = support ] || return 1
    dirname "$(dirname "$ANALYZE_HEADLESS")"
    return 0
  fi
  for override in GHIDRA_HOME GHIDRA_INSTALL_DIR; do
    if [[ -v "$override" ]]; then
      candidate="${!override}"
      [ -x "$candidate/support/analyzeHeadless" ] || return 1
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  headless="$(command -v analyzeHeadless 2>/dev/null || true)"
  if [ -x "$headless" ] && [ "$(basename "$(dirname "$headless")")" = support ]; then
    dirname "$(dirname "$headless")"
    return 0
  fi

  brew="$(rsdd_brew_prefix || true)"
  candidate="${brew:+$brew/opt/ghidra/libexec}"
  [ -n "$candidate" ] && [ -x "$candidate/support/analyzeHeadless" ] && {
    printf '%s\n' "$candidate"
    return 0
  }

  # Compatibility fallback for non-Homebrew tarball installs. Sort only the
  # discovered roots; no version is pinned in source.
  while IFS= read -r candidate; do
    [ -x "$candidate/support/analyzeHeadless" ] && { printf '%s\n' "$candidate"; return 0; }
  done < <(printf '%s\n' /opt/ghidra* | sort -Vr)
  return 1
}

rsdd_resolve_r2() {
  local brew candidate
  # An explicit override is authoritative. Set-but-not-executable means unusable;
  # do NOT fall through — same discipline as the *_JAR resolvers and rsdd_resolve_ilspy,
  # so a typo is never silently masked by a different installation.
  if [[ -v R2 ]]; then
    [ -x "$R2" ] || return 1
    printf '%s\n' "$R2"
    return 0
  fi
  # PATH lookup: most common installation site (package manager or manual install).
  candidate="$(command -v r2 2>/dev/null || true)"
  if [ -x "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  # Homebrew opt symlink (linuxbrew and macOS): stable, Cellar-version-independent.
  brew="$(rsdd_brew_prefix || true)"
  candidate="${brew:+$brew/opt/radare2/bin/r2}"
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  # Distro fallback: standard /usr/bin location (e.g. apt install radare2).
  # RSDD_R2_USRBIN overrides /usr/bin/r2 for hermetic tests; default is /usr/bin/r2.
  if [ -x "${RSDD_R2_USRBIN:-/usr/bin/r2}" ]; then
    printf '%s\n' "${RSDD_R2_USRBIN:-/usr/bin/r2}"
    return 0
  fi
  return 1
}

rsdd_system_pkgconfig_path() {
  local candidate out=""
  if [ -n "${RSDD_SYSTEM_PKGCONFIG_PATH:-}" ]; then
    printf '%s\n' "$RSDD_SYSTEM_PKGCONFIG_PATH"
    return 0
  fi
  for candidate in /usr/lib/*-linux-gnu/pkgconfig /usr/lib/pkgconfig /usr/share/pkgconfig; do
    [ -d "$candidate" ] || continue
    out="${out:+$out:}$candidate"
  done
  [ -n "$out" ] && printf '%s\n' "$out"
}

rsdd_pkg_config() {
  local pkg_config system_path combined
  pkg_config="${PKG_CONFIG_BIN:-$(command -v pkg-config 2>/dev/null || true)}"
  [ -x "$pkg_config" ] || return 127
  system_path="$(rsdd_system_pkgconfig_path || true)"
  combined="${PKG_CONFIG_PATH:-}"
  combined="${combined:+$combined:}$system_path"
  PKG_CONFIG_PATH="$combined" "$pkg_config" "$@"
}

rsdd_run_probe() {
  local command_path="$1" timeout_bin; shift
  [ -x "$command_path" ] || return 1
  timeout_bin="$(command -v timeout 2>/dev/null)" || return 127
  "$timeout_bin" "${RSDD_PROBE_TIMEOUT:-10}" "$command_path" "$@" >/dev/null 2>&1
}

rsdd_capture_probe() {
  local command_path="$1" timeout_bin; shift
  command -v "$command_path" >/dev/null 2>&1 || [ -x "$command_path" ] || return 1
  timeout_bin="$(command -v timeout 2>/dev/null)" || return 127
  "$timeout_bin" "${RSDD_PROBE_TIMEOUT:-10}" "$command_path" "$@" 2>&1
}

rsdd_probe_ghidra() {
  local home="$1" java_home out rc
  java_home="$(rsdd_resolve_java_home)" || return 1
  [ -x "$home/support/analyzeHeadless" ] || return 1
  if out="$(rsdd_capture_probe env JAVA_HOME="$java_home" "$home/support/analyzeHeadless" -help)"; then
    return 0
  else
    rc=$?
  fi
  [ "$rc" -ne 124 ] && [ "$rc" -ne 137 ] || return 1
  grep -q 'Headless Analyzer Usage' <<<"$out"
}

rsdd_probe_java_jar() {
  local name="$1" jar="$2" entry unzip_bin listing
  [ -s "$jar" ] || return 1
  case "$name" in
    vineflower) entry=org/jetbrains/java/decompiler/main/decompiler/ConsoleDecompiler.class ;;
    cfr) entry=org/benf/cfr/reader/Main.class ;;
    procyon) entry=com/strobel/decompiler/DecompilerDriver.class ;;
    *) return 2 ;;
  esac
  unzip_bin="$(command -v unzip 2>/dev/null)" || return 127
  rsdd_run_probe "$unzip_bin" -tqq "$jar" || return 1
  listing="$(rsdd_capture_probe "$unzip_bin" -Z1 "$jar" "$entry")" || return 1
  [ "$listing" = "$entry" ]
}

rsdd_file_sha256() {
  local file="$1" sha_bin output
  sha_bin="$(command -v sha256sum 2>/dev/null)" || return 127
  output="$(rsdd_capture_probe "$sha_bin" "$file")" || return 1
  printf '%s\n' "${output%% *}"
}

rsdd_resolve_ilspy() {
  local candidate
  # An explicit override is authoritative. Set-but-not-executable means unusable;
  # do NOT fall through — same discipline as the *_JAR resolvers, so a typo is
  # never silently masked by a different installation.
  if [[ -v ILSPYCMD ]]; then
    [ -x "$ILSPYCMD" ] || return 1
    printf '%s\n' "$ILSPYCMD"
    return 0
  fi
  # PATH lookup: dotnet tool install -g adds $HOME/.dotnet/tools to PATH when
  # configured, so a user who ran `dotnet tool install -g ilspycmd` may have it
  # on PATH already.
  candidate="$(command -v ilspycmd 2>/dev/null || true)"
  if [ -x "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  # Portable default: dotnet tool install -g always places tools under
  # $HOME/.dotnet/tools regardless of PATH configuration — never a hardcoded
  # per-user absolute path.
  candidate="$HOME/.dotnet/tools/ilspycmd"
  if [ -x "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  return 1
}

# _rsdd_dotnet_probe ROOT ILSPY — return 0 iff ROOT is a usable ilspycmd runtime root.
# Pre-filter: shared/Microsoft.NETCore.App must exist (cheap structural check).
# Real gate: DOTNET_ROOT=ROOT ilspycmd --version exits 0 within RSDD_PROBE_TIMEOUT seconds.
_rsdd_dotnet_probe() {
  local root="$1" ilspy="$2" timeout_bin
  [ -d "$root/shared/Microsoft.NETCore.App" ] || return 1
  timeout_bin="$(command -v timeout 2>/dev/null || true)"
  if [ -x "${timeout_bin:-}" ]; then
    DOTNET_ROOT="$root" "$timeout_bin" "${RSDD_PROBE_TIMEOUT:-10}" "$ilspy" --version >/dev/null 2>&1
  else
    DOTNET_ROOT="$root" "$ilspy" --version >/dev/null 2>&1
  fi
}

# rsdd_resolve_dotnet_root ILSPY — resolve and validate the .NET runtime root for ilspycmd.
# Prints the resolved DOTNET_ROOT path and exits 0; exits 1 if no usable root is found.
#
# Priority: RSDD_DOTNET_ROOT override → ambient DOTNET_ROOT → derived from dotnet binary
#   (checking the binary dir and its libexec sibling, covering stock and brew layouts).
# Each candidate is probed with "DOTNET_ROOT=<candidate> ilspycmd --version" — structural
# existence alone is not accepted (an empty or too-old runtime exits 131/150).
# RSDD_DOTNET_ROOT is fail-closed: if set but unusable, it errors without falling through.
rsdd_resolve_dotnet_root() {
  local ilspy="$1" candidate dir parent dotnet_bin

  # RSDD_DOTNET_ROOT: kit's own explicit knob. Authoritative — if set but does not
  # probe clean, fail closed; do NOT fall through to a different runtime (mirrors
  # the *_JAR resolver discipline: "explicit override is authoritative; a typo must
  # never be silently masked by a fallback").
  if [ -n "${RSDD_DOTNET_ROOT:-}" ]; then
    if _rsdd_dotnet_probe "${RSDD_DOTNET_ROOT}" "$ilspy"; then
      printf '%s\n' "${RSDD_DOTNET_ROOT}"; return 0
    fi
    echo "ERROR: RSDD_DOTNET_ROOT='${RSDD_DOTNET_ROOT}' is set but ilspycmd --version failed with it (usability probe failed). Fix or unset RSDD_DOTNET_ROOT." >&2
    return 1
  fi

  # Ambient DOTNET_ROOT (set by environment/distro, not the kit): try it, but allow
  # fall-through if the probe fails. This fixes silent shadowing by an old runtime
  # (e.g. /usr/lib/dotnet holding only .NET 8 when ilspycmd requires net10.0).
  if [ -n "${DOTNET_ROOT:-}" ]; then
    _rsdd_dotnet_probe "${DOTNET_ROOT}" "$ilspy" && { printf '%s\n' "${DOTNET_ROOT}"; return 0; }
    # Fall through to derivation.
  fi

  # Derive from the dotnet binary on PATH.
  dotnet_bin="$(command -v dotnet 2>/dev/null || true)"
  [ -x "$dotnet_bin" ] || return 1
  dir="$(dirname "$(realpath "$dotnet_bin")")"
  parent="$(dirname "$dir")"
  # Check the binary directory first (stock/tarball installs place shared/ alongside dotnet).
  # Also check the libexec sibling (brew wraps dotnet from bin/ with the runtime in libexec/).
  for candidate in "$dir" "$parent/libexec"; do
    _rsdd_dotnet_probe "$candidate" "$ilspy" && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}
