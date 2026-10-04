#!/usr/bin/env bash
# jvm-offline-probe.sh — was `jvm-callgraph.sh bootstrap` ever run on this host? (kit issue #1588)
# Sourced (never executed); defines: rsdd_jvm_build_verdict.
#
# What the probe checks (coarse, environment-only; no POM parsing, no build-log matching):
#   the local Maven repository directory exists AND contains at least one
#   org/apache/maven/plugins/maven-compiler-plugin/<version>/ directory holding a *.jar.
#   `bootstrap` (go-offline package) downloads that plugin, bootstrap writes no marker of its own,
#   and an offline build cannot work without it.
# What it deliberately does NOT check:
#   - that the plugin version matches the POM, or that every declared dependency/plugin is present
#     (a version bump without a re-bootstrap is a REAL gap: the build then fails and S1 FAILs so the
#     operator sees it);
#   - a custom <localRepository> in settings.xml (point RSDD_M2_REPO at it);
#   - the build log (a POM typo reads the same as a missing artifact there).
# Verdict is therefore SKIP only when the host provably never bootstrapped.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "jvm-offline-probe.sh is a source-only helper; do not execute it directly." >&2
  exit 1
fi

# rsdd_jvm_build_verdict [REPO]
#   Prints exactly one typed line and returns:
#     skip: <reason>                    rc 0  bootstrap never ran here (SKIP)
#     fail: bootstrap present           rc 1  a build failure is a real defect or a stale bootstrap (FAIL)
#     fail: probe error: <why>          rc 2  the probe could not look (FAIL, never SKIP)
#   REPO defaults to ${RSDD_M2_REPO:-${MAVEN_REPO_LOCAL:-$HOME/.m2/repository}}.
if ! declare -F rsdd_jvm_build_verdict >/dev/null 2>&1; then
  rsdd_jvm_build_verdict() {
    local repo="${1:-${RSDD_M2_REPO:-${MAVEN_REPO_LOCAL:-${HOME:-}/.m2/repository}}}"
    local plugdir="$repo/org/apache/maven/plugins/maven-compiler-plugin" d
    if [ -z "${HOME:-}" ] && [ -z "${1:-}${RSDD_M2_REPO:-}${MAVEN_REPO_LOCAL:-}" ]; then
      echo "fail: probe error: no HOME and no repo path given"; return 2
    fi
    if [ -e "$repo" ] && [ ! -d "$repo" ]; then
      echo "fail: probe error: local repo is not a directory: $repo"; return 2
    fi
    if [ ! -d "$repo" ]; then
      echo "skip: local Maven repo absent ($repo)"; return 0
    fi
    for d in "$plugdir"/*/; do
      [ -d "$d" ] || continue
      if compgen -G "$d*.jar" >/dev/null; then echo "fail: bootstrap present"; return 1; fi
    done
    echo "skip: no maven-compiler-plugin jar under $plugdir"; return 0
  }
fi
