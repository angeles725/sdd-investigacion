// Package helpers is the Go port of toolbelt/lib/adapter_helpers.py: the
// evidence envelope and manifest-CLI tail (EmitEvidence), the bind-scope guard
// (AssertSafeBindRoot), the venv bind (VenvRootFor, BindVenv), RunTruncation
// and WarnEvidence.
//
// Dropped as dead (no importer anywhere in research-sdd): pcap_magic_check,
// squashfs_superblock, PcapMagicError and the SQFS_* constants. The pcap magic
// constants stay because corroborate_pcap.py and pcap_flows.py import them.
package helpers

import "github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/core/adapter"

// Kind names which adapter_helpers exception class an Error stands for.
type Kind string

const (
	KindManifest  Kind = "ManifestError"
	KindVenvBind  Kind = "VenvBindError"
	KindBindScope Kind = "BindScopeError"
)

// Error is ManifestError, VenvBindError or BindScopeError: every one is an
// adapter.Error (errors.As to *adapter.Error succeeds), and Kind tells them
// apart. Err, when set, is the Python __cause__.
type Error struct {
	Kind Kind
	Msg  string
	Err  error
}

func newErr(kind Kind, msg string, cause error) *Error {
	return &Error{Kind: kind, Msg: msg, Err: cause}
}

func (e *Error) Error() string { return e.Msg }
func (e *Error) Unwrap() error { return e.Err }

// As makes every helpers.Error an adapter.Error, as the Python subclasses are.
func (e *Error) As(target any) bool {
	p, ok := target.(**adapter.Error)
	if ok {
		*p = &adapter.Error{Msg: e.Msg, Err: e.Err}
	}
	return ok
}
