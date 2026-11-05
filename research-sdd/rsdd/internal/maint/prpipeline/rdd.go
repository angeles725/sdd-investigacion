package prpipeline

import (
	"bytes"
	"os"
	"regexp"
	"strings"

	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
)

// Exit states of rdd-start and rdd-drive as the pipeline reads them (the legacy kit-rdd-*.sh contract).
const (
	rddNotDue        = 10
	rddConsent       = 15
	exitRDDNotApprov = 13
	exitRDDStartErr  = 14
	exitConsent      = 15
	driveTail        = 6
	driveLineMax     = 300
)

// driveNoise are the progress lines of the driver that the summary leaves out (`grep -vE '^(RUN|LAUNCH)'`).
var driveNoise = regexp.MustCompile(`^(RUN|LAUNCH)`)

// rdd is step 4: assess and start the native review (rdd-start), then follow it to acknowledgement (rdd-drive).
// Both run in process, in the worktree, writing the review document under the state dir.
func (p *pipeline) rdd() (int, bool) {
	o := p.o
	doc := p.state + "/rdd-" + o.pr + ".json"
	args := []string{"--base-ref", o.base}
	if o.consent == "granted" {
		args = append(args, "--consent", "granted")
	}
	s := p.s
	s.Cwd = p.wt
	switch rc := p.start(append(args, p.wt, doc), s); rc {
	case 0:
		return p.drive(doc, s)
	case rddNotDue:
		p.say("rdd-not-due: #%s needs no native review; continuing", o.pr)
		return 0, false
	case rddConsent:
		return p.fail(exitConsent, "consent-required", "#%s: re-run with --consent granted to record the maintainer's standing grant", o.pr), true
	case cli.ExitDegraded:
		return p.fail(cli.ExitDegraded, "degraded", "kit-rdd-start.sh reported a missing dependency"), true
	default:
		return p.fail(exitRDDStartErr, "rdd-start-error", "#%s: kit-rdd-start.sh exited %d", o.pr, rc), true
	}
}

// drive runs rdd-drive with its output in <state>/rdd-drive-<pr>.log and prints the summary the bash printed: the
// whole log for a consent envelope, else its last lines without the progress noise.
func (p *pipeline) drive(doc string, s cli.Stdio) (int, bool) {
	o := p.o
	log := p.state + "/rdd-drive-" + o.pr + ".log"
	var buf bytes.Buffer
	s.Out, s.Err = &buf, &buf
	drc := p.driveRDD([]string{p.wt, doc}, s)
	_ = os.WriteFile(log, buf.Bytes(), 0o666)
	if drc == rddConsent {
		p.s.Out.Write(buf.Bytes())
	} else {
		for _, ln := range tailLines(buf.String()) {
			p.say2(ln)
		}
	}
	switch drc {
	case 0:
		return 0, false
	case cli.ExitDegraded:
		return p.fail(cli.ExitDegraded, "degraded", "kit-rdd-drive.sh reported a missing dependency"), true
	case rddConsent:
		return p.fail(exitConsent, "consent-required", "the review document is a consent envelope (#%s)", o.pr), true
	default:
		return p.fail(exitRDDNotApprov, "rdd-not-approved", "#%s: the review did not reach acknowledgement (rc=%d, log %s)", o.pr, drc, log), true
	}
}

// say2 prints a driver line as is (no prefix).
func (p *pipeline) say2(line string) { p.s.Out.Write([]byte(line + "\n")) }

// tailLines is `grep -vE '^(RUN|LAUNCH)' | cut -c1-300 | tail -6`.
func tailLines(log string) []string {
	var keep []string
	if log != "" {
		for _, ln := range strings.Split(strings.TrimSuffix(log, "\n"), "\n") {
			if !driveNoise.MatchString(ln) {
				keep = append(keep, cut(ln, driveLineMax))
			}
		}
	}
	keep = keep[max(0, len(keep)-driveTail):]
	return keep
}

// cut keeps the first n characters of a line.
func cut(s string, n int) string {
	r := []rune(s)
	return string(r[:min(n, len(r))])
}
