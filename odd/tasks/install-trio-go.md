# install-trio-go — port the installer trio to Go

Objective: `research-sdd/install/install.sh` (548), `install/adapters.sh` (351) and `install/research-sdd-install.sh` (1729) become Go (`rsdd install harness`, `rsdd install setup`), modular, with the legacy defects fixed and pinned; `install.sh` shrinks to a bootstrap.
Branches: one per slice, each its own PR to main (stacked-to-main, auto-chain). First: `feat/install-trio-s0`.
Test runner: `GOFLAGS=-p=2 GOMAXPROCS=2 timeout 600 go test ./internal/<pkg>/` from `research-sdd/rsdd` (default build = with the frozen-legacy differentials; `-tags=nodiff` = without). Heavy runs only through `go-port-lanes/bin/heavy-run`.

## Specs

S1 (user, verbatim): "necesitamos pasar todo lo que tenemos python a GO, todo lo que se pueda mejorar, necesitamos que se mejore el codigo, optimizacion de codigo, necesitamos que el codgio de progrmaacion sea modular, paraq ue en caso de tengamos que modificar algo, anadir algo sepamos en donde tener que hacer eso."

S2 (user, verbatim): "tambien tomen en cuenta que ya hemos tenido problemas en la aprte de tareas de WSL2, que ocasionaban el colapsop o cierre de WSL2."

S3 (plan of record, `odd/tasks/go-port.md` §4.8, verbatim): "The installer builds from source when `go` is present, otherwise downloads the release asset and verifies its sha256."

S4 (safety, orchestrator ruling 2026-11-06; an assumption the user has not stated): no test, agent or session runs either installer against the real `$HOME`. Every run uses a scratch HOME (`--home <dir>` AND `HOME=<dir>`) created by the test under its temp dir. Tests put fakes for `apt-get`, `sudo`, `node`, `npm`, `pipx`, `curl`, `wget` and `git` (when the scenario does not need the real one) first on `PATH`; no test reaches the network. The first real-HOME run of the Go installer is left to the user.

