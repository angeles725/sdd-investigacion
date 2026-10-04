#!/usr/bin/env bash
# jvm-offline-probe.sh — classify a failed offline `mvn package` of jvm-callgraph from the
# ENVIRONMENT, never from the build log (kit issue #1588).
# Sourced (never executed); defines: rsdd_jvm_build_verdict.
#
# A log pattern such as "could not be resolved" is ALSO what a POM typo or an unbootstrapped
# version bump produces, so it cannot tell "this host never ran `jvm-callgraph.sh bootstrap`"
# from "the build is broken". The probe instead parses every groupId/artifactId/version the POM
# declares (dependencies and build plugins) and looks for each in the local Maven repository
# (<repo>/<group as path>/<artifact>/<version>/<artifact>-<version>.jar). Any absent coordinate means the bootstrap
# provably did not populate this host.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "jvm-offline-probe.sh is a source-only helper; do not execute it directly." >&2
  exit 1
fi

# rsdd_jvm_build_verdict POM [REPO]
#   Prints exactly one typed line and returns:
#     skip: <group:artifact:version>   rc 0  coordinate absent from REPO — bootstrap not run (SKIP)
#     fail: bootstrap present          rc 1  every declared coordinate is present — a failing build
#                                            is a real defect (FAIL)
#     fail: probe error: <why>         rc 2  POM unreadable / no coordinates / python3 missing —
#                                            the probe could not look (FAIL, never SKIP)
#   REPO defaults to ${RSDD_M2_REPO:-${MAVEN_REPO_LOCAL:-$HOME/.m2/repository}}. A custom
#   <localRepository> in settings.xml is not modelled: point RSDD_M2_REPO at it.
if ! declare -F rsdd_jvm_build_verdict >/dev/null 2>&1; then
  rsdd_jvm_build_verdict() {
    local pom="${1:-}" repo="${2:-${RSDD_M2_REPO:-${MAVEN_REPO_LOCAL:-${HOME:-}/.m2/repository}}}"
    command -v python3 >/dev/null 2>&1 || { echo "fail: probe error: python3 not found"; return 2; }
    [ -f "$pom" ] && [ -r "$pom" ] || { echo "fail: probe error: POM unreadable: $pom"; return 2; }
    local out rc
    out="$(python3 - "$pom" "$repo" <<'PY'
import os, sys
import xml.etree.ElementTree as ET
pom, repo = sys.argv[1], sys.argv[2]
try:
    root = ET.parse(pom).getroot()
except Exception as e:
    print("ERR:POM not parseable: %s" % e); sys.exit(2)
ns = root.tag[:root.tag.index("}") + 1] if root.tag.startswith("{") else ""
coords = []
for tag in ("dependency", "plugin"):
    for el in root.iter(ns + tag):
        g, a, v = (el.findtext(ns + k) for k in ("groupId", "artifactId", "version"))
        if tag == "plugin" and a and not g:
            g = "org.apache.maven.plugins"
        if g and a and v:
            coords.append((g.strip(), a.strip(), v.strip()))
if not coords:
    print("ERR:no groupId/artifactId/version coordinates found in POM"); sys.exit(2)
for g, a, v in coords:
    if not os.path.isfile(os.path.join(repo, *g.split("."), a, v, "%s-%s.jar" % (a, v))):
        print("MISSING:%s:%s:%s (not in %s)" % (g, a, v, repo)); sys.exit(0)
print("PRESENT"); sys.exit(0)
PY
)"; rc=$?
    case "$out" in
      MISSING:*) echo "skip: ${out#MISSING:}"; return 0 ;;
      PRESENT)   echo "fail: bootstrap present"; return 1 ;;
      ERR:*)     echo "fail: probe error: ${out#ERR:}"; return 2 ;;
      *)         echo "fail: probe error: unexpected probe output (rc=$rc)"; return 2 ;;
    esac
  }
fi
