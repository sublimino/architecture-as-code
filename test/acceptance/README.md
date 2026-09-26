# Browser acceptance tests

The canonical instructions are in [`../../TESTING.md`](../../TESTING.md). The short setup path is:

```bash
bun install --frozen-lockfile
bunx playwright install ffmpeg
```

To run:

```bash
cd ../..
make acceptance-test
```

[`SPEC-REGISTRY.tsv`](SPEC-REGISTRY.tsv) records where each spec runs. Add a row
for each new spec. [`test/acceptance-spec-coverage.bats`](../acceptance-spec-coverage.bats)
fails CI when the registry and the Playwright config do not agree.

To run one Playwright project, give its name to the runner script. The project
names are the `name` fields in [`playwright.config.ts`](playwright.config.ts).

```bash
cd ../..
scripts/acceptance-test.sh --project <name>
```
