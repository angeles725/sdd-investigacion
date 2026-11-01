//go:build linux

package adapter

import (
	"path/filepath"
	"testing"
)

func parityGroup(t *testing.T, cases []scriptCase) {
	t.Helper()
	worlds := map[string]*world{}
	base := t.TempDir()
	for i, c := range cases {
		if _, dup := worlds[c.name]; dup {
			c.name += "#" + itoa(i)
		}
		w := newWorld(t, filepath.Join(base, "g"+itoa(i)))
		c.run(w)
		worlds[c.name] = w
	}
	compareWorlds(t, worlds)
}

func TestParityManifestCreateCases(t *testing.T)   { parityGroup(t, createCases()) }
func TestParityManifestManifestCases(t *testing.T) { parityGroup(t, manifestCases(t)) }
func TestParityManifestMiscCases(t *testing.T)     { parityGroup(t, miscCases()) }
