package classfile

import (
	"errors"
	"os"
	"sort"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// The exported surface java-corroboration.v1 (internal/corroborate/java) reads class-file facts and archive
// entries through. It is the same reader and the same Python-zipfile semantics as the CLASSFILE line, so a
// second reader never exists: ReadFacts is class_file_facts, (*Jar).Facts is read_class_facts, Summarize is
// summarize_facts, and the Jar accessors are the slice of zipfile.ZipFile jar_inventory uses.

// Fact is one class's facts as the report prints them. A nil Major, LVT or ResugarRisk is the report's null;
// Reason is "" for null (a class read in full) and a typed token otherwise.
type Fact struct {
	Major       *int
	LVT         *bool
	ResugarRisk *bool
	Reason      string
}

func (f facts) public() Fact {
	out := Fact{Reason: f.reason}
	if f.majorKnown {
		major, risk := f.major, f.resugarRisk()
		out.Major, out.ResugarRisk = &major, &risk
	}
	if f.lvtKnown {
		lvt := f.lvt
		out.LVT = &lvt
	}
	return out
}

// ReadFacts is class_file_facts: the facts of one class file's bytes. An unreadable header gives null facts and
// a reason, never a fake major 0.
func ReadFacts(data []byte) Fact { return classFacts(data).public() }

// Map is the class_facts[] record of the report, {"entry": entry, **facts}.
func (f Fact) Map(entry string) map[string]any {
	m := map[string]any{"entry": entry, "major_version": nil, "has_LocalVariableTable": nil, "resugar_risk": nil, "reason": nil}
	if f.Major != nil {
		m["major_version"] = *f.Major
	}
	if f.LVT != nil {
		m["has_LocalVariableTable"] = *f.LVT
	}
	if f.ResugarRisk != nil {
		m["resugar_risk"] = *f.ResugarRisk
	}
	if f.Reason != "" {
		m["reason"] = f.Reason
	}
	return m
}

// Summarize is summarize_facts: lvt is yes|no|mixed|unknown (unknown: no class had a readable LVT fact);
// unreadable_classes counts classes with no readable major, partial_classes those whose header was read but whose
// body walk failed.
func Summarize(records []Fact) map[string]any {
	seen := map[int]bool{}
	var lvtYes, lvtNo bool
	risk, unreadable, partial := 0, 0, 0
	for _, r := range records {
		if r.Major != nil {
			seen[*r.Major] = true
			if r.Reason != "" {
				partial++
			}
		} else {
			unreadable++
		}
		if r.LVT != nil {
			lvtYes, lvtNo = lvtYes || *r.LVT, lvtNo || !*r.LVT
		}
		if r.ResugarRisk != nil && *r.ResugarRisk {
			risk++
		}
	}
	majors := []int{}
	for m := range seen {
		majors = append(majors, m)
	}
	sort.Ints(majors)
	state := "unknown"
	switch {
	case lvtYes && lvtNo:
		state = "mixed"
	case lvtYes:
		state = "yes"
	case lvtNo:
		state = "no"
	}
	return map[string]any{
		"classes": len(records), "major_versions": majors, "lvt": state,
		"resugar_risk_classes": risk, "unreadable_classes": unreadable, "partial_classes": partial,
	}
}

// EntryInfo is the zipfile.ZipInfo slice jar_inventory validates.
type EntryInfo struct {
	Name string // ZipInfo.filename
	Size uint64 // ZipInfo.file_size
	Mode uint32 // (external_attr >> 16) & 0xFFFF
}

// IsDir is ZipInfo.is_dir().
func (e EntryInfo) IsDir() bool { return strings.HasSuffix(e.Name, "/") }

// IsSymlink is stat.S_ISLNK(Mode).
func (e EntryInfo) IsSymlink() bool { return e.Mode&0o170000 == 0o120000 }

// Jar is an open archive. The zero value is not usable; call OpenJar and Close.
type Jar struct {
	f *os.File
	a *archive
}

// ErrNotArchive is zipfile.is_zipfile(path) == False (or the path is not readable as a file).
var ErrNotArchive = errors.New("not a zip archive")

// ErrCrash is an entry name that is not valid UTF-8: the legacy script died with a traceback (exit 1) here.
var ErrCrash = errCrash

// PyClass is the Python exception class name a classfile error stands for ("BadZipFile", "NotImplementedError",
// "EOFError", "error" for zlib.error, "RuntimeError", "OSError"); "" for an error this package does not classify.
func PyClass(err error) string {
	var pe *pyError
	var ee *entryError
	switch {
	case errors.As(err, &pe):
		return pe.class
	case errors.As(err, &ee):
		return ee.class
	}
	return ""
}

// IsBadZip reports zipfile.BadZipFile, the one class ZipFile.testzip converts into a returned name.
func IsBadZip(err error) bool { return PyClass(err) == "BadZipFile" }

// OpenJar is `zipfile.is_zipfile(path)` then `zipfile.ZipFile(path)`. A path that is not an archive is
// ErrNotArchive; an archive whose central directory is damaged is an error PyClass names.
func OpenJar(path string) (*Jar, error) {
	f, err := os.Open(pyPath(path))
	if err != nil {
		return nil, ErrNotArchive
	}
	fi, err := f.Stat()
	if err != nil {
		_ = f.Close()
		return nil, ErrNotArchive
	}
	rec, ok := findEOCD(f, fi.Size())
	if !ok {
		_ = f.Close()
		return nil, ErrNotArchive
	}
	a, err := openArchive(f, fi.Size(), rec)
	if err != nil {
		_ = f.Close()
		return nil, err
	}
	return &Jar{f: f, a: a}, nil
}

// Close releases the file.
func (j *Jar) Close() error { return j.f.Close() }

// Entries is ZipFile.infolist(), in central-directory order.
func (j *Jar) Entries() []EntryInfo {
	out := make([]EntryInfo, len(j.a.entries))
	for i, e := range j.a.entries {
		out[i] = EntryInfo{Name: e.name, Size: e.usize, Mode: (e.extAttr >> 16) & 0xFFFF}
	}
	return out
}

// TestZip is ZipFile.testzip(): it reads every entry in full, so a damaged stream or a CRC mismatch shows. It
// returns the first entry name that raised BadZipFile; any other failure (zlib.error, EOFError,
// NotImplementedError, an encrypted entry) is returned as the error, as testzip lets it propagate.
func (j *Jar) TestZip() (string, error) {
	for _, e := range j.a.entries {
		_, err := j.a.read(j.a.byName[e.name])
		switch {
		case err == nil:
		case IsBadZip(err):
			return e.name, nil
		default:
			return "", err
		}
	}
	return "", nil
}

// ResugarMinMajor is the first class-file major (Java 9) whose lowering a decompiler reverses on the way back;
// every class at or above it is flagged resugar_risk.
const ResugarMinMajor = resugarMinMajor

// MaxClassBytesVar and DefaultMaxClassBytes are the per-class read limit read_class_facts applies.
const (
	MaxClassBytesVar     = envMaxClass
	DefaultMaxClassBytes = defaultMaxClass
)

// EnvLimit reads a positive-integer limit from the environment the way the classfile command does: unset or
// empty is def, a malformed value warns on s.Err and falls back to def.
func EnvLimit(s cli.Stdio, name string, def uint64) uint64 { return envLimit(s, name, def) }

// Facts is read_class_facts: the facts of one entry, with a typed reason when it cannot be read.
func (j *Jar) Facts(entry string, maxClass uint64) (Fact, error) {
	e, ok := j.a.byName[entry]
	if !ok {
		return nullWith(reasonUnreadableEntry).public(), nil // KeyError
	}
	f, err := entryFacts(j.a, e, maxClass)
	if err != nil {
		return Fact{}, err
	}
	return f.public(), nil
}
