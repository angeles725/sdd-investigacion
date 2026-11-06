package show

import "testing"

const goldenS7 = goldenS2Dir + "s7.golden"

// TestReplayS7 replays the frozen oracle outputs of the campaign and document-cycle scenarios
// (testdata/golden/s7.golden, generated from the frozen script by the differential test) through the port, under
// -tags nodiff too, so a mutant of the S7 sections dies here without bash.
func TestReplayS7(t *testing.T) { replayDefault(t, s7Scenarios(), goldenS7) }

func TestS7ScenarioNamesAreUnique(t *testing.T) { uniqueNames(t, s7Scenarios()) }
