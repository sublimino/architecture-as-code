module github.com/acme-co/osramp/tools/riskctl

go 1.24

require (
	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/policy-engine v0.0.0
	gopkg.in/yaml.v3 v3.0.1
)

// The FAIR engine is shared with the policy-engine service rather than duplicated here.
// Two implementations of this maths in one repository will eventually disagree, and the first
// person to notice will be in the audience.
replace github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/policy-engine => ../../d2-signalloom/apps/policy-engine
