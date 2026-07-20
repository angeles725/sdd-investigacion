// Curated deterministic evidence only; this script never executes target code.
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.function.Function;

import ghidra.app.util.headless.HeadlessScript;
import ghidra.program.model.address.AddressIterator;
import ghidra.program.model.listing.*;
import ghidra.program.model.symbol.*;
import ghidra.program.util.DefinedDataIterator;

public class CuratedEvidenceExporter extends HeadlessScript {
    private static final String SCHEMA = "ghidra-curated-evidence.v1";
    private final Map<String,Integer> caps = new TreeMap<>();
    private final Map<String,Object> counts = new TreeMap<>();
    private final Map<String,Boolean> truncation = new TreeMap<>();
    private int stringCap, stringTruncations;

    @Override protected void run() throws Exception {
        String[] a = getScriptArgs();
        if (!isRunningHeadless() || currentProgram == null || a.length != 8) fail("expected output and seven caps");
        Path output = safeOutput(a[0]);
        String[] names = {"functions","symbols","imports","exports","strings","references","string_chars"};
        for (int i=0; i<names.length; i++) caps.put(names[i], positive(a[i+1]));
        stringCap = caps.get("string_chars");

        Map<String,Object> root = map(
            "analysis", map("timed_out", analysisTimeoutOccurred()),
            "caps", caps,
            "errors", new ArrayList<>(),
            "exports", exports(),
            "functions", collect("functions", currentProgram.getFunctionManager().getFunctions(true), f -> {
                ghidra.program.model.listing.Function fn=(ghidra.program.model.listing.Function)f;
                return map("address", text(fn.getEntryPoint().toString()), "external", fn.isExternal(),
                    "name", text(fn.getName()), "thunk", fn.isThunk()); }),
            "imports", collect("imports", currentProgram.getSymbolTable().getExternalSymbols(), s -> symbol((Symbol)s)),
            "limitations", List.of(text("Static program-model evidence only"), text("No decompilation or target execution")),
            "program", map("compiler", text(currentProgram.getCompilerSpec().getCompilerSpecID().toString()),
                "format", text(currentProgram.getExecutableFormat()), "image_base", text(currentProgram.getImageBase().toString()),
                "language", text(currentProgram.getLanguageID().toString()), "md5", text(currentProgram.getExecutableMD5()),
                "name", text(currentProgram.getName())),
            "references", collect("references", currentProgram.getReferenceManager().getReferenceIterator(currentProgram.getMinAddress()), r -> {
                Reference ref=(Reference)r; return map("from", text(ref.getFromAddress().toString()),
                    "to", text(ref.getToAddress().toString()), "type", text(ref.getReferenceType().getName())); }),
            "schema", SCHEMA,
            "strings", strings(),
            "symbols", collect("symbols", currentProgram.getSymbolTable().getAllSymbols(true), s -> symbol((Symbol)s)),
            "truncation", truncation,
            "warnings", new ArrayList<>()
        );
        root.put("counts", counts);
        root.put("string_values_truncated", stringTruncations);
        boolean partial = analysisTimeoutOccurred() || truncation.values().stream().anyMatch(Boolean::booleanValue) || stringTruncations > 0;
        root.put("status", partial ? "partial" : "complete");
        writeNew(output, json(root) + "\n");
    }

    private List<Object> exports() {
        AddressIterator addresses = currentProgram.getSymbolTable().getExternalEntryPointIterator();
        Iterator<Symbol> symbols = new Iterator<>() {
            public boolean hasNext(){ return addresses.hasNext(); }
            public Symbol next(){ return currentProgram.getSymbolTable().getPrimarySymbol(addresses.next()); }
        };
        return collect("exports", symbols, s -> symbol((Symbol)s));
    }

    private List<Object> strings() {
        DefinedDataIterator iterator = DefinedDataIterator.byDataInstance(currentProgram, Data::hasStringValue);
        return collect("strings", iterator, value -> {
            Data data=(Data)value; String raw=String.valueOf(data.getValue()); int before=stringTruncations;
            String bounded=text(raw);
            return map("address", text(data.getAddress().toString()), "value", bounded,
                "value_truncated", stringTruncations > before);
        });
    }

