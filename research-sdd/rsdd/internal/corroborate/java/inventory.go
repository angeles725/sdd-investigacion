package java

import (
	"errors"
	"os"
	"sort"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/corroborate/classfile"
)

// inventory is jar_inventory's result: what the staged input declares, before any adapter ran.
type inventory struct {
	entryCount      int
	expandedBytes   uint64
	classEntries    []string
	expectedTotal   int
	expectedClasses []string
	classesTruncated,
	multiRelease bool
}

// jarInventory is jar_inventory: the archive must be a real, safe, intact ZIP within the caps.
func jarInventory(path string, maxFiles, maxBytes, maxClasses int64) (*inventory, error) {
	fi, err := os.Stat(path)
	if err != nil {
		return nil, osFailure(err, path)
	}
	if fi.Size() > maxBytes {
		return nil, fail("input exceeds --max-bytes")
	}
	jar, err := classfile.OpenJar(path)
	switch {
	case errors.Is(err, classfile.ErrNotArchive):
		return nil, fail("input is not a valid JAR/ZIP")
	case err != nil:
		return nil, archiveFailure(err)
	}
	defer jar.Close()
	entries := jar.Entries()
	if int64(len(entries)) > maxFiles {
		return nil, fail("JAR entry count exceeds --max-files")
	}
	var expanded uint64
	for _, e := range entries {
		expanded += e.Size
	}
	if expanded > uint64(maxBytes) {
		return nil, fail("JAR expanded bytes exceed --max-bytes")
	}
	names := map[string]bool{}
	for _, e := range entries {
		if unsafeEntry(e) || names[e.Name] {
			return nil, fail("unsafe or duplicate JAR entry: %s", e.Name)
		}
		names[e.Name] = true
	}
	corrupt, err := jar.TestZip()
	if err != nil {
		return nil, corruptEntry(err)
	}
	if corrupt != "" {
		return nil, fail("corrupt JAR entry: %s", corrupt)
	}
	inv := &inventory{entryCount: len(entries), expandedBytes: expanded}
	var base []string
	seen := map[string]bool{}
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name, ".class") {
			continue
		}
		inv.classEntries = append(inv.classEntries, e.Name)
	}
	sort.Strings(inv.classEntries)
	for _, name := range inv.classEntries {
		if strings.HasPrefix(name, "META-INF/versions/") {
			inv.multiRelease = true
			continue
		}
		if strings.HasSuffix(name, "module-info.class") || strings.HasSuffix(name, "package-info.class") {
			continue
		}
		class := strings.ReplaceAll(name[:len(name)-len(".class")], "/", ".")
		if !seen[class] {
			seen[class] = true
			base = append(base, class)
		}
	}
	sort.Strings(base)
	inv.expectedTotal = len(base)
	inv.classesTruncated = int64(len(base)) > maxClasses
	if inv.classesTruncated {
		base = base[:maxClasses]
	}
	inv.expectedClasses = base
	if inv.classEntries == nil {
		inv.classEntries = []string{}
	}
	if inv.expectedClasses == nil {
		inv.expectedClasses = []string{}
	}
	return inv, nil
}

// unsafeEntry is the per-entry refusal of jar_inventory: an empty, backslashed, NUL-carrying, absolute,
// non-canonical or dot-dot name, or a symlink.
func unsafeEntry(e classfile.EntryInfo) bool {
	name := e.Name
	if e.IsDir() {
		name = name[:len(name)-1]
	}
	if name == "" || strings.ContainsAny(name, "\\\x00") || strings.HasPrefix(name, "/") {
		return true
	}
	if pyNorm(name) != name {
		return true // PurePosixPath(name).as_posix() != name
	}
	for _, part := range strings.Split(name, "/") {
		if part == ".." {
			return true
		}
	}
	return e.IsSymlink()
}

// archiveFailure is what main prints for a ZipFile the directory of which cannot be read.
func archiveFailure(err error) error {
	if errors.Is(err, classfile.ErrCrash) {
		return err
	}
	return fail("corrupt JAR archive: %s", classfile.PyClass(err))
}

// corruptEntry is the failure testzip lets through: zlib.error, EOFError and NotImplementedError are typed
// failures naming the exception class; anything else is an operational error.
func corruptEntry(err error) error {
	switch class := classfile.PyClass(err); class {
	case "error", "EOFError", "NotImplementedError":
		return fail("corrupt JAR entry: %s", class)
	case "OSError":
		return fail("[Errno 22] Invalid argument")
	}
	return err
}
