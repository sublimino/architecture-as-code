# Signal Loom documentation service

This Astro Starlight service follows the framework and visual approach used by
the sibling `native-cloud` repository. It does not copy native-cloud content or
custom components because that repository does not currently declare a
repository-wide code licence.

## Local commands

```bash
npm ci
npm run check
npm run build
```

The production build uses `/docs` as its Astro base path. The nginx image serves
the generated site at `/docs/` and exposes `/readyz` for Kubernetes probes.

## Source relationship

- Reference implementation: `/home/andy/src/cp/native-cloud`
- Shared framework: Astro Starlight
- Adapted design cue: the orange accent palette

TODO: Add explicit code and content licences to native-cloud before shared custom
source is reused or redistributed.
