//go:build !frostdb

package store

// HasFrostDB reports whether this binary was built with the frostdb store compiled in.
const HasFrostDB = false
