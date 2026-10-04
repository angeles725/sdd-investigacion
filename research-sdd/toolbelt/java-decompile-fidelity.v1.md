# java-decompile-fidelity.v1 — Source-Syntax Claims vs Bytecode Shape

**Status**: active
**Scope**: guidance (a reference matrix; no script reads it)

## Purpose

A claim about Java SOURCE SYNTAX (this code uses an `instanceof` pattern, a `var`, a text
block, a switch expression, a lambda, a record) that rests on a decompiled `.java` file is
INADMISSIBLE as `[CERT]` (METHODOLOGY §5, "Source-syntax claims from decompiled Java"). A
decompiler chooses the syntax it prints; the class file records only what javac emitted.
This matrix names, per construct, the bytecode shape that can distinguish it — or states
that none exists, in which case the claim stays `[INFER]` at most. Cite the shape with a
`javap -c -p -v` excerpt (`file:line` into the preserved output), never the decompiled text.

(Kit issue #1204. Builds on `toolbelt/java-fidelity-experiment.sh` (kit issue #1488) and the
lint pack `jvm` R1; this document is the reference table those do not carry.)

## Two facts that make decompiled syntax unreliable

1. **Resugaring depends on the class-file major version.** Vineflower rewrites bytecode into
   the newest syntax the class-file version allows. The SAME bytecode renders as classic code
   when the class is major 52 (Java 8) and as modern syntax when it is major 69 (Java 25) —
   measured on one `BQudtUnitTag` pair: identical bytecode, different printed syntax
   (niagara5-research B84 §84.3). The printed syntax therefore tells you the decompiler's
   rendering rule for that major version, not what the author wrote.
2. **Agreement between decompilers is not fidelity evidence.** Two or more engines (for
   example the pairwise agreement `corroborate-java.sh` reports) can print the same syntax
   because they apply the same resugaring rule. Agreement shows the engines are consistent
   with each other; it says nothing about the original source.

Record the class-file `major_version` (`javap -v`, "major version:" line) in every claim that
mentions syntax. Once kit issue #1205 lands, the decompile wrappers will print it; until then
read it from `javap -v` yourself — do not assume any wrapper does.

## Matrix

"Distinguishing shape" means a bytecode feature that javac emits ONLY for that construct (at
the stated class-file major version or newer). "None" means javac output is identical to the
classic form: the construct cannot be proved from the class file.

| Construct (min. major) | Distinguishing bytecode shape | Admissible as `[CERT]` from bytecode? |
|---|---|---|
| `instanceof` pattern (60) | None. javac emits `instanceof` + `checkcast` + store, the same as `if (x instanceof T) { T t = (T) x; … }`. | No — `[INFER]` |
| `var` (54) | None. Local types are inferred at compile time; the `LocalVariableTable` holds the resolved type. | No — `[INFER]` |
| Text block (59) | None. The compiler strips indentation and emits a plain `ldc` of the final string. | No — `[INFER]` |
| Enhanced `for` (any) | Arrays: `arraylength` + index loop over synthetic locals. `Iterable`: `invokeinterface iterator()/hasNext()/next()`. Same as a hand-written loop with those locals. | No for "used `for-each`"; the loop SHAPE is `[CERT]` |
| `switch` on strings (any) | `invokevirtual String.hashCode()` feeding a `lookupswitch`, followed by `String.equals` checks and a second `tableswitch`. | Yes for "string switch" |
| Switch expression, arrow form (58) | No dedicated opcode. An exhaustive switch expression with no `default` ends in a synthetic default that throws `IncompatibleClassChangeError` (before 21) or `MatchException` (21+). | Only when that synthetic default is present; otherwise No |
| Pattern `switch` / record patterns (65) | `invokedynamic` to `java.lang.runtime.SwitchBootstraps.typeSwitch` (or `enumSwitch`). | Yes |
| Lambda vs anonymous class (52) | `invokedynamic` to `LambdaMetafactory.metafactory` plus a private synthetic `lambda$<method>$<n>` method. An anonymous class instead yields a separate `Outer$<n>.class` with an `EnclosingMethod` attribute. | Yes for "lambda-or-method-reference vs anonymous class" |
| Method reference vs lambda (52) | Distinguishable ONLY when the `invokedynamic` implMethod handle (`BootstrapMethods` argument 2 in `javap -v`) points directly at the referenced target method. A synthetic `lambda$` body is ambiguous: javac also desugars some method references into one (array-constructor refs such as `int[]::new`, `super::m`, varargs-adapted refs, some protected/inaccessible targets, refs needing boxing/adaptation). | Direct implMethod handle: yes for "method reference". `lambda$` body: No for "lambda vs method reference" — `[INFER]` |
| Record (60) | `Record` attribute; superclass `java.lang.Record`; `toString`/`hashCode`/`equals` via `invokedynamic` to `ObjectMethods.bootstrap`. | Yes |
| Sealed type (61) | `PermittedSubclasses` attribute on the sealed class. | Yes |
| String concatenation (53) | `invokedynamic` to `StringConcatFactory.makeConcatWithConstants` (recipe string in the bootstrap arguments) versus a `StringBuilder.append` chain. | The FORM is `[CERT]`; it tracks the compile target, not how the author wrote the `+` |

## How to cite

- Cite the shape, not the printed syntax: for example `[CERT] javap -c -p -v preserved at
  sources/probes/b<N>/Foo.javap:212 shows invokedynamic makeConcatWithConstants (major 65)`.
- A "None" row cannot be upgraded by running more decompilers. State the limit and keep the
  claim `[INFER]`; if the question is load-bearing, find the original source (`*-sources.jar`,
  a docSource tree) instead of the decompiled one.
- A construct NOT in the matrix is not thereby admissible: derive its distinguishing shape
  first (compile a minimal fixture at two class-file versions and diff the `javap -c -p`
  output, as `java-fidelity-experiment.sh` does) and add a row here.
