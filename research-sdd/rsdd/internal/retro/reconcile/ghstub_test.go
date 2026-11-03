package reconcile

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// ghStubScript is the stub gh (and, below, sleep) the live cases put first on PATH. It logs every call to
// box/gh.log as "gh <args>" and answers from box/gh/ files, running the caller's own --jq through real jq, so a
// mistake in a jq program shows in the output. The same stub serves the legacy script and the port.
//
//	auth.rc                    exit code of `gh auth status` (default 0)
//	<state>.json, <state>.<n>.json   the JSON array the n-th `issue list --state <state>` call answers (default [])
//	list-<state>.rc, .rc.<n>   exit code of every / of the n-th such call; list-<state>.err is its stderr
//	api.json, api.rc, api.rc.<n>, api.err   the same for `gh api`
//
// GH_STUB_OLD_GH=1 makes a list asking for the stateReason field fail the way gh 2.45 does (not counted).
const ghStubScript = `#!@BASH@
B='@BOX@'
G="$B/gh"
printf '%s\n' "gh $*" >> "$B/gh.log"
nextn() { local f="$G/$1.n" n; n=$(( $(cat "$f" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$f"; echo "$n"; }
answer() { # <kind> <n> <data-file-or-empty> <jq>
  local rc=0 f
  for f in "$G/$1.rc.$2" "$G/$1.rc"; do [ -f "$f" ] && { rc="$(cat "$f")"; break; }; done
  if [ "$rc" != 0 ]; then cat "$G/$1.err" 2>/dev/null >&2; exit "$rc"; fi
  [ -f "$3" ] || { printf '[]' > "$B/empty.json"; set -- "$1" "$2" "$B/empty.json" "$4"; }
  jq -r "$4" "$3"
}
if [ "$1 $2" = "auth status" ]; then exit "$(cat "$G/auth.rc" 2>/dev/null || echo 0)"; fi
if [ "$1 $2" = "issue list" ]; then
  shift 2; state=open; jqp=''; json=''
  while [ $# -gt 0 ]; do
    case "$1" in --state) state=$2; shift ;; --jq) jqp=$2; shift ;; --json) json=$2; shift ;; esac
    shift
  done
  if [ -n "${GH_STUB_OLD_GH:-}" ]; then case ",$json," in *,stateReason,*) echo 'Unknown JSON field: "stateReason"' >&2; exit 1 ;; esac; fi
  n="$(nextn "list-$state")"
  d="$G/$state.$n.json"; [ -f "$d" ] || d="$G/$state.json"
  answer "list-$state" "$n" "$d" "$jqp"
  exit 0
fi
if [ "$1" = api ]; then
  jqp=''; while [ $# -gt 0 ]; do [ "$1" = --jq ] && jqp=$2; shift; done
  n="$(nextn api)"
  answer api "$n" "$G/api.json" "$jqp"
  exit 0
fi
echo "gh stub: unexpected call: $*" >&2; exit 99
`

const sleepStubScript = `#!@BASH@
printf '%s\n' "$1" >> '@BOX@/sleep.log'
`

// writeStubs installs box/bin/gh and box/bin/sleep and the stub's data files.
func writeStubs(t *testing.T, root string, files map[string]string) {
	t.Helper()
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Fatalf("the live cases need bash for the stub gh: %v", err)
	}
	if _, err := exec.LookPath("jq"); err != nil {
		t.Fatalf("the live cases need jq for the stub gh: %v", err)
	}
	rep := strings.NewReplacer("@BASH@", bash, "@BOX@", root)
	mustMkdir(t, filepath.Join(root, "bin"))
	mustMkdir(t, filepath.Join(root, "gh"))
	for name, script := range map[string]string{"gh": ghStubScript, "sleep": sleepStubScript} {
		if err := os.WriteFile(filepath.Join(root, "bin", name), []byte(rep.Replace(script)), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	for name, content := range files {
		mustWrite(t, filepath.Join(root, "gh", name), strings.ReplaceAll(content, "@BOX@", root))
	}
}
