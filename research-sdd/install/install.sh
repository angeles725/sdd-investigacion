#!/usr/bin/env bash
# install.sh — universal tiered idempotent installer for the research-sdd kit.
# Targets WSL2 Ubuntu/Debian. BASELINE always runs; heavy tiers are opt-in.
#
# Usage:
#   install.sh [--harness claude|codex|reasonix|all]
#              [--with-binary] [--with-pcap] [--with-firmware] [--with-vm]
#              [--with-pdf] [--with-net] [--with-dotnet] [--with-latex]
#              [--all-heavy] [--home <dir>] [--dry-run]
#
# Phases:
#   1 BASELINE — always; probe-before-install; sudo -n (never hangs).
#   2 HEAVY    — selected tier flags only; missing tools degrade, never break BASELINE.
#   3 VERIFY   — always; runs detect-tools.sh and prints a summary line.
#
# Exit: 0 when BASELINE succeeded (even when heavy tools are missing or degraded).
#       non-zero only when BASELINE itself failed.
set -uo pipefail

# -P/pwd -P: see research-sdd/toolbelt/verify-cd-physical.sh's own header for why (kit issue #1024).
SELF="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
KIT="$(cd -P "$SELF/.." && pwd -P)"

# Marker strings — match research-sdd-install.sh splice conventions.
START_MARKER='# research-sdd:start'
END_MARKER='# research-sdd:end'

# Mutable globals — set by parse_args, read by phase functions.
dry=0
harness="all"
home_dir="${HOME:-/root}"
tier_binary=0; tier_pcap=0; tier_firmware=0; tier_vm=0
tier_pdf=0; tier_net=0; tier_dotnet=0; tier_latex=0

# Accumulators for final summary.
_baseline_ok=1
_heavy_failed=()
_needs_approval=()

# --------------------------------------------------------------------------
# Probes
# --------------------------------------------------------------------------
have()     { command -v "$1" >/dev/null 2>&1; }
apt_have() { dpkg -s "$1" >/dev/null 2>&1; }

# sudo_n: run non-interactively; return 100 if password is required (never hangs).
sudo_n() {
  if sudo -n true 2>/dev/null; then sudo -n "$@"; else return 100; fi
}

# --------------------------------------------------------------------------
# Output helpers
# --------------------------------------------------------------------------
emit_plan()    { printf '  PLAN            %s\n' "$1"; }
emit_already() { printf '  ALREADY         %s\n' "$1"; }
emit_ok()      { printf '  INSTALLED       %s\n' "$1"; }
emit_needs()   { printf '  NEEDS-APPROVAL  %s\n' "$1"; }
emit_failed()  { printf '  FAILED          %s\n' "$1" >&2; }

# --------------------------------------------------------------------------
# Debian/Ubuntu guard.
# SENTINEL-DEBIAN-CHECK: apt-get probe; gates all BASELINE apt work.
# --------------------------------------------------------------------------
check_debian() {
  if ! have apt-get; then  # SENTINEL-DEBIAN-CHECK
    printf 'install.sh: this installer targets Debian/Ubuntu (apt-get required)\n' >&2
    printf 'install.sh: detected system is not Debian/Ubuntu — aborting BASELINE\n' >&2
    return 1
  fi
}

# --------------------------------------------------------------------------
# apt_install — probe-before-install; sudo -n (never hangs).
# Records INSTALLED / ALREADY / FAILED / NEEDS-APPROVAL per package.
# --------------------------------------------------------------------------
apt_install() {
  local pkg="$1" rc
  if apt_have "$pkg"; then emit_already "$pkg (apt)"; return 0; fi
  if [ "$dry" -eq 1 ]; then emit_plan "apt-get install -y $pkg"; return 0; fi  # SENTINEL-APT-DRY
  rc=0
  sudo_n apt-get install -y -q "$pkg" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    emit_ok "$pkg (apt)"
  elif [ "$rc" -eq 100 ]; then
    emit_needs "sudo apt-get install -y $pkg"
    _needs_approval+=("$pkg"); return 3
  else
    emit_failed "$pkg (apt)"; return 1
  fi
}

