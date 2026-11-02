package verify

// skillDriftHelp is what `verify-skill-drift.sh --help` prints: lines 3-32 of the script with the leading
// "# " stripped. A shim cannot print its own header, so the text lives here; the differential test pins it
// byte for byte against the frozen script.
const skillDriftHelp = `
Usage: verify-skill-drift.sh [--all | --harness <h>] [--home <dir>] [--profile <name>]
  --all      check every harness registered in adapters.sh (RESEARCH_SDD_HARNESSES)
             mutually exclusive with --harness; used by the SessionStart hook
  --harness  single harness to check (default: claude)
  --home     home dir used to resolve deployed skill paths (default: $HOME)
  --profile  prompt profile to compare the deployed skill against (kit issue #993 WU2):
             flag > $RESEARCH_SDD_PROFILE env > this harness's per-harness default
             (adapters.sh _RSDD_DEFAULT_PROFILE). profile "claude" compares against the kit
             source directly, byte-exact, exactly as before this flag existed. Any other
             profile is re-rendered into a throwaway temp dir (never the kit, never $home) via
             render-profile.sh and compared against THAT — propose-never-apply extended to
             renders. Ignored (profile "claude" behaviour only) when adapters.sh predates this
             feature (no rsdd_resolve_profile/rsdd_valid_profile) — e.g. a test fixture that
             defines its own minimal adapters.sh.

Exit codes for --all:
  0  all installed harnesses in-sync or all absent (absent is normal — SILENT)
  1  one or more installed harnesses diverged
  2  one or more harnesses could not be checked (src missing, adapters.sh unavailable,
     HOME unset or empty and no --home given, dangling symlink at deployed path)

Exit codes for single-harness mode:
  0  in-sync      deployed SKILL.md matches kit source byte-for-byte (SILENT)
  1  diverged     deployed SKILL.md differs from kit source
  2  could-not-run adapters.sh/kit source missing or unreadable; harness unknown;
                  HOME unset or empty and no --home given;
                  dangling symlink at deployed path
  3  absent       no deployed skill found (harness not installed / never run)

`
