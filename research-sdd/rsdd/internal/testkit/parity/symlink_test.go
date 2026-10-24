package parity

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"
)

type linkSpec struct{ at, target string }

func mkLinks(t *testing.T, root string, links []linkSpec) {
	t.Helper()
	for _, l := range links {
		p := filepath.Join(root, l.at)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(l.target, p); err != nil {
			t.Fatal(err)
		}
	}
}

// scanWithin runs scanSymlinks in a goroutine so a missing hop limit is a named
// failure inside the default test timeout instead of a hang.
func scanWithin(t *testing.T, root string) ([]UnsafeLink, error) {
	t.Helper()
	type out struct {
		links []UnsafeLink
		err   error
	}
	ch := make(chan out, 1)
	go func() {
		l, err := scanSymlinks(root)
		ch <- out{l, err}
	}()
	select {
	case o := <-ch:
		return o.links, o.err
	case <-time.After(5 * time.Second):
		t.Fatalf("scan did not terminate within 5s (hop limit missing?)")
		return nil, nil
	}
}

func scanPaths(t *testing.T, root string) []string {
	t.Helper()
	got, err := scanWithin(t, root)
	if err != nil {
		t.Fatal(err)
	}
	var paths []string
	for _, u := range got {
		paths = append(paths, u.Path)
	}
	sort.Strings(paths)
	return paths
}

func TestScanSymlinks(t *testing.T) {
	tests := []struct {
		name  string
		links []linkSpec
		want  []string // relative paths of the links that must be reported
	}{
		{"no links", nil, nil},
		{"absolute outward", []linkSpec{{"l", "/etc/passwd"}}, []string{"l"}},
		{"absolute pointing back inside the root", []linkSpec{{"l", "@ROOT@/f.md"}}, []string{"l"}},
		{"relative climbing out", []linkSpec{{"sub/l", "../../x"}}, []string{"sub/l"}},
		{"relative one up from the top", []linkSpec{{"l", "../x"}}, []string{"l"}},
		{"inward relative", []linkSpec{{"l", "f.md"}}, nil},
		{"inward relative up and down", []linkSpec{{"sub/l", "../f.md"}}, nil},
		{"inward dangling", []linkSpec{{"l", "nothing/here"}}, nil},
		{"inward dir link", []linkSpec{{"dl", "sub"}}, nil},
		{"dot dot that stays inside", []linkSpec{{"sub/deeper/l", "../../f.md"}}, nil},
		{"chain escaping on the second hop", []linkSpec{{"a", "sub/b"}, {"sub/b", "../../out"}}, []string{"a", "sub/b"}},
		{"chain escaping on the third hop", []linkSpec{{"a", "b"}, {"b", "c"}, {"c", "/abs"}}, []string{"a", "b", "c"}},
		{"escape through an intermediate dir link", []linkSpec{{"dl", "sub"}, {"x", "dl/../../out"}}, []string{"x"}},
		{"link through an inward dir link stays inward", []linkSpec{{"dl", "sub"}, {"x", "dl/f.md"}}, nil},
		{"two escaping links", []linkSpec{{"one", "/a"}, {"two/three", "../../b"}}, []string{"one", "two/three"}},
		{"cycle hits the hop limit", []linkSpec{{"a", "b"}, {"b", "a"}}, []string{"a", "b"}},
		{"self link hits the hop limit", []linkSpec{{"a", "a"}}, []string{"a"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			root := t.TempDir()
			writeTree(t, root, map[string]string{"f.md": "x", "sub/g.md": "y", "sub/deeper/h.md": "z"})
			links := make([]linkSpec, len(tt.links))
			for i, l := range tt.links {
				links[i] = linkSpec{l.at, strings.ReplaceAll(l.target, "@ROOT@", root)}
			}
			mkLinks(t, root, links)
			got := scanPaths(t, root)
			if strings.Join(got, ",") != strings.Join(tt.want, ",") {
				t.Fatalf("reported %v, want %v", got, tt.want)
			}
		})
	}
}

// TestScanSymlinksHopLimitIsExact pins the boundary: a chain whose head needs
// exactly maxLinkHops traversals is inward, one more is refused (head only).
func TestScanSymlinksHopLimitIsExact(t *testing.T) {
	for n, want := range map[int]string{maxLinkHops + 1: "", maxLinkHops + 2: "l0"} {
		root := t.TempDir()
		writeTree(t, root, map[string]string{"f.md": "x"})
		var links []linkSpec
		for i := 0; i < n; i++ {
			next := fmt.Sprintf("l%d", i+1)
			if i == n-1 {
				next = "f.md"
			}
			links = append(links, linkSpec{fmt.Sprintf("l%d", i), next})
		}
		mkLinks(t, root, links)
		if got := strings.Join(scanPaths(t, root), ","); got != want {
			t.Errorf("chain of %d links: reported %q, want %q", n, got, want)
		}
	}
}

func TestScanSymlinksReportsTargetTextAndReason(t *testing.T) {
	root := t.TempDir()
	mkLinks(t, root, []linkSpec{{"abs", "/etc/hosts"}, {"up", "../x"}, {"loop", "loop"}})
	got, err := scanWithin(t, root)
	if err != nil || len(got) != 3 {
		t.Fatalf("%v %v", got, err)
	}
	by := map[string]UnsafeLink{}
	for _, u := range got {
		by[u.Path] = u
	}
	if by["abs"].Target != "/etc/hosts" || !strings.Contains(by["abs"].Why, "absolute") {
		t.Errorf("abs: %+v", by["abs"])
	}
	if by["up"].Target != "../x" || !strings.Contains(by["up"].Why, "outside") {
		t.Errorf("up: %+v", by["up"])
	}
	if !strings.Contains(by["loop"].Why, "hop") {
		t.Errorf("loop: %+v", by["loop"])
	}
}

func TestScanSymlinksAbsentRootIsAnError(t *testing.T) {
	if _, err := scanSymlinks(filepath.Join(t.TempDir(), "gone")); err == nil {
		t.Fatal("an unreadable root must be an error, not 'no links'")
	}
}
