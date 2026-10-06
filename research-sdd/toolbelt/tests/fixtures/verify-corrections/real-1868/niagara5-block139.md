# Block 139

**The module names are NOT the package roots.** `com.tridium.nre` and `com.tridium.baja` are *packages*; the modules are `niagara.nre` and `niagara.baja`. My first `--patch-module` attempt was rejected with `WARNING: Unknown module: com.tridium.nre` — that warning was the measurement, not a failure of the technique. This corrects the assumption behind [Block 1]'s packaging focus for anyone reasoning from package names to module identities.
