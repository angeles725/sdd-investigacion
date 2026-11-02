# testkit/parity cases for the hook-wiring port (kit issue #2356)

Each directory is one case: `spec.json` (legacy argv relative to the legacy kit root, `rsdd` argv, env) and the
fixture target under `inputs/`. The legacy side is `internal/core/hookwiring/testdata/legacy/driver.sh`, which sources a frozen verbatim copy
of the first half of the old `lib/hook-wiring.sh`, so any checkout that holds these files is a valid legacy root.

Run from `research-sdd/rsdd` (the runner builds `rsdd` itself unless `RSDD_BIN` is set):

    RSDD_PARITY_LEGACY=$(cd .. && pwd) \
    RSDD_PARITY_SPECS=$PWD/internal/hook/testdata/parity \
    RSDD_PARITY_REQUIRE=1 \
    go test ./internal/testkit/parity -run 'TestParity$' -count=1 -v

U2.3b (kit issue #2357) adds `launch-*` and `wired-exec-*` cases: the legacy side is the frozen `hook-wiring-half2.sh`
through the `cli-launch-state` / `cli-wired-exec` driver modes. The runner fixes HOME, so the HOME-dependent shapes
(`$HOME/...` commands, the default history root) live in `differential_test.go` instead.

Cases cannot hold a `.git` directory (git does not track one), so the off-root shapes are covered by
`differential_test.go` instead, which builds its fixtures at run time.