# --------------------------------------------------------------------------
# splice_marker — idempotent marker-block splice into a shell profile file.
# $1 = target file (typically ~/.bashrc)
# $2 = block content (lines that go INSIDE the markers)
# Re-run: strips the existing managed block, then appends fresh content — idempotent.
# --------------------------------------------------------------------------
splice_marker() {
  local file="$1" content="$2" tmp body
  local _splice_is_dry="${dry:-0}"  # SENTINEL-DRY-RUN: mutate to 0 to verify guard bites
  if [ "$_splice_is_dry" -eq 1 ]; then
    emit_plan "splice ${START_MARKER}..${END_MARKER} block into ${file}"
    printf '%s\n' "$content" | sed 's/^/  | /'
    return 0
  fi
  tmp="$(mktemp)" || return 1
  mkdir -p "$(dirname "$file")"
  local _splice_has_existing=0  # SENTINEL-IDEMPOTENT: mutate to 1 to verify idempotency guard bites
  [ -f "$file" ] && grep -qF "$START_MARKER" "$file" 2>/dev/null && _splice_has_existing=1
  if [ "$_splice_has_existing" -eq 1 ]; then
    # Strip the first well-formed start..end pair; preserve everything else.
    # Orphan handling: if start has no matching end, flush the buffered content
    # back (preserving all user content) and exit 3 to signal the orphan.
    local _splice_aw=0
    awk -v start="$START_MARKER" -v end="$END_MARKER" '
      BEGIN { done=0; inblk=0; buf="" }
      {
        if (!done && !inblk && $0 == start) { inblk=1; buf=$0 ORS; next }
        if (inblk) {
          if ($0 == end) { inblk=0; done=1; buf=""; next }
          buf=buf $0 ORS; next
        }
        print
      }
      END { if (inblk) { printf "%s", buf; exit 3 } }
    ' "$file" > "$tmp" || _splice_aw=$?
    if [ "$_splice_aw" -eq 3 ]; then  # SENTINEL-ORPHAN-SKIP
      rm -f "$tmp"
      printf 'install.sh: WARNING malformed marker in %s (start without matching end) — file left untouched; remove the stray marker and re-run\n' "$file" >&2
      _needs_approval+=("bashrc-orphan: remove stray ${START_MARKER} from ${file}")
      return 3
    fi
  elif [ -f "$file" ]; then
    cat "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
  else
    : > "$tmp"
  fi
  body="$(cat "$tmp")"
  if [ -n "$body" ]; then
    printf '%s\n\n%s\n%s\n%s\n' "$body" "$START_MARKER" "$content" "$END_MARKER" > "$tmp"
  else
    printf '%s\n%s\n%s\n' "$START_MARKER" "$content" "$END_MARKER" > "$tmp"
  fi
  mv -f "$tmp" "$file"
}

# --------------------------------------------------------------------------
# node_ok — returns 0 when a usable Node.js ≥ 20 is already present.
# --------------------------------------------------------------------------
node_ok() {
  have node || return 1
  local v
  v="$(node --version 2>/dev/null | sed 's/^v//' | cut -d. -f1)"
  case "${v:-}" in ''|*[!0-9]*) return 1 ;; esac
  [ "$v" -ge 20 ]
}

# --------------------------------------------------------------------------
# install_nodejs — Node.js ≥ 20 via NodeSource APT keyring (never pipe-to-shell).
# --------------------------------------------------------------------------
install_nodejs() {
  if node_ok; then emit_already "nodejs (>=20)"; return 0; fi
  if [ "$dry" -eq 1 ]; then
    emit_plan "curl NodeSource GPG key → /etc/apt/keyrings/nodesource.gpg"
    emit_plan "add NodeSource apt source → /etc/apt/sources.list.d/nodesource.list"
    emit_plan "apt-get update && apt-get install -y nodejs"
    return 0
  fi
  local rc=0
  sudo_n true >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 100 ]; then
    emit_needs "NodeSource key + apt-source + apt-get install nodejs (sudo required)"
    _needs_approval+=("nodejs"); return 3
  fi
  local tmpkey
  tmpkey="$(mktemp)"
  if ! curl -fsSL "https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key" \
       -o "$tmpkey" 2>/dev/null; then
    rm -f "$tmpkey"; emit_failed "nodejs (NodeSource key download)"; return 1
  fi
  sudo -n mkdir -p /etc/apt/keyrings 2>/dev/null || true
  if ! sudo -n gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg "$tmpkey" 2>/dev/null; then
    rm -f "$tmpkey"; emit_failed "nodejs (NodeSource key import)"; return 1
  fi
  rm -f "$tmpkey"
  printf 'deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main\n' \
    | sudo -n tee /etc/apt/sources.list.d/nodesource.list >/dev/null
  sudo -n apt-get update -q >/dev/null 2>&1 || true
  rc=0
  sudo_n apt-get install -y -q nodejs >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    emit_ok "nodejs (NodeSource v20)"
  elif [ "$rc" -eq 100 ]; then
    emit_needs "sudo apt-get install -y nodejs"
    _needs_approval+=("nodejs"); return 3
  else
    emit_failed "nodejs (NodeSource)"; return 1
  fi
}

