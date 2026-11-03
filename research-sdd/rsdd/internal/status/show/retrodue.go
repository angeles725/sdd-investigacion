package show

// coversDerive is _rd_covers_derive; the derivation lands in the next commit, until then the declared counter stays.
func (c *ctx) coversDerive(state, declared string) (eff, note string) { return declared, "" }
