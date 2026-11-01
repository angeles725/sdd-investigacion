package maint

import (
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// shlexSplit is shlex.split(s) (POSIX mode, comments off): whitespace separates words, single quotes are
// literal, inside double quotes a backslash escapes only " and \, outside quotes it escapes any character.
// An unterminated quote or a trailing backslash is an error, as Python raises ValueError.
func shlexSplit(s string) ([]string, error) {
	var words []string
	var cur strings.Builder
	started := false
	rs := []rune(s)
	for i := 0; i < len(rs); i++ {
		r := rs[i]
		switch r {
		case ' ', '\t', '\r', '\n':
			if started {
				words = append(words, cur.String())
				cur.Reset()
				started = false
			}
		case '\\':
			if i+1 >= len(rs) {
				return nil, errors.New("no escaped character")
			}
			i++
			cur.WriteRune(rs[i])
			started = true
		case '\'':
			started = true
			j := i + 1
			for ; j < len(rs) && rs[j] != '\''; j++ {
				cur.WriteRune(rs[j])
			}
			if j >= len(rs) {
				return nil, errors.New("no closing quotation")
			}
			i = j
		case '"':
			started = true
			j := i + 1
			for ; j < len(rs) && rs[j] != '"'; j++ {
				if rs[j] == '\\' {
					if j+1 >= len(rs) {
						return nil, errors.New("no escaped character")
					}
					if n := rs[j+1]; n == '"' || n == '\\' {
						j++
						cur.WriteRune(n)
						continue
					}
				}
				cur.WriteRune(rs[j])
			}
			if j >= len(rs) {
				return nil, errors.New("no closing quotation")
			}
			i = j
		default:
			cur.WriteRune(r)
			started = true
		}
	}
	if started {
		words = append(words, cur.String())
	}
	return words, nil
}

// optSpec declares one long option (the kit tools have no short ones besides -h).
type optSpec struct {
	name    string
	choices []string // empty: any value
	integer bool
	def     string
}

type parsed struct {
	opts map[string]string
	pos  []string
	help bool
}

// usageError is an argparse error: the caller prints the usage and the message, then exits 2.
type usageError struct{ msg string }

func (e *usageError) Error() string { return e.msg }

// parseArgs follows argparse for these tools: options and the nPos positionals may be interleaved, a long
// option may be abbreviated to any unique prefix, "--name=value" works, "--" ends the options, and a value
// that looks like a negative number is a value, not an option.
func parseArgs(args []string, specs []optSpec, posNames ...string) (parsed, error) {
	nPos := len(posNames)
	p := parsed{opts: map[string]string{}}
	for _, s := range specs {
		p.opts[s.name] = s.def
	}
	byName := map[string]optSpec{}
	names := []string{"help"}
	for _, s := range specs {
		byName[s.name] = s
		names = append(names, s.name)
	}
	sort.Strings(names)
	onlyPos := false
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case onlyPos || a == "-" || !strings.HasPrefix(a, "-") || isNegativeNumber(a):
			p.pos = append(p.pos, a)
			continue
		case a == "--":
			onlyPos = true
			continue
		case a == "-h":
			p.help = true
			continue
		case !strings.HasPrefix(a, "--"):
			return p, &usageError{fmt.Sprintf("unrecognized arguments: %s", a)}
		}
		name, val, hasVal := strings.Cut(strings.TrimPrefix(a, "--"), "=")
		full, err := expandOption(name, names)
		if err != nil {
			return p, err
		}
		if full == "help" {
			p.help = true
			continue
		}
		spec := byName[full]
		if !hasVal {
			if i+1 >= len(args) || (strings.HasPrefix(args[i+1], "-") && args[i+1] != "-" && !isNegativeNumber(args[i+1])) {
				return p, &usageError{fmt.Sprintf("argument --%s: expected one argument", full)}
			}
			i++
			val = args[i]
		}
		if len(spec.choices) > 0 && !contains(spec.choices, val) {
			return p, &usageError{fmt.Sprintf("argument --%s: invalid choice: %s (choose from %s)", full, pyStrRepr(val), quoteAll(spec.choices))}
		}
		if spec.integer {
			if _, err := strconv.Atoi(strings.TrimSpace(val)); err != nil {
				return p, &usageError{fmt.Sprintf("argument --%s: invalid int value: %s", full, pyStrRepr(val))}
			}
		}
		p.opts[full] = val
	}
	if p.help {
		return p, nil
	}
	if len(p.pos) < nPos {
		return p, &usageError{"the following arguments are required: " + strings.Join(posNames[len(p.pos):], ", ")}
	}
	if len(p.pos) > nPos {
		return p, &usageError{fmt.Sprintf("unrecognized arguments: %s", strings.Join(p.pos[nPos:], " "))}
	}
	return p, nil
}

func expandOption(name string, names []string) (string, error) {
	if contains(names, name) {
		return name, nil
	}
	var hits []string
	for _, n := range names {
		if name != "" && strings.HasPrefix(n, name) {
			hits = append(hits, n)
		}
	}
	switch len(hits) {
	case 1:
		return hits[0], nil
	case 0:
		return "", &usageError{fmt.Sprintf("unrecognized arguments: --%s", name)}
	}
	return "", &usageError{fmt.Sprintf("ambiguous option: --%s could match %s", name, strings.Join(hits, ", "))}
}

// negNumber is argparse's _negative_number_matcher.
var negNumber = regexp.MustCompile(`^-\d+$|^-\d*\.\d+$`)

func isNegativeNumber(s string) bool { return negNumber.MatchString(s) }

func contains(list []string, s string) bool {
	for _, e := range list {
		if e == s {
			return true
		}
	}
	return false
}

func quoteAll(list []string) string {
	q := make([]string, len(list))
	for i, e := range list {
		q[i] = pyStrRepr(e)
	}
	return strings.Join(q, ", ")
}
