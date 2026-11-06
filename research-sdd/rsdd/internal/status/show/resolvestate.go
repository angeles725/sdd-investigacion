package show

import "github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/kit"

// resolveState is the state-file resolver of the run: the startup pick and the --sync-state --focus re-pick both
// go through it, so a test can force the rc 3 a real corpus cannot reach (the script's bash suite stubbed
// resolve_state_file from its second call on).
var resolveState resolver = kit.ResolveStateFile
