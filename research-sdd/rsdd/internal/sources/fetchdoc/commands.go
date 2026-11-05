// Package fetchdoc is `rsdd sources fetch-doc`, the port of toolbelt/fetch-doc.sh: it downloads and preserves an
// external source (a datasheet, a manual, a forum page) inside TARGET/sources/ and registers it in SOURCES.md.
//
// The work is split by responsibility across the sources domain: runner (starting tools), slug (snapshot names),
// redirect (the URL to register), download (part files, curl/wget), place (overwrite policy, versioned names),
// and core/srcregistry (the registry table and sha256 helpers, shared with verify-sources). This package owns the
// command line, the three modes (doc.go, web.go, ocr.go), cancellation (session.go) and the test seam (seam.go).
package fetchdoc

import "github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"

// Commands is this package's contribution to the command table. Exit 3 prints its own typed "DEGRADED:" lines, so
// no generic one is appended.
var Commands = []cli.Command{{
	Name:    "fetch-doc",
	Group:   "sources",
	Summary: "download and preserve an external source under TARGET/sources with a SOURCES.md row (port of fetch-doc.sh)",
	Run:     Run,
}}
