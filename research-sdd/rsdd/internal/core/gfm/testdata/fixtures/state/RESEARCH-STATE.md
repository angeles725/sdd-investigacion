# Table Reader Parity — Research State
next_session_queue: B3-G1, B3-G2, B3-G3, B3-G4, B3-G5, B3-G6, B3-G7, B3-G8, B3-G9, B3-G10
<!-- Fixture for table-reader-parity.test.sh (kit #2148): `\|`, `\\|`, `\\\|` are each ONE escaped pipe in GFM.
     The 5-column deferred rows (B3-G7..10; G10 escapes the status cell) are open deferred rows like B3-G1..3 (kit #2162): deferred_open counts both
     widths, so known_gaps = gaps_closed + investigable_open + deferred_open and verify-state.sh prints no sum WARN. -->

<!-- research-state.v1 -->
schema: research-state.v1
covered_blocks: 9
block_scope: shared-global
gaps_closed: 3
known_gaps: 16
investigable_open: 6
requires_execution_open: 0
blocked_open: 0
deferred_open: 7
<!-- /research-state.v1 -->

## Coverage
- **Coverage metric**: 3 / 16 closed

## Gap-backlog (prioritized)
| Priority | Gap | Artifact | Status |
|---|---|---|---|
| high | B1-G1 mid\|esc | x | pending |
| high | B1-G2 mid\\|even | x | pending |
| high | B1-G3 mid\\\|triple | x | pending |
| high | B2-G1 ok | x | pending · last\|esc |
| high | B2-G2 ok | x | pending · last\\|even |
| high | B2-G3 ok | x | pending · last\\\|triple |
| deferred | B3-G1 d\|esc | x | parked |
| deferred | B3-G2 d\\|even | x | parked |
| deferred | B3-G3 d\\\|triple | x | parked |
| deferred | B3-G4 closed | x | ✅ done \| y |
| deferred | B3-G5 closed | x | ✅ done \\| y |
| deferred | B3-G6 closed | x | ✅ done \\\| y |

| Priority | ID | Gap | Artifact | Status |
|---|---|---|---|---|
| deferred | B3-G7 | g\|esc | x | parked |
| deferred | B3-G8 | g\\|even | x | parked |
| deferred | B3-G9 | g\\\|triple | x | parked |
| deferred | B3-G10 | g | x | parked \| z |

## Iteration history
| It | Focus | Block | New gaps |
|---|---|---|---|
| 1\|a | f | B1 | 1 |
| 2\\|a | f | B2 | 1 |
| 3\\\|a | f | B3 | 1 |
| 4 | f\|a | B4 | 1 |
| 5 | f\\|a | B5 | 1 |
| 6 | f\\\|a | B6 | 1 |
| 7 | f | B7 | 1 \| a |
| 8 | f | B8 | 1 \\| a |
| 9 | f | B9 | 1 \\\| a |

## Stop control
