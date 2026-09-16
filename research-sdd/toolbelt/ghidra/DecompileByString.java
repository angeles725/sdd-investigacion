// DecompileByString — Ghidra headless postScript.
// Anchors decompilation on STRING content, not symbol names: for a binary stripped of
// user symbols (Mocana-static nverify.exe), the load-bearing functions are FUN_* and
// cannot be filtered by name. This script finds defined strings whose content matches a
// needle, walks references to each string back to the containing function, dedups, and
// decompiles those functions — so a citation can name the anchor string + the FUN_@entry.
//
// Config via env:
//   RSDD_OUT_FILE  absolute path of the .txt to write (default: ./decomp-bystring.txt)
//   RSDD_NEEDLES   '|'-separated substrings; a string matches if it CONTAINS any needle
//   RSDD_TIMEOUT   per-function decompile timeout secs (default 180)
//
// Promoted from niagara-research/tools/ghidra-scripts/DecompileByString.java
// (retro 2026-08-07, niagara platform-native sub-pass B379-B382; verdict: promote).
// This kit copy is canonical; the target copy is superseded.
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.listing.Data;
import ghidra.program.model.listing.DataIterator;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;
import ghidra.program.model.listing.Listing;
import ghidra.program.model.address.Address;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceManager;
import java.io.File;
import java.io.PrintWriter;
import java.util.LinkedHashMap;
import java.util.Map;

public class DecompileByString extends GhidraScript {
    private static String env(String k, String d) {
        String v = System.getenv(k);
        return (v == null || v.trim().isEmpty()) ? d : v.trim();
    }

    @Override
    public void run() throws Exception {
        String outPath = env("RSDD_OUT_FILE", "./decomp-bystring.txt");
        String needlesRaw = env("RSDD_NEEDLES", "unsigned|manifest|Manifest|Tridium Public Key|certificate chain|Certificate chain|signature|MANIFEST");
        int timeout = Integer.parseInt(env("RSDD_TIMEOUT", "180"));
        String[] needles = needlesRaw.split("\\|");

        PrintWriter out = new PrintWriter(new File(outPath));
        Listing listing = currentProgram.getListing();
        FunctionManager fm = currentProgram.getFunctionManager();
        ReferenceManager rm = currentProgram.getReferenceManager();
        DecompInterface decomp = new DecompInterface();
        decomp.openProgram(currentProgram);

        // function entry -> list of anchor strings that pointed into it
        Map<Address, StringBuilder> hits = new LinkedHashMap<>();
        int strScanned = 0, strMatched = 0;

        DataIterator di = listing.getDefinedData(true);
        while (di.hasNext()) {
            Data d = di.next();
            if (d == null) continue;
            Object val = d.getValue();
            if (val == null) continue;
            String s = val.toString();
            if (s.length() < 4) continue;
            strScanned++;
            boolean match = false;
            for (String n : needles) { if (!n.isEmpty() && s.contains(n)) { match = true; break; } }
            if (!match) continue;
            strMatched++;
            Address strAddr = d.getAddress();
            for (Reference ref : rm.getReferencesTo(strAddr)) {
                Function f = fm.getFunctionContaining(ref.getFromAddress());
                if (f == null) continue;
                Address entry = f.getEntryPoint();
                hits.computeIfAbsent(entry, k -> new StringBuilder());
                String tag = s.length() > 60 ? s.substring(0, 60) + "..." : s;
                hits.get(entry).append("      anchor @").append(ref.getFromAddress())
                    .append(" -> \"").append(tag.replace("\n", "\\n")).append("\"\n");
            }
        }

        out.println("/* DecompileByString over " + currentProgram.getName());
        out.println("   needles : " + needlesRaw);
        out.println("   strings : " + strMatched + " matched of " + strScanned + " defined");
        out.println("   functions anchored: " + hits.size() + " */");

        int exported = 0, failed = 0;
        for (Map.Entry<Address, StringBuilder> e : hits.entrySet()) {
            Address entry = e.getKey();
            Function f = fm.getFunctionAt(entry);
            out.println();
            out.println("/* ==== " + (f == null ? "?" : f.getName()) + " @ " + entry + " ==== */");
            out.print(e.getValue().toString());
            if (f == null) { out.println("/* no function at entry */"); failed++; continue; }
            DecompileResults res = decomp.decompileFunction(f, timeout, monitor);
            if (res == null || res.getDecompiledFunction() == null) {
                out.println("/* FAILED: " + (res == null ? "no results" : res.getErrorMessage()) + " */");
                failed++;
                continue;
            }
            out.println(res.getDecompiledFunction().getC());
            exported++;
        }
        out.println();
        out.println("/* total: " + exported + " decompiled, " + failed + " failed */");
        decomp.dispose();
        out.close();
        println("DecompileByString: " + exported + " decompiled, " + failed + " failed -> " + outPath);
    }
}
