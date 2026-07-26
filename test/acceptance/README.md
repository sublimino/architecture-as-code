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
