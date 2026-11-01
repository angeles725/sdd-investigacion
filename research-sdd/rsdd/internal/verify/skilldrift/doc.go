// Package skilldrift ports research-sdd/toolbelt/verify-skill-drift.sh and verify-skill-drift-hook.sh (kit issue #2365):
//
//	rsdd verify skill-drift      [--all | --harness <h>] [--home <dir>] [--profile <name>]
//	rsdd verify skill-drift-hook
//
// The first detects a deployed SKILL.md that diverged from the kit source; the second is the SessionStart hook that runs the
// first with --all, then `research-sdd-install.sh --verify` and the kit-staleness check, and emits the findings as
// additionalContext. Both are byte-identical to the scripts (frozen in testdata/legacy, sha-pinned) except for the
// divergences listed in intended.go.
//
// Where the scripts find the kit: a binary cannot see the shim's directory, so the shims export RSDD_TOOLBELT_DIR (their own
// physical directory, resolved by the RSDD-SELF-DIR idiom) before they exec. Without it the commands report a typed
// could-not-run, never a guess.
//
// Exec seam (declared, kit issue #2365): install/adapters.sh is not ported here. Its bash functions (rsdd_field,
// rsdd_resolve_profile, rsdd_valid_profile and the RESEARCH_SDD_HARNESSES list) are evaluated by `bash` in adapters.go, and the
// profile re-render runs the kit's render-profile.sh (render.go). Nothing else is shelled out.
package skilldrift
