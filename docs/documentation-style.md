# Documentation Language and Structure Rules

Use these rules for operator guides, user guides, reference pages, and runbooks.
They adapt the software-documentation parts of the
[STE-Code system prompt](https://raw.githubusercontent.com/NikolaRHristov/STE-Code/Current/ste-code/artifacts/level5/system-prompt.txt),
which derives its controlled-language approach from ASD-STE100.

The repository review used the first 100 lines of the prompt. The rules below
apply the useful constraints without treating source code as technical English.

## Language rules

1. Use one approved term for each concept.
2. Use the same term in headings, text, commands, and diagrams.
3. Use active voice when the actor matters.
4. Use imperative verbs for instructions: `Run`, `Open`, `Select`, `Verify`.
5. Put one action in each numbered step.
6. Put the condition before the action when sequence matters.
7. Keep sentences short enough to scan without backtracking.
8. Replace vague verbs such as “handle” and “manage” with exact actions.
9. Expand an abbreviation at its first use on each standalone page.
10. Preserve exact spelling for commands, paths, API fields, and product names.
11. State observed behaviour as fact only when evidence supports it.
12. Label planned behaviour as `Roadmap` or `TODO`.
13. Put a warning before the action that can cause harm or data loss.
14. Give a verification command or visible result after a procedure.

## Structure rules

- Start task pages with their outcome and prerequisites.
- Separate user tasks from implementation detail.
- Prefer numbered steps for procedures and tables for reference data.
- Use descriptive link text. Do not use “click here.”
- Keep one canonical source for volatile lists, counts, and assignments.
- Link to that source instead of copying its contents.
- Use Mermaid only when relationships, order, or state changes are clearer
  visually than in prose.
- Add prose before each diagram so screen-reader users get the same meaning.
- Keep diagrams small enough to understand without zooming.
- Give each roadmap gap an owner, trigger, or verification condition when known.

## Exceptions

Do not rewrite source code, command output, log output, quotations, legal text,
protocol names, or externally defined API terms to satisfy these rules. Explain
an unfamiliar exact term after it instead.

## Review checklist

- [ ] The page has one primary reader and one primary outcome.
- [ ] Terms match the glossary and adjacent navigation labels.
- [ ] Each numbered step contains one user action.
- [ ] Commands use paths and flags that exist in the repository.
- [ ] Dangerous actions have a preceding warning.
- [ ] Planned behaviour is not described as available behaviour.
- [ ] Relative links resolve from the page location.
- [ ] Heading anchors resolve after rendering.
- [ ] Mermaid diagrams explain relationships rather than decorate pages.
- [ ] Procedures end with an observable verification step.
