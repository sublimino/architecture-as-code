#!/usr/bin/env bats
#
# The decision-record tier is stated twice. scripts/docs-lint.sh matches it with
# the RECORDS regex. docs/README.md lists it in the "Decision records" section.
#
# The two copies are kept by hand, so they can drift. This suite checks both
# directions on the real tree. Every linked record must match RECORDS. Every
# RECORDS file at docs/ top level or the repository root must be linked.
#
# A check that finds nothing looks the same as a check that checks nothing. So
# the parse must find at least ten targets, and a planted record must fail.
#
# No cluster and no network: bash, awk, sed, and git only.

setup() {
	repo_root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
	cd "$repo_root"
	RECORDS="$(sed -n "s/^RECORDS='\(.*\)'$/\1/p" scripts/docs-lint.sh)"
	section="$(awk '/^## 5 · Decision records/{p=1;next} /^## /{p=0} p' docs/README.md)"
}

# link_targets TEXT — print every markdown link target in TEXT, one per line.
link_targets() {
	printf '%s\n' "$1" | grep -o '](\([^)]*\))' | sed 's/^](//; s/)$//'
}

# percent_decode TARGET — decode %XX escapes such as %20, %28, and %29.
percent_decode() {
	printf '%b' "${1//%/\\x}"
}

# percent_encode NAME — encode space and parentheses the way the index does.
percent_encode() {
	local s="$1"
	s="${s// /%20}"
	s="${s//(/%28}"
	s="${s//)/%29}"
	printf '%s' "$s"
}

# unindexed_records SECTION REGEX FILE... — print each FILE that matches REGEX
# but is not linked from SECTION. Returns 1 if any file is printed.
# FILE is a repository path. docs/x.md must be linked as x.md, and y.md as ../y.md.
unindexed_records() {
	local text="$1" regex="$2" file target missing=0
	shift 2
	for file in "$@"; do
		[[ "$file" =~ $regex ]] || continue
		case "$file" in
		docs/*/*) continue ;;
		docs/*) target="${file#docs/}" ;;
		*/*) continue ;;
		*) target="../$file" ;;
		esac
		if [[ "$text" == *"]($(percent_encode "$target"))"* ]] ||
			[[ "$text" == *"]($(percent_encode "$target")#"* ]] ||
			[[ "$text" == *"]($target)"* ]]; then
			continue
		fi
		printf 'unindexed record: %s (expected link target %s)\n' "$file" "$(percent_encode "$target")"
		missing=1
	done
	return "$missing"
}

@test "extracts the RECORDS pattern from the lint" {
	echo "RECORDS=$RECORDS"
	[ -n "$RECORDS" ]
	[[ "MEMORY/x.md" =~ $RECORDS ]]
	[[ ! "README.md" =~ $RECORDS ]]
}

@test "extracts a non-empty Decision records section from docs/README.md" {
	[ -n "$section" ]
	[[ "$section" == *"Decision records are dated"* ]]
}

@test "every docs/ record linked in the Decision records section matches RECORDS" {
	[ -n "$RECORDS" ]
	local target path checked=0 failed=0
	while IFS= read -r target; do
		target="${target%%#*}"
		[ -n "$target" ] || continue
		case "$target" in
		http://* | https://*) continue ;;
		*/) continue ;;
		*.md) ;;
		*) continue ;;
		esac
		path="$(percent_decode "$target")"
		case "$path" in
		../*) path="${path#../}" ;;
		*) path="docs/$path" ;;
		esac
		checked=$((checked + 1))
		if [ ! -f "$path" ]; then
			echo "missing file: $path (link target $target)"
			failed=1
		elif ! [[ "$path" =~ $RECORDS ]]; then
			echo "not matched by RECORDS: $path (link target $target)"
			failed=1
		fi
	done < <(link_targets "$section")
	echo "checked $checked target(s)"
	[ "$checked" -ge 10 ]
	[ "$failed" -eq 0 ]
}

@test "every RECORDS-tier file at docs/ top level is linked from the Decision records section" {
	[ -n "$RECORDS" ]
	local -a files=()
	mapfile -t files < <(git -c core.quotepath=off ls-files 'docs/*.md' | awk -F/ 'NF == 2')
	[ "${#files[@]}" -ge 10 ]
	run unindexed_records "$section" "$RECORDS" "${files[@]}"
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "every RECORDS-tier file at the repository root is linked from the Decision records section as ../NAME" {
	[ -n "$RECORDS" ]
	local -a files=()
	mapfile -t files < <(git -c core.quotepath=off ls-files '*.md' | awk -F/ 'NF == 1')
	[ "${#files[@]}" -ge 1 ]
	run unindexed_records "$section" "$RECORDS" "${files[@]}"
	echo "$output"
	[ "$status" -eq 0 ]
}

@test "a planted unindexed record fails the section check" {
	run unindexed_records "$section" '^docs/Planted' "docs/Planted-Record.md" "docs/README.md"
	echo "$output"
	[ "$status" -ne 0 ]
	[[ "$output" == *"docs/Planted-Record.md"* ]]
	[[ "$output" != *"docs/README.md"* ]]
}

@test "a planted indexed record passes the section check" {
	run unindexed_records "[x](Planted%20%28A%29.md)" '^docs/Planted' "docs/Planted (A).md"
	echo "$output"
	[ "$status" -eq 0 ]
}
