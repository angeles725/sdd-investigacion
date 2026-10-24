package parity

import (
	"fmt"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"strings"
)

// maxLinkHops bounds how many symlinks a single resolution may traverse; a
// loop or an absurdly long chain hits it and is refused.
const maxLinkHops = 40

// UnsafeLink is a symlink in a scratch copy that leaves the copy root.
type UnsafeLink struct {
	Path   string // slash-separated, relative to the copy root
	Target string // the link text exactly as stored
	Why    string
}

// scanSymlinks finds every symlink under root whose resolution can leave root.
// Resolution is lexical and hop by hop inside root, so it never touches the
// filesystem outside it:
//   - an absolute target is unsafe, even one that points back inside root;
//   - a relative target that climbs above root with ".." is unsafe;
//   - a chain is followed through inward links (and through inward directory
//     links met mid-path) and is unsafe if any hop escapes or the hop limit
//     is reached;
//   - inward links, dangling ones included, are safe.
//
// Every offending link is returned, not just the first. An unreadable root is an
// error, never "no links".
func scanSymlinks(root string) ([]UnsafeLink, error) {
	links := map[string]string{}
	var order []string
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		if info.Mode()&fs.ModeSymlink == 0 {
			return nil
		}
		rel, err := filepath.Rel(root, p)
		if err != nil {
			return err
		}
		target, err := os.Readlink(p)
		if err != nil {
			return err
		}
		rel = filepath.ToSlash(rel)
		links[rel] = target
		order = append(order, rel)
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("scan symlinks in %s: %w", root, err)
	}
	var unsafe []UnsafeLink
	for _, rel := range order {
		if why := resolveLink(links, rel, links[rel]); why != "" {
			unsafe = append(unsafe, UnsafeLink{Path: rel, Target: links[rel], Why: why})
		}
	}
	return unsafe, nil
}

func isAbsTarget(t string) bool {
	return strings.HasPrefix(t, "/") || strings.HasPrefix(t, `\`) || filepath.IsAbs(t)
}

func splitComps(t string) []string { return strings.Split(filepath.ToSlash(t), "/") }

// resolveLink walks target from the directory holding the link at rel and
// returns "" when the walk stays inside the root, else the reason it does not.
func resolveLink(links map[string]string, rel, target string) string {
	if isAbsTarget(target) {
		return "absolute target"
	}
	var cur []string
	if d := path.Dir(rel); d != "." {
		cur = strings.Split(d, "/")
	}
	queue := splitComps(target)
	hops := 0
	for len(queue) > 0 {
		c := queue[0]
		queue = queue[1:]
		switch c {
		case "", ".":
			continue
		case "..":
			if len(cur) == 0 {
				return "target resolves outside the copy root"
			}
			cur = cur[:len(cur)-1]
			continue
		}
		cand := strings.Join(append(append([]string{}, cur...), c), "/")
		next, isLink := links[cand]
		if !isLink {
			cur = append(cur, c)
			continue
		}
		if hops++; hops > maxLinkHops {
			return fmt.Sprintf("hop limit of %d reached (loop or chain too long)", maxLinkHops)
		}
		if isAbsTarget(next) {
			return fmt.Sprintf("chain reaches the absolute target of %s", cand)
		}
		queue = append(splitComps(next), queue...)
	}
	return ""
}

func refusal(tree string, unsafe []UnsafeLink) Problem {
	var sb strings.Builder
	fmt.Fprintf(&sb, "the %s scratch copy holds %d symlink(s) that leave the copy root; the case is refused and neither side was run:", tree, len(unsafe))
	for _, u := range unsafe {
		fmt.Fprintf(&sb, "\n  %s -> %q (%s)", u.Path, u.Target, u.Why)
	}
	return Problem{KindUnsafeLink, sb.String()}
}
