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

.PHONY: check fmt-check vet test race lint teeth cross parity build clean

check: fmt-check vet test

fmt-check:
	@out="$$(gofmt -l .)"; if [ -n "$$out" ]; then echo "gofmt needed:"; echo "$$out"; exit 1; fi

vet:
	go vet ./...

test:
	@$(CAPPED) go test -timeout $(TEST_TIMEOUT) $(TESTFLAGS) ./...

# -race needs cgo, so this target overrides the CGO_ENABLED=0 default. It runs under the same CAPPED
# wrapper as `test`, with its own knobs because a -race run uses several times the memory and time:
# RACE_MEM_KB (default 8 GiB, KiB units) is the address-space cap and RACE_TIMEOUT the per-binary timeout.
# A race binary was checked to start under the 8 GiB cap. RACE_MEM_KB=unlimited opts out. The cap is a
# target-specific TEST_MEM_KB, so `test` and `teeth` keep their own; a TEST_MEM_KB given on the make
# command line still wins over it (GNU make precedence), so set RACE_MEM_KB, not TEST_MEM_KB, for race.
RACE_MEM_KB  ?= 8388608
RACE_TIMEOUT ?= 30m
race: TEST_MEM_KB = $(RACE_MEM_KB)
race:
	@export CGO_ENABLED=1; $(CAPPED) go test -timeout $(RACE_TIMEOUT) $(TESTFLAGS) -race ./...

lint:
	go run $(STATICCHECK) ./...

# Mutation testing over the packages that carry behaviour. The gate is
# "no LIVED mutant among the covered ones", decided by the bridge suite
# (rsdd-go.test.sh --prove-teeth), not by a percentage: this target prints
# gremlins' report and exits 0 whatever the efficacy. Timed-out mutants are
# reported, not failed; the raised timeout coefficient keeps a loaded machine
# from turning kills into timeouts. Each mutant's test binary runs under the CAPPED wrapper (GOFLAGS
# reaches the `go test` gremlins starts); `go run -exec=env` keeps gremlins itself and its builds uncapped.
# TEETHTAGS reaches every mutant's test build: `nodiff` drops the bash differential tests (internal/core/retrogrammar
# takes ~80 s per run), which `make check` still runs once; gremlins reruns a whole package per mutant.
TEETHTAGS ?= nodiff
# Gremlins defaults to one mutant worker per CPU, each running `go test` on every core: on a small shared CI runner
# that starves the baseline coverage run (it then prints only `exit status 1`). TEETH_WORKERS bounds the parallel
# mutant workers (gremlins --workers) and TEETH_TEST_CPU the CPUs each mutant's test run may use, exported as
# GOMAXPROCS (gremlins passes its environment to `go test`). Never gremlins --test-cpu: v0.6.0 hands `go test`
# the single argument "-cpu N", the test run then fails to set up, and every mutant reads as KILLED.
# TEETH_PKG scopes the run to one package ("./internal/cli"); the default "." is the whole module, which the
# bridge suite narrows to the packages a PR changed when RSDD_TEETH_BASE is set. Like TEST_MEM_KB, all three
# are overridable on the command line or in the environment.
TEETH_WORKERS  ?= 4
TEETH_TEST_CPU ?= 1
TEETH_PKG      ?= .
teeth:
	@export GOFLAGS="$$GOFLAGS -tags=$(TEETHTAGS)" GOMAXPROCS=$(TEETH_TEST_CPU); $(CAPPED) go run -exec=env $(GREMLINS) unleash --timeout-coefficient 6 --workers $(TEETH_WORKERS) $(TEETH_PKG)

cross:
	h=$$(go run ./cmd/rsdd-srchash .) && \
	GOOS=linux  GOARCH=amd64 go build -ldflags "-s -w -X $(SOURCE_HASH_SYM)=$$h" -o /dev/null ./cmd/rsdd && \
	GOOS=windows GOARCH=amd64 go build -ldflags "-s -w -X $(SOURCE_HASH_SYM)=$$h" -o /dev/null ./cmd/rsdd && \
	GOOS=darwin GOARCH=arm64 go build -ldflags "-s -w -X $(SOURCE_HASH_SYM)=$$h" -o /dev/null ./cmd/rsdd

# Legacy-vs-Go differential harness (testkit/parity). The caller sets RSDD_PARITY_LEGACY.
parity:
	$(CAPPED) go test -count=1 -run '^TestParity$$' ./internal/testkit/parity

build:
	mkdir -p $(BIN_DIR)
	h=$$(go run ./cmd/rsdd-srchash .) && go build -ldflags "-s -w -X $(SOURCE_HASH_SYM)=$$h" -o $(BIN_DIR)/rsdd ./cmd/rsdd

# Removes only what this Makefile builds. gremlins has no fixed workdir here, and the Go build and
# module caches (GOCACHE, GOMODCACHE) are deliberately left alone.
clean:
	rm -rf $(BIN_DIR)
