package formats

import (
	"errors"
	"slices"
	"strings"
	"testing"
)

func TestZipPrivateFSCheckMountSelection(t *testing.T) {
	const denied = "output must reside on a Linux-private filesystem"
	// mount builds a mountinfo line with the given number of left-hand fields (id parent major:minor root
	// mount-point ... optional fields) before the " - " separator.
	mount := func(point, fstype string, leftFields int) string {
		left := []string{"36", "35", "98:0", "/", point, "rw", "shared:1", "master:2"}[:leftFields]
		if leftFields < 5 {
			left = []string{"36", "35", "98:0", "/mnt"}[:leftFields]
		}
		return strings.Join(left, " ") + " - " + fstype + " src rw"
	}
	table := func(lines ...string) string { return strings.Join(lines, "\n") + "\n" }
	for name, c := range map[string]struct {
		path, info string
		want       string
	}{
		"five left fields is a mount line":    {"/mnt/x/out", table(mount("/mnt", "ext4", 5)), ""},
		"six left fields is a mount line":     {"/mnt/x/out", table(mount("/mnt", "ext4", 6)), ""},
		"four left fields is not":             {"/mnt/x/out", table(mount("/mnt", "ext4", 4)), denied},
		"relative mount point is ignored":     {"/rel/x/y", table(mount("/", "nfs", 6), mount("rel/x", "ext4", 6)), denied},
		"dot mount point matches every path":  {"/a/b", table(mount(".", "ext4", 6)), ""},
		"same depth: the first line wins":     {"/mnt/x", table(mount("/mnt", "ext4", 6), mount("/mnt", "nfs", 6)), ""},
		"same depth: the first line wins (2)": {"/mnt/x", table(mount("/mnt", "nfs", 6), mount("/mnt", "ext4", 6)), denied},
		"two root lines: the first wins":      {"/mnt/x", table(mount("/", "ext4", 6), mount("/", "nfs", 6)), ""},
		"deeper mount first":                  {"/mnt/x/out", table(mount("/mnt/x", "ext4", 6), mount("/mnt", "nfs", 6)), ""},
		"deeper mount last":                   {"/mnt/x/out", table(mount("/mnt", "nfs", 6), mount("/mnt/x", "ext4", 6)), ""},
		"deepest mount decides, not first":    {"/mnt/x/out", table(mount("/", "ext4", 6), mount("/mnt", "nfs", 6)), denied},
		"a mount that does not contain it":    {"/mnt/x", table(mount("/", "ext4", 6), mount("/mnt/z", "nfs", 6)), ""},
		"no line at all":                      {"/mnt/x", "", denied},
		"private root, shallower sibling":     {"/mnt/x", table(mount("/mnt/x", "tmpfs", 6), mount("/mnt/xy", "nfs", 6)), ""},
		"malformed line for a matching mount": {"/mnt/x", "36 35 98:0 / /mnt rw - \n", "malformed mountinfo line"},
	} {
		err := zipPrivateFSCheck(c.path, c.info)
		if got := zipErrorMessage(err); got != c.want {
			t.Errorf("%s: error %q, want %q", name, got, c.want)
		}
	}
}

func TestVerbOf(t *testing.T) {
	if got := verbOf(nil); got != "" {
		t.Errorf("verbOf(nil) = %q", got)
	}
	if got := verbOf([]string{}); got != "" {
		t.Errorf("verbOf(empty) = %q", got)
	}
	if got := verbOf([]string{"create", "--root"}); got != "create" {
		t.Errorf("verbOf = %q", got)
	}
}

func TestZipDeepestFirst(t *testing.T) {
	got := zipDeepestFirst(map[string]bool{"a": true, "z": true, "a/b": true, "d/e": true, "a/b/c": true})
	if want := []string{"a/b/c", "a/b", "d/e", "a", "z"}; !slices.Equal(got, want) {
		t.Errorf("order = %v, want %v", got, want)
	}
	if got := zipDeepestFirst(nil); len(got) != 0 {
		t.Errorf("no directories: %v", got)
	}
}

func TestZipFirstErrorStopsAtTheFirstFailure(t *testing.T) {
	boom, later := errors.New("boom"), errors.New("later")
	var ran []string
	step := func(name string, err error) func() error {
		return func() error { ran = append(ran, name); return err }
	}
	if err := zipFirstError(step("a", nil), step("b", boom), step("c", later)); err != boom || !slices.Equal(ran, []string{"a", "b"}) {
		t.Errorf("failure in the middle: err %v, ran %v", err, ran)
	}
	ran = nil
	if err := zipFirstError(step("a", boom), step("b", nil)); err != boom || !slices.Equal(ran, []string{"a"}) {
		t.Errorf("failure first: err %v, ran %v", err, ran)
	}
	ran = nil
	if err := zipFirstError(step("a", nil), step("b", nil)); err != nil || !slices.Equal(ran, []string{"a", "b"}) {
		t.Errorf("all succeed: err %v, ran %v", err, ran)
	}
	if err := zipFirstError(); err != nil {
		t.Errorf("no steps: %v", err)
	}
}