# --------------------------------------------------------------------------
# install_pipx — apt (Ubuntu 23.04+) with pip --user fallback.
# --------------------------------------------------------------------------
install_pipx() {
  if have pipx; then emit_already "pipx"; return 0; fi
  if [ "$dry" -eq 1 ]; then
    emit_plan "apt install pipx  OR  python3 -m pip install --user pipx && pipx ensurepath"
    return 0
  fi
  # Try apt first (Ubuntu 23.04+)
  local rc=0
  sudo_n apt-get install -y -q pipx >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    emit_ok "pipx (apt)"; return 0
  fi
  # Fallback: pip --user (blocked on Ubuntu 23.04+ by PEP 668 "externally-managed").
  local pip_rc=0
  python3 -m pip install --user -q pipx >/dev/null 2>&1 || pip_rc=$?
  if [ "$pip_rc" -eq 0 ]; then
    emit_ok "pipx (pip --user)"
    python3 -m pipx ensurepath >/dev/null 2>&1 || true
    return 0
  fi
  # pip --user failed — most likely PEP 668 on Ubuntu 23.04+ (externally managed env).
  emit_failed "pipx (apt needs sudo; pip --user blocked by PEP 668 on Ubuntu 23.04+ — grant sudo and re-run)"
  return 1
}

# --------------------------------------------------------------------------
# build_bashrc_block — emit the content lines for the ~/.bashrc marker section.
# --------------------------------------------------------------------------
build_bashrc_block() {
  local kit_path="$1"
  printf '%s\n%s\n%s\n%s\n%s\n%s\n%s' \
    "export RESEARCH_SDD_KIT=\"${kit_path}\"" \
    'export RESEARCH_HOME="${RESEARCH_HOME:-$HOME}"' \
    '# ensure ~/.local/bin is on PATH (pipx CLIs, frida-tools, etc.)' \
    'case ":${PATH}:" in' \
    '  *":${HOME}/.local/bin:"*) ;;' \
    '  *) export PATH="${PATH}:${HOME}/.local/bin" ;;' \
    'esac'
}

# --------------------------------------------------------------------------
# call_install_tool — invoke toolbelt/install-tool.sh and record outcome.
# --------------------------------------------------------------------------
call_install_tool() {
  local recipe="$1" rc=0
  if [ "$dry" -eq 1 ]; then emit_plan "install-tool.sh $recipe"; return 0; fi
  "$KIT/toolbelt/install-tool.sh" "$recipe" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) emit_ok "$recipe (install-tool.sh)" ;;
    3) emit_needs "install-tool.sh $recipe (sudo password or manual step required)"
       _needs_approval+=("$recipe") ;;
    *) emit_failed "$recipe (install-tool.sh rc=$rc)"
       _heavy_failed+=("$recipe") ;;
  esac
  return "$rc"
}

