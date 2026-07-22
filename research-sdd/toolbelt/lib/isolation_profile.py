"""Canonical isolation-profile construction for Research-SDD adapters.

An isolation profile records the sandbox security posture that was in effect
when a corroboration adapter ran.  Every analysis-manifest.v1 document carries
exactly one profile under the "isolation_profile" key.

Schema contract: see isolation-profile.v1.md alongside this module.

Required fields (4-key shape):
    name             str   Human-readable profile identifier.
    static_only      bool  True  = the adapter never executes target code.
    network_access   bool  False = the adapter runs with network denied.
    target_execution bool  MUST be False for all corroboration adapters.

Construction authority:
    make_profile() is the ONLY sanctioned way to produce an isolation-profile
    dict.  It enforces target_execution=False at construction time, so no
    corroboration adapter can silently weaken the safety posture.  The
    analysis_manifest.py validator remains the read-time enforcement point
    (analysis_manifest.py:382-385).

Named constants:
    Each distinct sandbox posture used by the toolbelt has a module-level
    constant.  Import the constant directly; do NOT copy the dict inline.
    Adapters with a dynamic posture (e.g. Ghidra's optional network access)
    call make_profile() at their own call site.
"""
from __future__ import annotations

from typing import Any


def make_profile(
    name: str,
    *,
    static_only: bool = True,
    network_access: bool = False,
    target_execution: bool = False,
) -> dict[str, Any]:
    """Return a canonical isolation-profile dict.

    Parameters
    ----------
    name:
        Human-readable profile identifier (non-empty string).
    static_only:
        True (default) when the adapter never executes target code.
    network_access:
        False (default) when the sandbox runs with network denied.
        Pass True only for sandboxes that intentionally allow network
        traffic (e.g. Ghidra without isolation).
    target_execution:
        MUST remain False for all Research-SDD corroboration adapters.
        Passing True raises ValueError so callers cannot silently weaken
        the posture.  The analysis_manifest.py validator also enforces
        this at read time (line 384).

    Raises
    ------
    ValueError
        If name is empty, whitespace-only, or not a str; or if
        target_execution is True.
    """
    if not isinstance(name, str) or not name.strip():
        raise ValueError(
            f"isolation profile name must be a non-empty string; got {name!r}"
        )
    if target_execution:
        raise ValueError(
            "target_execution must be False for corroboration adapters; "
            "use a dedicated detonation adapter for target-executing analysis"
        )
    return {
        "name": name,
        "static_only": static_only,
        "network_access": network_access,
        "target_execution": target_execution,
    }


# ---------------------------------------------------------------------------
# Named profiles — one constant per distinct sandbox posture.
#
# Import the right constant directly; never copy the dict inline.
# ---------------------------------------------------------------------------

# Bubblewrap sandbox, static analysis, all network denied.
# Shared by: corroborate_firmware, corroborate_java, corroborate_native.
PROFILE_BWRAP_STATIC_NETWORK_DENIED = make_profile("bubblewrap-static-network-denied")

# Bubblewrap sandbox, offline PCAP read (capinfos + tshark, no live traffic).
# Shared by: corroborate_pcap, pcap_flows.
PROFILE_BWRAP_PCAP_OFFLINE = make_profile("bubblewrap-pcap-offline")

# Per-tool offline profiles (each used by exactly one adapter).
PROFILE_BWRAP_CAPA_OFFLINE   = make_profile("bubblewrap-capa-offline")
PROFILE_BWRAP_FLOSS_OFFLINE  = make_profile("bubblewrap-floss-offline")
PROFILE_BWRAP_KAITAI_OFFLINE = make_profile("bubblewrap-kaitai-offline")
PROFILE_BWRAP_UNBLOB_OFFLINE = make_profile("bubblewrap-unblob-offline")

# SquashFS extractor running unsquashfs inside bubblewrap.
PROFILE_BWRAP_UNSQUASHFS = make_profile("bwrap-unsquashfs")

# In-process adapters (Python-only, no subprocess, no network, no execution).
PROFILE_INPROCESS_ZIP_METADATA = make_profile("in-process-metadata-only")
PROFILE_INPROCESS_ZIP_STORED   = make_profile("in-process-static-stored-copy")

# ---------------------------------------------------------------------------
# Ghidra profiles are NOT named constants here because the security posture
# varies at runtime depending on the --isolated flag:
#
#   isolated=True  → make_profile("bubblewrap-ghidra-static")
#   isolated=False → make_profile("test-only-untrusted-bwrap", network_access=True)
#
# Callers must call make_profile() directly at their own call site.
# ---------------------------------------------------------------------------
