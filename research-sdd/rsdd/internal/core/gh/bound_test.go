package gh

import "testing"

func TestResolveBound(t *testing.T) {
	cases := []struct {
		name    string
		environ []string
		knob    string
		dflt    int
		want    Bound
	}{
		{"unset takes the default silently", nil, "", 0, Bound{Seconds: 20}},
		{"caller default", nil, "", 10, Bound{Seconds: 10}},
		{"negative default is the package default", nil, "", -3, Bound{Seconds: 20}},
		{"plain value", []string{"RSDD_GH_TIMEOUT=5"}, "", 10, Bound{Seconds: 5}},
		{"leading zeros", []string{"RSDD_GH_TIMEOUT=007"}, "", 10, Bound{Seconds: 7}},
		{"nine digits", []string{"RSDD_GH_TIMEOUT=999999999"}, "", 10, Bound{Seconds: 999999999}},
		{"nine digits after zeros", []string{"RSDD_GH_TIMEOUT=0000000005"}, "", 10, Bound{Seconds: 5}},
		{"ten digits", []string{"RSDD_GH_TIMEOUT=1234567890"}, "", 10, Bound{Seconds: 10, Bad: true}},
		{"empty", []string{"RSDD_GH_TIMEOUT="}, "", 10, Bound{Seconds: 10, Bad: true}},
		{"zero", []string{"RSDD_GH_TIMEOUT=0"}, "", 10, Bound{Seconds: 10, Bad: true}},
		{"zeros", []string{"RSDD_GH_TIMEOUT=000"}, "", 10, Bound{Seconds: 10, Bad: true}},
		{"negative", []string{"RSDD_GH_TIMEOUT=-5"}, "", 10, Bound{Seconds: 10, Bad: true}},
		{"garbage", []string{"RSDD_GH_TIMEOUT=abc"}, "", 10, Bound{Seconds: 10, Bad: true}},
		{"trailing garbage", []string{"RSDD_GH_TIMEOUT=5s"}, "", 10, Bound{Seconds: 10, Bad: true}},
		{"space", []string{"RSDD_GH_TIMEOUT= 5"}, "", 10, Bound{Seconds: 10, Bad: true}},
		{"last entry wins", []string{"RSDD_GH_TIMEOUT=abc", "RSDD_GH_TIMEOUT=3"}, "", 10, Bound{Seconds: 3}},
		{"other variables ignored", []string{"RSDD_GH_TIMEOUTX=3", "XRSDD_GH_TIMEOUT=4"}, "", 10, Bound{Seconds: 10}},
		{"own knob", []string{"RSDD_GH_TIMEOUT=3", "K=4"}, "K", 60, Bound{Seconds: 4}},
		{"own knob ignores the default knob", []string{"RSDD_GH_TIMEOUT=3"}, "K", 60, Bound{Seconds: 60}},
		{"own knob garbage", []string{"K=x"}, "K", 60, Bound{Seconds: 60, Bad: true}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := ResolveBound(c.environ, c.knob, c.dflt); got != c.want {
				t.Fatalf("ResolveBound(%q, %q, %d) = %+v, want %+v", c.environ, c.knob, c.dflt, got, c.want)
			}
		})
	}
}
