package researchsdd.callgraph;

import java.io.IOException;
import java.io.OutputStream;
import java.net.URI;
import java.nio.ByteBuffer;
import java.nio.channels.FileChannel;
import java.nio.charset.StandardCharsets;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.nio.file.attribute.PosixFilePermission;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.Set;
import java.util.TreeSet;
import java.util.function.Function;
import java.util.stream.Collectors;
import sootup.callgraph.CallGraph;
import sootup.callgraph.ClassHierarchyAnalysisAlgorithm;
import sootup.core.inputlocation.AnalysisInputLocation;
import sootup.core.model.SootMethod;
import sootup.core.model.SourceType;
import sootup.core.signatures.MethodSignature;
import sootup.java.bytecode.frontend.inputlocation.JavaClassPathAnalysisInputLocation;
import sootup.java.core.views.JavaView;

/** Non-executing, deterministic JVM call-graph evidence exporter. */
public final class Main {
  private static final Comparator<MethodSignature> BY_SIGNATURE =
      Comparator.comparing(MethodSignature::toString);
  private static final List<String> COMPONENTS = List.of(
      "org.soot-oss:sootup.callgraph:2.0.0",
      "org.soot-oss:sootup.java.bytecode.frontend:2.0.0");

  private Main() {}

  public static void main(String[] args) {
    try {
      Config config = Config.parse(args);
      analyze(config);
    } catch (UserFailure failure) {
      System.err.println("jvm-callgraph: " + failure.getMessage());
      System.exit(2);
    } catch (Exception failure) {
      System.err.println("jvm-callgraph: analysis failed: " + failure.getMessage());
      System.exit(2);
    }
  }

  private static void analyze(Config config) throws IOException {
    FileIdentity input = identify(config.input, "input");
    List<FileIdentity> dependencies = new ArrayList<>();
    for (Path path : config.dependencies) dependencies.add(identify(path, "dependency"));
    Set<String> protectedPaths = dependencies.stream().map(FileIdentity::path).collect(Collectors.toSet());
    protectedPaths.add(input.path());
    rejectCollision(canonicalOutput(config.output), protectedPaths);
    Set<String> uniqueDependencyPaths = dependencies.stream().map(FileIdentity::path)
        .collect(Collectors.toSet());
    if (uniqueDependencyPaths.size() != dependencies.size() || uniqueDependencyPaths.contains(input.path())) {
      throw new UserFailure("input and dependency paths must be unique after normalization");
    }

    Path staging = Files.createTempDirectory("rsdd-jvm-callgraph-");
    try {
      Files.setPosixFilePermissions(staging, Set.of(PosixFilePermission.OWNER_READ,
          PosixFilePermission.OWNER_WRITE, PosixFilePermission.OWNER_EXECUTE));
      Path stagedInput = stageVerified(config.input, input, staging.resolve("input.jar"), "input");
      List<Path> stagedDependencies = new ArrayList<>();
      for (int index = 0; index < dependencies.size(); index++) {
        stagedDependencies.add(stageVerified(config.dependencies.get(index), dependencies.get(index),
            staging.resolve("dependency-" + index + ".jar"), "dependency"));
      }
      Files.setPosixFilePermissions(staging, Set.of(PosixFilePermission.OWNER_READ,
          PosixFilePermission.OWNER_EXECUTE));
      analyzeStaged(config, input, dependencies, protectedPaths, stagedInput, stagedDependencies);
    } finally {
      removeStaging(staging);
    }
  }

