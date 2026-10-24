// Package probe is tool detection for the kit: the Go port of toolbelt/lib/tool-env.sh and of the
// hand-rolled `command -v` probes.
//
// Contract (behaviour-equivalent to tool-env.sh, pinned by the differential test against it):
//   - Input is the environment given to New (unset and empty are distinct, as `[[ -v ]]` sees them), its
//     PATH, the working directory and a fixed set of host paths (/usr/lib/jvm, /opt/ghidra*,
//     /home/linuxbrew/.linuxbrew, /usr/bin/r2, /usr/lib/*-linux-gnu/pkgconfig, ...).
//   - LookPath is bash's `command -v` for an external: the first executable non-directory on PATH, else the
//     first existing non-directory (bash prefers, it does not require, the execute bit); an empty element
//     is "."; an unset or empty PATH searches the working directory and answers an absolute path.
//   - An explicit override variable (*_JAR, ANALYZE_HEADLESS, GHIDRA_HOME, GHIDRA_INSTALL_DIR, R2,
//     ILSPYCMD) is authoritative: set but unusable fails with ErrOverrideUnusable, never falling through.
//     JAVA_HOME and RESEARCH_SDD_JAVA_HOME are candidates, not overrides.
//   - A Java home is usable when bin/java and bin/javap are executable and `timeout T bin/java -version`
//     (T = RSDD_PROBE_TIMEOUT, default 10) exits 0 with a first line whose last `version "N` has N >= 21.
//   - Every resolver returns the path printed by its shell function, or a *Degraded error (the shell's
//     return 1) mapping to reasons.DegradedMissingRuntimeDependency. JavaJar's unknown name (the shell's
//     return 2) is ErrUnknownTool. Absence is never an empty string with a nil error.
//
// The package reads no process environment: everything comes from New, which keeps tests hermetic.
// tool-env.sh's run/capture probes (rsdd_probe_*, rsdd_pkg_config, rsdd_file_sha256) and
// rsdd_resolve_dotnet_root execute tools and are left to core/proc.
package probe
