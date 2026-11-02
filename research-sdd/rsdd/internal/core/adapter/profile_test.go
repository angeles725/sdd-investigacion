//go:build linux

package adapter

import (
	"encoding/json"
	"os/exec"
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

func TestParityMakeProfile(t *testing.T) {
	type in struct {
		Name            string `json:"name"`
		StaticOnly      bool   `json:"static_only"`
		NetworkAccess   bool   `json:"network_access"`
		TargetExecution bool   `json:"target_execution"`
	}
	var cases []in
	for _, name := range []string{"x", "", "  ", "\t", " a ", " ", "\u200b", "\x1f", "é", "it's", "a\"b", "bubblewrap-ghidra-static", "test-only-untrusted-bwrap"} {
		for m := 0; m < 8; m++ {
			cases = append(cases, in{name, m&1 != 0, m&2 != 0, m&4 != 0})
		}
	}
	rs := runDriver[pyOut](t, "profile", cases)
	for i, c := range cases {
		p, err := MakeProfile(c.Name, c.StaticOnly, c.NetworkAccess, c.TargetExecution)
		label := jsonString(c)
		if !rs[i].OK {
			pe, ok := err.(*PyError)
			if !ok || pe.Class != rs[i].Class || pe.Msg != rs[i].Msg {
				t.Errorf("%s: python %s(%q), go %v", label, rs[i].Class, rs[i].Msg, err)
			}
			continue
		}
		if err != nil {
			t.Errorf("%s: python ok, go %v", label, err)
			continue
		}
		got, _ := json.Marshal(p.Map())
		var want, have map[string]any
		_ = json.Unmarshal(rs[i].Value, &want)
		_ = json.Unmarshal(got, &have)
		if !reflect.DeepEqual(want, have) {
			t.Errorf("%s: python %v, go %v", label, want, have)
		}
	}
}

func TestParityNamedProfileConstants(t *testing.T) {
	py, err := exec.LookPath("python3")
	if err != nil {
		t.Fatalf("python3 is required: %v", err)
	}
	out, err := exec.Command(py, "-I", "testdata/manifest_driver.py", mustAbs(t, toolbeltDir), "profile_consts").Output()
	if err != nil {
		t.Fatal(err)
	}
	var want map[string]map[string]any
	if err := json.Unmarshal(out, &want); err != nil {
		t.Fatal(err)
	}
	got := map[string]map[string]any{}
	for k, p := range NamedProfiles() {
		got[k] = p.Map()
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("named profiles differ from isolation_profile.py\n go     %v\n python %v", got, want)
	}
	if len(got) != 8 {
		t.Fatalf("expected the 8 constants of isolation_profile.py, got %d", len(got))
	}
}
