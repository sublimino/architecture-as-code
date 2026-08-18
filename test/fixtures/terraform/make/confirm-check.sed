# Mutation: make the destroy confirmation compare against a value nobody types,
# so a mismatched CONFIRM no longer aborts.
# Expected effect: `make gcp-tf-destroy ENV=demo-1 CONFIRM=demo-2` proceeds.
s#"$(CONFIRM)" != "$(ENV)"#"$(CONFIRM)" = "zzz-never-typed"#
