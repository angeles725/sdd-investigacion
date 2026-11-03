// Package corrections is `rsdd verify corrections <target-dir>`: the §14 reciprocal-backlink lint of a
// Research-SDD corpus, ported from toolbelt/verify-corrections.sh (kit issue #2625).
//
// A block that declares "Corrects [Block N]" must be back-linked by block N ("corrected in B<this>"). The
// command reads every canonical block file under the target (core/kit's discriminator, depth <= 3), extracts the
// correction declarations of each, resolves their targets and requires the reciprocal note.
package corrections
