package show

// The default report of research-sdd-status.sh (slice S6): the structured status of one corpus. The sections that
// belong to slice S7, the §8c campaign block and the document-cycle outline, are reached through seams the S7 port
// fills; until then the production wiring answers the typed not-yet-ported line instead of a report with a hole.

// docMode is what the document-cycle detection answers (the _doc_mode / _doc_noheading flags).
type docMode int

const (
	docNone      docMode = iota // not a document-cycle corpus
	docOutline                  // method: document-cycle with a ## Outline heading
	docNoHeading                // method: document-cycle without one: the gap-centric verdicts are kept
)

// docCycle is the document-cycle section of the script (slice S7): the detection, and for an outline corpus the
// outline line (outline_summary + outline_line) and the outline's own next step (outline_next_step).
type docCycle struct {
	mode        docMode
	outlineLine func(c *ctx) string
	nextStep    func(c *ctx) string
}

// sections are the parts of the default report that belong to slice S7.
type sections struct {
	campaign func(c *ctx)          // campaign_status_block
	doc      func(c *ctx) docCycle // the _doc_mode detection and the outline readers
}

// liveSections are the production sections: none yet, so the default mode is still not ported (see defaultOr).
var liveSections = sections{}

// defaultOr answers the default report and leaves every other mode to rest. A section the report needs and no
// slice has ported yet makes it rest too.
func defaultOr(sm sections, rest tail) tail {
	return func(c *ctx) int {
		if c.opts.mode != modeStatus || sm.campaign == nil || sm.doc == nil {
			return rest(c)
		}
		return c.report(sm)
	}
}
