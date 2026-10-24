package grammar

import (
	"reflect"
	"testing"
)

func TestDismissedIDs(t *testing.T) {
	for line, want := range map[string]struct {
		ids       []string
		malformed bool
	}{
		"<!-- review-status: applied · PARTIAL — shipped: #1; DISMISSED: #2 (reason; more); DEFERRED: #7 -->": {[]string{"2"}, false},
		"PARTIAL; DISMISSED: #2; DEFERRED: #7; DISMISSED: P3-P4 -->":                                          {[]string{"2", "P3", "P4"}, false},
		"x; DISMISSED: ; y":                       {nil, true},
		"x; DISMISSED: (only a reason)":           {nil, true},
		"x; dismissed: 3":                         {nil, false},
		"x; xDISMISSED: 3":                        {nil, false},
		"x (DISMISSED: 3) DISMISSED: 4":           {[]string{"4"}, false},
		"x --> DISMISSED: 4":                      {nil, false},
		"x; DISMISSED: 4 (a (nested) b) --> c; d": {[]string{"4"}, false},
		"DISMISSED:5":                             {[]string{"5"}, false},
		"review-status: a DISMISSED: 1 review-status: DISMISSED: 2": {[]string{"1", "review-status:", "DISMISSED:", "2"}, false},
		"": {nil, false},
	} {
		ids, malformed, err := dismissedIDs(line)
		if err != nil || !reflect.DeepEqual(ids, want.ids) || malformed != want.malformed {
			t.Errorf("dismissedIDs(%q) = %q %v %v, want %q %v", line, ids, malformed, err, want.ids, want.malformed)
		}
	}
}

func TestMarkerRowState(t *testing.T) {
	m := "<!-- review-status: applied · PARTIAL — shipped: #1, P2-P3; DISMISSED: #2, #4 (why); DEFERRED: #7 -->"
	for _, c := range []struct {
		line, rid string
		want      RowState
	}{
		{m, "1", RowShipped}, {m, "P3", RowShipped}, {m, "2", RowDismissed}, {m, "4", RowDismissed},
		{m, "7", RowOpen}, {m, "9", RowOpen}, {m, "", RowMalformed}, {"", "1", RowMalformed},
		{"<!-- review-status: applied · sha -->", "1", RowNotPartial},
		{"<!-- review-status: applied · PARTIAL — shipped: #1; DISMISSED: ; -->", "1", RowShipped},
		{"<!-- review-status: applied · PARTIAL — shipped: #1; DISMISSED: ; -->", "3", RowMalformed},
		{"<!-- review-status: applied · PARTIAL — shipped: #2; DISMISSED: #2 -->", "2", RowShipped},
		{"<!-- review-status: applied · PARTIAL — shipped: P1-P100001 -->", "P1", RowMalformed},
	} {
		if got := MarkerRowState(c.line, c.rid); got != c.want {
			t.Errorf("MarkerRowState(%q, %q) = %q, want %q", c.line, c.rid, got, c.want)
		}
	}
}