  private static void analyzeStaged(Config config, FileIdentity input,
      List<FileIdentity> dependencies, Set<String> protectedPaths, Path stagedInput,
      List<Path> stagedDependencies) throws IOException {

    JavaView applicationView = new JavaView(List.of(
        new JavaClassPathAnalysisInputLocation(stagedInput.toString(), SourceType.Application)));
    List<AnalysisInputLocation> locations = new ArrayList<>();
    locations.add(new JavaClassPathAnalysisInputLocation(stagedInput.toString(), SourceType.Application));
    for (Path dependency : stagedDependencies) {
      locations.add(new JavaClassPathAnalysisInputLocation(dependency.toString(), SourceType.Library));
    }
    JavaView view = new JavaView(locations);

    // Never enumerate the runtime image: DefaultRuntimeAnalysisInputLocation expands
    // every JDK class. Enumerate only the primary JAR, then resolve graph targets lazily.
    List<MethodSignature> applicationMethods = applicationView.getClasses()
        .filter(clazz -> !clazz.isLibraryClass())
        .flatMap(clazz -> clazz.getMethods().stream())
        .map(SootMethod::getSignature)
        .sorted(BY_SIGNATURE)
        .toList();
    Set<String> applicationSignatures = applicationMethods.stream()
        .map(MethodSignature::toString).collect(Collectors.toCollection(LinkedHashSet::new));

    TreeSet<MethodSignature> entrySet = new TreeSet<>(BY_SIGNATURE);
    for (String exact : config.entries) {
      MethodSignature signature;
      try {
        signature = view.getIdentifierFactory().parseMethodSignature(exact);
      } catch (RuntimeException invalid) {
        throw new UserFailure("invalid entry signature: " + exact);
      }
      if (!applicationSignatures.contains(signature.toString()) || applicationView.getMethod(signature).isEmpty()) {
        throw new UserFailure("entry method not found: " + exact);
      }
      entrySet.add(signature);
    }
    for (String contains : config.entryContains) {
      List<MethodSignature> matched = applicationMethods.stream()
          .filter(method -> method.toString().contains(contains)).toList();
      if (matched.isEmpty()) throw new UserFailure("entry selector matched no methods: " + contains);
      if (matched.size() > config.maxEntryMatches) {
        throw new UserFailure("entry selector exceeded --max-entry-matches: " + contains);
      }
      entrySet.addAll(matched);
    }
    if (config.entries.isEmpty() && config.entryContains.isEmpty()) {
      applicationView.getClasses().filter(clazz -> !clazz.isLibraryClass())
          .flatMap(clazz -> clazz.getMethods().stream())
          .filter(method -> method.isStatic() && method.isMain(view.getIdentifierFactory()))
          .map(SootMethod::getSignature).forEach(entrySet::add);
      if (entrySet.isEmpty()) throw new UserFailure("no application main method found; provide --entry or --entry-contains");
    }
    List<MethodSignature> entries = List.copyOf(entrySet);
    CallGraph graph = new ClassHierarchyAnalysisAlgorithm(view).initialize(entries);

    List<MethodSignature> allNodes = graph.getMethodSignatures().stream().sorted(BY_SIGNATURE).toList();
    List<MethodSignature> sinks = allNodes.stream()
        .filter(method -> config.sinkContains.stream().anyMatch(term -> method.toString().contains(term)))
        .toList();
    if (!config.sinkContains.isEmpty() && sinks.isEmpty()) {
      throw new UserFailure("sink selectors matched no reachable methods");
    }

    TreeSet<Edge> allEdges = new TreeSet<>();
    for (MethodSignature caller : allNodes) {
      graph.callTargetsFrom(caller).forEach(callee -> allEdges.add(new Edge(caller.toString(), callee.toString())));
    }

    boolean nodesCut = allNodes.size() > config.maxNodes;
    boolean edgesCut = allEdges.size() > config.maxEdges;
    List<String> nodes = allNodes.stream().limit(config.maxNodes).map(MethodSignature::toString).toList();
    List<Edge> edges = allEdges.stream().limit(config.maxEdges).toList();

    int totalXrefs = 0;
    boolean xrefsCut = false;
    List<Xref> xrefs = new ArrayList<>();
    for (MethodSignature sink : sinks) {
      List<String> callers = graph.callSourcesTo(sink).stream().sorted(BY_SIGNATURE)
          .map(MethodSignature::toString).distinct().toList();
      totalXrefs += callers.size();
      int remaining = config.maxXrefs - xrefs.stream().mapToInt(x -> x.callers().size()).sum();
      if (remaining <= 0) { xrefsCut = true; break; }
      if (callers.size() > remaining) xrefsCut = true;
      xrefs.add(new Xref(sink.toString(), callers.stream().limit(remaining).toList()));
    }

    List<PathEvidence> paths = new ArrayList<>();
    boolean pathsCut = false;
    boolean depthCut = false;
    outer:
    for (MethodSignature entry : entries) {
      for (MethodSignature sink : sinks) {
        SearchResult result = shortestPath(graph, entry, sink, config.maxDepth);
        depthCut |= result.depthLimited();
        if (!result.path().isEmpty()) {
          if (paths.size() == config.maxPaths) { pathsCut = true; break outer; }
          paths.add(new PathEvidence(entry.toString(), sink.toString(),
              result.path().stream().map(MethodSignature::toString).toList()));
        }
      }
    }

    List<String> allUnresolved = allNodes.stream().filter(method -> view.getMethod(method).isEmpty())
        .map(MethodSignature::toString).toList();
    List<String> unresolved = allUnresolved.stream().limit(100).toList();
    List<String> limitations = new ArrayList<>();
    limitations.add("CHA may overapproximate virtual dispatch targets.");
    limitations.add("SootUp 2.0.0 CHA does not model invokedynamic call edges.");
    limitations.add("JDK runtime classes are not expanded; runtime calls can remain unresolved.");
    if (!allUnresolved.isEmpty()) limitations.add("Some reachable methods were unresolved; add dependency JARs for better coverage.");
    if (nodesCut || edgesCut || xrefsCut || pathsCut || depthCut) {
      limitations.add("One or more configured evidence caps truncated the report.");
    }

    verifyStaged(input, stagedInput, "input");
    for (int index = 0; index < dependencies.size(); index++)
      verifyStaged(dependencies.get(index), stagedDependencies.get(index), "dependency");

    LinkedHashMap<String, Object> root = new LinkedHashMap<>();
    root.put("schema", "jvm-callgraph.v1");
    root.put("tool", mapOf("name", "research-sdd-jvm-callgraph", "version", "1.0.0", "components", COMPONENTS));
    root.put("runtime", runtimeIdentity());
    root.put("analyzer", analyzerIdentity());
    root.put("inputs", mapOf("primary", input, "dependencies", dependencies));
    root.put("algorithm", "CHA");
    root.put("entries", entries.stream().map(MethodSignature::toString).toList());
    root.put("entry_selection", mapOf("exact", config.entries, "contains", config.entryContains,
        "discovered_main", config.entries.isEmpty() && config.entryContains.isEmpty()));
    root.put("sink_selection", config.sinkContains);
    root.put("nodes", nodes);
    root.put("edges", edges);
    root.put("reverse_xrefs", xrefs);
    root.put("paths", paths);
    root.put("counts", mapOf("nodes_total", allNodes.size(), "nodes_emitted", nodes.size(),
        "edges_total", allEdges.size(), "edges_emitted", edges.size(),
        "xrefs_total", totalXrefs, "paths_emitted", paths.size(),
        "unresolved_total", allUnresolved.size(), "unresolved_emitted", unresolved.size()));
    root.put("caps", mapOf("max_depth", config.maxDepth, "max_paths", config.maxPaths,
        "max_nodes", config.maxNodes, "max_edges", config.maxEdges,
        "max_xrefs", config.maxXrefs, "max_entry_matches", config.maxEntryMatches));
    root.put("truncated", mapOf("depth", depthCut, "paths", pathsCut, "nodes", nodesCut,
        "edges", edgesCut, "xrefs", xrefsCut, "unresolved", allUnresolved.size() > unresolved.size()));
    root.put("unresolved", unresolved);
    root.put("errors", List.of());
    root.put("limitations", limitations);
    root.put("completeness", "partial");
    writeOutput(config.output, (Json.write(root) + "\n").getBytes(StandardCharsets.UTF_8),
        config.overwrite, protectedPaths);
  }