# --------------------------------------------------------------------------
# Phase 2 — HEAVY tiers (only the flags given; --all-heavy = all)
# --------------------------------------------------------------------------
phase_binary() {
  printf '\n[heavy: binary]\n'
  for pkg in binutils radare2 openjdk-21-jdk hexedit bvi bubblewrap; do
    apt_install "$pkg" || true
  done
  call_install_tool vineflower || true
  call_install_tool cfr        || true
  call_install_tool procyon    || true
  # Ghidra: not auto-installable — mandatory notice.
  printf '  NOTICE  Ghidra: download from https://ghidra-sre.org/ → install to /opt/ghidra_*\n'
  printf '  NOTICE    Then add to your profile: export GHIDRA_HOME=/opt/ghidra_<version>\n'
  printf '  NOTICE    bwrap MUST be root-owned /usr/bin/bwrap (apt-installed above, never brew)\n'
}

phase_pcap() {
  printf '\n[heavy: pcap]\n'
  for pkg in tshark tcpdump wireshark-common; do
    apt_install "$pkg" || true
  done
}

phase_firmware() {
  printf '\n[heavy: firmware]\n'
  for pkg in binwalk squashfs-tools yara; do
    apt_install "$pkg" || true
  done
  call_install_tool unblob || true
  printf '  NOTICE  kaitai-struct-compiler: no apt package — install via brew (macOS) or manually\n'
  printf '  NOTICE    https://kaitai.io/#download\n'
}

phase_vm() {
  printf '\n[heavy: vm]\n'
  for pkg in qemu-system qemu-user-static qemu-utils; do
    apt_install "$pkg" || true
  done
  # Docker: needs-approval path (apt channel + usermod + Desktop licensing).
  printf '  NOTICE  Docker: not auto-installed (Desktop licensing applies; requires usermod -aG docker $USER)\n'
  printf '  NOTICE    Install via: https://docs.docker.com/engine/install/ubuntu/\n'
}

phase_pdf() {
  printf '\n[heavy: pdf]\n'
  for pkg in poppler-utils tesseract-ocr pandoc; do
    apt_install "$pkg" || true
  done
  local venv="${RESEARCH_SDD_VENV:-${home_dir}/.local/share/research-sdd-tools/venv}"
  if [ "$dry" -eq 1 ]; then  # SENTINEL-PDF-DRY
    emit_plan "python3 -m venv ${venv}"
    emit_plan "pip install pymupdf4llm PyMuPDF into ${venv}"
    return 0
  fi
  if ! python3 -m venv "$venv" >/dev/null 2>&1; then
    emit_failed "python venv at ${venv}"; _heavy_failed+=("pdf-venv"); return 0
  fi
  if "$venv/bin/pip" install -q pymupdf4llm PyMuPDF >/dev/null 2>&1; then
    emit_ok "pymupdf4llm PyMuPDF (venv: ${venv})"
  else
    emit_failed "pymupdf4llm/PyMuPDF (venv install failed)"
    _heavy_failed+=("pymupdf4llm")
  fi
}

phase_net() {
  printf '\n[heavy: net]\n'
  for pkg in gdb gdb-multiarch strace ltrace; do
    apt_install "$pkg" || true
  done
  call_install_tool frida || true
}

phase_dotnet() {
  printf '\n[heavy: dotnet]\n'
  if [ "$dry" -eq 1 ]; then
    emit_plan "download packages-microsoft-prod.deb → dpkg -i"
    emit_plan "apt-get update && apt-get install -y dotnet-sdk-8.0"
    emit_plan "install-tool.sh ilspycmd"
    emit_plan "apt-get install powershell (requires Microsoft apt channel)"
    return 0
  fi
  local lsb_rel ms_deb rc=0
  lsb_rel="$(lsb_release -rs 2>/dev/null || true)"
  if [ -n "$lsb_rel" ]; then
    ms_deb="$(mktemp --suffix=.deb)"
    if curl -fsSL \
       "https://packages.microsoft.com/config/ubuntu/${lsb_rel}/packages-microsoft-prod.deb" \
       -o "$ms_deb" 2>/dev/null; then
      sudo_n dpkg -i "$ms_deb" >/dev/null 2>&1 || rc=$?
      [ "$rc" -eq 100 ] && {
        emit_needs "sudo dpkg -i packages-microsoft-prod.deb (Microsoft apt channel)"
        _needs_approval+=("packages-microsoft-prod")
      }
      sudo_n apt-get update -q >/dev/null 2>&1 || true
    else
      emit_needs "Microsoft apt channel (download failed — add manually)"
      _needs_approval+=("packages-microsoft-prod")
    fi
    rm -f "$ms_deb"
  else
    emit_needs "lsb_release unavailable — install packages-microsoft-prod.deb manually"
    _needs_approval+=("packages-microsoft-prod")
  fi
  apt_install dotnet-sdk-8.0 || true
  call_install_tool ilspycmd  || true
  apt_install powershell      || true   # note: requires the Microsoft channel above
}

