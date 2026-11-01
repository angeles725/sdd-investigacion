package fidelity

import (
	"bytes"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

var (
	poolRef  = regexp.MustCompile(`#[0-9]+(, *[0-9]+)?`)
	engineRe = regexp.MustCompile(`^.*\(engine=([A-Za-z0-9_.-]*)[ )].*$`)
)

// javaFiles is `find DIR -maxdepth 1 -type f -name '*.java' | sort`.
func javaFiles(dir string) []string {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var out []string
	for _, e := range ents {
		if e.Type().IsRegular() && strings.HasSuffix(e.Name(), ".java") {
			out = append(out, dir+"/"+e.Name())
		}
	}
	return out // ReadDir is sorted by name
}

// findFiles is `find DIR -type f -name '*<suffix>' | sort`, with DIR kept as the caller spelled it.
func (e *experiment) findFiles(dir, suffix string) []string {
	root := e.at(dir)
	var out []string
	_ = filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err == nil && d.Type().IsRegular() && strings.HasSuffix(d.Name(), suffix) {
			out = append(out, dir+"/"+filepath.ToSlash(strings.TrimPrefix(p, root+string(filepath.Separator))))
		}
		return nil
	})
	sort.Strings(out)
	return out
}

func (e *experiment) write(path string, data []byte) { _ = os.WriteFile(e.at(path), data, 0o644) }

func (e *experiment) verdict(name, mode, v, reason string) {
	if reason != "" {
		reason = " reason=" + reason
	}
	fmt.Fprintf(e.s.Out, "FIDELITY %s mode=%s verdict=%s%s\n", name, mode, v, reason)
	switch v {
	case "GOOD":
		e.nGood++
	case "DIVERGED":
		e.nDiv++
	default:
		e.nBad++
	}
}

// cell measures one fixture in one mode. It returns true when the run must stop with a DEGRADED exit.
func (e *experiment) cell(name, src, mode string, flags []string) (stop bool) {
	base := e.work + "/" + name + "/" + mode
	orig, dec, re, logf := base+"/orig", base+"/dec", base+"/re", base+"/log"
	_ = os.RemoveAll(e.at(base))
	for _, d := range []string{orig, dec, re} {
		_ = os.MkdirAll(e.at(d), 0o755)
	}
	javac := func(out, in string) Result {
		r := e.exec(e.javac, append(append([]string{}, flags...), "-d", out, in)...)
		e.write(logf, r.Output)
		return r
	}
	if javac(orig, src).RC != 0 {
		e.verdict(name, mode, "FAILED", "compile")
		return false
	}
	classes := e.findFiles(orig, ".class")
	if len(classes) != 1 {
		e.verdict(name, mode, "FAILED", "multi-class")
		return false
	}
	cls := classes[0]

	dr := e.run(e.decompiler, e.timeout, cls, dec)
	e.write(base+"/dec.log", dr.Output)
	eng := engineOf(dr.Output)
	if eng != "" && !contains(e.engines, eng) {
		e.engines = append(e.engines, eng)
	}
	if dr.RC == 4 {
		e.nFallback++
		if eng == "" {
			eng = "unknown"
		}
		fmt.Fprintf(e.s.Out, "FALLBACK %s mode=%s labelled-engine=%s\n", name, mode, eng)
	}
	switch {
	case dr.RC == 3:
		e.degraded("decompiler-missing", fmt.Sprintf("(decompiler exit 3 on %s mode=%s: required tool missing)", name, mode))
		return true
	case dr.RC == 124:
		e.verdict(name, mode, "FAILED", "timeout")
		return false
	case dr.RC != 0 && dr.RC != 4:
		e.verdict(name, mode, "FAILED", "decompile")
		return false
	}
	decoded := e.findFiles(dec, ".java")
	if len(decoded) == 0 {
		e.verdict(name, mode, "FAILED", "no-output")
		return false
	}
	if len(decoded) > 1 {
		e.verdict(name, mode, "FAILED", "multi-output")
		return false
	}
	if javac(re, decoded[0]).RC != 0 {
		e.verdict(name, mode, "FAILED", "recompile")
		return false
	}
	var rcls []string
	for _, c := range e.findFiles(re, filepath.Base(cls)) {
		if filepath.Base(c) == filepath.Base(cls) {
			rcls = append(rcls, c)
		}
	}
	if len(rcls) == 0 {
		e.verdict(name, mode, "FAILED", "recompile-no-class")
		return false
	}
	origJavap := e.exec(e.javap, "-c", "-p", cls)
	e.write(base+"/orig.javap", origJavap.Output)
	if origJavap.RC != 0 {
		e.verdict(name, mode, "FAILED", "javap-original")
		return false
	}
	reJavap := e.exec(e.javap, "-c", "-p", strings.Join(rcls, "\n"))
	e.write(base+"/re.javap", reJavap.Output)
	if reJavap.RC != 0 {
		e.verdict(name, mode, "FAILED", "javap-recompiled")
		return false
	}
	if sameBytecode(origJavap.Output, reJavap.Output) {
		e.verdict(name, mode, "GOOD", "")
	} else {
		e.verdict(name, mode, "DIVERGED", "")
	}
	return false
}

// lvtPresent is yes | no | unmeasured. Unmeasured means the original did not compile or javap failed, so the
// absence of a LocalVariableTable was never observed (it must not read as "no").
func (e *experiment) lvtPresent(name, mode string) string {
	base := e.work + "/" + name + "/" + mode
	var all []byte
	n := 0
	for _, c := range e.findFiles(base+"/orig", ".class") {
		r := e.exec(e.javap, "-l", "-p", c)
		all = append(all, r.Output...)
		if r.RC != 0 {
			e.write(base+"/lvt.javap", all)
			return "unmeasured"
		}
		n++
	}
	e.write(base+"/lvt.javap", all)
	if n == 0 {
		return "unmeasured"
	}
	if bytes.Contains(all, []byte("LocalVariableTable")) {
		return "yes"
	}
	return "no"
}

// engineOf is the wrapper's "(engine=<e>)" label: the status line carries it on rc 0 and "(engine=<e> <detail>)"
// on a degraded rc 4 run. The last line that has one wins, even with an empty label.
func engineOf(log []byte) string {
	label := ""
	for _, line := range strings.Split(string(log), "\n") {
		if m := engineRe.FindStringSubmatch(line); m != nil {
			label = m[1]
		}
	}
	return label
}

// normalise strips constant-pool references ("#7", "#7, 3": javap -c prints them per instruction and they shift
// with unrelated pool order) and the "Compiled from" header (it names the .java, which differs). Everything else,
// instruction offsets and branch targets included, stays and must match.
func normalise(b []byte) string {
	var sb strings.Builder
	rest := string(b)
	for rest != "" {
		line, tail, hadNL := strings.Cut(rest, "\n")
		rest = tail
		line = poolRef.ReplaceAllString(line, "")
		if strings.HasPrefix(line, "Compiled from") {
			continue
		}
		sb.WriteString(line)
		if hadNL {
			sb.WriteByte('\n')
		}
	}
	return sb.String()
}

// sameBytecode compares the normalised listings the way `[ "$(a)" = "$(b)" ]` does: trailing newlines do not count.
func sameBytecode(a, b []byte) bool {
	return strings.TrimRight(normalise(a), "\n") == strings.TrimRight(normalise(b), "\n")
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}
