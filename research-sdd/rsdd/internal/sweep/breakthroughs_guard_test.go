package sweep

import (
	"bytes"
	"encoding/json"
	"io"
	"strings"
	"testing"
)

// A panic inside the breakthroughs hook must still reach the session as the could-not-run envelope (CLAUDE.md
// section 7, kit issue #2610), and as exactly ONE JSON object whenever it strikes: before any output (the
// environment is read while TARGETS.md resolves) or late, after the sweep already printed lines (the read of a
// block file). The sweep exits 1 only when it could not run, so the panic shares that header and needs no flag.

// jsonObjects decodes every JSON object of out.
func jsonObjects(t *testing.T, out string) []map[string]any {
	t.Helper()
	var all []map[string]any
	dec := json.NewDecoder(strings.NewReader(out))
	for {
		var o map[string]any
		err := dec.Decode(&o)
		if err == io.EOF {
			return all
		}
		if err != nil {
			t.Fatalf("stdout is not a stream of JSON objects: %v\n%s", err, out)
		}
		all = append(all, o)
	}
}

func runPanickingBTHook(t *testing.T, s func(w *world) (read readFunc)) (ctx, stdout string) {
	t.Helper()
	w := newWorld(t)
	a := w.tgt("targetA")
	w.block(a, "pfx-block1.md", true)
	w.targets(w.root+"/gone", a) // the absent target prints before the block read panics
	w.btLedger()
	var out, errb bytes.Buffer
	st := w.stdio(&out, &errb)
	read := s(w)
	if read == nil {
		st.Env = func(string) string { panic("boom early") }
		read = w.readFile()
	}
	func() {
		defer func() {
			if p := recover(); p != nil {
				t.Fatalf("the panic escaped the hook: %v", p)
			}
		}()
		if rc := runBreakthroughsHook(options{kit: w.kit, hook: true}, st, read); rc != 0 {
			t.Fatalf("rc=%d, want 0 (a hook never fails the session)", rc)
		}
	}()
	if errb.Len() != 0 {
		t.Errorf("stderr %q, want empty", errb.String())
	}
	if n := len(jsonObjects(t, out.String())); n != 1 {
		t.Fatalf("stdout holds %d JSON objects, want exactly 1:\n%s", n, out.String())
	}
	return decodeContext(t, out.String()), out.String()
}

func TestBreakthroughsHookPanicStillEmitsEnvelope(t *testing.T) {
	ctx, _ := runPanickingBTHook(t, func(*world) readFunc { return nil })
	if !strings.HasPrefix(ctx, "Research-SDD breakthroughs sweep could not run (exit 1 — check TARGETS.md and lib/ helper):\n") || !strings.Contains(ctx, "rsdd: internal-error: boom early") {
		t.Errorf("context %q", ctx)
	}
}

func TestBreakthroughsHookLatePanicStillEmitsOneEnvelope(t *testing.T) {
	ctx, _ := runPanickingBTHook(t, func(w *world) readFunc {
		return func(p string) ([]byte, error) {
			if strings.HasSuffix(p, "-block1.md") {
				panic("boom late")
			}
			return w.readFile()(p)
		}
	})
	if !strings.HasPrefix(ctx, "Research-SDD breakthroughs sweep could not run (exit 1 — check TARGETS.md and lib/ helper):\n") ||
		!strings.Contains(ctx, "INFO: corpus not found (absent-input): ") || !strings.Contains(ctx, "rsdd: internal-error: boom late") {
		t.Errorf("context %q", ctx)
	}
}
