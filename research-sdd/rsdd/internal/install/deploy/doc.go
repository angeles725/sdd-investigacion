// Package deploy will hold the Go port of research-sdd-install.sh: the harness installer that surfaces the
// research-sdd skill, launcher block, slash-command template, extension and agent definitions into each AI
// harness's own config root, and its --verify and --uninstall modes.
//
// It has no exported API yet. Today the package carries only the characterization harness of slice S0a
// (odd/tasks/install-trio-go.md): the frozen legacy scripts under testdata/legacy and the tests that pin what they do
// in a scratch HOME, so the port has an oracle and the legacy defects are visible as named expectations.
package deploy
