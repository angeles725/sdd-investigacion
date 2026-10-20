package parity

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// Typed problem kinds. Every failure the runner reports carries one.
const (
	KindUndeclared   = "undeclared-divergence"
	KindStale        = "stale-declaration"
	KindNoReason     = "intended-no-reason"
	KindTimeout      = "timeout"
	KindCorpusMod    = "corpus-modified"
	KindCorpusRead   = "corpus-unreadable"
	KindSpecInvalid  = "spec-invalid"
	KindExecFailed   = "exec-failed"
	KindOutputTooBig = "output-too-large"
	KindSandbox      = "sandbox-error"
	KindEmptyInput   = "empty-input"
	KindAbsentInput  = "absent-input"
	KindDegraded     = "degraded"
)

const (
	placeholderInput  = "{{input}}"
	placeholderCorpus = "{{corpus}}"
	placeholderSbx    = "{{sandbox}}"
)

// Problem is one typed finding.
type Problem struct {
	Kind   string
	Detail string
}

func (p Problem) String() string { return p.Kind + ": " + p.Detail }

// Spec is spec.json.
type Spec struct {
	Legacy []string          `json:"legacy"`
	Rsdd   []string          `json:"rsdd"`
	Env    map[string]string `json:"env"`
	Corpus bool              `json:"corpus"`
}

// Intended is one declared divergence; the schema is golden's intended.json.
type Intended struct {
	Field  string `json:"field"`
	Reason string `json:"reason"`
}

// Case is a loaded case directory. Problems holds load-time findings; a case
// with problems is reported as failed and never executed.
type Case struct {
	Name        string
	Dir         string
	Spec        Spec
	Intended    []Intended
	Normalisers []Normaliser
	Stdin       []byte
	HasInputs   bool
	Problems    []Problem
}

// reservedEnv are the keys the runner fixes for isolation.
var reservedEnv = map[string]bool{"PATH": true, "LC_ALL": true, "TZ": true, "HOME": true, "TMPDIR": true}

var placeholderRe = regexp.MustCompile(`\{\{[^}]*\}\}`)

// LoadCases reads every case directory under dir. A missing dir is an
// absent-input error and a dir with no case directories is an empty-input
// error; neither is a pass.
func LoadCases(dir string) ([]Case, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("%s: parity spec dir %s unreadable: %w", KindAbsentInput, dir, err)
	}
	var cases []Case
	for _, e := range entries {
		if e.IsDir() {
			cases = append(cases, loadCase(filepath.Join(dir, e.Name())))
		}
	}
	if len(cases) == 0 {
		return nil, fmt.Errorf("%s: 0 parity specs under %s", KindEmptyInput, dir)
	}
	sort.Slice(cases, func(i, j int) bool { return cases[i].Name < cases[j].Name })
	return cases, nil
}

func loadCase(dir string) Case {
	c := Case{Name: filepath.Base(dir), Dir: dir}
	bad := func(kind, format string, a ...any) Case {
		c.Problems = append(c.Problems, Problem{kind, fmt.Sprintf(format, a...)})
		return c
	}
	raw, err := os.ReadFile(filepath.Join(dir, "spec.json"))
	if err != nil {
		return bad(KindSpecInvalid, "spec.json missing or unreadable: %v", err)
	}
	if err := strictJSON(raw, &c.Spec); err != nil {
		return bad(KindSpecInvalid, "spec.json: %v", err)
	}
	if p := validateSpec(c.Spec); p != "" {
		return bad(KindSpecInvalid, "spec.json: %s", p)
	}
	if st, err := os.Stat(filepath.Join(dir, "inputs")); err == nil && st.IsDir() {
		c.HasInputs = true
	}
	if b, err := os.ReadFile(filepath.Join(dir, "stdin")); err == nil {
		c.Stdin = b
	} else if !os.IsNotExist(err) {
		return bad(KindSpecInvalid, "stdin unreadable: %v", err)
	}
	if usesPlaceholder(c.Spec, placeholderInput) && !c.HasInputs {
		return bad(KindSpecInvalid, "spec uses {{input}} but the case has no inputs/ directory")
	}
	if b, err := os.ReadFile(filepath.Join(dir, "intended.json")); err == nil {
		list, norms, probs := parseIntended(b)
		c.Intended, c.Normalisers = list, norms
		c.Problems = append(c.Problems, probs...)
	} else if !os.IsNotExist(err) {
		return bad(KindSpecInvalid, "intended.json unreadable: %v", err)
	}
	return c
}

