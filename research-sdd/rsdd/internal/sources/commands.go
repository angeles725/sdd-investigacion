// Package sources is the domain of the external-source commands (`rsdd sources ...`): the tools that preserve and
// check the evidence under TARGET/sources/. It only composes its sub-packages' command tables; each sub-package
// owns one responsibility (fetchdoc: the downloader; runner, slug, redirect, download, place: its parts). What
// another domain also needs lives in internal/core (srcregistry: the SOURCES.md table and sha256 helpers).
package sources

import (
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/cli"
	"github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/sources/fetchdoc"
)

// Commands is this domain's contribution to the command table.
var Commands = append([]cli.Command(nil), fetchdoc.Commands...)
