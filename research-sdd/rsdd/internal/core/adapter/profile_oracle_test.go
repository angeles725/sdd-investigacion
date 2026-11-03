//go:build linux && !nodiff

package adapter

import (
	"encoding/json"
	"os/exec"
	"reflect"
	"testing"
)

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
