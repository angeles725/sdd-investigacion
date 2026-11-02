package retrogrammar

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"
)

// Frozen oracle. The live differential (differential_test.go, opt-in) runs the REAL lib/retro-grammar.sh and
// lib/retro-status.sh once per input; forking bash per case takes about 80 s, longer than a CI package timeout
// leaves room for. Every input of that differential (fixtures, generated documents, edge files, token, title and
// marker-line corpora) is frozen here with the bash result (rc, stdout, stderr), and TestOracleReplay replays the
// Go port against it byte for byte, in well under a second, in every plain `go test`.
//
// Files (testdata/):
//   - oracle-docs.txt:  one strconv.Quote'd document per line; the case key "d<N>" is line N (0-based).
//   - oracle-cases.txt: one case per line, tab separated: mode, key, rc, quoted stdout, quoted stderr. The key is
//     "d<N>" (a document written to a temp file), "s:<name>" (a path the document cannot express: emptypath,
//     missing, dir, locked) or a quoted "t:<input>" (a token, title, marker line, rowstate pair or id list).
//
// Regenerate from the live oracle with RETROGRAMMAR_UPDATE=1 go test -count=1 ./internal/core/retrogrammar (no
// -run, no -short: a partial run would freeze a partial corpus). The run records only when every live check
// passes, so the goldens always hold bash's answer. The machine-specific fleet pass is live only.
const (
	oracleDocsFile  = "testdata/oracle-docs.txt"
	oracleCasesFile = "testdata/oracle-cases.txt"
	pathPlaceholder = "{PATH}" // stands for the input path inside a frozen stderr
)

const basePlaceholder = "{BASE}" // stands for the input file's base name inside a frozen result

// anonymize replaces the machine-specific input path (and its base name in the entry_warn prefix, the one place bash prints it; other echoes of a name are document content) in both channels with placeholders.
func anonymize(b bashOut, p string) bashOut {
	if p == "" {
		return b
	}
	sub := func(s string) string {
		s = strings.ReplaceAll(s, p, pathPlaceholder)
		return strings.ReplaceAll(s, "WARN: "+filepath.Base(p)+":", "WARN: "+basePlaceholder+":")
	}
	b.stdout, b.stderr = sub(b.stdout), sub(b.stderr)
	return b
}

// deanonymize is the inverse of anonymize for the path the replay materialised.
func deanonymize(b bashOut, p string) bashOut {
	if p == "" {
		return b
	}
	sub := func(s string) string {
		s = strings.ReplaceAll(s, pathPlaceholder, p)
		return strings.ReplaceAll(s, "WARN: "+basePlaceholder+":", "WARN: "+filepath.Base(p)+":")
	}
	b.stdout, b.stderr = sub(b.stdout), sub(b.stderr)
	return b
}

// oracleCase is one frozen bash result. key has the in-memory form: "d:"+content, "s:"+name or "t:"+input.
type oracleCase struct {
	mode, key string
	out       bashOut
}

func oracleID(mode, key string) string { return mode + "\x00" + key }

// parseOracle decodes the two golden files.
func parseOracle(docs, cases string) ([]oracleCase, error) {
	var docList []string
	for i, l := range splitNonEmpty(docs) {
		s, err := strconv.Unquote(l)
		if err != nil {
			return nil, fmt.Errorf("%s line %d: %v", oracleDocsFile, i+1, err)
		}
		docList = append(docList, s)
	}
	var out []oracleCase
	for i, l := range splitNonEmpty(cases) {
		f := strings.Split(l, "\t")
		if len(f) != 5 {
			return nil, fmt.Errorf("%s line %d: %d fields, want 5", oracleCasesFile, i+1, len(f))
		}
		c := oracleCase{mode: f[0]}
		switch {
		case strings.HasPrefix(f[1], "d"):
			n, err := strconv.Atoi(f[1][1:])
			if err != nil || n < 0 || n >= len(docList) {
				return nil, fmt.Errorf("%s line %d: bad document key %q", oracleCasesFile, i+1, f[1])
			}
			c.key = "d:" + docList[n]
		case strings.HasPrefix(f[1], "s:"):
			c.key = f[1]
		default:
			k, err := strconv.Unquote(f[1])
			if err != nil {
				return nil, fmt.Errorf("%s line %d: bad key: %v", oracleCasesFile, i+1, err)
			}
			c.key = k
		}
		rc, err := strconv.Atoi(f[2])
		if err != nil {
			return nil, fmt.Errorf("%s line %d: bad rc: %v", oracleCasesFile, i+1, err)
		}
		c.out.rc = rc
		if c.out.stdout, err = strconv.Unquote(f[3]); err != nil {
			return nil, fmt.Errorf("%s line %d: bad stdout: %v", oracleCasesFile, i+1, err)
		}
		if c.out.stderr, err = strconv.Unquote(f[4]); err != nil {
			return nil, fmt.Errorf("%s line %d: bad stderr: %v", oracleCasesFile, i+1, err)
		}
		out = append(out, c)
	}
	return out, nil
}

