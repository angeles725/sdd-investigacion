package kit

import (
	"errors"
	"path/filepath"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/gfm"
)

// NameResult is the outcome of NameForRetro on success.
type NameResult struct {
	Name     string
	Warnings []string // stderr WARN lines the bash helper prints (a name cell with whitespace)
}

// ErrNoAncestor is the bash rc 2: TARGETS.md was read fine, no registered ancestor holds the retro. It is a
// no-match, distinct from every operational failure (rc 1).
var ErrNoAncestor = errors.New("kit: no registered ancestor")

const blanks = " \t\n\v\f\r"

// NameForRetro is target_name_for_retro: the Target NAME (row cell 2) of the nearest registered ancestor of the
// directory that holds the retro's retros/ dir. Both sides are compared as physical paths. The row is selected
// by its PATH cell only (kit issue #1304 item 4). Errors other than ErrNoAncestor carry the bash stderr text.
//
// Row cells are split on every pipe (awk -F'|'), NOT with core/gfm: gfm honours `\|`, bash does not (finding F5).
func NameForRetro(targetsPath, retro string, getenv Getenv) (NameResult, error) {
	if targetsPath == "" || retro == "" {
		return NameResult{}, &msgError{"target-paths: target_name_for_retro needs <targets_md> <retro>", ErrUsage}
	}
	src, err := ReadTargets(targetsPath)
	if err != nil {
		return NameResult{}, err
	}
	rdir, ok := physDir(filepath.Dir(retro))
	if !ok {
		return NameResult{}, &msgError{"target-paths: retro directory not found for " + retro, ErrAbsentInput}
	}
	pairs := PairsAll(src, getenv)
	if len(pairs) == 0 {
		return NameResult{}, &msgError{"target-paths: no registered target paths parsed from " + targetsPath, ErrAbsentInput}
	}
	var exps []string
	var hit []Pair
	hasRH := false
	for _, p := range pairs {
		if strings.HasPrefix(p.Raw, "$RESEARCH_HOME") || strings.HasPrefix(p.Raw, "${RESEARCH_HOME}") {
			hasRH = true
		}
		if e, ok := physDir(p.Expanded); ok {
			exps = append(exps, e)
			hit = append(hit, p)
		}
	}
	if len(exps) == 0 && hasRH {
		rh := getenv("RESEARCH_HOME")
		if rh == "" {
			rh = getenv("HOME")
		}
		return NameResult{}, &msgError{"target-paths: no registered target path in " + targetsPath +
			" resolves to a directory — it has $RESEARCH_HOME rows, so RESEARCH_HOME (" + rh + ") is probably wrong", ErrAbsentInput}
	}
	idx := -1
	for anc := filepath.Dir(rdir); idx < 0; anc = filepath.Dir(anc) {
		for i, e := range exps {
			if e == anc {
				idx = i // the first (innermost) ancestor wins, in any row order
				break
			}
		}
		if anc == "/" {
			break
		}
	}
	if idx < 0 {
		return NameResult{}, ErrNoAncestor
	}
	raw := hit[idx].Raw
	name := ""
	for _, line := range strings.Split(src, "\n") {
		if !isRowLine(line) {
			continue
		}
		var nameCell, pathCell string
		if Behaviour.SplitEscapedPipes { // F5, legacy: awk -F'|' splits on every pipe, `\|` included
			f := strings.Split(line, "|")
			if len(f) < 4 {
				continue
			}
			nameCell, pathCell = f[2], f[3]
		} else {
			cells, _ := gfm.SplitRow(line, gfm.Options{KeepCR: true})
			if len(cells) < 3 {
				continue
			}
			nameCell, pathCell = gfm.Unescape(cells[1]), gfm.Unescape(cells[2])
		}
		if strings.Contains(pathCell, "`"+raw+"`") {
			name = strings.Trim(strings.NewReplacer("`", "", "*", "").Replace(nameCell), blanks)
			break
		}
	}
	res := NameResult{Name: name}
	switch {
	case name == "":
		res.Name = filepath.Base(hit[idx].Expanded)
	case strings.ContainsAny(name, blanks):
		res.Warnings = []string{"WARN: target name cell '" + name + "' for " + raw + " contains whitespace and cannot be a label — using basename"}
		res.Name = filepath.Base(hit[idx].Expanded)
	}
	return res, nil
}
