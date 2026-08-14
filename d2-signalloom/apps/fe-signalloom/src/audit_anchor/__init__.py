"""Transparency-log anchoring for the Signal Loom audit trail.

Hash-chaining a log does not prevent tampering. ``git commit --amend`` plus a
force-push rewrites history and every hash that follows it, and the only reason
anyone notices is that other people hold clones. The chain is not the
protection; the independent witness is. This package builds the witness.

See README.md in this directory for what it proves and, more importantly, what
it does not.
"""
