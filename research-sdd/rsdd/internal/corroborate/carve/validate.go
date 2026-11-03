package carve

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strconv"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/fsx"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/jsonout"
)

// readStaged reads the worker's report through one no-follow descriptor, refusing a file that is not the
// regular, owned, 0400 file the worker made or that changed while it was read.
func readStaged(path string, euid uint64) ([]byte, error) {
	f, err := openNoFollow(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	before, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if !stagedFile(before, euid) {
		return nil, errStagedType
	}
	data, err := io.ReadAll(f)
	if err != nil {
		return nil, err
	}
	after, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if tupleOf(before) != tupleOf(after) {
		return nil, errors.New("staged input changed while reading")
	}
	return data, nil
}

// decodeReport parses the report keeping integers exact.
func decodeReport(data []byte) (map[string]any, error) {
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	var report map[string]any
	if err := dec.Decode(&report); err != nil {
		return nil, err
	}
	if _, err := dec.Token(); err != io.EOF {
		return nil, errors.New("extra data after the report")
	}
	if report == nil {
		return nil, errors.New("report is not an object")
	}
	return report, nil
}

var reportKeys = []string{"caps", "carves", "input", "isolation", "isolation_artifact", "limitations", "schema"}

var errContract = errors.New("manifest contract mismatch")

// checkContract refuses a report that is not exactly what this run asked the worker to produce: the same
// keys, schema, staged-input record, caps, isolation claim and launcher identity. Values are compared through
// their canonical encoding, so a type or key-order difference cannot slip through.
func checkContract(report map[string]any, want map[string]any) error {
	keys := make([]string, 0, len(report))
	for k := range report {
		keys = append(keys, k)
	}
	slices.Sort(keys)
	if !slices.Equal(keys, reportKeys) || report["schema"] != schema {
		return errContract
	}
	for name, expected := range want {
		a, errA := jsonout.Canonical(report[name])
		b, errB := jsonout.Canonical(expected)
		if errA != nil || errB != nil || !bytes.Equal(a, b) {
			return errContract
		}
	}
	return nil
}

// carveRecords reads the report's carve list into typed records.
func carveRecords(report map[string]any) ([]carveRecord, error) {
	list, ok := report["carves"].([]any)
	if !ok {
		return nil, errCarveRecord
	}
	out := make([]carveRecord, 0, len(list))
	for _, raw := range list {
		m, ok := raw.(map[string]any)
		if !ok {
			return nil, errCarveRecord
		}
		kind, _ := m["kind"].(string)
		path, _ := m["path"].(string)
		sum, _ := m["sha256"].(string)
		offset, okO := integer(m["offset"])
		size, okS := integer(m["size"])
		if !okO || !okS {
			return nil, errCarveRecord
		}
		out = append(out, carveRecord{kind, offset, size, path, sum})
	}
	return out, nil
}

func integer(v any) (int64, bool) {
	n, ok := v.(json.Number)
	if !ok {
		return 0, false
	}
	i, err := strconv.ParseInt(n.String(), 10, 64)
	return i, err == nil
}

var errCarveRecord = errors.New("manifest carve record is invalid")

// validateTree is the parent's check of everything the worker left in stage before it is published: the
// carve list is ordered and well formed, every carved file equals its input range and its record, the tree
// holds exactly the report, the carves and the staged input, every entry is owned, read-only and unlinked
// elsewhere, and the report file is the canonical encoding of the report just read. On success the staged
// input is removed and the directories are synced.
func validateTree(stage string, report map[string]any, euid uint64) error {
	records, err := carveRecords(report)
	if err != nil {
		return err
	}
	if !slices.IsSortedFunc(records, compareRecords) {
		return errors.New("manifest carve order is invalid")
	}
	expected := map[string]bool{schema + ".json": true, "input.bin": true}
	for _, item := range records {
		rel := carvePath(item.Offset, item.Kind)
		if (item.Kind != kindUImage && item.Kind != kindSquashFS) || item.Path != rel || item.Size < 1 {
			return errCarveRecord
		}
		if err := verifyCarve(stage, item); err != nil {
			return err
		}
		expected[rel] = true
	}
	seen := map[string]bool{}
	err = filepath.WalkDir(stage, func(path string, d fs.DirEntry, err error) error {
		if err != nil || path == stage {
			return err
		}
		fi, err := os.Lstat(path)
		if err != nil {
			return err
		}
		uid, nlink, ok := owner(fi)
		want := os.FileMode(0o400)
		if fi.IsDir() {
			want = 0o700
		}
		if !ok || uid != euid || fi.Mode().Perm() != want || fi.Mode()&(os.ModeSetuid|os.ModeSetgid|os.ModeSticky) != 0 {
			return errors.New("output ownership or mode violation")
		}
		switch {
		case fi.Mode().IsRegular():
			if nlink != 1 {
				return errors.New("output regular file has external hardlinks")
			}
			rel, _ := filepath.Rel(stage, path)
			seen[filepath.ToSlash(rel)] = true
		case !fi.IsDir():
			return errors.New("output tree contains a link or special file")
		}
		return nil
	})
	if err != nil {
		return err
	}
	canonical, err := jsonout.Canonical(report)
	if err != nil {
		return err
	}
	onDisk, err := os.ReadFile(filepath.Join(stage, schema+".json"))
	if err != nil || !sameSet(seen, expected) || !bytes.Equal(onDisk, canonical) {
		return errors.New("output tree or canonical manifest mismatch")
	}
	if err := os.Remove(filepath.Join(stage, "input.bin")); err != nil {
		return err
	}
	for _, dir := range []string{filepath.Join(stage, "carves"), stage} {
		if err := fsx.SyncDir(dir); err != nil {
			return err
		}
	}
	return nil
}

func compareRecords(a, b carveRecord) int {
	switch {
	case a.Offset != b.Offset:
		return cmpInt(a.Offset, b.Offset)
	case a.Kind != b.Kind:
		if a.Kind < b.Kind {
			return -1
		}
		return 1
	}
	return cmpInt(a.Size, b.Size)
}

func cmpInt(a, b int64) int {
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
	}
	return 0
}

