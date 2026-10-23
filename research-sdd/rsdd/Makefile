# rsdd - Go port of the research-sdd toolbelt. Run from research-sdd/rsdd
# (or `make -C research-sdd/rsdd <target>`).
#
# Tool versions are pinned via `go run tool@vX`; bump them here, in one place.
STATICCHECK := honnef.co/go/tools/cmd/staticcheck@v0.8.2
GREMLINS    := github.com/go-gremlins/gremlins/cmd/gremlins@v0.6.0

BIN_DIR := ../bin
export CGO_ENABLED := 0

.PHONY: check fmt-check vet test race lint teeth cross parity build

check: fmt-check vet test

fmt-check:
	@out="$$(gofmt -l .)"; if [ -n "$$out" ]; then echo "gofmt needed:"; echo "$$out"; exit 1; fi

vet:
	go vet ./...

test:
	go test ./...

# -race needs cgo, so this target overrides the CGO_ENABLED=0 default.
race:
	CGO_ENABLED=1 go test -race ./...

lint:
	go run $(STATICCHECK) ./...

# Mutation testing over the packages that carry behaviour. The gate is
# "no LIVED mutant among the covered ones", decided by the bridge suite
# (rsdd-go.test.sh --prove-teeth), not by a percentage: this target prints
# gremlins' report and exits 0 whatever the efficacy. Timed-out mutants are
# reported, not failed; the raised timeout coefficient keeps a loaded machine
# from turning kills into timeouts.
teeth:
	go run $(GREMLINS) unleash --timeout-coefficient 6 .

cross:
	GOOS=linux  GOARCH=amd64 go build -o /dev/null ./cmd/rsdd
	GOOS=windows GOARCH=amd64 go build -o /dev/null ./cmd/rsdd
	GOOS=darwin GOARCH=arm64 go build -o /dev/null ./cmd/rsdd

# Placeholder: the legacy-vs-Go differential runner (testkit/parity) lands
# in U0.5. Nothing is ported yet, so there is nothing to compare; this
# target says so instead of pretending to have checked something.
parity:
	@echo "parity: no ported commands yet"

build:
	mkdir -p $(BIN_DIR)
	go build -o $(BIN_DIR)/rsdd ./cmd/rsdd
