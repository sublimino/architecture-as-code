# KPAI and Antigravity Collaborator Review

## Purpose

This record captures the requested one-shot collaborator work. The review kept
both tools read-only and bounded. It did not disable either sandbox.

## Inspected surfaces

The KPAI inspection covered the `kpai-local` help, profile selection output,
read-only grant options, resume wrapper, sandbox probe, and available test
runner. The Antigravity inspection covered `agy --help`, the
`antigravity-local` and `agy-local` wrappers, profile selection output, print
mode, JSON output options, workspace grants, and resume behaviour.

Both tools support the capabilities needed for this task:

- a one-shot prompt;
- an explicit working directory;
- additional read-only paths;
- machine-readable output;
- a bounded parent process;
- sandbox diagnostics.

## One-shot request

Both collaborators received the same request: inspect the repository without
editing it, compare the root guides, user workflows, manifests, Make targets,
and tests, then return evidence-backed recommendations for correctness,
navigation, controlled language, the `/docs` design, onboarding, and roadmap
honesty.

## Invocation evidence

### KPAI

The `kpai-local` invocation selected the `kpai-claude-code` profile and added a
read grant for this repository. Its preflight stopped before model execution:

```text
ERROR: pai.ts has drifted from the claude-pai fork.
diff: /home/andy/.claude/PAI/TOOLS/pai.ts: Permission denied
```

The drift guard failed closed. The review did not copy either file or disable
the guard because that would modify an external tool to complete a read-only
documentation task.

### Antigravity

The `antigravity-local` invocation selected the `antigravity-local` profile and
added a read grant for this repository. Its preflight stopped before model
execution:

```text
nono: Profile inheritance error: base profile 'antigravity' not found
```

A direct `agy` retry could not write its state below
`~/.gemini/antigravity-cli/` in the current outer sandbox. The review did not
disable the sandbox or change the external profile hierarchy.

## Shared intelligence

The tools produced no model recommendations, so none are attributed to them.
Their help, tests, wrappers, and failure behaviour still support these joint
conclusions:

1. Run collaborator preflight before critical-path repository work.
2. Test profile inheritance inside the caller's outer sandbox.
3. Separate read grants from writable model state.
4. Keep one-shot runs non-interactive and time-bounded.
5. Capture standard error even when JSON output was requested.
6. Treat a failed-closed guard as evidence, not as permission to bypass it.
7. Record collaborator provenance separately from synthesized repository facts.
8. Do not claim consensus when neither model reached inference.

The main repository review therefore used direct repository evidence and
independent review agents. See [`DOCUMENTATION-AUDIT.md`](DOCUMENTATION-AUDIT.md)
for the findings and [`FIRST-USER-ONBOARDING-PROPOSAL.md`](FIRST-USER-ONBOARDING-PROPOSAL.md)
for the resulting proposal.
