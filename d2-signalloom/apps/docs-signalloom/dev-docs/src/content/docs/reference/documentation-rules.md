---
title: Documentation rules
description: Write concise engineering guidance through adapted STE-Code and evidence-led review.
---

The [glossary](/dev-docs/reference/glossary/) defines portal terms.
These rules adapt [STE-Code Level 5](https://github.com/NikolaRHristov/STE-Code/blob/Current/ste-code/artifacts/level5/system-prompt.txt).
The [repository style rules](https://github.com/controlplaneio-in-toto/osramp-demo/blob/main/docs/documentation-style.md) define the local application.

## Editorial rules

1. Use one term for one concept.
2. Define an unfamiliar abbreviation at first use.
3. Keep descriptions below 25 words per sentence.
4. Keep instructions below 20 words per sentence.
5. Put one action in each numbered step.
6. Put the condition before the action.
7. Use active voice and simple tenses.
8. Put risk warnings before risky steps.
9. Keep notes descriptive.
10. Link each source claim to its evidence.

The repository uses British English under the STE-Code project exception.
Commands, code, identifiers, quotations, and external names retain their exact spelling.

## Evidence and safety

1. Inspect a target recipe before describing its behaviour.
2. Distinguish source behaviour from deployed protection.
3. Label planned behaviour as `Roadmap`.
4. State access limits and stop conditions.
5. Use selected metadata instead of secret values or raw logs.
6. Keep assessment procedures read-only.

An assessment must not prescribe automatic remediation.
The [assessment template](/dev-docs/reference/security-assessment-template/) defines evidence and result fields.

## Links and page structure

1. Use `/dev-docs/...` for engineering pages.
2. Use `/docs/...` for existing user pages.
3. Use repository links for unpublished source files.
4. Give each page one primary reader and outcome.
5. Start procedures with prerequisites and their expected result.
6. End procedures with an observable check.

The engineering portal shares existing styles and public assets. Content changes do not need a separate design system.

## Automated checks and editorial review

`make docs-dev-lint` checks engineering Markdown, including new files.
It runs the [documentation checker](https://github.com/controlplaneio-in-toto/osramp-demo/blob/main/scripts/docs-lint.sh) and the engineering prose gate.
`make docs-lint` includes this engineering check.

The prose gate checks simple word choices [1.1], instruction length [5.1], description length [6.3], and semicolons [8.1].
It excludes frontmatter, code fences, headings, tables, and HTML comments.
Inline code keeps its exact text and counts as one word under the repository adaptation.
`make docs-dev-test` tests this subset.
`make docs-dev-build` runs the prose gate before the Astro build.

The checker does not prove control claims or assess command safety.
Editorial review checks meaning, term consistency, active voice, instruction length, and evidence quality.

The [portal package](https://github.com/controlplaneio-in-toto/osramp-demo/blob/main/d2-signalloom/apps/docs-signalloom/package.json) supplies frontmatter, build, and link checks.
A successful build does not prove safe procedures or complete STE-Code compliance.

1. Run the available automated checks.
2. Review each procedure against the editorial rules.
3. Review each command for unintended writes or sensitive output.
4. Record skipped checks and remaining work.

These checks do not certify complete ASD-STE100 compliance.
