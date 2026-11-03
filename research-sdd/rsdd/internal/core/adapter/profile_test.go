//go:build linux

package adapter

import (
	"reflect"
	"strings"
	"testing"
)

func TestMakeProfileDefaultsAndOverrides(t *testing.T) {
	p, err := MakeProfile("test-profile", true, false, false)
	if err != nil || p != (Profile{Name: "test-profile", StaticOnly: true}) {
		t.Fatalf("defaults: %+v %v", p, err)
	}
	if got := p.Map(); !reflect.DeepEqual(got, map[string]any{"name": "test-profile", "static_only": true, "network_access": false, "target_execution": false}) {
		t.Fatalf("Map = %v", got)
	}
	n, _ := MakeProfile("test-network", true, true, false)
	d, _ := MakeProfile("test-dynamic", false, false, false)
	if !n.NetworkAccess || !n.StaticOnly || n.TargetExecution || d.StaticOnly || d.NetworkAccess || d.TargetExecution {
		t.Fatalf("overrides: %+v %+v", n, d)
	}
}

func TestMakeProfileRefusals(t *testing.T) {
	for _, name := range []string{"", "   ", "\t\n", " ", "\x1c"} {
		_, err := MakeProfile(name, true, false, false)
		want := "isolation profile name must be a non-empty string; got " + pyRepr(name)
		if pe, ok := err.(*PyError); !ok || pe.Class != "ValueError" || pe.Msg != want {
			t.Errorf("name %q: %v, want ValueError %q", name, err, want)
		}
	}
	_, err := MakeProfile("bad", true, false, true)
	want := "target_execution must be False for corroboration adapters; use a dedicated detonation adapter for target-executing analysis"
	if pe, ok := err.(*PyError); !ok || pe.Class != "ValueError" || pe.Msg != want {
		t.Errorf("target_execution: %v", err)
	}
	// The name is checked before target_execution, as in the Python.
	if _, err := MakeProfile("", true, false, true); err == nil || !strings.Contains(err.Error(), "non-empty string") {
		t.Errorf("name must be checked first: %v", err)
	}
}