func splitNonEmpty(s string) []string {
	var out []string
	for _, l := range strings.Split(s, "\n") {
		if l != "" {
			out = append(out, l)
		}
	}
	return out
}

// formatOracle encodes cases deterministically (documents and cases sorted) so a regeneration diffs cleanly.
func formatOracle(cases map[string]oracleCase) (docs, out string) {
	docSet := map[string]bool{}
	for _, c := range cases {
		if strings.HasPrefix(c.key, "d:") {
			docSet[c.key[2:]] = true
		}
	}
	docList := make([]string, 0, len(docSet))
	for d := range docSet {
		docList = append(docList, d)
	}
	sort.Strings(docList)
	idx := map[string]int{}
	var db strings.Builder
	for i, d := range docList {
		idx[d] = i
		db.WriteString(strconv.Quote(d))
		db.WriteByte('\n')
	}
	all := make([]oracleCase, 0, len(cases))
	for _, c := range cases {
		all = append(all, c)
	}
	sort.Slice(all, func(i, j int) bool {
		if all[i].mode != all[j].mode {
			return all[i].mode < all[j].mode
		}
		return all[i].key < all[j].key
	})
	var cb strings.Builder
	for _, c := range all {
		key := strconv.Quote(c.key)
		if strings.HasPrefix(c.key, "d:") {
			key = "d" + strconv.Itoa(idx[c.key[2:]])
		} else if strings.HasPrefix(c.key, "s:") {
			key = c.key
		}
		fmt.Fprintf(&cb, "%s\t%s\t%d\t%s\t%s\n", c.mode, key, c.out.rc, strconv.Quote(c.out.stdout), strconv.Quote(c.out.stderr))
	}
	return db.String(), cb.String()
}

func loadOracle() ([]oracleCase, error) { return loadOracleFrom(oracleDocsFile, oracleCasesFile) }

// loadOracleFrom reads the two golden files. A missing one is named with the command that rebuilds it, so a
// checkout without the goldens fails with that one message, not with a bare read error.
func loadOracleFrom(docsPath, casesPath string) ([]oracleCase, error) {
	var text [2]string
	for i, p := range []string{docsPath, casesPath} {
		b, err := os.ReadFile(p)
		if errors.Is(err, fs.ErrNotExist) {
			return nil, fmt.Errorf("goldens missing: %s; regenerate with RETROGRAMMAR_UPDATE=1 make retrogrammar-live", p)
		} else if err != nil {
			return nil, err
		}
		text[i] = string(b)
	}
	return parseOracle(text[0], text[1])
}

// oracleSide is the Go rendering of one frozen case. path is the file the input was materialised as ("" for a
// non-file input); skip is set when the premise cannot be rebuilt here (a mode-000 file under root).
type oracleSide struct {
	dir   string
	docs  map[string]string // content -> file written for it
	count int
}

func (o *oracleSide) materialise(key string) (path string, skip bool, err error) {
	switch {
	case key == "s:emptypath":
		return "", false, nil
	case key == "s:missing":
		return filepath.Join(o.dir, "missing.md"), false, nil
	case key == "s:dir":
		p := filepath.Join(o.dir, "adir")
		return p, false, os.MkdirAll(p, 0o755)
	case key == "s:locked":
		if os.Geteuid() == 0 { // root reads a mode-000 file: the unreadable premise is unavailable
			return "", true, nil
		}
		p := filepath.Join(o.dir, "locked.md")
		if _, err := os.Stat(p); err == nil || os.IsPermission(err) {
			return p, false, nil // already written by an earlier case (a mode-000 file cannot be rewritten)
		}
		return p, false, os.WriteFile(p, []byte("## Proposed kit deltas\n"), 0)
	case strings.HasPrefix(key, "d:"):
		if p, ok := o.docs[key]; ok {
			return p, false, nil
		}
		o.count++
		p := filepath.Join(o.dir, "d"+strconv.Itoa(o.count)+".md")
		o.docs[key] = p
		return p, false, os.WriteFile(p, []byte(key[2:]), 0o644)
	}
	return "", false, fmt.Errorf("unknown file key %q", key)
}

