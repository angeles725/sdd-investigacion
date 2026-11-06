package toolcatalog

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"unicode/utf8"
)

// The SessionStart output budget of the catalog hook (kit issue #1816, openspec/specs/kit-session-cost) on a FROZEN
// reading of the real fleet (testdata/budget/*.raw, sanitised, never the live corpus). These are the cases the bash
// suite sessionstart-budget.test.sh ran through a stub instrument, now that the hook is Go and runs the check in process:
//
//	cat-1 -> TestBudgetCap            (and tooth C, the compaction skipped: the per-tool WARN lines return)
//	cat-2 -> TestBudgetSummaryVerbatim
//	cat-3 -> TestBudgetCollapsedLine  (and tooth H, a name dropped from the collapsed line)
//	cat-4 -> TestBudgetCollapsedLine  (the (N) equals the name count)
//	cat-mb -> TestBudgetMultibyteCut  (and tooth J, the byte cut without the incomplete-sequence trim; both locales)
//
// The teeth were proved by hand in PR #2769 (each mutation applied to hookctx.go, compact.go or cut.go, run, restored);
// the package's mutation run keeps proving them. The cap is a budget assertion on a FROZEN fixture, not the live
// aggregate reading.

const catalogHookCap = 700 // characters of hook stdout, as `wc -m` counts them

func readBudgetRaw(t *testing.T, name string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", "budget", name))
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// budgetHook runs the hook command over a stub check that replays raw (rc 0) in the given locale: its stdout.
func budgetHook(raw, loc string) string {
	stub := func(_ string, _ locale, out, _ io.Writer) int {
		_, _ = io.WriteString(out, raw)
		return 0
	}
	var out, errb bytes.Buffer
	runHook(nil, stdio(&out, &errb, "", loc), stub)
	return out.String()
}

// budgetContext is the additionalContext the hook printed.
func budgetContext(t *testing.T, stdout string) string {
	t.Helper()
	var env struct {
		Hook struct {
			Ctx string `json:"additionalContext"`
		} `json:"hookSpecificOutput"`
	}
	if err := json.Unmarshal([]byte(stdout), &env); err != nil {
		t.Fatalf("hook stdout is not the envelope: %v\n%s", err, stdout)
	}
	return env.Hook.Ctx
}

func TestBudgetCap(t *testing.T) {
	t.Parallel()
	for _, loc := range locales {
		out := budgetHook(readBudgetRaw(t, "verify-tool-catalog.raw"), loc)
		if n := utf8.RuneCountInString(out); n > catalogHookCap {
			t.Errorf("LC_ALL=%s: catalog hook is %d characters, cap %d", loc, n, catalogHookCap)
		}
	}
}

func TestBudgetSummaryVerbatim(t *testing.T) {
	t.Parallel()
	raw := readBudgetRaw(t, "verify-tool-catalog.raw")
	ctx := budgetContext(t, budgetHook(raw, "C"))
	n := 0
	for _, l := range strings.Split(raw, "\n") {
		if strings.HasPrefix(l, "Summary:") {
			n++
			if !strings.Contains(ctx, l) {
				t.Errorf("Summary line altered or missing: %q", l)
			}
		}
	}
	if n == 0 {
		t.Fatal("the frozen reading has no Summary line: the check would pass vacuously")
	}
}

func TestBudgetCollapsedLine(t *testing.T) {
	t.Parallel()
	raw := readBudgetRaw(t, "verify-tool-catalog.raw")
	ctx := budgetContext(t, budgetHook(raw, "C"))
	collapsed := regexp.MustCompile(`(?m)^WARN  installed-but-not-cataloged \(([0-9]+)\):.*$`).FindStringSubmatch(ctx)
	if collapsed == nil {
		t.Fatalf("no collapsed line in:\n%s", ctx)
	}
	names := regexp.MustCompile(`(?m)^WARN  installed-but-not-cataloged: '([^']*)'`).FindAllStringSubmatch(raw, -1)
	if len(names) == 0 {
		t.Fatal("fixture carries no uncataloged tool")
	}
	for _, m := range names { // scoped to the collapsed line: the Summary line also lists the names
		if !strings.Contains(collapsed[0], m[1]) {
			t.Errorf("collapsed line lost tool name: %s", m[1])
		}
	}
	if n, _ := strconv.Atoi(collapsed[1]); n != len(names) {
		t.Errorf("collapsed count %s != name count %d", collapsed[1], len(names))
	}
}

func TestBudgetMultibyteCut(t *testing.T) {
	t.Parallel()
	raw := readBudgetRaw(t, "verify-tool-catalog-multibyte.raw")
	for _, loc := range locales {
		stdout := budgetHook(raw, loc)
		ctx := budgetContext(t, stdout) // the unmarshal fails on an invalid sequence only after the replacement, so also look for U+FFFD
		if !utf8.ValidString(stdout) || strings.ContainsRune(stdout, utf8.RuneError) || strings.ContainsRune(ctx, utf8.RuneError) {
			t.Errorf("LC_ALL=%s: invalid UTF-8 after the multibyte cut: %q", loc, ctx)
		}
		if !strings.Contains(ctx, "WARN  xxxx") {
			t.Errorf("LC_ALL=%s: the cut WARN line is missing: %q", loc, ctx)
		}
	}
}
