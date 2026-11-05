// Package kitmaint holds what the kit-maintenance pipeline tools share (kit issue #2212, ported from
// toolbelt/maint/kit-maint-common.sh): number and path helpers, the bounded child runners with kit_retry's
// semantics, the typed dependency probe, and the flock / process-group primitives. Both the `rsdd maint` commands and
// the merge train (`rsdd gate merge-train`) use it, so a domain never imports another domain (archtest).
package kitmaint
