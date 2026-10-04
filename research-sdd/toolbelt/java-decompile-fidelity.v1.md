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

Exclusivity test applied to every row: can javac emit this bytecode shape from a DIFFERENT source construct at any
class-file major version >= 52? A shape is `[CERT]`-admissible only for the claim it is exclusive to, and only within
the stated major range. Verdicts: `[CERT]-admissible` (exclusive shape exists), `[INFER]-only` (a shape exists but a
different source form can emit it), `no-bytecode-trace` (javac erases the construct; nothing to cite). Row ids are
stable anchors: cite them as `java-decompile-fidelity.v1.md#fid-NN`.

Global caveats for every row: (1) the rows describe javac output; Kotlin, Scala, obfuscators and bytecode rewriters can
emit the same shapes from other sources, so check the class's producer (`SourceFile`, `Kotlin`/`Scala` attributes, build
metadata) before treating a shape as proof of Java source; (2) preview features (minor_version 65535) are outside this
table; (3) "min. major" is the first NON-preview major.

| Id | Construct (min. major) | Shape and exclusivity analysis | Verdict |
|---|---|---|---|
| <a id="fid-01"></a>FID-01 | `instanceof` pattern (60) | None. javac emits `instanceof` + `checkcast` + store, identical to `if (x instanceof T) { T t = (T) x; ... }`. | no-bytecode-trace |
| <a id="fid-02"></a>FID-02 | `var` (54) | None. Erased at compile time; the `LocalVariableTable` holds the resolved type, as for an explicit declaration. | no-bytecode-trace |
| <a id="fid-03"></a>FID-03 | Text block (59) | None. The compiler strips indentation and emits an `ldc` of the final string, identical to an ordinary literal with the same value. | no-bytecode-trace |
| <a id="fid-04"></a>FID-04 | Enhanced `for` (52+) | Arrays: `arraylength` + index loop over synthetic copies of the array, length and index. `Iterable`: `invokeinterface iterator()/hasNext()/next()`. A hand-written indexed or iterator loop emits the same instructions. | `[INFER]-only` for "used for-each"; the loop shape itself is `[CERT]` |
| <a id="fid-05"></a>FID-05 | String-keyed `switch` (52+) | `String.hashCode()` into a `lookupswitch`, then `String.equals` checks and a second switch. Shared by statement and expression, colon and arrow forms (the syntactic form is not recoverable); hand-written hash dispatch can emit it too. | `[CERT]-admissible` for "string-keyed switch dispatch" only; `[INFER]-only` for source form |
| <a id="fid-06"></a>FID-06 | Switch expression vs statement (58) | No dedicated opcode. The synthetic throwing `default` is NOT exclusive: for an exhaustive switch over an enum with no `default`, javac 14-20 (majors 58-64) emits `IncompatibleClassChangeError` and 21+ (major 65+) emits `MatchException`; from major 65 an exhaustive pattern switch STATEMENT over a sealed hierarchy or with pattern labels also gets a synthetic `MatchException` default. Expression vs statement is not distinguishable by it. | `[INFER]-only` (no-bytecode-trace for expression vs statement) |
| <a id="fid-07"></a>FID-07 | Pattern / `case null` switch (65) | `invokedynamic` to `java.lang.runtime.SwitchBootstraps.typeSwitch` (or `enumSwitch`), statement or expression alike. Record patterns add `MatchException` handling. | `[CERT]-admissible` for "pattern-or-null-label switch" (major 65+); not for statement vs expression |
| <a id="fid-08"></a>FID-08 | Lambda vs anonymous class (52) | `invokedynamic` to `LambdaMetafactory.metafactory` (or `altMetafactory` for serializable/marker lambdas) plus a private synthetic `lambda$<method>$<n>`; an anonymous class instead has its own `Outer$<n>.class` whose `InnerClasses` entry has a zero name index (local classes carry a name). A `lambda$` body can also come from a desugared method reference (FID-09). | `[CERT]-admissible` for "lambda-or-method-reference vs anonymous class"; `[INFER]-only` for lambda vs method reference |
| <a id="fid-09"></a>FID-09 | Method reference vs lambda (52) | Distinguishable ONLY when the `invokedynamic` implMethod handle (`BootstrapMethods` argument 2 in `javap -v`) points directly at the referenced target method. A synthetic `lambda$` body is ambiguous: javac also desugars some method references into one (array-constructor refs such as `int[]::new`, `super::m`, varargs-adapted refs, some protected/inaccessible targets, refs needing boxing/adaptation). | `[CERT]-admissible` for "method reference" when the handle is direct; `[INFER]-only` for a `lambda$` body |
| <a id="fid-10"></a>FID-10 | Record (60) | `Record` attribute and superclass `java.lang.Record`. `toString`/`hashCode`/`equals` via `invokedynamic` `ObjectMethods.bootstrap` only when not hand-written, so their absence proves nothing. javac rejects a hand-written subclass of `Record`. | `[CERT]-admissible` for "record declaration" (major 60+) |
| <a id="fid-11"></a>FID-11 | Sealed type (61) | `PermittedSubclasses` attribute on the sealed class; no other source construct produces it. | `[CERT]-admissible` for "sealed" (major 61+) |
| <a id="fid-12"></a>FID-12 | String concatenation `+` (53) | `invokedynamic` `StringConcatFactory.makeConcatWithConstants` (recipe in the bootstrap arguments) is emitted only for source `+`/`+=` at major 53+ unless javac is run with `-XDstringConcat=inline`. A `StringBuilder.append` chain is emitted for `+` at major 52 and below, for `+` at 53+ under the inline flag, AND for an explicit `StringBuilder`. | indy form: `[CERT]-admissible` for "`+` concatenation" (major 53+); `StringBuilder` chain: `[INFER]-only` at every major |

## How to cite

- Cite the shape, not the printed syntax: for example `[CERT] javap -c -p -v preserved at
  sources/probes/b<N>/Foo.javap:212 shows invokedynamic makeConcatWithConstants (major 65)`.
- A `no-bytecode-trace` or `[INFER]-only` row cannot be upgraded by running more decompilers. State the limit and keep the
  claim `[INFER]`; if the question is load-bearing, find the original source (`*-sources.jar`,
  a docSource tree) instead of the decompiled one.
- A construct NOT in the matrix is not thereby admissible: derive its distinguishing shape
  first (compile a minimal fixture at two class-file versions and diff the `javap -c -p`
  output, as `java-fidelity-experiment.sh` does) and add a row here.
