package git

import (
	"slices"
	"testing"
)

func TestWithoutSelectors(t *testing.T) {
	cases := []struct {
		name     string
		in, want []string
	}{
		{"nil", nil, []string{}},
		{"empty", []string{}, []string{}},
		{"nothing to drop", []string{"PATH=/bin", "HOME=/h"}, []string{"PATH=/bin", "HOME=/h"}},
		{"single selector", []string{"GIT_DIR=/x"}, []string{}},
		{"first", []string{"GIT_DIR=/x", "PATH=/bin", "HOME=/h"}, []string{"PATH=/bin", "HOME=/h"}},
		{"middle", []string{"PATH=/bin", "GIT_WORK_TREE=/x", "HOME=/h"}, []string{"PATH=/bin", "HOME=/h"}},
		{"last", []string{"PATH=/bin", "HOME=/h", "GIT_INDEX_FILE=/x"}, []string{"PATH=/bin", "HOME=/h"}},
		{"all four", []string{"GIT_DIR=a", "GIT_WORK_TREE=b", "GIT_COMMON_DIR=c", "GIT_INDEX_FILE=d", "PATH=/bin"}, []string{"PATH=/bin"}},
		{"a repeated selector", []string{"GIT_DIR=a", "PATH=/bin", "GIT_DIR=b"}, []string{"PATH=/bin"}},
		{"a repeated name keeps the last value", []string{"A=1", "B=1", "A=2"}, []string{"B=1", "A=2"}},
		{"a repeated name, last first", []string{"A=1", "A=2", "A=3", "B=1"}, []string{"A=3", "B=1"}},
		{"a similar name stays", []string{"GIT_DIR_X=1", "XGIT_DIR=1", "GIT_DIR"}, []string{"GIT_DIR_X=1", "XGIT_DIR=1", "GIT_DIR"}},
		{"an empty value is a value", []string{"GIT_DIR=", "A="}, []string{"A="}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := WithoutSelectors(c.in)
			if got == nil || !slices.Equal(got, c.want) {
				t.Fatalf("got %#v, want %#v", got, c.want)
			}
		})
	}
}

func TestWithoutSelectorsLeavesItsInput(t *testing.T) {
	in := []string{"GIT_DIR=a", "A=1", "A=2"}
	WithoutSelectors(in)
	if !slices.Equal(in, []string{"GIT_DIR=a", "A=1", "A=2"}) {
		t.Fatalf("input changed: %#v", in)
	}
}