    private Map<String,Object> symbol(Symbol s) {
        return map("address", text(s.getAddress().toString()), "external", s.isExternal(),
            "name", text(s.getName()), "type", text(s.getSymbolType().toString()));
    }

    private List<Object> collect(String kind, Iterator<?> source, Function<Object,Map<String,Object>> convert) {
        int cap=caps.get(kind), observed=0; List<Object> out=new ArrayList<>();
        while (source.hasNext() && observed <= cap) {
            Object value=source.next(); observed++;
            if (out.size() < cap) out.add(convert.apply(value));
        }
        out.sort(Comparator.comparing(this::json));
        boolean stopped=source.hasNext() || observed > cap;
        counts.put(kind, map("emitted", out.size(), "exact", !stopped, "observed", observed));
        truncation.put(kind, stopped);
        return out;
    }

    private Path safeOutput(String value) throws IOException {
        Path path;
        try { path=Path.of(value); } catch (InvalidPathException e) { return fail("invalid output path"); }
        if (!path.isAbsolute() || !path.equals(path.normalize()) || path.getFileName() == null || Files.exists(path,LinkOption.NOFOLLOW_LINKS))
            return fail("unsafe output path");
        Path parent=path.getParent();
        if (parent == null || !Files.isDirectory(parent) || !parent.equals(parent.toRealPath())) return fail("unsafe output parent");
        return path;
    }

    private int positive(String value) {
        try { int n=Integer.parseInt(value); if (n > 0) return n; } catch (NumberFormatException ignored) { }
        return fail("caps must be positive integers");
    }

    private <T> T fail(String message) {
        printerr(message); setHeadlessContinuationOption(HeadlessContinuationOption.ABORT_AND_DELETE);
        throw new IllegalArgumentException(message);
    }

    private String text(String value) {
        if (value == null) value="";
        int length=value.codePointCount(0,value.length());
        if (length <= stringCap) return value;
        stringTruncations++;
        return value.substring(0,value.offsetByCodePoints(0,stringCap));
    }

    private static Map<String,Object> map(Object... values) {
        Map<String,Object> result=new TreeMap<>();
        for (int i=0; i<values.length; i+=2) result.put((String)values[i],values[i+1]);
        return result;
    }

    private String json(Object value) {
        if (value == null) return "null";
        if (value instanceof String s) return quote(s);
        if (value instanceof Number || value instanceof Boolean) return value.toString();
        StringBuilder b=new StringBuilder();
        if (value instanceof Map<?,?> m) {
            b.append('{'); boolean comma=false;
            for (Map.Entry<?,?> e:m.entrySet()) { if (comma)b.append(','); comma=true; b.append(quote((String)e.getKey())).append(':').append(json(e.getValue())); }
            return b.append('}').toString();
        }
        b.append('['); boolean comma=false;
        for (Object item:(Iterable<?>)value) { if (comma)b.append(','); comma=true; b.append(json(item)); }
        return b.append(']').toString();
    }

    private String quote(String value) {
        StringBuilder b=new StringBuilder("\"");
        for (int i=0; i<value.length(); i++) {
            char c=value.charAt(i);
            if (c=='"' || c=='\\') b.append('\\').append(c);
            else if (c=='\b') b.append("\\b"); else if (c=='\f') b.append("\\f");
            else if (c=='\n') b.append("\\n"); else if (c=='\r') b.append("\\r"); else if (c=='\t') b.append("\\t");
            else if (c < 0x20 || (Character.isSurrogate(c) && (i+1==value.length() || !Character.isSurrogatePair(c,value.charAt(i+1)))))
                b.append(String.format("\\u%04x",(int)c));
            else { b.append(c); if (Character.isHighSurrogate(c)) b.append(value.charAt(++i)); }
        }
        return b.append('"').toString();
    }

    private void writeNew(Path output, String payload) throws IOException {
        try (BufferedWriter writer=Files.newBufferedWriter(output,StandardCharsets.UTF_8,StandardOpenOption.CREATE_NEW,StandardOpenOption.WRITE)) {
            writer.write(payload);
        }
    }
}
