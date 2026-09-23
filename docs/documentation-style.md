# Documentation style rules

These rules apply to the documentation of this repository. They adapt
[STE-Code](https://github.com/NikolaRHristov/STE-Code/blob/Current/ste-code/artifacts/level5/system-prompt.txt),
the software-documentation form of ASD-STE100 Simplified Technical English. The
rule numbers in brackets refer to STE-Code level 5.

`make docs-lint` checks the rules that a script can check. The section
[What `make docs-lint` checks](#what-make-docs-lint-checks) lists them.

## Scope

The rules apply to two groups of documents in different ways.

| Group | Examples | Rules that apply |
| :--- | :--- | :--- |
| **Living documents** | `README.md`, `AGENTS.md`, `TESTING.md`, `docs/README.md`, slice `AGENTS.md` and `README.md` files, runbooks, reference pages | All rules |
| **Decision records** | Proposals, reports, audits, proofs, evidence, `ISA.md`, `MEMORY/` | Links and anchors only. Do not rewrite a record to match these rules. |

A decision record shows the state at the time of writing. Correct a broken link
in a record. Do not change what the record says.

The rules do not apply to source code, command output, log output, quotations,
legal text, or names defined outside this repository. Keep those exactly as they
are. Explain an unfamiliar exact term in the next sentence.

## Words

1. Use one term for one item [1.11]. The terms are in the
   [glossary](README.md#glossary). Use the same term in headings, text,
   commands, and diagrams.
2. Use a simple verb with one meaning [1.1, 1.3]. The table below gives the
   replacements for frequent problem words.
3. Do not use a noun as a verb [1.7]. Write "send the request to the API", not
   "API the request".
4. Write a long technical noun in full at its first use on a page [2.2]. Then
   use the short form. Expand each abbreviation at its first use.
5. Do not put more than three nouns in a row [2.1]. Use `of`, `for`, or `on` to
   split a longer group.
6. Keep the exact spelling of commands, paths, API fields, and product names.

<!-- docs-lint: off -->

| Do not write | Write |
| :--- | :--- |
| utilize, utilise, leverage | use |
| execute (a command) | run |
| generate | make, create |
| bootstrap, initiate, commence | start |
| retrieve, fetch | get |
| validate, verify | check (use "verify" only for a cryptographic signature) |
| terminate | stop |
| in order to | to |
| prior to | before |
| facilitate | help, permit |
| whilst | while |
| e.g., i.e. | for example, that is |
| simply, just, obviously, basically | (delete the word) |
| click here | a link label that names the target |

<!-- docs-lint: on -->

### Spelling

This repository uses British English (en_GB) spelling: behaviour, organisation,
colour. STE-Code Rule 1.14 permits a project directive to replace American
spelling. Do not change the spelling in code, identifiers, CLI flags, API
fields, or quoted text. Correct the spelling in a living document when you
edit it for another reason. Do not make a change only to correct spelling.

## Verbs and voice

1. Use the active voice [3.6]. Write "Flux applies the manifest", not "the
   manifest is applied".
2. Use the simple tenses: present, past, and future [3.2]. Do not use "has
   been applied" or "is being applied".
3. Use the "-ing" form only in a technical noun, such as "port forwarding" [3.5].
4. Use a verb for an action, not a noun [3.7]. Write "check the image", not
   "do a check of the image".
5. Do not make phrasal verbs [9.3]. Write "start", not "spin up". Write "stop",
   not "tear down", except in a command name such as `teardown`.

## Procedures

A procedure is a list of steps that a reader does.

1. Start the page or the section with its result and its prerequisites.
2. Write each step as a command in the imperative form [5.3]: `Run`, `Open`,
   `Set`, `Check`.
3. Put one instruction in each step [5.2]. Two actions that must occur
   together can share one step.
4. Keep each instruction to 20 words or fewer [5.1].
5. Put the condition before the instruction [5.4]: "If the pod is not ready,
   run `make doctor`."
6. End the procedure with a check that shows the result, such as a command and
   its expected output.

## Descriptions

A description tells the reader how something works.

1. Keep each sentence to 25 words or fewer [6.3].
2. Give one topic to each paragraph [6.5].
3. Do not write more than six sentences in a paragraph [6.6].
4. Give the general information first, then the details [6.1].
5. State a behaviour as fact only when a test, a command, or a file shows it.
   Label planned behaviour as `Roadmap`.
6. Do not copy a volatile list or count into more than one document. Link to
   the one source that owns it. A count that is written by hand becomes
   incorrect when the tree changes.

## Warnings, cautions, and notes

Use the correct label for the level of risk [7.1].

| Label | Use it for |
| :--- | :--- |
| `WARNING:` | A risk of data loss, a security exposure, or a cost that you cannot recover |
| `CAUTION:` | A risk of damage to the cluster, the lane, or the test results |
| `NOTE:` | Information only. A note does not contain an instruction [5.5]. |

1. Put the warning or the caution before the step that causes the risk.
2. Start with a clear command or condition [7.2]: "Do not run ...", or
   "Before you run ..., ...".
3. Give the risk or the possible result in the next sentence [7.3].

Example:

```text
WARNING: Do not run `gcp-ci.sh destroy` against `signalloom-ci`.
The command deletes the shared VPC and NAT network. The second CI VM
also uses that network.
```

## Punctuation

1. Do not use a semicolon [8.1]. Write two sentences.
2. Use a colon only before a list or an example [8.4].
3. Use a hyphen to join words that act as one unit [2.3, 8.2], such as
   "hand-off file". Do not join more than three words.
4. Inline code counts as one word [8.6].

## Structure and links

1. Give each page one primary reader and one primary outcome.
2. Keep user tasks separate from implementation detail.
3. Use numbered steps for procedures and tables for reference data.
4. Make every file reference a relative link when the file exists in the
   repository. A path in backticks alone is not a link.
5. Percent-encode spaces and parentheses in a link target:
   `Proposal%20—%20Name%20%282026-Q3%29.md`. GitHub does not show a link whose
   target contains a raw space.
6. Link to a heading with its GitHub anchor. A repeated heading gets `-1`,
   `-2`, and so on.
7. Add each new top-level page in `docs/` to [`README.md`](README.md).

## Diagrams

1. Use Mermaid only when a relationship, an order, or a state change is
   clearer in a diagram than in text.
2. Put one sentence before each diagram. The sentence tells the reader what the
   diagram shows. A screen reader then gets the same information.
3. Put the same targets as normal links next to the diagram. GitHub does not
   run `click` directives in Mermaid, so a diagram node is not a link.
4. Keep a diagram small enough to read without zoom. Use the same terms as the
   text.

## What `make docs-lint` checks

`make docs-lint` runs [`scripts/docs-lint.sh`](../scripts/docs-lint.sh) on each
tracked Markdown file. Each file gets one of three tiers:

| Tier | Files | Checks |
| :--- | :--- | :--- |
| All checks | The navigation layer: the root `README.md`, `AGENTS.md`, `TESTING.md`, and `HUMAN_VALIDATION.md`, this directory's `README.md` and this page, and each slice `AGENTS.md` (`DEFAULT_FILES` in the script) | All the checks in the table below |
| Correctness | Each other living document | `link`, `anchor`, `space`, `make`, `fence` |
| Links only | Decision records (`RECORDS` in the script) | `link`, `anchor`, `space` |

To run all checks on other files, give their paths:
`scripts/docs-lint.sh docs/FAQ.md`. Move a living document into the navigation
layer when its prose meets the rules.

| Check | Rule | Finding |
| :--- | :--- | :--- |
| `link` | Structure 4 | A relative link target does not exist |
| `anchor` | Structure 6 | A `#fragment` matches no heading in the target file |
| `space` | Structure 5 | A link target contains a raw space |
| `make` | Descriptions 5 | A `make TARGET` names no target in the root Makefile, the nearest slice Makefile, or the `make -C DIR` Makefile |
| `fence` | Structure | A code fence is opened and never closed |
| `orphan` | Structure 7 | A top-level page in `docs/` has no link from `docs/README.md` |
| `semicolon` | Punctuation 1 | A prose sentence contains a semicolon |
| `long` | Descriptions 1 | A prose sentence has more than 25 words |
| `word` | Words 2 | A prose sentence contains a word from the table in [Words](#words) |

The script does not check fenced code, tables, headings, or HTML comments. To
exclude a region, such as the table of problem words above, put it between
`<!-- docs-lint: off -->` and `<!-- docs-lint: on -->`. Do not use the markers
to hide a finding in normal text. Correct the text.

The script cannot check voice, tense, term consistency, or the 20-word limit
for instructions. Check those in review.

[`test/docs-lint.bats`](../test/docs-lint.bats) plants one defect for each
check and makes sure that the script reports it. Run it with
`make docs-lint-test`.

## Review checklist

- [ ] Each command, path, target, and count agrees with the tree.
- [ ] Each file reference is a link.
- [ ] Each step contains one instruction.
- [ ] Each warning or caution is before its step and gives the risk.
- [ ] Planned behaviour is labelled `Roadmap`.
- [ ] Each diagram has a sentence before it and links next to it.
- [ ] `make docs-lint` reports no findings.
