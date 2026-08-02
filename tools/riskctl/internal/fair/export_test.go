package fair

import "math/rand"

// newTestRNG gives the tests a generator built the same way the engine builds its own, so the
// distribution helpers can be exercised directly without going through a full simulation.
func newTestRNG(seed int64) *rand.Rand { return rand.New(rand.NewSource(seed)) }