func strictJSON(b []byte, v any) error {
	d := json.NewDecoder(bytes.NewReader(b))
	d.DisallowUnknownFields()
	if err := d.Decode(v); err != nil {
		return err
	}
	if d.More() {
		return fmt.Errorf("trailing data after the JSON value")
	}
	return nil
}

func allArgs(s Spec) []string {
	var out []string
	out = append(out, s.Legacy...)
	out = append(out, s.Rsdd...)
	keys := make([]string, 0, len(s.Env))
	for k := range s.Env {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		out = append(out, s.Env[k])
	}
	return out
}

func usesPlaceholder(s Spec, ph string) bool {
	for _, a := range allArgs(s) {
		if strings.Contains(a, ph) {
			return true
		}
	}
	return false
}

func validateSpec(s Spec) string {
	if len(s.Legacy) == 0 || s.Legacy[0] == "" {
		return "legacy argv is empty"
	}
	if !filepath.IsLocal(s.Legacy[0]) {
		return fmt.Sprintf("legacy[0] %q must be a path relative to the legacy kit root", s.Legacy[0])
	}
	if len(s.Rsdd) == 0 {
		return "rsdd argv is empty"
	}
	for k := range s.Env {
		if reservedEnv[k] {
			return fmt.Sprintf("env %s is fixed by the runner and cannot be overridden", k)
		}
	}
	for _, a := range allArgs(s) {
		for _, ph := range placeholderRe.FindAllString(a, -1) {
			switch ph {
			case placeholderInput, placeholderCorpus, placeholderSbx:
			default:
				return fmt.Sprintf("unknown placeholder %s", ph)
			}
		}
	}
	uses := usesPlaceholder(s, placeholderCorpus)
	if uses && !s.Corpus {
		return `{{corpus}} used but "corpus": true is not set`
	}
	if s.Corpus && !uses {
		return `"corpus": true but no {{corpus}} placeholder: the run would repeat identically per corpus`
	}
	return ""
}

// intendedEntry is one intended.json entry. golden's {field, reason} entries
// are valid unchanged (parity adds the field "effect"); parity also accepts
// {normalise, pattern?, reason} entries. Exactly one of field/normalise is set.
type intendedEntry struct {
	Field     string `json:"field"`
	Normalise string `json:"normalise"`
	Pattern   string `json:"pattern"`
	Reason    string `json:"reason"`
}

// parseIntended validates the entries and splits them into declared field
// divergences and compiled normalisers.
func parseIntended(b []byte) ([]Intended, []Normaliser, []Problem) {
	var list []intendedEntry
	if err := strictJSON(b, &list); err != nil {
		return nil, nil, []Problem{{KindSpecInvalid, "intended.json: " + err.Error()}}
	}
	var fields []Intended
	var norms []normaliserEntry
	var probs []Problem
	for i, e := range list {
		if (e.Field == "") == (e.Normalise == "") {
			probs = append(probs, Problem{KindSpecInvalid, fmt.Sprintf("intended.json entry %d: exactly one of field or normalise is required", i)})
			continue
		}
		if e.Normalise != "" {
			norms = append(norms, normaliserEntry{e.Normalise, e.Pattern, e.Reason})
			continue
		}
		switch e.Field {
		case "stdout", "stderr", "exit", "effect":
		default:
			probs = append(probs, Problem{KindSpecInvalid, fmt.Sprintf("intended.json entry %d: field %q is not one of stdout|stderr|exit|effect", i, e.Field)})
			continue
		}
		if e.Pattern != "" {
			probs = append(probs, Problem{KindSpecInvalid, fmt.Sprintf("intended.json entry %d (%s): pattern is only valid for a pid normaliser", i, e.Field)})
		}
		if strings.TrimSpace(e.Reason) == "" {
			probs = append(probs, Problem{KindNoReason, fmt.Sprintf("intended.json entry %d (%s): every intended divergence needs a non-empty reason", i, e.Field)})
		}
		fields = append(fields, Intended{Field: e.Field, Reason: e.Reason})
	}
	compiled, nprobs := compileNormalisers(norms)
	return fields, compiled, append(probs, nprobs...)
}
