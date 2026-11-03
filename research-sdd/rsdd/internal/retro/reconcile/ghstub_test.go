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
//	list-<state>.hang          the call sleeps 5 s before answering (to meet RSDD_GH_TIMEOUT); only the port bounds gh
//
// The stub is as strict as the old bash stub was: a flag it does not know, a --json field outside
// ghJSONFields, a --limit that is not a positive integer, a stray positional argument, or any other subcommand
// exits 98 and is written to box/gh.reject, which runGo turns into a test failure (checkToolCalls). The accepted
// shapes are exactly the ones the port and the legacy script make.
//
// GH_STUB_OLD_GH=1 makes a list asking for the stateReason field fail the way gh 2.45 does (not counted).
const ghStubScript = `#!@BASH@
B='@BOX@'
G="$B/gh"
printf '%s\n' "gh $*" >> "$B/gh.log"
reject() { printf '%s\n' "$1: gh $*" >> "$B/gh.reject"; echo "gh stub: $1" >&2; exit 98; }
nextn() { local f="$G/$1.n" n; n=$(( $(cat "$f" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$f"; echo "$n"; }
answer() { # <kind> <n> <data-file-or-empty> <jq>
  local rc=0 f
  [ ! -f "$G/$1.hang" ] || exec '@SLEEP@' 5
  for f in "$G/$1.rc.$2" "$G/$1.rc"; do [ -f "$f" ] && { rc="$(cat "$f")"; break; }; done
  if [ "$rc" != 0 ]; then [ ! -f "$G/$1.err" ] || cat "$G/$1.err" >&2; exit "$rc"; fi
  [ -f "$3" ] || { printf '[]' > "$B/empty.json"; set -- "$1" "$2" "$B/empty.json" "$4"; }
  jq -r "$4" "$3"
}
if [ "$1 $2" = "auth status" ]; then exit "$(cat "$G/auth.rc" 2>/dev/null || echo 0)"; fi
if [ "$1 $2" = "issue list" ]; then
  shift 2; state=open; jqp=''; json=''
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo|--search) [ $# -ge 2 ] || reject "$1 needs a value"; shift ;;
      --state) [ $# -ge 2 ] || reject "$1 needs a value"; state=$2; shift ;;
      --jq) [ $# -ge 2 ] || reject "$1 needs a value"; jqp=$2; shift ;;
      --json) [ $# -ge 2 ] || reject "$1 needs a value"; json=$2; shift ;;
      --limit) [ $# -ge 2 ] || reject "$1 needs a value"
        case "$2" in ''|*[!0-9]*) reject "--limit $2 is not a number" ;; esac
        [ $((10#$2)) -gt 0 ] || reject "--limit $2 is not positive"; shift ;;
      *) reject "unknown argument $1" ;;
    esac
    shift
  done
  case "$state" in open|closed) ;; *) reject "unknown --state $state" ;; esac
  oldifs=$IFS; IFS=,; for f in $json; do case "$f" in @FIELDS@) ;; *) IFS=$oldifs; reject "unknown --json field $f" ;; esac; done; IFS=$oldifs
  if [ -n "${GH_STUB_OLD_GH:-}" ]; then case ",$json," in *,stateReason,*) echo 'Unknown JSON field: "stateReason"' >&2; exit 1 ;; esac; fi
  n="$(nextn "list-$state")"
  d="$G/$state.$n.json"; [ -f "$d" ] || d="$G/$state.json"
  answer "list-$state" "$n" "$d" "$jqp"
  exit 0
fi
if [ "$1" = api ]; then
  shift; jqp=''; urls=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --paginate) ;;
      --jq) [ $# -ge 2 ] || reject "--jq needs a value"; jqp=$2; shift ;;
      -*) reject "unknown argument $1" ;;
      *) urls=$((urls + 1)); case "$1" in repos/*/*/*) ;; *) reject "unexpected endpoint $1" ;; esac ;;
    esac
    shift
  done
  [ "$urls" = 1 ] || reject "gh api takes exactly one endpoint"
  n="$(nextn api)"
  answer api "$n" "$G/api.json" "$jqp"
  exit 0
fi
reject "unexpected call"
`

// ghJSONFields are the --json fields of the calls the audit makes (the fields `gh issue list --json` knows).
var ghJSONFields = []string{"body", "stateReason", "comments", "number"}

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
	sleep, err := exec.LookPath("sleep")
	if err != nil {
		t.Fatalf("the live cases need sleep for the hanging stub gh: %v", err)
	}
	rep := strings.NewReplacer("@BASH@", bash, "@SLEEP@", sleep, "@BOX@", root, "@FIELDS@", strings.Join(ghJSONFields, "|"))
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
