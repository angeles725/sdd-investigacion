# rsdd - Go port of the research-sdd toolbelt. Run from research-sdd/rsdd
# (or `make -C research-sdd/rsdd <target>`).
#
# Tool versions are pinned via `go run tool@vX`; bump them here, in one place.
STATICCHECK := honnef.co/go/tools/cmd/staticcheck@v0.8.2
GREMLINS    := github.com/go-gremlins/gremlins/cmd/gremlins@v0.6.0

BIN_DIR := ../bin
# Link-time stamp read by `rsdd version --source-hash`; the value comes from
# cmd/rsdd-srchash (the same code the tests pin against the fixture).
SOURCE_HASH_SYM := github.com/angeles725/sdd-investigacion/research-sdd/rsdd/internal/commands.sourceHash
export CGO_ENABLED := 0

# Every test binary that `make test` or `make teeth` starts runs under a memory cap and a timeout, so a
# runaway (a gremlins mutant that allocated without bound OOM-killed the 7 GB CI runner) dies as a test
# FAILURE - KILLED for gremlins - instead of starving the host. The cap is RLIMIT_AS (ulimit -v, KiB) set
# by a generated `go test -exec` wrapper: only test binaries and what they spawn are capped, never the
# compiler or linker, so the cap cannot turn into a build failure. The Go runtime alone reserves ~512 MiB
# of address space at start and the largest clean test binary peaks at ~70 MB RSS. TEST_MEM_KB=unlimited
# opts out explicitly (for a platform without ulimit -v); a cap that cannot be set fails the target.
TEST_MEM_KB  ?= 1048576
TEST_TIMEOUT ?= 5m
TESTFLAGS    ?=
define CAPPED
d="$$(mktemp -d)" && trap 'rm -rf "$$d"' EXIT && case "$$d" in *[[:space:]]*) echo "temp dir path has whitespace: $$d" >&2; exit 2 ;; esac && \
( ulimit -v $(TEST_MEM_KB) ) || { echo "cannot set ulimit -v $(TEST_MEM_KB) (set TEST_MEM_KB=unlimited to opt out)" >&2; exit 2; } && \
printf '#!/bin/sh\nulimit -v %s || exit 97\nexec "$$@"\n' '$(TEST_MEM_KB)' >"$$d/capexec" && chmod +x "$$d/capexec" && \
GOFLAGS="$$GOFLAGS -exec=$$d/capexec"
endef

.PHONY: check fmt-check vet test race lint teeth cross parity build

check: fmt-check vet test

fmt-check:
	@out="$$(gofmt -l .)"; if [ -n "$$out" ]; then echo "gofmt needed:"; echo "$$out"; exit 1; fi

vet:
	go vet ./...

test:
	@$(CAPPED) go test -timeout $(TEST_TIMEOUT) $(TESTFLAGS) ./...

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
# from turning kills into timeouts. Each mutant's test binary runs under the CAPPED wrapper (GOFLAGS
# reaches the `go test` gremlins starts); `go run -exec=env` keeps gremlins itself and its builds uncapped.
# TEETHTAGS reaches every mutant's test build: `nodiff` drops the bash differential tests (internal/retro/grammar
# takes ~80 s per run), which `make check` still runs once; gremlins reruns a whole package per mutant.
TEETHTAGS ?= nodiff
teeth:
	@export GOFLAGS="$$GOFLAGS -tags=$(TEETHTAGS)"; $(CAPPED) go run -exec=env $(GREMLINS) unleash --timeout-coefficient 6 .

cross:
	h=$$(go run ./cmd/rsdd-srchash .) && \
	GOOS=linux  GOARCH=amd64 go build -ldflags "-s -w -X $(SOURCE_HASH_SYM)=$$h" -o /dev/null ./cmd/rsdd && \
	GOOS=windows GOARCH=amd64 go build -ldflags "-s -w -X $(SOURCE_HASH_SYM)=$$h" -o /dev/null ./cmd/rsdd && \
	GOOS=darwin GOARCH=arm64 go build -ldflags "-s -w -X $(SOURCE_HASH_SYM)=$$h" -o /dev/null ./cmd/rsdd

# Placeholder: the legacy-vs-Go differential runner (testkit/parity) lands
# in U0.5. Nothing is ported yet, so there is nothing to compare; this
# target says so instead of pretending to have checked something.
parity:
	@echo "parity: no ported commands yet"

build:
	mkdir -p $(BIN_DIR)
	h=$$(go run ./cmd/rsdd-srchash .) && go build -ldflags "-s -w -X $(SOURCE_HASH_SYM)=$$h" -o $(BIN_DIR)/rsdd ./cmd/rsdd
