// Package serial owns the rsdd commands for serial-port tooling: offline analysis of serial frame logs and
// passive capture from a serial port (serial-frame.v1), and the read-only COM-port acquisition helper. See docs/adding-a-command.md.
package serial

import (
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/serial/console"
)

// Commands is this domain's contribution to the command table. A unit adds
// its entries here and never edits internal/commands.
var Commands = []cli.Command{
	{Name: "frame-analyze", Group: "serial", Summary: "offline analysis of serial frame logs: stats, diff and checksum search (serial-frame.v1)", Run: SerialFrameAnalyze},
	{Name: "frame-capture", Group: "serial", Summary: "passive serial frame capture: baud sweep and idle-gap framing (serial-frame.v1)", Run: SerialFrameCapture},
	console.Command,
}
