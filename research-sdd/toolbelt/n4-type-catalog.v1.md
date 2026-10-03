# `n4-type-catalog.v1`

```
n4-type-catalog.sh build <dir>... [--out catalog.json]
n4-type-catalog.sh show  <catalog.json|dir> <ClassName|pkg.Class>
```

Static, offline catalog of the Slotomatic slot declarations of a Niagara-like Java
corpus: slot names, flags, defaults and facets per type, without a station. A station's
`.bog` stores only non-default values and a live station serves its type contract only
over BOX; the declarations below survive both original javadoc source and decompilation:

```java
public static final Property in8 = newProperty(Flags.READONLY, new BStatusNumeric(...), null);
public static final Action   set = newAction(Flags.OPERATOR, BDouble.DEFAULT, null);
public static final Topic    ev  = newTopic(Flags.SUMMARY, null);
```

Python 3 stdlib only. Read-only with respect to the corpus: `build` walks `*.java`
files and never evaluates or executes anything; the only write is the optional
`--out` JSON.

## Output

`build` emits a key-sorted JSON object `{ "<package>.<Class>": record }` (stdout, or
`--out`). A record is `{package, class, extends, source, properties[], actions[],
topics[]}`; each slot is `{name, flags, flagLetters, args[], default, facets}` plus
`unknownFlags[]` when the flag expression held a token the decoder does not know.
Value expressions stay strings. `flags` is the integer of `javax.baja.sys.Flags`
(`Flags.READONLY | Flags.SUMMARY` and decompiler `(int)9` both give `9`), `flagLetters`
the Niagara letter form (`rs`).

The summary line (stdout with `--out`, stderr otherwise):

```
types: N  properties: N  actions: N  topics: N  java-files: N  unknown-flag-tokens: N  duplicates: N  unreadable: N
```

`show` prints one type (`pkg.Class` or a bare `Class` suffix) from a catalog or by
building a directory on the fly.

## Exit codes and the three empty states

| Exit | Meaning |
|---|---|
| 0 | catalog built / type shown |
| 1 | nothing catalogued: no `.java` files under the roots (empty-input), `.java` files but no slot declarations (no-match; the message carries the file count), or `show` of an unknown type |
| 2 | usage error, a root that is not a directory (absent-input), an unreadable `--catalog`, or `python3` missing (typed `degraded` message on stderr, no catalog) |

A zero never reads as success: the summary always states how many `.java` files were
read, so "0 types from 0 files" and "0 types from 4,000 files" are distinguishable.

## Provenance and limits

- An entry is evidence only for the file it was parsed from (`source`). Inherited slots
  are NOT merged; walk `extends` yourself. A type with no declarations is omitted.
- The walk is sorted; when two trees declare the same `package.Class`, the first wins and
  `duplicates` counts the rest (deterministic output, byte-identical rebuilds).
- Flag tokens other than `Flags.NAME`, an integer, or a hex literal are NOT dropped
  silently: they are listed in the slot's `unknownFlags`, warned on stderr, and counted in
  `unknown-flag-tokens`. The decoded `flags` is then a lower bound for that slot. Known
  case: `Flags.A + Flags.B` (a `+` instead of `|`) is reported this way (1 slot in the
  N4 `docSource` corpus: `BRelation.inbound`).
- Unreadable files are counted and warned, never skipped quietly.

## Measured on the N4 corpus (read-only, 2026-10-03)

- `docSource` original source (2,603 `.java`): 721 types, 3,274 properties, 404 actions,
  69 topics, 1 unknown flag token, 0 duplicates.
- CFR vs Vineflower trees, 339 module pairs with both: 5,296 common types, 32,427 slots,
  32,427 flag-equal, 0 unknown tokens. The retro's 853/853 figure is a narrower slice; its
  selection is not recorded in the source issue, so it was not reproduced literally.

Companion suite: `tests/n4-type-catalog.test.sh` (synthetic fixtures under
`tests/fixtures/n4-type-catalog/`, mutation controls under `--prove-teeth`).