  private static SearchResult shortestPath(CallGraph graph, MethodSignature entry,
      MethodSignature sink, int maxDepth) {
    ArrayDeque<MethodSignature> queue = new ArrayDeque<>();
    Map<MethodSignature, MethodSignature> previous = new HashMap<>();
    Map<MethodSignature, Integer> depth = new HashMap<>();
    Set<MethodSignature> seen = new HashSet<>();
    queue.add(entry); seen.add(entry); depth.put(entry, 0);
    boolean limited = false;
    while (!queue.isEmpty()) {
      MethodSignature current = queue.removeFirst();
      int currentDepth = depth.get(current);
      if (current.equals(sink)) break;
      List<MethodSignature> nextMethods = graph.callTargetsFrom(current).stream().sorted(BY_SIGNATURE).toList();
      if (currentDepth >= maxDepth) {
        if (!nextMethods.isEmpty()) limited = true;
        continue;
      }
      for (MethodSignature next : nextMethods) {
        if (seen.add(next)) {
          previous.put(next, current); depth.put(next, currentDepth + 1); queue.addLast(next);
        }
      }
    }
    if (!seen.contains(sink)) return new SearchResult(List.of(), limited);
    ArrayList<MethodSignature> path = new ArrayList<>();
    for (MethodSignature at = sink; at != null; at = previous.get(at)) path.add(at);
    Collections.reverse(path);
    return new SearchResult(List.copyOf(path), limited);
  }

