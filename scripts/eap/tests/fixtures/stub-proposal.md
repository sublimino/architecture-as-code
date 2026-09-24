# Proposal — Stub EAP Proposal (fixture)

This fixture stands in for a vault proposal in `2. Areas/CEO/Innovation Proposals/`.
It exists so a zero-match grep for `Innovation Proposals` over `scripts/eap/*.py`
has a positive control that shares the tree but not the file under test: if this
file does not match, the grep cannot see, and a zero elsewhere means nothing.

| Deliverable | Wire spec |
| :--- | :--- |
| D1 | Authorization: Bearer <Dex JWT> for humans and systems; SPIFFE SVID for agents; no identity header |
