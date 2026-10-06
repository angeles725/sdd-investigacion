#!/usr/bin/env bash
# tests/lib/jvm-offline-probe.sh — TEST-ONLY scaffolding (moved from lib/, kit issue #1821 item 3): was `jvm-callgraph.sh bootstrap` ever run on this host? (kit issue #1588)
# Sourced (never executed); defines: rsdd_jvm_build_verdict.
#
# What the probe checks (coarse, environment-only; no POM parsing, no build-log matching):
#   some `_remote.repositories` file under
#   <local repo>/org/apache/maven/plugins/maven-compiler-plugin/ names the mirror id declared in
#   jvm-callgraph/maven-central-settings.xml (the id is read from that file, not hardcoded here).
#   `bootstrap` runs with that settings file, so every artifact it fetches is tagged with that id;
#   a compiler-plugin cached by any OTHER Maven project carries a different id (or none) and does
#   NOT count — a host-wide cached plugin is not evidence that bootstrap ran.
# What it deliberately does NOT check:
#   - that the plugin version matches the POM, or that every declared dependency/plugin is present
#     (a version bump without a re-bootstrap is a REAL gap: the build then fails and S1 FAILs so the
#     operator sees it);
#   - a custom <localRepository> in settings.xml (point RSDD_M2_REPO at it);
#   - the build log (a POM typo reads the same as a missing artifact there).
# Verdict is SKIP only when the host provably never bootstrapped.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "jvm-offline-probe.sh is a source-only helper; do not execute it directly." >&2
  exit 1
fi

_RSDD_JVM_PROBE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# rsdd_jvm_build_verdict [REPO [SETTINGS]]
#   Prints exactly one typed line and returns:
#     skip: <reason>                    rc 0  bootstrap never ran here (SKIP)
#     fail: bootstrap present           rc 1  a build failure is a real defect or a stale bootstrap (FAIL)
#     fail: probe error: <why>          rc 2  the probe could not look (FAIL, never SKIP)
#   REPO defaults to ${RSDD_M2_REPO:-${MAVEN_REPO_LOCAL:-$HOME/.m2/repository}}; SETTINGS defaults
#   to the toolbelt's jvm-callgraph/maven-central-settings.xml.
if ! declare -F rsdd_jvm_build_verdict >/dev/null 2>&1; then
  rsdd_jvm_build_verdict() {
    local repo="${1:-${RSDD_M2_REPO:-${MAVEN_REPO_LOCAL:-}}}"
    local settings="${2:-$_RSDD_JVM_PROBE_DIR/../../jvm-callgraph/maven-central-settings.xml}"
    [ -n "$repo" ] || repo="${HOME:-}/.m2/repository"
    if [ -z "${HOME:-}" ] && [ -z "${1:-}${RSDD_M2_REPO:-}${MAVEN_REPO_LOCAL:-}" ]; then
      echo "fail: probe error: no HOME and no repo path given"; return 2
    fi
    [ -r "$settings" ] || { echo "fail: probe error: settings unreadable: $settings"; return 2; }
    local id
    id="$(sed -n 's:.*<id>\(.*\)</id>.*:\1:p;T;q' "$settings")"
    [ -n "$id" ] || { echo "fail: probe error: no mirror <id> in $settings"; return 2; }
    if [ -e "$repo" ] && [ ! -d "$repo" ]; then
      echo "fail: probe error: local repo is not a directory: $repo"; return 2
    fi
    if [ ! -d "$repo" ]; then
      echo "skip: local Maven repo absent ($repo)"; return 0
    fi
    local plugdir="$repo/org/apache/maven/plugins/maven-compiler-plugin" rc=0
    if [ -d "$plugdir" ]; then
      grep -rqsF --include=_remote.repositories -e ">$id=" "$plugdir" || rc=$?
      case "$rc" in
        0) echo "fail: bootstrap present"; return 1 ;;
        1) ;;
        *) echo "fail: probe error: grep failed (rc=$rc) under $plugdir"; return 2 ;;
      esac
    fi
    echo "skip: no maven-compiler-plugin artifact tagged with mirror id '$id' under $plugdir"; return 0
  }
fi
