// Package secretscan is the domain of `rsdd secrets scan`, the leaked-secret-value scanner ported from
// toolbelt/scan-secrets.sh. It owns the command line (args.go, run.go); the scan itself is the core-tier engine
// internal/core/secretscan, which the corpus archive gate also calls in process. See docs/adding-a-command.md.
package secretscan

import "github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"

// Commands is this domain's contribution to the command table. Exit 3 prints its own typed "DEGRADED:" lines, so
// no generic one is appended.
var Commands = []cli.Command{{
	Name:    "scan",
	Group:   "secrets",
	Summary: "scan a corpus for leaked secret values: high-confidence patterns plus an advisory tier (port of scan-secrets.sh)",
	Run:     Run,
}}
