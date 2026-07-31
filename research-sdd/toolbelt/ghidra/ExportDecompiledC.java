// ExportDecompiledC — Ghidra headless postScript: export decompiled C for selected functions.
//
// WHY THIS EXISTS
//   `decompile-native.sh ghidra <bin> <out>` imports and analyses a binary into a Ghidra project but
//   exports NO C source: the wrapper's `--script` hook is what a C export needs, and Ghidra ships no
//   such script (its bundled Decompiler scripts are analysis helpers — DecompilerStackProblemsFinder,
//   FindPotentialDecompilerProblems, ShowCCalls — none of them writes C out).
//
// USAGE (the wrapper passes only the script NAME, no args, so configuration comes from the environment)
//   RSDD_OUT=<dir> [RSDD_FN_FILTER=<java-regex>] [RSDD_MAX_FN=<n>] [RSDD_TIMEOUT=<secs>] \
//     decompile-native.sh ghidra <binary> <out-dir> --script <path-to-this-file>
//
//   RSDD_OUT        where to write <program>.c        (default: the process cwd)
//   RSDD_FN_FILTER  only export functions whose NAME matches this regex (unanchored Java find).
//                   OMIT AT YOUR PERIL on a large DLL: a 3 MB PE holds thousands of functions and a
//                   full export is both slow and unreadable. Filtering is the point of this script.
//   RSDD_MAX_FN     stop after N successfully decompiled functions (0 / unset = no cap)
//   RSDD_TIMEOUT    per-function decompiler timeout in seconds (default 120)
//
// OUTPUT
//   One `<program>.c` with a `/* ---- <name> @ <entry> ---- */` banner per function, so a citation can
//   name the function and its entry address. Failures are recorded inline as `/* FAILED: ... */` rather
//   than dropped silently — a missing function must not read as an absent one.

import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileOptions;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;
import ghidra.util.task.ConsoleTaskMonitor;

import java.io.BufferedWriter;
import java.io.File;
import java.io.FileWriter;
import java.io.PrintWriter;
import java.util.regex.Pattern;

public class ExportDecompiledC extends GhidraScript {

    private static String env(String key, String fallback) {
        String v = System.getenv(key);
        return (v == null || v.trim().isEmpty()) ? fallback : v.trim();
    }

    private static int envInt(String key, int fallback) {
        try {
            return Integer.parseInt(env(key, Integer.toString(fallback)));
        } catch (NumberFormatException e) {
            return fallback;
        }
    }

    @Override
    public void run() throws Exception {
        File outDir = new File(env("RSDD_OUT", System.getProperty("user.dir")));
        if (!outDir.isDirectory() && !outDir.mkdirs()) {
            println("RSDD-EXPORT: cannot create output dir " + outDir.getAbsolutePath());
            return;
        }

        String filter = env("RSDD_FN_FILTER", "");
        Pattern pattern = filter.isEmpty() ? null : Pattern.compile(filter);
        int maxFn = envInt("RSDD_MAX_FN", 0);
        int timeout = envInt("RSDD_TIMEOUT", 120);

        String safeName = currentProgram.getName().replaceAll("[^A-Za-z0-9._-]", "_");
        File outFile = new File(outDir, safeName + ".c");

        DecompInterface decompiler = new DecompInterface();
        decompiler.setOptions(new DecompileOptions());
        if (!decompiler.openProgram(currentProgram)) {
            println("RSDD-EXPORT: decompiler refused to open " + currentProgram.getName());
            return;
        }

        int exported = 0;
        int failed = 0;
        int skipped = 0;
        try (PrintWriter out = new PrintWriter(new BufferedWriter(new FileWriter(outFile)))) {
            out.println("/* rsdd ghidra C export");
            out.println("   program : " + currentProgram.getName());
            out.println("   filter  : " + (pattern == null ? "<none — ALL functions>" : filter));
            out.println("*/");

            FunctionIterator functions = currentProgram.getFunctionManager().getFunctions(true);
            while (functions.hasNext() && !monitor.isCancelled()) {
                Function f = functions.next();
                String name = f.getName();
                if (pattern != null && !pattern.matcher(name).find()) {
                    skipped++;
                    continue;
                }

                DecompileResults res = decompiler.decompileFunction(f, timeout, new ConsoleTaskMonitor());
                out.println();
                out.println("/* ---- " + name + " @ " + f.getEntryPoint() + " ---- */");
                if (res == null || !res.decompileCompleted() || res.getDecompiledFunction() == null) {
                    String why = (res == null) ? "no results" : res.getErrorMessage();
                    out.println("/* FAILED: " + why + " */");
                    failed++;
                    continue;
                }
                out.println(res.getDecompiledFunction().getC());
                exported++;
                if (maxFn > 0 && exported >= maxFn) {
                    out.println();
                    out.println("/* RSDD_MAX_FN=" + maxFn + " reached — export truncated here */");
                    println("RSDD-EXPORT: hit RSDD_MAX_FN=" + maxFn + ", stopping early");
                    break;
                }
            }
        } finally {
            decompiler.dispose();
        }

        println("RSDD-EXPORT: " + exported + " exported, " + failed + " failed, "
                + skipped + " filtered out -> " + outFile.getAbsolutePath());
    }
}
