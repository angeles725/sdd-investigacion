package shellx

import (
	"reflect"
	"testing"
)

func TestDirName(t *testing.T) {
	for in, want := range map[string]string{"/x": "/", "x": ".", "/a/b": "/a", "/": "/", "": ".", "a/b/": "a", "//x": "/", "a//b": "a"} {
		if got := DirName(in); got != want {
			t.Errorf("DirName(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestBaseName(t *testing.T) {
	for in, want := range map[string]string{"": "", "/": "/", "//": "/", "a": "a", "a/b": "b", "a/b/": "b", "/a": "a"} {
		if got := BaseName(in); got != want {
			t.Errorf("BaseName(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestDecimal(t *testing.T) {
	for _, c := range []struct {
		in string
		v  int64
		ok bool
	}{
		{"0", 0, true}, {"09", 9, true}, {"9223372036854775807", 1<<63 - 1, true}, {"9223372036854775808", 0, false},
		{"9223372036854775800", 9223372036854775800, true}, {"92233720368547758070", 0, false},
		{"", 0, false}, {"1a", 0, false}, {"/", 0, false}, {":", 0, false}, {"-1", 0, false},
	} {
		if v, ok := Decimal(c.in); v != c.v || ok != c.ok {
			t.Errorf("Decimal(%q) = %d,%v want %d,%v", c.in, v, ok, c.v, c.ok)
		}
	}
}

func TestRecordLines(t *testing.T) {
	for _, c := range []struct {
		in   string
		want []string
	}{{"", nil}, {"a", []string{"a"}}, {"a\n", []string{"a"}}, {"a\n\n", []string{"a", ""}}, {"a\nb", []string{"a", "b"}}, {"\n", []string{""}}} {
		if got := RecordLines(c.in); !reflect.DeepEqual(got, c.want) {
			t.Errorf("RecordLines(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestWsClass(t *testing.T) {
	if WsClass != " \t\n\v\f\r" {
		t.Errorf("WsClass = %q", WsClass)
	}
}
