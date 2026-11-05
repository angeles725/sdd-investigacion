package cleancheck

import (
	"strconv"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/cleancheck"
)

// scriptName prefixes the usage and error lines: the legacy script's name is part of its output contract.
const scriptName = "clean-check.sh"

const usageLine = "Usage: " + scriptName + " [--target DIR] [--tmp DIR] [--stale-hours N] [--scratchpad DIR] [--base REF] [--evidence DIR] [--backup-days N]"

// maxDigits bounds the two ages: nine decimal digits cannot overflow the minute arithmetic.
const maxDigits = 9

// parsed is what the command line asked for.
type parsed struct {
	opts cleancheck.Options
	help bool
}

// refusal is a command line the command will not run: the error text, printed after the usage line.
type refusal string

// parse reads the flags in order, as the script's loop did: a value flag takes the next word whatever it looks like,
// the first unknown word ends the parse, -h/--help ends it with the usage (exit 0), and the last of a repeated flag
// wins. One thing is stricter than the script: an explicit empty value for a path or a ref is refused (the script
// treated it as "not given" and quietly scanned the working directory, the default tmp or no base). The ages are
// checked after the loop exactly as before. Only flags are read here; the environment is the caller's.
func parse(args []string) (parsed, refusal) {
	p := parsed{opts: cleancheck.Options{StaleHours: cleancheck.DefaultStaleHours, BackupDays: cleancheck.DefaultBackupDays}}
	var stale, backup *string
	paths := map[string]*string{
		"--target": &p.opts.Target, "--tmp": &p.opts.Tmp, "--scratchpad": &p.opts.Scratchpad,
		"--base": &p.opts.Base, "--evidence": &p.opts.Evidence,
	}
	ages := map[string]**string{"--stale-hours": &stale, "--backup-days": &backup}
	for i := 0; i < len(args); i++ {
		a := args[i]
		if a == "-h" || a == "--help" {
			p.help = true
			return p, ""
		}
		path, isPath := paths[a]
		num, isAge := ages[a]
		if !isPath && !isAge {
			return p, refusal("unknown argument: " + a)
		}
		if i+1 >= len(args) {
			return p, refusal(a + " needs a value")
		}
		i++
		v := args[i]
		switch {
		case isAge:
			*num = &v
		case v == "":
			return p, refusal(a + " needs a non-empty value")
		default:
			*path = v
		}
	}
	var r refusal
	if p.opts.StaleHours, r = age("--stale-hours", stale, cleancheck.DefaultStaleHours); r != "" {
		return p, r
	}
	p.opts.BackupDays, r = age("--backup-days", backup, cleancheck.DefaultBackupDays)
	return p, r
}

// age reads a decimal age: digits only, at most nine of them, a leading zero still decimal (08 is 8). An age that
// was not given is the default; one given as an empty word is refused like any other non-number.
func age(flag string, raw *string, def int) (int, refusal) {
	if raw == nil {
		return def, ""
	}
	if n, err := strconv.Atoi(*raw); err == nil && digitsOnly(*raw) && len(*raw) <= maxDigits {
		return n, ""
	}
	return 0, refusal(flag + " must be a decimal integer of at most 9 digits: '" + *raw + "'")
}

func digitsOnly(s string) bool {
	for _, c := range s {
		if c < '0' || c > '9' {
			return false
		}
	}
	return s != ""
}
