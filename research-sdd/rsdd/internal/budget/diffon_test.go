//go:build !nodiff

package budget

// differentialOn is false under the nodiff tag (the mutation run, make teeth): TestParity runs the frozen
// legacy script and real node for every case, which multiplies the cost of each mutant.
const differentialOn = true
