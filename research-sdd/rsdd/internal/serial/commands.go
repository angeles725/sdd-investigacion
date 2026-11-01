// Package serial owns the rsdd commands for serial-port tooling: offline analysis of serial frame logs and
// passive capture from a serial port (serial-frame.v1). See docs/adding-a-command.md.
package serial

import "github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"

// Commands is this domain's contribution to the command table. A unit adds
// its entries here and never edits internal/commands.
var Commands = []cli.Command{
	{Name: "serial-frame-analyze", Group: "serial", Summary: "offline analysis of serial frame logs: stats, diff and checksum search (serial-frame.v1)", Run: SerialFrameAnalyze},
	{Name: "serial-frame-capture", Group: "serial", Summary: "passive serial frame capture: baud sweep and idle-gap framing (serial-frame.v1)", Run: SerialFrameCapture},
}
