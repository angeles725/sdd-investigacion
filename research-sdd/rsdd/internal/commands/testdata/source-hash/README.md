# source-hash fixture

Input tree for TestFixtureHash. `expected-hash.txt` was computed INDEPENDENTLY of the Go
implementation, with this shell pipeline run from this directory:

    find . -type f \( -name '*.go' ! -name '*_test.go' -o -path ./go.mod -o -path ./go.sum \
        -o -path './vendor/*' -o -path './embed/*' -o -path '*/embed/*' \) \
        ! -path './testdata/*' ! -path '*/testdata/*' \
      | sed 's|^\./||' | LC_ALL=C sort \
      | while IFS= read -r p; do printf '%s\0%s\n' "$p" "$(sha256sum < "$p" | cut -d' ' -f1)"; done \
      | sha256sum | awk '{print "sha256:" $1}'

`find -type f` skips the symlink `link.go`. Excluded on purpose: a_test.go, link.go (symlink),
testdata/skip.go, pkg/testdata/skip.go, notes.txt, README.md, expected-hash.txt.
