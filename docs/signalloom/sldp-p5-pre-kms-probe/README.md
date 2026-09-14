# SLDP-P5-PRE — KMS signer prototype

The prototype that produced the §2 verdict in
[`../sldp-p5-pre-proof.md`](../sldp-p5-pre-proof.md): **does Witness accept a
KMS-backed signer?**

It is deliberately parked outside every Go module in this repository — there is no
root `go.mod`, so nothing here is compiled by any app's build or test run. `go.mod.txt`
carries the resolved dependency set rather than a live `go.mod` for the same reason.

## What it answers

| Section | Question |
| :--- | :--- |
| A | Does `go-witness` expose KMS signer providers, and which key algorithms do they declare? |
| B | Is the KMS code path reachable without cloud credentials (i.e. does it fail at the credential boundary, not earlier)? |
| C | Does an unrecognised KMS scheme fail closed? |
| D | Is a `go-witness`-produced DSSE envelope byte-compatible with Signal Loom's hand-rolled one, and would the in-repo verifier accept it? |

Section D is the one that matters most: it reproduces
`store/segment_attestor.go:206-224` verbatim alongside `go-witness`'s own signer over
an identical payload, so the two `keyid` derivations can be compared directly.

## Running it

```bash
mkdir -p /tmp/kmsprobe && cd /tmp/kmsprobe
cp .../sldp-p5-pre-kms-probe/main.go .
cp .../sldp-p5-pre-kms-probe/go.mod.txt go.mod
GOFLAGS=-mod=mod go mod tidy && go run .
```

Pinned to `github.com/in-toto/go-witness v0.8.4` — the library behind the
`witness v0.9.1` CLI that `scripts/setup.sh:33` installs. Requires network access to
`proxy.golang.org` on first run. Requires **no** cloud credentials: sections A, C and
D are fully offline, and section B's expected output *is* the credential error.
