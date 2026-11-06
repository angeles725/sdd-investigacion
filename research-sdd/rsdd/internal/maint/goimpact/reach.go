package goimpact

import "fmt"

// reach turns a package's reverse closure into SHIM, UNREACHED and BLIND lines, or a typed FULL.
//
// Blind-spot bash files (rule ii) are added to the selection of every change that can reach the built binary,
// that is every non-test file whose closure holds the main package, not only command packages. They never make
// the file FULL, and they are NOT counted against --wide: the wide threshold counts only the SHIM bash files.
// The blind set is one fixed list per run, so folding it into the threshold would turn every change FULL.
func (a *Analysis) reach(file, dir string) []string {
	closure := a.mod.ReverseClosure(dir)
	cmds := a.mod.ClosureCommands(closure)
	inBinary := false
	for _, d := range closure {
		inBinary = inBinary || d == BinaryPkg
	}
	if len(cmds) == 0 && !inBinary {
		return []string{"NONE\t" + file + "\tgo-test-only"}
	}
	closureLine := fmt.Sprintf("CLOSURE\t%s\t%d\t%d", file, len(closure), len(cmds))
	distinct := map[string]bool{}
	var shims, unreached, blinds []string
	for _, c := range cmds {
		if len(a.callers[c]) == 0 { // C2: the enumerator sees every form, so no toolbelt suite reaches it
			unreached = append(unreached, "UNREACHED\t"+file+"\t"+c.String())
			continue
		}
		for _, b := range a.callers[c] {
			distinct[b] = true
			shims = append(shims, "SHIM\t"+file+"\t"+b+"\t"+c.String())
		}
	}
	if len(distinct) > a.wide {
		return append(full(file, fmt.Sprintf("closure of %d bash files is wider than %d", len(distinct), a.wide)), closureLine)
	}
	if inBinary {
		for _, f := range a.blind {
			blinds = append(blinds, "BLIND\t"+file+"\t"+f.Path+"\t"+f.Blind())
		}
	}
	out := append(append(shims, unreached...), blinds...)
	if len(shims) == 0 && len(blinds) == 0 {
		reason := "no-bash-caller"
		if len(cmds) == 0 {
			reason = "no-command"
		}
		out = append(out, "NONE\t"+file+"\t"+reason)
	}
	return append(out, closureLine)
}