S5 (modularity, from the user's standing rule): one responsibility per file, about 200 lines or less, data tables separate from logic, a domain never imports a domain (archtest). Shared engines live in `internal/core/*`.

S6 (slice S0a, this branch — TESTS ONLY, no production behaviour): freeze `install/adapters.sh` and `install/research-sdd-install.sh` byte-identical under `internal/install/deploy/testdata/legacy/` with their sha256 pinned in a test, build a characterization harness that runs the FROZEN legacy installer in a scratch HOME, and pin the legacy behaviour of the scenarios in "Failure modes" below that concern `research-sdd-install.sh` and `adapters.sh`. Each scenario asserts every observable effect: exit code, stdout, stderr (normalized for the scratch root), and the resulting tree (paths, modes, symlinks, content hashes). Scenarios whose legacy result is one of the "Legacy defects" below pin the LEGACY result and name the defect number in the scenario, so the Go port later flips exactly those expectations on purpose. `install.sh` (apt, sudo, Node, pipx, .bashrc) is NOT run in S0a: it is slice S0b, before S8.

S7 (slices S1-S9): as listed in "Slices" below. Each slice's specs are added here when it starts.

### External contract (s10 plan §2; explorer reading, spot-checked where marked VERIFIED)
- `--verify` lines and exits (0 match/absent, 1 drift, 2 degraded/usage; :1680-1693): parsed by
  internal/verify/skilldrifthook.go:52 (`^verify (harness=[^ ]+ status=degraded|kit status=behind)`), :314-317;
  asserted by install/tests/research-sdd-install.test.sh:2018-2044. Line shapes at :1037, :1110-1114, :976-984,
  :950-956, :843-857.
- Fix-command text `--harness <h> [--force-skill]`: skilldrift.go:452, install/pi/research-sdd-hooks.ts:173,225,
  verify-skill-drift.test.sh:120.
- Launcher block: markers `<!-- research-sdd:start/end -->` and the `Kit checkout:` / `Kit path:` lines
  (adapters.sh:313-322) are parsed by research-sdd-hooks.ts:143-146 and templates/hook-kit-run.sh:36; the render dir
  research-sdd/profile/* is read by research-sdd-hooks.ts:150.
- `.bashrc` block `export RESEARCH_SDD_KIT=` (install.sh:239), read by hook-kit-run.sh:26 (INFERRED as its source).
- adapters.sh as a FILE: existence check skilldrift.go:329; sourced or copied by kit-checkout-resolution.test.sh:90,
  verify-skill-drift.test.sh:19/43, verify-skill-drift-hook.test.sh:19/51, pi-hooks.test.sh:88,
  suite-impact.test.sh:260/484, ci-path-filter-coverage.test.sh:373.
- Goldens install/tests/golden/plan-{claude,pi,gentle-shell}.txt; toolbelt/tests/install.test.sh:20-30 mutates the
  bash text at SENTINEL-* comments (those teeth cannot carry over as-is); self-dir-idiom.test.sh:77-78,147-152.
- Docs: README.md:13-16, research-sdd/README.md:159-176, tool-registry.md:430, DYNAMIC-SETUP.md:12-21,
  skills/README.md:22-25, SKILL.md:305. PROMPT-LOOP.md: no reference.
- install.sh exits: 0 baseline OK, 1 baseline failed or not Debian, 2 unknown argument (:405-409).


### Go layout (s10 plan §3)
Shared engines go to core because verify must not import install (archtest):
- internal/core/harness: table.go (adapter table as DATA), field.go (paths + pi override), launcher.go
  (RenderSection, RenderTemplate), profile.go (Valid, List, Resolve). API: All() []Harness, Lookup(name),
  (Harness).Paths(home, env) (Paths, error). The copy in verify/skilldrift.go:55-60 moves here.
- internal/core/bundle: manifest.go (member hash incl. the `#research-sdd-section` suffix), record.go (parse/write
  `.installed-bundle-state` atomically), verify.go (`Verify(Options) Result{Lines, Exit}`), kitstale.go.
- internal/install/deploy (research-sdd-install.sh): options.go (flags + mode-conflict matrix), splice.go (ONE orphan
  policy, symlink write-through, mode kept), artifact.go (per-file deploy states), plan.go (dry-run lines), render.go
  (unrecorded guard, clean/complete, behind a Renderer interface), uninstall*.go, snippet.go, api.go
  (`Install(Options) Result`, `Uninstall(Options) Result`).
- internal/install/setup (install.sh): tiers.go (tier DATA), apt.go, node.go, pipx.go, bashrc.go (reuses deploy
  splice), report.go; calls a new exported detect.Check(Options) Result instead of grepping the cache file.
- Commands: `rsdd install harness`, `rsdd install setup` in the install domain's commands.go.
- Open (INFERRED, check before S4): whether archtest judges only the top-level segment, so install/setup may import
  install/deploy; whether detect-tools should move from flat internal/install to internal/install/detect.


### Slices (s10 plan §4)
S0 tests only: freeze the three legacy files under testdata/legacy, differential harness, the §5 scenarios as failing
   tests. S1 core/harness checked against adapters.sh; migrate skilldrift.go to it. S2 core/bundle record + manifest +
   Verify. S3 `rsdd install harness --verify`; skilldrifthook.go:158 calls bundle.Verify IN PROCESS (removes the Go ->
   bash hop that exists today); the bash --verify branch execs rsdd. S4 deploy splice + artifact state machine +
   markers. S5 profile render (needs the render-profile lane; proc fallback until its API exists). S6 install
   composition + goldens with the duplicate line removed: research-sdd-install.sh becomes a shim. S7 uninstall.
   S8 setup (tiers, apt, Node, pipx, .bashrc, in-process detect; needs the install-tool lane): install.sh becomes the
   bootstrap entry. S9 migrate the suites that source adapters.sh, drop skilldrift.go:329, DELETE adapters.sh.
   Correction to an earlier edge: adapters.sh only NAMES verify-tool-catalog.sh (:343); the trio does not call it.


### Failure modes (s10 plan §5)
- Kill during cp (:574/587/611): legacy leaves a truncated file that no longer matches its marker, next run says
  "diverged" and needs --force-skill. Go: atomic write; the next run is a managed update, exit 0.
- Kill before the record is written (:917): --verify prints `status=degraded reason=installed files present but no
  bundle record`, exit 2 (:976-981).
- Re-run: same bytes, same bundle_sha256, exactly one block, the .bashrc block once.
- Hand-edited SKILL.md: WARNING, kept, `kept-hand-edit=` recorded, then --verify exit 1; the same during a profile
  switch: exit 1 and launcher unchanged (:595-600); --force-skill with an existing .local-backup: exit 1 (:580).
- Unrecorded file in the render dir: REFUSED exit 1, nothing removed; --backup-unrecorded moves it.
- Symlinked prompt file: written through, link kept. Symlinked .bashrc: legacy severs it (install.sh:149), Go keeps it.
  Symlinked research-sdd/profile: refuse to clean. Read-only config root: exit 1, no record.
- HOME unset: install.sh silently uses /root (:36), r-s-install.sh dies under set -u (:1623); Go: typed exit 2.
  `--home ""`: exit 2. pi override relative or `/`: exit 2 (adapters.sh:157).
- --verify states: match; drift with modified / missing / extra; absent; corrupt record; digest mismatch with no
  differing member (:1105); missing agent source; degraded beats drift for the exit code.
- Uninstall: dry run by default; `kept (modified|unproven|symlink|outside config root)`; second run reports absent;
  no python3 -> exit 2 and nothing removed (:1324).
- Concurrent runs: no lock today. Go: a per-config-root lock, clear failure when busy (unix build tag).
- Success after doing nothing: `install.sh --harness bogus --dry-run` exits 0 (:442-444); a dry-run SKIP for a
  non-regular destination exits 0 while the real run fails later at :905.


### Legacy defects (s10 plan §6)
1. Duplicated pi-extension deploy block (:1551-1566 and :1568-1578); the golden pins the duplicate.
2. :619 a failed marker write only warns; later runs read the installer's own file as a hand-edit.
3. mktemp in $TMPDIR (mode 0600) then mv: the user's CLAUDE.md, AGENTS.md or .bashrc ends up 0600, and the rename is
   not atomic across filesystems (:203/:163, install.sh:111/:149).
4. Unbalanced markers handled two ways: install.sh:131-136 refuses (rc 3); r-s-install.sh:226-228 appends a second
   block and returns success.
5. install.sh:193,:361 hide `apt-get update` failures with `|| true`; :192 does not check tee; :197 prints INSTALLED
   without re-checking the version. 6. :356-360 a dpkg failure other than 100 is ignored.
7. :390 `${2:?}` gives a non-2 usage error while :409 returns 2. 8. :477 the cache path ignores --home.
9. :442-447 dry-run never previews the skill plan and does not validate the harness name.
10. r-s-install.sh:630 a failed orphan-profile cleanup only warns.
Not classified: :833 reads $PWD/.pi/subagents.json (verify output depends on cwd, documented);
skilldrift.go:42-45 keeps a known pi-override defect on purpose.


## Tasks

- [ ] T0a · S4, S6 · route: delegated (one sonnet writer; reason: context backstop of the orchestrating session) · commit: —
- [ ] T0b · S4 · install.sh characterization with fake apt/sudo/node/pipx · route: — · commit: —
- [ ] T1 · core/harness (adapter table as data; skilldrift.go copy moves there) · owner s3 or s1 · commit: —
- [ ] T2 · core/bundle (record, manifest, Verify) · commit: —
- [ ] T3 · `rsdd install harness --verify`; skilldrifthook calls bundle.Verify in process · commit: —
- [ ] T4 · deploy splice + artifact state machine · commit: —
- [ ] T5 · profile render (needs render-profile, s3) · commit: —
- [ ] T6 · install composition; research-sdd-install.sh becomes a shim · commit: —
- [ ] T7 · uninstall · commit: —
- [ ] T8 · setup; install.sh becomes the bootstrap (needs install-tool, s2, and the release workflow, s1) · commit: —
- [ ] T9 · migrate the suites that source adapters.sh; delete adapters.sh · commit: —

## Log

L1 (2026-11-06, user's original request, verbatim): "Ahora vamos a realizar lo siguiente: Primero, necesitamos pasar todo lo que tenemos python a GO, todo lo que se pueda mejorar, necesitamos que se mejore el codigo, optimizacion de codigo, necesitamos que el codgio de progrmaacion sea modular, paraq ue en caso de tengamos que modificar algo, anadir algo sepamos en donde tener que hacer eso. van a estar trabajando @1, @2, @3, y @4. @1 Va ser el que va a estar orquestando y tomando decisiones, pero de igual forma cada uno de todos se debe de tomar las recomendacions y ver cual es la mejor recomendacion. No me pregunten nada, vayan directo con sus recomendaciones [...] Trabajen con commit + push + pr + pr view + issues + merge, etc."
L2 (2026-11-06): slice plan by s10 (`sdd-investigacion-worktrees/s10-data/install-trio-plan.md`, origin/main 4f257f40), adopted by s1 with: distribution per go-port.md §4.8 (s10 withdrew its "release binaries optional"); real HOME off limits (S4); S0 split into S0a (deploy + adapters) and S0b (install.sh) so nothing that calls apt or sudo runs before its fakes are reviewed.
L3 (2026-11-06): forecast well over 400 authored lines → auto-chain, one PR per slice.
