// Package resume ports resume-state.sh and resume-render.sh (kit issue #2578) to `rsdd status resume-state` and
// `rsdd status resume-render`.
package resume

import "github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"

// StateCommand is `rsdd status resume-state`. Exit 3 is the typed DEGRADED contract of the script, which prints its own
// DEGRADED: line, so PlainExit3 keeps the dispatcher from appending a second one.
var StateCommand = cli.Command{Name: "resume-state", Group: "status", Summary: "machine-readable resume state derived from git (worktrees, branches, open PRs)", Run: RunState, PlainExit3: true}

// RenderCommand is `rsdd status resume-render`.
var RenderCommand = cli.Command{Name: "resume-render", Group: "status", Summary: "prose resume handoff rendered from a resume-state document", Run: RunRender, PlainExit3: true}

// RunState is the entry point of resume-state.
func RunState(args []string, s cli.Stdio) int { return 99 }

// RunRender is the entry point of resume-render.
func RunRender(args []string, s cli.Stdio) int { return 99 }
