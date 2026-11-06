package archtest

// The limits of the file-size ratchet, defined here and nowhere else. Owner rule: "about 200 lines or less";
// orchestrator ruling 2026-11-06: "200 reviewed target, 400 hard ceiling".
const (
	SoftLimit = 200
	HardLimit = 400
	// DebtFileName is the debt list kept at the module root.
	DebtFileName = "modularity-debt.txt"
)
