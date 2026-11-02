package adapter

import "strings"

// Port of lib/isolation_profile.py: the canonical isolation-profile record.

// Profile is the four-field sandbox posture every analysis manifest carries.
type Profile struct {
	Name                                       string
	StaticOnly, NetworkAccess, TargetExecution bool
}

// MakeProfile is make_profile(name, static_only=, network_access=, target_execution=). The name is
// checked first, then target_execution, which must stay false.
func MakeProfile(name string, staticOnly, networkAccess, targetExecution bool) (Profile, error) {
	if strings.TrimFunc(name, pySpace) == "" {
		return Profile{}, valueError("isolation profile name must be a non-empty string; got " + pyRepr(name))
	}
	if targetExecution {
		return Profile{}, valueError("target_execution must be False for corroboration adapters; use a dedicated detonation adapter for target-executing analysis")
	}
	return Profile{name, staticOnly, networkAccess, targetExecution}, nil
}

// Map is the dict make_profile returns.
func (p Profile) Map() map[string]any {
	return map[string]any{"name": p.Name, "static_only": p.StaticOnly, "network_access": p.NetworkAccess, "target_execution": p.TargetExecution}
}

// NamedProfiles are the module's PROFILE_* constants, keyed by constant name.
func NamedProfiles() map[string]Profile {
	named := map[string]string{
		"PROFILE_BWRAP_STATIC_NETWORK_DENIED": "bubblewrap-static-network-denied",
		"PROFILE_BWRAP_PCAP_OFFLINE":          "bubblewrap-pcap-offline",
		"PROFILE_BWRAP_CAPA_OFFLINE":          "bubblewrap-capa-offline",
		"PROFILE_BWRAP_FLOSS_OFFLINE":         "bubblewrap-floss-offline",
		"PROFILE_BWRAP_KAITAI_OFFLINE":        "bubblewrap-kaitai-offline",
		"PROFILE_BWRAP_UNSQUASHFS":            "bwrap-unsquashfs",
		"PROFILE_INPROCESS_ZIP_METADATA":      "in-process-metadata-only",
		"PROFILE_INPROCESS_ZIP_STORED":        "in-process-static-stored-copy",
	}
	out := make(map[string]Profile, len(named))
	for k, n := range named {
		out[k], _ = MakeProfile(n, true, false, false)
	}
	return out
}
