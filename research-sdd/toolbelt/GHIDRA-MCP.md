# ghidra-mcp — agent-directed native decompilation

**GhidraMCP v5.14.2** plugin (251 MCP tools) installed and registered as an MCP server
in Claude Code (user scope). It lets the agent decompile, rename, type, analyze
data-flow and emulate P-code over native binaries, via Ghidra 12.1.

> The MCP registration takes effect on **restarting Claude Code**. Ghidra's tools only
> respond when there is a Ghidra server **alive at `127.0.0.1:8089`** with a binary
> loaded. Without that, the MCP server shows as connected but the tools fail.

## Components (paths)

| Piece | Path |
|---|---|
| Repo / build | `/home/cristian/dev/ghidra-mcp` |
| Installed extension | `~/.config/ghidra/ghidra_12.1_PUBLIC/Extensions/GhidraMCP/` |
| MCP bridge (stdio) | `/home/cristian/dev/ghidra-mcp/bridge_mcp_ghidra.py` |
| Bridge interpreter | `/home/cristian/dev/ghidra-mcp/.venv/bin/python` (Python 3.13.14) |
| MCP registration | `~/.claude.json` (user scope) — `claude mcp get ghidra-mcp` |

## Bringing up the :8089 server

### Option A — GUI (requires display; Win11 WSLg provides it)
1. `cd /home/linuxbrew/.linuxbrew/Cellar/ghidra/12.1/libexec && ./ghidraRun`
2. Import/open a binary in a **CodeBrowser** window.
3. **File > Configure > Configure All Plugins > GhidraMCP** (already marked as known).
4. **Tools > GhidraMCP > Start MCP Server** → `http://127.0.0.1:8089/`.
5. Verify: `curl http://127.0.0.1:8089/check_connection`

### Option B — Headless server (no display, ideal for WSL)
The class `com.xebyte.headless.GhidraMCPHeadlessServer` ships in the standard jar:
```bash
export JAVA_HOME=/home/linuxbrew/.linuxbrew/opt/openjdk@21
GH=/home/linuxbrew/.linuxbrew/Cellar/ghidra/12.1/libexec
CP=/home/cristian/dev/ghidra-mcp/target/GhidraMCP-5.14.2.jar
for d in Framework Features Processors; do for j in $GH/Ghidra/$d/*/lib/*.jar; do CP="$CP:$j"; done; done
$JAVA_HOME/bin/java -Dghidra.home=$GH -Dapplication.name=GhidraMCP \
  -classpath "$CP" com.xebyte.headless.GhidraMCPHeadlessServer --bind 127.0.0.1 --port 8089
```
Load a binary and analyze:
```bash
curl -X POST -d "file=/path/to/binary.exe" http://127.0.0.1:8089/load_program
curl -X POST http://127.0.0.1:8089/run_analysis
```
(There is also a Docker route: `docker-compose up -d ghidra-mcp` from the repo.)

## When to use which

- **Triage / batch / scriptable** → `decompile-native.sh ghidra|r2|quick` (no live server needed).
- **Interactive agent-directed research** (rename, document, data-flow,
  emulation) → ghidra-mcp with the server alive (Option B) + restart Claude Code.

## Troubleshooting

### Ghidra 12.1.2 crashes under JDK 26 — requires JDK 21

Ghidra 12.1.2 enforces `application.java.min=21` and its launcher (`GhidraLauncher.launch`) throws
under OpenJDK 26. The kit wrappers (`decompile-native.sh`, `corroborate-ghidra.sh`) resolve
`JAVA_HOME` explicitly via `lib/tool-env.sh` and never use the PATH `java`, so they are immune.
A MANUAL launch — GUI, `analyzeHeadless` invoked by hand, or a PyGhidra script run outside the
kit — must force JDK 21:

```sh
export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64   # distro JDK 21
# OR
export JAVA_HOME=/home/linuxbrew/.linuxbrew/opt/openjdk@21   # Homebrew JDK 21
```

Verify with `$JAVA_HOME/bin/java -version` before launching.

### PyGhidra / headless-Python needs a Java extraction post-script

PyGhidra and headless Python analysis do NOT call `decompileFunction` in the same way as the GUI
decompiler. To extract decompiled output from headless analysis (e.g. recovering specific functions
by string cross-reference), write a Java post-script (`.java`) passed via `analyzeHeadless
-postScript`; the Java post-script API has full access to the decompiler service. The equivalent
Python path via PyGhidra is available but requires a matching `jpype` environment — the Java
post-script route is simpler and was confirmed working in this environment (pi5-decoding B14).
