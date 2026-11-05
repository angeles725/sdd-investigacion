package scoreloop

import (
	"encoding/json"
	"errors"
	"fmt"
	"os/exec"
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/proc"
)

// jq is needed only for a RSDD_OPERATOR_INPUT_JQ / RSDD_COMPACT_JQ override: the built-in filters run in Go.

const (
	jqTimeout  = 2 * time.Minute
	jqMaxBytes = 256 << 20
)

// jqRunner evaluates the operator and compaction filters over a transcript file, one verdict per record that has a
// timestamp and a type (by position among the file's values).
type jqRunner func(path string, cfg *Config) (map[int]verdict, error)

var errJQMissing = errors.New("jq not found in PATH")

// jqProgram wraps the two filters: per eligible record, the list of each filter's outputs.
func jqProgram(cfg *Config) string {
	op, cx := cfg.OperatorJQ, cfg.CompactJQ
	if op == "" {
		op = defaultOperatorJQ
	}
	if cx == "" {
		cx = defaultCompactJQ
	}
	return fmt.Sprintf(`[ to_entries[] | .key as $i | .value
  | (.timestamp // empty) as $t | (.type // empty) as $y
  | {i: $i, op: [ (%s) ], cx: [ (%s) ]} ]`, op, cx)
}

// newJQRunner returns the runner that execs jq with env as its environment.
func newJQRunner(env []string) jqRunner { return jqRunnerWith(env, jqTimeout, jqMaxBytes) }

// jqRunnerWith is newJQRunner with explicit bounds (a unit test shrinks them).
func jqRunnerWith(env []string, timeout time.Duration, maxBytes int) jqRunner {
	return func(path string, cfg *Config) (map[int]verdict, error) {
		res, err := proc.Run(proc.Spec{
			Argv: []string{"jq", "-c", "-s", jqProgram(cfg), path}, Env: env, Timeout: timeout, MaxBytes: maxBytes,
		})
		if errors.Is(err, exec.ErrNotFound) {
			return nil, errJQMissing
		}
		if err != nil || res.Reason != "" || res.ReturnCode != 0 {
			return nil, errors.New("jq failed")
		}
		return parseVerdicts(res.Stdout)
	}
}

// parseVerdicts reads jq's output. A filter that yielded no value drops its record (as the legacy pipeline did);
// one that yielded several is refused (the legacy pipeline duplicated the record).
func parseVerdicts(out []byte) (map[int]verdict, error) {
	var entries []struct {
		I  int   `json:"i"`
		Op []any `json:"op"`
		Cx []any `json:"cx"`
	}
	if err := json.Unmarshal(out, &entries); err != nil {
		return nil, err
	}
	verdicts := make(map[int]verdict, len(entries))
	for _, e := range entries {
		if len(e.Op) == 0 || len(e.Cx) == 0 {
			continue
		}
		if len(e.Op) > 1 || len(e.Cx) > 1 {
			return nil, errors.New("jq filter yielded several values for one record")
		}
		verdicts[e.I] = verdict{operator: e.Op[0] == true, compact: e.Cx[0] == true}
	}
	return verdicts, nil
}

// setJQFailure records why the override evaluation failed: jq absent or a parse failure.
func (f *Facts) setJQFailure(err error) {
	if errors.Is(err, errJQMissing) {
		f.MissingTool = "jq"
		return
	}
	f.ParseFailed = true
}
