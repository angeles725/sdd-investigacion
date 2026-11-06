//go:build unix && !nodiff

package deploy

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"strings"
	"testing"
)

// reorderRecord rewrites the bundle record with its file= lines in reverse order and a bundle_sha256 recomputed over
// that order (digest = sha256 of "<sha>\t<rel>\n" per line, as _rsdd_write_bundle_state computes it). The record is
// self-consistent, every member still matches, but the verifier hashes a SORTED manifest, so only the digest differs.
func (w *world) reorderRecord(rel string) {
	w.t.Helper()
	b, err := os.ReadFile(w.hp(rel))
	if err != nil {
		w.t.Fatal(err)
	}
	var files []string
	var rest []string
	for _, l := range strings.Split(strings.TrimRight(string(b), "\n"), "\n") {
		switch {
		case strings.HasPrefix(l, "file="):
			files = append([]string{l}, files...)
		case strings.HasPrefix(l, "bundle_sha256="):
		default:
			rest = append(rest, l)
		}
	}
	var manifest strings.Builder
	for _, l := range files {
		sum, path, _ := strings.Cut(strings.TrimPrefix(l, "file="), "  ")
		manifest.WriteString(sum + "\t" + path + "\n")
	}
	d := sha256.Sum256([]byte(manifest.String()))
	out := "bundle_sha256=" + hex.EncodeToString(d[:]) + "\n" + strings.Join(rest, "\n") + "\n" + strings.Join(files, "\n") + "\n"
	if err := os.WriteFile(w.hp(rel), []byte(out), 0o600); err != nil {
		w.t.Fatal(err)
	}
}

// dropKit removes a path from the staged kit and re-baselines the "kit unchanged" check, like the kit-agent case of
// TestVerifyStates.
func (w *world) dropKit(rel string) {
	w.t.Helper()
	if err := os.RemoveAll(join(w.kit, rel)); err != nil {
		w.t.Fatal(err)
	}
	w.kitBefore = w.snapshot(w.kit)
}

// Failure mode "--verify: digest mismatch with no differing member (:1105)": degraded, exit 2, "inconsistent record".
func TestVerifyDigestMismatchWithoutDifferingMember(t *testing.T) {
	w := newWorld(t)
	w.check("install", w.install("--harness", "claude"), 0, fromGolden, "")
	w.check("verify before", w.install("--verify", "--harness", "claude"), 0, fromGolden, "")
	w.reorderRecord(".claude/research-sdd/.installed-bundle-state")
	w.check("verify", w.install("--verify", "--harness", "claude"), 2, fromGolden, "")
}

// Failure mode "--verify: missing agent source". The kit loses its agent definitions (or, for pi, the extension
// source) after the install: the comparison set cannot be built, so the verdict is degraded, exit 2. A single
// missing agent file is different: the record still names it, so the bundle matches.
func TestVerifyMissingKitSource(t *testing.T) {
	cases := []struct {
		name, harness, drop string
		rc                  int
	}{
		{"agent dir", "claude", "agents/claude", 2},
		// a recorded agent whose kit source file is gone still matches: the comparison set is the record plus the kit
		{"one agent file", "claude", "agents/claude/research-sdd-risk.md", 0},
		{"pi extension", "pi", "install/pi/research-sdd-hooks.ts", 2},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			w := newWorld(t)
			w.check("install", w.install("--harness", c.harness), 0, fromGolden, "")
			w.dropKit(c.drop)
			w.check("verify", w.install("--verify", "--harness", c.harness), c.rc, fromGolden, "")
		})
	}
}