// goSide runs the Go port on one frozen input.
func (o *oracleSide) goSide(mode, key string) (got bashOut, path string, skip bool, err error) {
	if f, ok := fileModes[mode]; ok {
		path, skip, err = o.materialise(key)
		if err != nil || skip {
			return bashOut{}, "", skip, err
		}
		return f(path), path, false, nil
	}
	in := strings.TrimPrefix(key, "t:")
	switch {
	case tokenModes[mode] != nil:
		return tokenModes[mode](in), "", false, nil
	case lineModes[mode] != nil:
		return lineModes[mode](in), "", false, nil
	case mode == "titleid":
		return bashOut{rc: rcOf(TitleHasIdentity(in))}, "", false, nil
	case mode == "rowstate":
		line, rid, _ := strings.Cut(in, "\x1f")
		return bashOut{stdout: string(MarkerRowState(line, rid)) + "\n"}, "", false, nil
	case mode == "dupids":
		return bashOut{stdout: joinLines(DupIDs(strings.Split(in, "\n")))}, "", false, nil
	}
	return bashOut{}, "", false, fmt.Errorf("unknown mode %q", mode)
}

// oracleModes are the modes the golden must carry; one missing means cases were dropped.
func oracleModes() []string {
	var modes []string
	for m := range fileModes {
		modes = append(modes, m)
	}
	for m := range tokenModes {
		modes = append(modes, m)
	}
	for m := range lineModes {
		modes = append(modes, m)
	}
	modes = append(modes, "titleid", "rowstate", "dupids")
	sort.Strings(modes)
	return modes
}

func TestOracleReplay(t *testing.T) {
	if os.Getenv("RETROGRAMMAR_UPDATE") == "1" {
		t.Skip("RETROGRAMMAR_UPDATE=1: regenerating the goldens from the live oracle")
	}
	cases, err := loadOracle()
	if err != nil {
		t.Fatal(err)
	}
	o := &oracleSide{dir: t.TempDir(), docs: map[string]string{}}
	perMode := map[string]int{}
	distinct := map[string]map[bashOut]bool{}
	bad := map[string]int{}
	for _, c := range cases {
		got, path, skip, err := o.goSide(c.mode, c.key)
		if err != nil {
			t.Fatalf("%s %q: %v", c.mode, c.key, err)
		}
		if skip {
			continue
		}
		want := deanonymize(c.out, path)
		perMode[c.mode]++
		if distinct[c.mode] == nil {
			distinct[c.mode] = map[bashOut]bool{}
		}
		distinct[c.mode][c.out] = true
		if got != want {
			if bad[c.mode]++; bad[c.mode] <= 5 {
				t.Errorf("%s %.80q:\n  go=%+v\nbash=%+v", c.mode, c.key, got, want)
			}
		}
	}
	for _, m := range oracleModes() {
		if perMode[m] == 0 {
			t.Errorf("mode %s has no frozen case: the golden dropped it (regenerate with RETROGRAMMAR_UPDATE=1)", m)
		}
		// Every mode answered at least two ways on the frozen corpus; a single outcome proves nothing.
		if len(distinct[m]) < 2 && perMode[m] > 0 {
			t.Errorf("mode %s: one bash outcome for all %d frozen cases: vacuous", m, perMode[m])
		}
	}
	for m, n := range bad {
		if n > 5 {
			t.Errorf("%s: %d more disagreements not shown", m, n-5)
		}
	}
	t.Logf("replayed %d frozen cases over %d modes", len(cases), len(perMode))
}

func TestOracleMissingGoldensNamesTheRegenerateCommand(t *testing.T) {
	dir := t.TempDir()
	docs := filepath.Join(dir, "oracle-docs.txt")
	if err := os.WriteFile(docs, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct{ docs, cases, missing string }{
		{filepath.Join(dir, "absent-docs.txt"), filepath.Join(dir, "absent-cases.txt"), "absent-docs.txt"},
		{docs, filepath.Join(dir, "absent-cases.txt"), "absent-cases.txt"},
	} {
		_, err := loadOracleFrom(c.docs, c.cases)
		want := "goldens missing: " + filepath.Join(dir, c.missing) + "; regenerate with RETROGRAMMAR_UPDATE=1 make retrogrammar-live"
		if err == nil || err.Error() != want {
			t.Errorf("loadOracleFrom(%s, %s) error = %v, want %q", c.docs, c.cases, err, want)
		}
	}
}
