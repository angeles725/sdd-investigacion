// Package formats owns the rsdd commands for binary format readers (zip, squashfs, qnx6, pcap, uimage, classfile, hdb).
// See docs/adding-a-command.md.
package formats

import "github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"

// Commands is this domain's contribution to the command table. A unit adds
// its entries here and never edits internal/commands.
var Commands = []cli.Command{
	{Name: "qnx6-read", Group: "formats", Summary: "list or extract from a raw QNX6 Power-Safe image (read-only)", Run: QNX6Read},
}