phase_latex() {
  printf '\n[heavy: latex]\n'
  for pkg in texlive-latex-base texlive-pictures latexmk; do
    apt_install "$pkg" || true
  done
}

# --------------------------------------------------------------------------
# Argument parsing
# --------------------------------------------------------------------------
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --harness)       harness="${2:?harness value required}"; shift 2 ;;
      --home)          home_dir="${2:?home value required}"; shift 2 ;;
      --dry-run)       dry=1; shift ;;
      --with-binary)   tier_binary=1; shift ;;
      --with-pcap)     tier_pcap=1; shift ;;
      --with-firmware) tier_firmware=1; shift ;;
      --with-vm)       tier_vm=1; shift ;;
      --with-pdf)      tier_pdf=1; shift ;;
      --with-net)      tier_net=1; shift ;;
      --with-dotnet)   tier_dotnet=1; shift ;;
      --with-latex)    tier_latex=1; shift ;;
      --all-heavy)
        tier_binary=1; tier_pcap=1; tier_firmware=1; tier_vm=1
        tier_pdf=1; tier_net=1; tier_dotnet=1; tier_latex=1; shift ;;
      -h|--help)
        sed -n '3,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        exit 0 ;;
      *)
        printf 'install.sh: unknown argument "%s"\n' "$1" >&2
        printf 'install.sh: use --help for usage\n' >&2
        return 2 ;;
    esac
  done
}

