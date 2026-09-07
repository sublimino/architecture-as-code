module github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/cmd/riskctl

go 1.24

require (
	github.com/acme-co/osramp/tools/riskctl v0.0.0
)

replace (
	github.com/acme-co/osramp/tools/riskctl => ../../../tools/riskctl
	github.com/controlplaneio-in-toto/osramp-demo/d2-signalloom/apps/policy-engine => ../../apps/policy-engine
)
