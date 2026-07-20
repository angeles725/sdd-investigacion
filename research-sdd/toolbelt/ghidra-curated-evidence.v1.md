# Ghidra curated evidence v1

`ghidra-curated-evidence.v1` is the deterministic boundary between Ghidra 12.1.2 headless analysis and later Research-SDD adapters. The exporter reads Ghidra's analyzed program model only. It does not emulate, debug, launch, or execute imported code.

## Invocation

Run `CuratedEvidenceExporter.java` as a headless post-script with exactly eight arguments:

```text
<absolute-output.json> <functions> <symbols> <imports> <exports> <strings> <references> <string-chars>
```

Every cap is an explicit positive decimal integer. The output must be a normalized absolute path beneath an existing, non-symlink-resolved parent and must not already exist. Missing, malformed, non-positive, relative, normalized-different, or colliding arguments reject the script, publish no new report, and request project deletion.

## Encoding and order

The file is compact UTF-8 JSON followed by one LF. Object keys are lexicographically ordered. Evidence arrays are ordered by their canonical record encoding. There are no timestamps, random identifiers, executable paths, project paths, output paths, or host paths.

## Object

The top level contains `schema`, `status`, `program`, `analysis`, the six evidence arrays, `counts`, `caps`, `truncation`, `string_values_truncated`, `warnings`, `errors`, and `limitations`.

All fields are required. Consumers must reject an unknown schema rather than guessing compatibility. JSON numbers in this contract are non-negative integers; booleans are JSON booleans, not strings.

| Field | Type | Meaning |
| --- | --- | --- |
| `schema` | string | Exact value `ghidra-curated-evidence.v1`. |
| `status` | string | `complete` or `partial`. |
| `program` | object | Stable imported-program identity and language metadata. |
| `analysis` | object | Headless analysis timeout state. |
| evidence fields | arrays | Curated records, each bounded by its named cap. |
| `counts` | object | Per-evidence traversal observations. |
| `caps` | object | The seven validated invocation limits. |
| `truncation` | object | Per-evidence early-stop booleans. |
| `string_values_truncated` | integer | Number of shortened emitted values. |
| diagnostic fields | arrays | Warnings, errors, and known limitations. |

- `status` is `complete` only when analysis did not time out, every evidence traversal was exhausted, and no string value was shortened; otherwise it is `partial`.
- `program` records stable name, format, language, compiler, image base, and executable MD5 metadata. It deliberately omits the executable path.
- `analysis.timed_out` comes from Ghidra's headless analysis-timeout state.
- Functions record address, name, external state, and thunk state. Symbols, imports, and exports record address, name, type, and external state. Strings record address, value, and per-value truncation. References record source, destination, and type.
- `warnings`, `errors`, and `limitations` are always present arrays. This exporter reports contract failures by publishing no report and requesting project deletion. Ghidra 12.1.2 may still return zero from the outer `analyzeHeadless` process after the post-script rejects its input; process exit alone is not a success signal.

Addresses use Ghidra's address text for the imported program. Consumers must treat addresses as opaque strings scoped to this report; they are not host pointers. Symbol and reference types use Ghidra 12.1.2 program-model names and are version-scoped strings.

The exporter never includes Ghidra project identity, script arguments, log content, source filenames, source directories, executable paths, or output paths. A string discovered inside the imported binary remains target evidence and is not host provenance.

## Caps and truthfulness

Caps apply while traversing each Ghidra iterator, not after materializing an unbounded result. At most `cap + 1` records are observed. The extra observation proves truncation without scanning the remainder.

For every evidence class, `counts` reports `emitted`, `observed`, and `exact`. If traversal stops early, `exact` is false, `observed` is only the number actually visited, and `truncation` is true. It is never presented as a total. Every emitted string value is bounded by `string_chars`; `string_values_truncated` reports how many were shortened, while string records additionally expose `value_truncated`.

Record caps are independent. Reaching one cap does not stop another evidence traversal. A consumer determines completeness per class from `counts.<class>.exact`, not from `observed`, and determines report-wide completeness from `status`.

String bounds count Unicode code points. Truncation preserves a valid prefix and never splits a surrogate pair. JSON escaping is deterministic: quotes, reverse solidus, controls, and unpaired surrogates are escaped; other characters are encoded directly as UTF-8.

## Versioning

This schema is authored and behavior-tested against Ghidra 12.1.2. A change to field meaning, required fields, ordering, cap truthfulness, or address/value encoding requires a new schema version. Additive implementation fixes that preserve byte-level semantics remain v1.

The source-shipped script is compiled by Ghidra headless. The real-Ghidra test is therefore both an API compatibility check and an execution check. Supporting another Ghidra version requires running that behavior suite and revisiting this version statement.

## Safety boundary

The exporter uses only analyzed `Program`, function, symbol, defined-data, and reference models. It contains no debugger, emulator, process-launch, or target-call surface.

Ghidra still parses untrusted binary input in the host process. This slice does not claim parser containment, network isolation, resource isolation, immutable tool provenance, or protection from local user configuration. Those controls belong to the later hardened Python/Bubblewrap adapter and MUST NOT be inferred from this contract.

Creating a Ghidra project and running analyzers can write Ghidra-owned temporary state. Callers are responsible for isolated project and user-state directories and project deletion. The exporter creates only the requested report with create-new semantics.

The future hardened wrapper MUST require a newly published, well-formed report independently of the outer process exit. Missing, unchanged, or malformed output is failure even when `analyzeHeadless` returns zero.

## Consumer checks

A conforming consumer should fail closed unless all of these hold:

- UTF-8 decoding and JSON parsing succeed with no trailing data after the LF.
- `schema` is the exact supported version.
- Required fields and per-record fields are present with the documented types.
- Every `emitted` count equals its array length and does not exceed its cap.
- `observed` is not treated as a total when `exact` is false.
- `status` agrees with timeout and truncation state.
- Evidence addresses remain scoped to the recorded program metadata.

## Limitations

The contract describes curated static evidence, not complete program semantics. Ghidra analysis can be incomplete or wrong, symbols may be synthesized, references depend on enabled analyzers, and capped observations cannot establish unseen totals. Isolation, staging, provenance, process output bounds, and hostile-parser containment belong to the later hardened adapter slice and are intentionally out of scope here.