# --------------------------------------------------------------------------
# main
# --------------------------------------------------------------------------
main() {
  parse_args "$@" || exit $?

  # ---- Phase 1: BASELINE --------------------------------------------------
  printf '[baseline]\n'

  if ! check_debian; then
    exit 1
  fi

  for pkg in git python3 python3-pip python3-venv jq curl wget shellcheck build-essential; do
    apt_install "$pkg" || _baseline_ok=0
  done

  install_nodejs || _baseline_ok=0
  install_pipx   || _baseline_ok=0

  # Splice env vars and PATH into ~/.bashrc via idempotent marker block.
  local bashrc="${home_dir}/.bashrc"
  local block
  block="$(build_bashrc_block "$KIT")"
  printf '\n  splicing env block into %s\n' "$bashrc"
  splice_marker "$bashrc" "$block" || _baseline_ok=0

  # Wire the skill into the requested harness.
  printf '\n  wiring skill into harness: %s\n' "$harness"
  if [ "$dry" -eq 1 ]; then
    emit_plan "research-sdd-install.sh --harness $harness --home $home_dir --dry-run"
  else
    "$SELF/research-sdd-install.sh" --harness "$harness" --home "$home_dir" || _baseline_ok=0  # SENTINEL-SKILL-DEPLOY
  fi

  # SDD-agents notice — informational only; never blocks or fails.
  local agent_file="${home_dir}/.claude/agents/sdd-apply.md"
  if [ ! -f "$agent_file" ]; then  # SENTINEL-AGENTS-NOTICE
    printf '\n  OPTIONAL  SDD-orchestration agents not found at %s\n' "$agent_file"
    printf '  OPTIONAL  The core research loop works without them.\n'
    printf '  OPTIONAL  They are typically provided by gentle-ai (the orchestration harness).\n'
    printf '  OPTIONAL  See: https://github.com/Gentleman-Programming/gentle-ai\n'
  fi

  # ---- Phase 2: HEAVY -----------------------------------------------------
  [ "$tier_binary"   -eq 1 ] && phase_binary
  [ "$tier_pcap"     -eq 1 ] && phase_pcap
  [ "$tier_firmware" -eq 1 ] && phase_firmware
  [ "$tier_vm"       -eq 1 ] && phase_vm
  [ "$tier_pdf"      -eq 1 ] && phase_pdf
  [ "$tier_net"      -eq 1 ] && phase_net
  [ "$tier_dotnet"   -eq 1 ] && phase_dotnet
  [ "$tier_latex"    -eq 1 ] && phase_latex

  # ---- Phase 3: SELF-VERIFY -----------------------------------------------
  printf '\n[verify]\n'
  local detect="$KIT/toolbelt/detect-tools.sh"
  if [ -f "$detect" ]; then
    local av=0 mi=0 _detect_ok=1
    if [ "$dry" -eq 0 ]; then
      # Run detect-tools.sh and read counts from the cache file it writes.
      # --quiet suppresses the per-tool table on stdout; the cache file holds the rows.
      # PROBE_FAILED counts as missing — include it in the MISSING/UNUSABLE tally.
      local cache_file="${RESEARCH_TOOLS_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/research-sdd/tool-capabilities.txt}"
      bash "$detect" --quiet 2>/dev/null || true
      if [ -f "$cache_file" ]; then
        local av_rc=0 mi_rc=0
        local _av_re='^[[:space:]]+[^[:space:]].*[[:space:]]AVAILABLE([[:space:]]|$)'  # SENTINEL-GREP-AV-ANCHOR
        av="$(grep -cE "$_av_re" "$cache_file" 2>/dev/null)" || av_rc=$?
        mi="$(grep -cE '^[[:space:]]+[^[:space:]].*[[:space:]](MISSING|UNUSABLE|PROBE_FAILED)([[:space:]]|$)' "$cache_file" 2>/dev/null)" || mi_rc=$?
        if [ "$av_rc" -ge 2 ] || [ "$mi_rc" -ge 2 ]; then
          printf '  DEGRADED  grep error reading cache at %s\n' "$cache_file"
          _detect_ok=0; av=0; mi=0
        elif [ "${av:-0}" -eq 0 ] && [ "${mi:-0}" -eq 0 ]; then
          printf '  DEGRADED  cache exists but reports zero tools (empty or unrecognized format)\n'
          _detect_ok=0
        fi
      else
        printf '  DEGRADED  detect-tools.sh ran but cache not found at %s\n' "$cache_file"
        _detect_ok=0
      fi
    else
      emit_plan "detect-tools.sh --quiet (skipped in dry-run)"
    fi
    local _bl_status
    [ "$_baseline_ok" -eq 1 ] && _bl_status="BASELINE OK" || _bl_status="BASELINE DEGRADED"
    if [ "$dry" -eq 1 ]; then
      printf '  SUMMARY  %s | inventory skipped (dry-run)\n' "$_bl_status"
    elif [ "$_detect_ok" -eq 1 ]; then
      printf '  SUMMARY  %s | AVAILABLE: %d | MISSING/UNUSABLE: %d\n' "$_bl_status" "$av" "$mi"
    else
      printf '  SUMMARY  %s | tool inventory degraded (see DEGRADED lines above)\n' "$_bl_status"
    fi
  else
    printf '  SUMMARY  detect-tools.sh not found — skipping tool inventory\n'
  fi

  if [ "${#_heavy_failed[@]}" -gt 0 ]; then
    printf '\n  HEAVY FAILED (check logs above):\n'
    local item
    for item in "${_heavy_failed[@]}"; do printf '    - %s\n' "$item"; done
  fi

  if [ "${#_needs_approval[@]}" -gt 0 ]; then
    printf '\n  NEEDS-APPROVAL (re-run with sudo access or install manually):\n'
    for item in "${_needs_approval[@]}"; do printf '    - %s\n' "$item"; done
  fi

  if [ "$_baseline_ok" -eq 1 ]; then
    printf '\nDone. Reload your shell:  source %s\n' "$bashrc"
    return 0
  else
    if [ "${#_needs_approval[@]}" -gt 0 ]; then
      printf '\nBASELINE incomplete — review NEEDS-APPROVAL lines above and re-run.\n' >&2
    else
      printf '\nBASELINE had failures — review FAILED lines above.\n' >&2
    fi
    return 1
  fi
}

# --------------------------------------------------------------------------
# Entry point — allow sourcing for unit tests (main is skipped when sourced).
# --------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
