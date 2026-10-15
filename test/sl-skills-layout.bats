#!/usr/bin/env bats
# test/sl-skills-layout.bats
#
# @id      sl-skills-layout
# @target  .agents/skills, .claude/skills, .gitignore
# @doc     .agents/skills/sl-drift-sweep/SKILL.md
#
# Layout contract for repo skills. `.agents/skills` is the only home for the
# Signal Loom skills. Claude Code discovers project skills under
# `.claude/skills/<name>/SKILL.md`, so `.claude/skills` is one committed,
# relative symlink to `../.agents/skills`. A new skill directory is exposed
# without further edits.

setup() {
	ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	SKILLS="$ROOT/.agents/skills"
	EXPOSED="$ROOT/.claude/skills"
}

# Value of `name:` inside the leading `---` frontmatter block only.
frontmatter_name() {
	awk '
		NR == 1 { if ($0 != "---") exit; next }
		/^---$/ { exit }
		/^name:[[:space:]]*/ { sub(/^name:[[:space:]]*/, ""); gsub(/^["'\'']|["'\'']$/, ""); print; exit }
	' "$1"
}

@test "every .agents/skills directory has a SKILL.md whose frontmatter name equals the directory" {
	local count=0 dir name got bad=""
	for dir in "$SKILLS"/*/; do
		name="$(basename "$dir")"
		count=$((count + 1))
		if [ ! -f "$dir/SKILL.md" ]; then
			bad+="$name: missing SKILL.md"$'\n'
			continue
		fi
		got="$(frontmatter_name "$dir/SKILL.md")"
		[ "$got" = "$name" ] || bad+="$name: frontmatter name '${got}'"$'\n'
	done
	# Non-vacuous: the 13 Signal Loom skills existed when this suite landed.
	[ "$count" -ge 13 ] || { echo "only $count skill dirs found"; return 1; }
	[ -z "$bad" ] || { printf '%s' "$bad"; return 1; }
}

@test "no tracked or untracked file in the repo references the retired cp-sl prefix" {
	# Built from parts so this file does not match itself.
	local pat="cp""-sl-"
	run git -C "$ROOT" grep --untracked -I -n -F -e "$pat"
	# git grep exits 1 when nothing matches, 0 on a match, >1 on error.
	[ "$status" -eq 1 ] || { echo "$output"; return 1; }
}

@test ".claude/skills is a committed relative symlink to ../.agents/skills" {
	[ -L "$EXPOSED" ]
	[ "$(readlink "$EXPOSED")" = "../.agents/skills" ]
	# A repo-level ignore must not drop the link (a global `.claude/` ignore is common).
	run git -C "$ROOT" check-ignore -q .claude/skills
	[ "$status" -eq 1 ]
}

@test "every sl-* skill resolves through .claude/skills to the repo copy" {
	local count=0 dir name bad=""
	for dir in "$SKILLS"/sl-*/; do
		name="$(basename "$dir")"
		count=$((count + 1))
		if [ ! -f "$EXPOSED/$name/SKILL.md" ]; then
			bad+="$name: not exposed"$'\n'
			continue
		fi
		[ "$(realpath "$EXPOSED/$name")" = "$(realpath "$dir")" ] ||
			bad+="$name: resolves to $(realpath "$EXPOSED/$name")"$'\n'
	done
	[ "$count" -ge 13 ] || { echo "only $count sl-* dirs found"; return 1; }
	[ -z "$bad" ] || { printf '%s' "$bad"; return 1; }
}
