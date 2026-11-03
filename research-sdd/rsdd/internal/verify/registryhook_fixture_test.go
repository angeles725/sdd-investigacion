package verify

import (
	"bytes"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"unicode/utf8"
)

// The SessionStart output budget of the registry hook (kit issue #1816, openspec/specs/kit-session-cost) on a FROZEN
// reading of the real fleet (testdata/registry-hook/*.raw, sanitised, never the live corpus). These are the cases the
// bash suite sessionstart-budget.test.sh (reg-1..reg-9) ran through a stub instrument; the hook is Go now and the
// compact filter is exercised directly. The cap is a budget assertion on a FROZEN fixture, not the live aggregate.

const registryHookCap = 1400 // characters of hook stdout, as `wc -m` counts them

func readRaw(t *testing.T, name string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", "registry-hook", name))
	if err != nil {
		t.Fatal(err)
	}
	return strings.TrimRight(string(b), "\n")
}

// hookStdout is what RunRegistryHook prints for a registry report: the envelope around header and body.
func hookStdout(body string, u awkChars) string {
	var buf bytes.Buffer
	writeSessionStart(&buf, hdrRegistryOK+"\n"+compactRegistry(body, u))
	return buf.String()
}

func TestRegistryHookBudgetOnFrozenFleetReading(t *testing.T) {
	raw := readRaw(t, "verify-registry.raw")
	for _, u := range []awkChars{false, true} {
		out := hookStdout(raw, u)
		ctx := compactRegistry(raw, u)
		if n := utf8.RuneCountInString(out); n > registryHookCap {
			t.Errorf("chars=%v: hook stdout is %d characters, cap %d", bool(u), n, registryHookCap)
		}
		// reg-2: the Summary line carries every count and passes whole.
		for _, l := range strings.Split(raw, "\n") {
			if strings.HasPrefix(l, "Summary:") && !strings.Contains(ctx, l+"\n") && !strings.HasSuffix(ctx, l) {
				t.Errorf("chars=%v: Summary line altered or missing: %q", bool(u), l)
			}
		}
		// reg-3: no WARN is dropped without a count (shown + omitted == total).
		total := strings.Count(raw, "\nWARN") + btoi(strings.HasPrefix(raw, "WARN"))
		shown := len(regexp.MustCompile(`(?m)^WARN  `).FindAllString(ctx, -1))
		omitted := 0
		if m := regexp.MustCompile(`(?m)^WARN: \+([0-9]+) more WARN line`).FindStringSubmatch(ctx); m != nil {
			omitted, _ = strconv.Atoi(m[1])
		}
		if shown+omitted != total {
			t.Errorf("chars=%v: WARN accounting: shown %d + omitted %d != %d", bool(u), shown, omitted, total)
		}
		// reg-4, reg-5, reg-7, reg-8
		want(t, ctx, "INFO: 14 registered target(s) absent", "INFO: 1 per-row INFO line(s) omitted",
			"Verify RESEARCH_HOME (/fx/home) and that corpora exist at the registered paths.",
			"kit repo is NOT in its own TARGETS.md", "master cell is 236 chars")
	}
}

func btoi(b bool) int {
	if b {
		return 1
	}
	return 0
}

// reg-9: a multibyte character straddling a cut point never yields invalid UTF-8 (nor the U+FFFD the envelope encoder
// would turn it into), whatever the locale's unit.
func TestRegistryHookMultibyteCutStaysValidUTF8(t *testing.T) {
	raw := readRaw(t, "verify-registry-multibyte.raw")
	for _, u := range []awkChars{false, true} {
		out := compactRegistry(raw, u)
		if !utf8.ValidString(out) || strings.ContainsRune(out, utf8.RuneError) {
			t.Errorf("chars=%v: invalid UTF-8 after a multibyte cut: %q", bool(u), out)
		}
		if env := hookStdout(raw, u); strings.Contains(env, "�") || strings.Contains(env, `�`) {
			t.Errorf("chars=%v: the envelope carries U+FFFD", bool(u))
		}
	}
}