  private static FileIdentity identify(Path requested, String role) throws IOException {
    Path lexical = requested.toAbsolutePath().normalize();
    if (Files.isSymbolicLink(lexical)) {
      throw new UserFailure(role + " must be a regular non-symlink file: " + lexical);
    }
    Path path = lexical.toRealPath();
    if (!Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS))
      throw new UserFailure(role + " must be a regular non-symlink file: " + lexical);
    long sizeBefore = Files.size(path);
    String digest = sha256(path);
    long sizeAfter = Files.size(path);
    if (sizeBefore != sizeAfter) throw new UserFailure(role + " changed while hashing: " + path);
    return new FileIdentity(path.toString(), sizeAfter, digest);
  }

  private static Path stageVerified(Path source, FileIdentity expected, Path staged,
      String role) throws IOException {
    FileIdentity before = identify(source, role);
    if (!expected.equals(before)) throw new UserFailure(role + " changed while staging: " + expected.path());
    Files.copy(Path.of(expected.path()), staged);
    verifyStaged(expected, staged, role);
    FileIdentity after = identify(source, role);
    if (!expected.equals(after)) {
      throw new UserFailure(role + " changed while staging: " + expected.path());
    }
    Files.setPosixFilePermissions(staged, Set.of(PosixFilePermission.OWNER_READ));
    return staged;
  }

  static void verifyStaged(FileIdentity expected, Path staged, String role) throws IOException {
    FileIdentity actual = identify(staged, "staged " + role);
    if (expected.size() != actual.size() || !expected.sha256().equals(actual.sha256())) {
      throw new UserFailure("private staged " + role + " identity mismatch");
    }
  }

  private static void removeStaging(Path staging) throws IOException {
    if (!Files.exists(staging, LinkOption.NOFOLLOW_LINKS)) return;
    Files.setPosixFilePermissions(staging, Set.of(PosixFilePermission.OWNER_READ,
        PosixFilePermission.OWNER_WRITE, PosixFilePermission.OWNER_EXECUTE));
    try (var paths = Files.walk(staging)) {
      for (Path path : paths.sorted(Comparator.reverseOrder()).toList()) Files.deleteIfExists(path);
    }
  }

  private static Map<String, Object> runtimeIdentity() throws IOException {
    Path launcher = Path.of(System.getProperty("java.home"), "bin", "java");
    FileIdentity identity = identify(launcher, "Java launcher");
    return mapOf("version", System.getProperty("java.version"),
        "vendor", System.getProperty("java.vendor"), "java_home", System.getProperty("java.home"),
        "major", Runtime.version().feature(), "launcher", identity);
  }

  private static Object analyzerIdentity() throws IOException {
    try {
      URI uri = Main.class.getProtectionDomain().getCodeSource().getLocation().toURI();
      return identify(Path.of(uri), "analyzer");
    } catch (Exception failure) {
      throw new UserFailure("cannot identify analyzer artifact: " + failure.getMessage());
    }
  }

  private static String sha256(Path path) throws IOException {
    try {
      MessageDigest digest = MessageDigest.getInstance("SHA-256");
      try (var input = Files.newInputStream(path)) {
        byte[] buffer = new byte[64 * 1024];
        for (int read; (read = input.read(buffer)) >= 0;) if (read > 0) digest.update(buffer, 0, read);
      }
      return java.util.HexFormat.of().formatHex(digest.digest());
    } catch (NoSuchAlgorithmException impossible) {
      throw new AssertionError(impossible);
    }
  }

  private static Path canonicalOutput(Path requested) throws IOException {
    Path lexical = requested.toAbsolutePath().normalize();
    if (Files.isSymbolicLink(lexical)) throw new UserFailure("output must not be a symlink: " + lexical);
    Path parent = Optional.ofNullable(lexical.getParent()).orElse(Path.of(".").toAbsolutePath());
    Path realParent = parent.toRealPath();
    if (!Files.isDirectory(realParent, LinkOption.NOFOLLOW_LINKS))
      throw new UserFailure("output directory does not exist: " + parent);
    Path output = realParent.resolve(lexical.getFileName());
    if (Files.isSymbolicLink(output)) throw new UserFailure("output must not be a symlink: " + output);
    return output;
  }

  private static void rejectCollision(Path output, Set<String> protectedPaths) throws IOException {
    for (String protectedPath : protectedPaths) {
      Path input = Path.of(protectedPath);
      if (output.equals(input) || (Files.exists(output, LinkOption.NOFOLLOW_LINKS) && Files.isSameFile(output, input)))
        throw new UserFailure("output must not collide with an input file: " + output);
    }
  }

  private static void writeOutput(Path requested, byte[] bytes, boolean overwrite,
      Set<String> protectedPaths) throws IOException {
    Path output = canonicalOutput(requested);
    rejectCollision(output, protectedPaths);
    Path parent = output.getParent();
    Path temp = Files.createTempFile(parent, ".jvm-callgraph-", ".tmp");
    try {
      try (FileChannel channel = FileChannel.open(temp, StandardOpenOption.WRITE)) {
        channel.write(ByteBuffer.wrap(bytes)); channel.force(true);
      }
      if (!overwrite) {
        try { Files.createLink(output, temp); }
        catch (java.nio.file.FileAlreadyExistsException exists) {
          throw new UserFailure("output already exists; pass --overwrite: " + output);
        }
      } else {
        try { Files.move(temp, output, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING); }
        catch (AtomicMoveNotSupportedException unsupported) {
          Files.move(temp, output, StandardCopyOption.REPLACE_EXISTING);
        }
      }
    } finally {
      Files.deleteIfExists(temp);
    }
  }

  private static LinkedHashMap<String, Object> mapOf(Object... pairs) {
    LinkedHashMap<String, Object> map = new LinkedHashMap<>();
    for (int index = 0; index < pairs.length; index += 2) map.put((String) pairs[index], pairs[index + 1]);
    return map;
  }

  record FileIdentity(String path, long size, String sha256) {}
  private record Edge(String caller, String callee) implements Comparable<Edge> {
    public int compareTo(Edge other) { int byCaller = caller.compareTo(other.caller); return byCaller != 0 ? byCaller : callee.compareTo(other.callee); }
  }
  private record Xref(String sink, List<String> callers) {}
  private record PathEvidence(String entry, String sink, List<String> methods) {}
  private record SearchResult(List<MethodSignature> path, boolean depthLimited) {}

  private static final class Config {
    Path input; Path output; boolean overwrite;
    final List<Path> dependencies = new ArrayList<>();
    final List<String> entries = new ArrayList<>(), entryContains = new ArrayList<>(), sinkContains = new ArrayList<>();
    int maxDepth = 32, maxPaths = 100, maxNodes = 10_000, maxEdges = 50_000, maxXrefs = 10_000, maxEntryMatches = 100;

    static Config parse(String[] args) {
      Config c = new Config(); Set<String> seenSingletons = new HashSet<>();
      Set<String> seenDependencies = new HashSet<>(), seenEntries = new HashSet<>(), seenEntryTerms = new HashSet<>(), seenSinkTerms = new HashSet<>();
      for (int i = 0; i < args.length; i++) {
        String option = args[i];
        if (option.equals("--overwrite")) { if (!seenSingletons.add(option)) fail("duplicate option: " + option); c.overwrite = true; continue; }
        if (!Set.of("--input", "--dependency", "--entry", "--entry-contains", "--sink-contains", "--output",
            "--max-depth", "--max-paths", "--max-nodes", "--max-edges", "--max-xrefs", "--max-entry-matches").contains(option)) fail("unknown option: " + option);
        if (++i >= args.length || args[i].isEmpty()) fail("missing value for " + option);
        String value = args[i];
        switch (option) {
          case "--input" -> { single(seenSingletons, option); c.input = Path.of(value); }
          case "--output" -> { single(seenSingletons, option); c.output = Path.of(value); }
          case "--dependency" -> { unique(seenDependencies, value, option); c.dependencies.add(Path.of(value)); }
          case "--entry" -> { unique(seenEntries, value, option); c.entries.add(value); }
          case "--entry-contains" -> { unique(seenEntryTerms, value, option); c.entryContains.add(value); }
          case "--sink-contains" -> { unique(seenSinkTerms, value, option); c.sinkContains.add(value); }
          case "--max-depth" -> { single(seenSingletons, option); c.maxDepth = positive(value, option); }
          case "--max-paths" -> { single(seenSingletons, option); c.maxPaths = positive(value, option); }
          case "--max-nodes" -> { single(seenSingletons, option); c.maxNodes = positive(value, option); }
          case "--max-edges" -> { single(seenSingletons, option); c.maxEdges = positive(value, option); }
          case "--max-xrefs" -> { single(seenSingletons, option); c.maxXrefs = positive(value, option); }
          case "--max-entry-matches" -> { single(seenSingletons, option); c.maxEntryMatches = positive(value, option); }
          default -> throw new AssertionError(option);
        }
      }
      if (c.input == null) fail("--input is required");
      if (c.output == null) fail("--output is required");
      c.dependencies.sort(Comparator.comparing(path -> path.toAbsolutePath().normalize().toString()));
      c.entries.sort(String::compareTo); c.entryContains.sort(String::compareTo); c.sinkContains.sort(String::compareTo);
      return c;
    }
    private static void single(Set<String> seen, String option) { if (!seen.add(option)) fail("duplicate option: " + option); }
    private static void unique(Set<String> seen, String value, String option) { if (!seen.add(value)) fail("duplicate value for " + option + ": " + value); }
    private static int positive(String value, String option) { try { int n = Integer.parseInt(value); if (n > 0) return n; } catch (NumberFormatException ignored) {} fail(option + " must be a positive integer"); return 0; }
    private static void fail(String message) { throw new UserFailure(message); }
  }

  private static final class UserFailure extends RuntimeException { UserFailure(String message) { super(message); } }

  private static final class Json {
    static String write(Object value) {
      StringBuilder out = new StringBuilder(); append(out, value); return out.toString();
    }
    private static void append(StringBuilder out, Object value) {
      if (value == null) out.append("null");
      else if (value instanceof String text) string(out, text);
      else if (value instanceof Number || value instanceof Boolean) out.append(value);
      else if (value instanceof FileIdentity file) append(out, mapOf("path", file.path(), "sha256", file.sha256(), "size", file.size()));
      else if (value instanceof Edge edge) append(out, mapOf("callee", edge.callee(), "caller", edge.caller()));
      else if (value instanceof Xref xref) append(out, mapOf("callers", xref.callers(), "sink", xref.sink()));
      else if (value instanceof PathEvidence path) append(out, mapOf("entry", path.entry(), "methods", path.methods(), "sink", path.sink()));
      else if (value instanceof Map<?, ?> map) {
        out.append('{'); boolean first = true;
        for (var item : map.entrySet()) { if (!first) out.append(','); first = false; string(out, item.getKey().toString()); out.append(':'); append(out, item.getValue()); }
        out.append('}');
      } else if (value instanceof Iterable<?> items) {
        out.append('['); boolean first = true;
        for (Object item : items) { if (!first) out.append(','); first = false; append(out, item); }
        out.append(']');
      } else throw new IllegalArgumentException("unsupported JSON value: " + value.getClass());
    }
    private static void string(StringBuilder out, String value) {
      out.append('"');
      for (int i = 0; i < value.length(); i++) {
        char c = value.charAt(i);
        switch (c) { case '"' -> out.append("\\\""); case '\\' -> out.append("\\\\"); case '\b' -> out.append("\\b"); case '\f' -> out.append("\\f"); case '\n' -> out.append("\\n"); case '\r' -> out.append("\\r"); case '\t' -> out.append("\\t"); default -> { if (c < 0x20) out.append(String.format("\\u%04x", (int)c)); else out.append(c); } }
      }
      out.append('"');
    }
  }
}