func sameSet(a, b map[string]bool) bool {
	if len(a) != len(b) {
		return false
	}
	for k := range a {
		if !b[k] {
			return false
		}
	}
	return true
}

// verifyCarve re-reads one carved file next to the staged input: its bytes must equal the input range they
// claim, and their size and digest must equal the record.
func verifyCarve(stage string, item carveRecord) error {
	carved, err := openNoFollow(filepath.Join(stage, item.Path))
	if err != nil {
		return err
	}
	defer carved.Close()
	source, err := openNoFollow(filepath.Join(stage, "input.bin"))
	if err != nil {
		return err
	}
	defer source.Close()
	before, err := carved.Stat()
	if err != nil {
		return err
	}
	digest := sha256.New()
	var size int64
	have, want := make([]byte, 1<<20), make([]byte, 1<<20)
	for {
		// An empty read (n == 0, at the end of the file) compares and hashes nothing, so it needs no guard.
		n, rerr := io.ReadFull(carved, have)
		if _, err := source.ReadAt(want[:n], item.Offset+size); err != nil || !bytes.Equal(have[:n], want[:n]) {
			return errors.New("carve source range mismatch")
		}
		digest.Write(have[:n])
		size += int64(n)
		if rerr == io.EOF || rerr == io.ErrUnexpectedEOF {
			break
		}
		if rerr != nil {
			return rerr
		}
	}
	after, err := carved.Stat()
	if err != nil {
		return err
	}
	b, a := tupleOf(before), tupleOf(after)
	if b.dev != a.dev || b.ino != a.ino || b.size != a.size || b.mtimeNs != a.mtimeNs || b.ctimeNs != a.ctimeNs {
		return errors.New("carve changed while validating")
	}
	if size != item.Size || "sha256:"+hex.EncodeToString(digest.Sum(nil)) != item.SHA256 {
		return errors.New("carve identity mismatch")
	}
	return nil
}
