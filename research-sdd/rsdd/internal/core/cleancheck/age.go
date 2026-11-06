package cleancheck

// Defaults of the two ages, as the script had them. They live here and nowhere else: the command line leaves an age
// it was not given unset, and the engine applies the default.
const (
	DefaultStaleHours = 24
	DefaultBackupDays = 14
)

// Age is a retention age that may be left unset. The script gave an explicit 0 a meaning of its own (`find -mmin +0`:
// every owned tmp.* entry, every matching backup is already stale), so a plain int cannot say both "not given" and
// "0". The zero Age is "not given" and means the default; AgeOf(0) is the explicit 0.
type Age struct {
	n   int
	set bool
}

// AgeOf is an age that was given: hours for StaleHours, days for BackupDays.
func AgeOf(n int) Age { return Age{n: n, set: true} }

// or is the age, or def when it was not given.
func (a Age) or(def int) int {
	if !a.set {
		return def
	}
	return a.n
}
