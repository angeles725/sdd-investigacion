package show

import (
	"time"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/gh"
)

// legacyDue is the cached probe as the S5 scenario tables model it: the canned fake of the world answers it with the
// argv `rsdd retro reconcile` had (--issues-cache <file> <retro>), bounded by _IDG_RECONCILE_TIMEOUT_SECS. Those
// worlds state what the child SAYS (a timeout, a degraded line, an exit code), not what a retro holds, so they run
// the gate through the subprocess seam; the in-process answer is pinned by inproc_test.go over real retros.
func legacyDue(retro, cache string, s cli.Stdio) probeResult {
	o := (&ctx{s: s}).ghOptions()
	secs := time.Duration(gh.ResolveBound(o.Env, o.Knob, o.Default).Seconds) * time.Second
	return reconcileRun([]string{"--issues-cache", cache, retro}, secs, s)
}
