package decompile

import (
	"bytes"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

// unit is one affected unit of the typed result.
type unit struct{ name, reason, fallback, result, note string }

// markerRE matches the failure texts of the engines, anchored as comments. Vineflower writes
// "// $VF: Couldn't be decompiled" INDENTED inside the method body, so leading whitespace is allowed; only a
// comment-LEADING line counts (a trailing comment after code does not). The informational '$VF:' comments
// (synthetic class, Extended synchronized range, finally-block / variable-type / multi-entry exception-range notes)
// are not failures; the ones saying the output is WRONG or will not compile are.
var markerRE = regexp.MustCompile(`^[[:space:]]*(//|/\*+|\*)[[:space:]]*(\$VF: (Couldn.t be decompiled|Could not decompile|Unable to decompile|Failed to decompile|[^!]*decompiled code is not correct|Invalid label|Made invalid labels)|Unable to fully decompile class|Unable to fully structure code|This method has failed to decompile|This method could not be decompiled|Exception decompiling|COULD NOT DECOMPILE)`)

// generatedClassRE names the separately compiled top-level classes that merely EXTEND a name already in the jar
// (CGLIB / Spring proxies, ByteBuddy subclasses): the engines emit them as their own source, so they are units
// and their omission must be detected. Only a name that ENDS in the generated suffix matches.
var generatedClassRE = regexp.MustCompile(`\$\$(Enhancer|FastClass|KeyFactory)By[A-Za-z0-9_]*\$\$[A-Za-z0-9_]+$|\$\$SpringCGLIB\$\$[0-9]+$|\$ByteBuddy\$[A-Za-z0-9_]+$`)

const (
	markerFound = iota
	markerNone
	markerError
)

// fileMarker scans one file for a failure marker.
func fileMarker(p string) int {
	b, err := os.ReadFile(p)
	if err != nil {
		return markerError
	}
	for _, line := range bytes.Split(b, []byte("\n")) {
		if markerRE.Match(line) {
			return markerFound
		}
	}
	return markerNone
}

// layoutKey is the unit's package-relative path. CFR/Procyon write output paths that follow the package, so a
// class stored under BOOT-INF/classes/, WEB-INF/classes/ or META-INF/versions/N/ is emitted WITHOUT that prefix.
func layoutKey(p string) string {
	for _, pre := range []string{"BOOT-INF/classes/", "WEB-INF/classes/"} {
		if strings.HasPrefix(p, pre) {
			return strings.TrimPrefix(p, pre)
		}
	}
	if rest, ok := strings.CutPrefix(p, "META-INF/versions/"); ok {
		if _, tail, ok := strings.Cut(rest, "/"); ok {
			return tail
		}
	}
	return p
}

// isUnitClass: a decompilation unit is a top-level class OR an orphan. A '$' class is INNER when any non-empty
// prefix ending just before one of its '$' has a .class beside it ($Gson$Types$X is inner of $Gson$Types although
// '$Gson' itself has no class); inner classes are emitted inside their outer's source.
func isUnitClass(f string) bool {
	b := strings.TrimSuffix(filepath.Base(f), ".class")
	if generatedClassRE.MatchString(b) {
		return true
	}
	for k := 1; k < len(b); k++ {
		if b[k] == '$' && isFile(filepath.Join(filepath.Dir(f), b[:k]+".class")) {
			return false
		}
	}
	return true
}

// record adds an affected unit. result: ok (fallback output in place), marked (the fallback output itself carries a
// failure marker), kept-primary (the marked primary output was kept) or failed (the unit has NO output).
func (j *job) record(u unit) {
	j.units = append(j.units, u)
	j.handled[layoutKey(u.name)] = true
	if u.result == "failed" {
		j.partial++
	}
}

// fallbackUnit decompiles input with the fallback engine into the out-dir.
func (j *job) fallbackUnit(name, reason, input, note string) {
	failed := "failed"
	if reason == "marker" {
		failed = "kept-primary"
	}
	fb := j.cfg.fallback
	if fb == "none" {
		j.record(unit{name, reason, "none", failed, note})
		return
	}
	tmp, err := os.MkdirTemp(j.work, "fb")
	j.must(err)
	rc := j.runEngine(fb, input, tmp)
	switch {
	case rc == 3:
		j.record(unit{name, reason, "unavailable", failed, note})
	case rc == 0 && hasJava(tmp):
		j.must(copyTree(tmp, j.outDir()))
		res := "ok" // a fallback whose OWN output carries a failure marker is not a success
		for _, rel := range find(tmp, func(rel string, d fs.DirEntry) bool { return d.Type().IsRegular() && strings.HasSuffix(rel, ".java") }) {
			if fileMarker(filepath.Join(tmp, rel)) == markerFound {
				res = "marked"
				break
			}
		}
		j.record(unit{name, reason, fb, res, note})
	default:
		j.record(unit{name, reason, fb, failed, note})
	}
}

// unitName names the whole input as a unit.
func (j *job) unitName() string {
	base := filepath.Base(j.cfg.in)
	if strings.HasSuffix(strings.ToLower(base), ".class") {
		return base[:len(base)-len(".class")]
	}
	return "<whole-artifact>"
}

// noIsolation records that the jar cannot be extracted: why on the unit, sweepWhy on the status line.
func (j *job) noIsolation(why, sweepWhy string) bool {
	_ = os.RemoveAll(j.ext)
	j.isolationWhy, j.sweepWhy = why, sweepWhy
	return false
}

// ensureExt extracts the jar's classes once; it fails (typed) when unzip is absent, the jar is unsafe, or it holds
// no class entries (a sources jar). unzip exit 1 means WARNINGS only (executable or prefixed jars) and is
// accepted; 11 = no matching entries; anything else is a real failure.
func (j *job) ensureExt() bool {
	if isDir(j.ext) {
		return true
	}
	unzip, err := j.d.tools.LookPath(j.cfg.unzipBin)
	if err != nil {
		j.isolationWhy, j.sweepWhy = "isolation=unavailable", "coverage-sweep-unavailable"
		return false
	}
	switch rc := j.d.run(j.cmd(unzip, "-q", "-o", j.cfg.in, "*.class", "-d", j.ext)).RC; rc {
	case 0, 1:
	case 11:
		return j.noIsolation("isolation=no-class-entries", "no-class-entries")
	default:
		return j.noIsolation("isolation=unavailable", "coverage-sweep-unavailable")
	}
	if len(find(j.ext, isClassName)) == 0 {
		return j.noIsolation("isolation=no-class-entries", "no-class-entries")
	}
	// A jar must not smuggle symlinks into the scratch tree.
	if len(find(j.ext, func(_ string, d fs.DirEntry) bool { return d.Type()&fs.ModeSymlink != 0 })) > 0 {
		return j.noIsolation("isolation=unavailable", "coverage-sweep-unavailable")
	}
	return true
}

// countResources is the failure path's count of non-class jar entries, which the per-package / whole-artifact
// re-runs do NOT copy: N, or "unknown" when the listing cannot be taken.
func (j *job) countResources() {
	j.resources = "unknown"
	unzip, err := j.d.tools.LookPath(j.cfg.unzipBin)
	if err != nil {
		return
	}
	res := j.d.run(j.cmd(unzip, "-Z1", j.cfg.in))
	if res.RC != 0 {
		return
	}
	n := 0
	if out := string(res.Stdout); out != "" {
		for _, l := range strings.Split(strings.TrimSuffix(out, "\n"), "\n") {
			if !strings.HasSuffix(l, "/") && !strings.HasSuffix(l, ".class") {
				n++
			}
		}
	}
	j.resources = strconv.Itoa(n)
}

// bisectPackage runs the primary engine per unit (top-level class or orphan '$' class) of one failing package.
func (j *job) bisectPackage(pkg string, idx int, reason string) {
	j.isolationLevel = "class"
	var outer []string
	for _, rel := range find(filepath.Join(j.ext, pkg), func(rel string, _ fs.DirEntry) bool {
		return !strings.Contains(rel, "/") && strings.HasSuffix(rel, ".class")
	}) {
		if isUnitClass(filepath.Join(j.ext, pkg, rel)) {
			outer = append(outer, rel)
		}
	}
	for k, rel := range outer {
		if j.budgetExhausted() {
			return // what is left is uncovered, so the sweep reports the exhausted budget
		}
		name := strings.TrimSuffix(rel, ".class")
		unitName := name
		if pkg != "." {
			unitName = pkg + "/" + name
		}
		f := filepath.Join(j.ext, pkg, rel)
		if len(outer) == 1 && reason != "empty" {
			j.fallbackUnit(unitName, reason, f, "")
			continue
		}
		cin := filepath.Join(j.work, "cin", strconv.Itoa(idx)+"-"+strconv.Itoa(k+1))
		cout := filepath.Join(j.work, "cout", strconv.Itoa(idx)+"-"+strconv.Itoa(k+1))
		j.must(os.MkdirAll(filepath.Join(cin, pkg), 0o755))
		j.copyClasses(filepath.Join(j.ext, pkg), filepath.Join(cin, pkg), func(b string) bool {
			return b == name+".class" || (strings.HasPrefix(b, name+"$") && strings.HasSuffix(b, ".class"))
		})
		switch crc := j.runEngine(j.cfg.engine, cin, cout); {
		case crc == 0 && hasJava(cout):
			j.must(copyTree(cout, j.outDir()))
		case crc == 0:
			j.fallbackUnit(unitName, "empty", f, "")
		default:
			j.fallbackUnit(unitName, reasonOf(crc), f, "")
		}
	}
}

// copyClasses copies the regular files of src (one level) accepted by match into dst.
func (j *job) copyClasses(src, dst string, match func(name string) bool) {
	ents, err := os.ReadDir(src)
	j.must(err)
	for _, e := range ents {
		if e.Type().IsRegular() && match(e.Name()) {
			j.must(copyFile(filepath.Join(src, e.Name()), filepath.Join(dst, e.Name())))
		}
	}
}

// isolateJar runs the primary engine per package, then per unit inside a failing package, then the coverage
// sweep. It returns 1 when isolation is unavailable, 2 when the isolation budget ran out, else 0.
func (j *job) isolateJar() int {
	if !j.ensureExt() {
		return 1
	}
	j.isolationLevel = "package"
	j.isoT0 = j.s.Clock()
	j.isolating = true
	seen := map[string]bool{}
	var pkgs []string
	for _, rel := range find(j.ext, isClassName) {
		d := filepath.Dir(rel)
		if d == "." {
			d = "" // the root sorts before every package, as its bare path sorts before "<root>/<pkg>"
		}
		if !seen[d] {
			seen[d] = true
			pkgs = append(pkgs, d)
		}
	}
	sort.Strings(pkgs)
	for n, pkg := range pkgs {
		if pkg == "" {
			pkg = "."
		}
		if j.budgetExhausted() {
			return 2
		}
		pin, pout := filepath.Join(j.work, "pin", strconv.Itoa(n+1)), filepath.Join(j.work, "pout", strconv.Itoa(n+1))
		j.must(os.MkdirAll(filepath.Join(pin, pkg), 0o755))
		j.copyClasses(filepath.Join(j.ext, pkg), filepath.Join(pin, pkg), func(b string) bool { return strings.HasSuffix(b, ".class") })
		switch prc := j.runEngine(j.cfg.engine, pin, pout); {
		case prc == 0 && hasJava(pout):
			j.must(copyTree(pout, j.outDir())) // the package decompiled whole
		case prc == 0:
			j.bisectPackage(pkg, n+1, "empty") // exit 0 with no source is never silently dropped
		default:
			j.bisectPackage(pkg, n+1, reasonOf(prc))
		}
	}
	return j.sweepCoverage()
}

// unitCovered: this run produced source for the unit. A file merely PRESENT in a reused out-dir is stale, not
// coverage: it must be newer than this run's stamp.
func (j *job) unitCovered(name string) bool {
	return j.isFresh(filepath.Join(j.outDir(), name+".java")) || j.isFresh(filepath.Join(j.outDir(), layoutKey(name)+".java"))
}

// findClass is the extracted .class of a unit named by its OUTPUT path (prefix-layout aware).
func (j *job) findClass(name string) string {
	cands := []string{
		filepath.Join(j.ext, name+".class"),
		filepath.Join(j.ext, "BOOT-INF/classes", name+".class"),
		filepath.Join(j.ext, "WEB-INF/classes", name+".class"),
	}
	vers, _ := filepath.Glob(filepath.Join(j.ext, "META-INF/versions/*", name+".class"))
	for _, c := range append(cands, vers...) {
		if isFile(c) {
			return c
		}
	}
	return ""
}

// hasBaseClass: the jar also carries the unit as a plain or WEB-INF entry (not versioned). A BOOT-INF base needs no
// test: it sorts before META-INF/versions, so its unit is already covered or handled when the versioned entry comes.
func (j *job) hasBaseClass(key string) bool {
	return isFile(filepath.Join(j.ext, key+".class")) ||
		isFile(filepath.Join(j.ext, "WEB-INF/classes", key+".class"))
}

// sweepCoverage demands that every unit class of the extracted jar is covered by fresh output or by a unit line.
// It returns 2 when the isolation budget is spent before a needed fallback. A multi-release versioned entry whose
// base entry exists is skipped: the base entry is the unit.
func (j *job) sweepCoverage() int {
	for _, rel := range find(j.ext, isClassName) {
		name := strings.TrimSuffix(rel, ".class")
		if !isUnitClass(filepath.Join(j.ext, rel)) {
			continue
		}
		if strings.HasPrefix(name, "META-INF/versions/") && j.hasBaseClass(layoutKey(name)) {
			continue
		}
		if j.unitCovered(name) || j.handled[layoutKey(name)] {
			continue
		}
		if j.isolating && j.budgetExhausted() {
			return 2
		}
		j.fallbackUnit(name, "missing", filepath.Join(j.ext, rel), "")
	}
	return 0
}

// scanMarkers falls back, per class, for every freshly written .java that carries a failure marker.
func (j *job) scanMarkers() {
	files := find(j.outDir(), func(rel string, d fs.DirEntry) bool {
		return d.Type().IsRegular() && strings.HasSuffix(rel, ".java")
	})
	for _, rel := range files {
		f := filepath.Join(j.outDir(), rel)
		name := strings.TrimSuffix(rel, ".java")
		// A pre-existing file inside the stamp's backdate window is not this run's.
		if !j.isFresh(f) || j.handled[layoutKey(name)] {
			continue
		}
		switch fileMarker(f) {
		case markerNone:
			continue
		case markerError:
			j.record(unit{name, "marker-scan-error", "none", "kept-primary", ""})
			continue
		}
		input := j.cfg.in
		if !strings.HasSuffix(strings.ToLower(input), ".class") {
			var c string
			if j.ensureExt() {
				c = j.findClass(name)
			}
			if c == "" {
				note := j.isolationWhy
				if note == "" {
					note = "no-class-entry"
				}
				j.record(unit{name, "marker", "none", "kept-primary", note})
				continue
			}
			input = c
		}
		j.fallbackUnit(name, "marker", input, "")
	}
}
