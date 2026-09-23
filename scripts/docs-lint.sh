#!/usr/bin/env bash
# docs-lint.sh — check the navigation-layer documentation against the rules in
# docs/documentation-style.md. Offline. Needs only bash, awk, and git.
#
# Usage:
#   scripts/docs-lint.sh              # check the default navigation-layer files
#   scripts/docs-lint.sh FILE...      # check the given markdown files only
#
# Checks (each finding is one line: FILE:LINE: CHECK: detail):
#   link      a relative link target does not exist
#   anchor    a #fragment does not match a heading in the target file
#   space     a link target contains a raw space (GitHub does not render it)
#   make      a `make TARGET` reference names no target in the root Makefile,
#             the nearest slice Makefile, or the `make -C DIR` Makefile
#   semicolon a prose sentence contains a semicolon (STE Rule 8.1)
#   long      a prose sentence has more than DOCS_LINT_MAX_WORDS words
#             (STE Rule 6.3, default 25)
#   word      a prose sentence uses a word from the banned-word list
#   fence     a code fence is opened and never closed
#   orphan    a top-level docs/*.md file has no link from docs/README.md
#
# The checks skip fenced code blocks, tables, headings, HTML comments, and any
# region between <!-- docs-lint: off --> and <!-- docs-lint: on -->.
# Exit status: 0 when no findings, 1 when findings, 2 on usage error.

set -o errexit -o pipefail

ROOT="${DOCS_LINT_ROOT:-$(git -C "$(dirname "${BASH_SOURCE[0]}")/.." rev-parse --show-toplevel)}"
MAX_WORDS="${DOCS_LINT_MAX_WORDS:-25}"
cd "$ROOT"

# The navigation layer: the files a reader or an agent uses to find their way.
# Point-in-time records (proposals, reports, audits, ISAs) are not in this list.
DEFAULT_FILES=(
  README.md
  AGENTS.md
  TESTING.md
  HUMAN_VALIDATION.md
  docs/README.md
  docs/documentation-style.md
  d2-agent-trust/AGENTS.md
  d2-cpai/AGENTS.md
  d2-infra/AGENTS.md
  d2-k8s-afm/AGENTS.md
  d2-osramp-apps/AGENTS.md
  d2-osramp-fleet/AGENTS.md
  d2-signalloom/AGENTS.md
  d2-signalloom/README.md
)

# Banned words and phrases (lower case, extended regex). Each has a simpler
# approved replacement in docs/documentation-style.md.
BANNED='utili[sz]e|leverag(e|es|ed|ing)|in order to|prior to|facilitate|commence|whilst|simply|obviously|basically|e\.g\.|i\.e\.|click here'

if [[ $# -gt 0 ]]; then
  FILES=("$@")
else
  FILES=("${DEFAULT_FILES[@]}")
fi

for f in "${FILES[@]}"; do
  [[ -f "$f" ]] || { echo "docs-lint: no such file: $f" >&2; exit 2; }
done

# ---------------------------------------------------------------------------
# extract FILE — print tab-separated records for one markdown file:
#   L <line> <link-target>
#   M <line> <make-args>          (text after "make " up to a shell separator)
#   P <line> <sentence>           (one prose sentence, inline code collapsed)
#   F <line>                      (a code fence that is never closed)
# ---------------------------------------------------------------------------
extract() {
  awk -v OFS='\t' '
    function flush(   s, n, i, parts) {
      if (para == "") return
      s = para; para = ""
      n = split(s, parts, /[.!?][)"*_]*[ \t]+/)
      for (i = 1; i <= n; i++) if (parts[i] ~ /[A-Za-z]/) print "P", pstart, parts[i]
    }
    function makes(text, ln,   t, a) {
      t = text
      while (match(t, /(^|[^A-Za-z0-9_-])make[ \t]+[^`|;&)#]*/)) {
        a = substr(t, RSTART, RLENGTH)
        sub(/^[^m]*make[ \t]+/, "", a)
        print "M", ln, a
        t = substr(t, RSTART + RLENGTH)
      }
    }
    /<!-- *docs-lint: *off *-->/ { off = 1; flush(); next }
    /<!-- *docs-lint: *on *-->/  { off = 0; next }
    off { next }
    /^[ \t]*(```|~~~)/ { flush(); fence = !fence; if (fence) fstart = NR; next }
    fence { if ($0 ~ /^[ \t]*(\$ )?make[ \t]/) makes($0, NR); next }
    /<!--/ { incomment = 1 }
    incomment { if ($0 ~ /-->/) incomment = 0; next }
    {
      line = $0
      # Links and make references come from every non-code line, tables included.
      t = line
      gsub(/`[^`]*`/, "", t)
      while (match(t, /\]\([^)]*\)/)) {
        target = substr(t, RSTART + 2, RLENGTH - 3)
        sub(/[ \t]+"[^"]*"$/, "", target)
        print "L", NR, target
        t = substr(t, RSTART + RLENGTH)
      }
      c = line
      while (match(c, /`[^`]*`/)) {
        # makes() calls match(), which resets the global RSTART and RLENGTH.
        code = substr(c, RSTART + 1, RLENGTH - 2)
        c = substr(c, RSTART + RLENGTH)
        if (code ~ /^make[ \t]/) makes(code, NR)
      }
    }
    /^[ \t]*$/ { flush(); next }
    /^[ \t]*(#|\||>[ \t]*$|<)/ { flush(); next }
    /^[ \t]*([-*+]|[0-9]+\.)[ \t]/ { flush() }
    {
      p = line
      gsub(/`[^`]*`/, "CODE", p)                 # inline code counts as one word
      gsub(/!?\[([^]]*)\]\([^)]*\)/, "LINK", p)  # a link counts as its label
      sub(/^[ \t]*([-*+]|[0-9]+\.)[ \t]+/, "", p)
      sub(/^[ \t]*>[ \t]*/, "", p)
      if (para == "") pstart = NR
      para = para " " p
    }
    END { flush(); if (fence) print "F", fstart, "" }
  ' "$1"
}

# anchors FILE — print every heading anchor in FILE, one per line. The slug
# follows GitHub: lower case, punctuation removed, spaces to hyphens, and a
# -1, -2, ... suffix on a repeated heading.
anchors() {
  awk '
    /^[ \t]*(```|~~~)/ { fence = !fence; next }
    fence || !/^#{1,6} / { next }
    {
      s = $0
      sub(/^#+ +/, "", s); sub(/ +#+ *$/, "", s)
      s = tolower(s)
      gsub(/[^a-z0-9 _-]/, "", s)
      gsub(/ /, "-", s)
      print (seen[s] ? s "-" seen[s] : s)
      seen[s]++
    }
  ' "$1"
  # Explicit HTML anchors.
  { rg -o --no-filename 'id="[^"]+"' "$1" 2>/dev/null || true; } | sed 's/^id="//; s/"$//'
}

# The anchors of each target file, read once. Key: file path. Value: newline list.
declare -A ANCHORS=()
has_anchor() {
  local file="$1" frag="$2"
  [[ -v "ANCHORS[$file]" ]] || ANCHORS[$file]=$'\n'"$(anchors "$file")"$'\n'
  [[ "${ANCHORS[$file]}" == *$'\n'"$frag"$'\n'* ]]
}

# targets MAKEFILE — print every explicit target name (patterns keep their %).
targets() {
  awk -F: '/^[^\t#=][^=]*:([^=]|$)/ && $1 !~ /^\./ { n = split($1, a, /[ \t]+/); for (i = 1; i <= n; i++) if (a[i] != "") print a[i] }' "$1"
}

# The targets of each Makefile, read once. TARGETS key: "makefile|name".
# PATTERNS key: makefile. Value: space-separated regular expressions.
declare -A TARGETS=() PATTERNS=() LOADED=()
load_targets() {
  local mf="$1" t
  [[ -v "LOADED[$mf]" ]] && return 0
  LOADED[$mf]=1
  PATTERNS[$mf]=""
  while IFS= read -r t; do
    if [[ "$t" == *%* ]]; then
      PATTERNS[$mf]+="^${t//%/.+}\$ "
    else
      TARGETS["$mf|$t"]=1
    fi
  done < <(targets "$mf")
}

# has_target MAKEFILE NAME — true when MAKEFILE defines NAME (patterns allowed).
has_target() {
  local mf="$1" name="$2" re
  load_targets "$mf"
  [[ -v "TARGETS[$mf|$name]" ]] && return 0
  for re in ${PATTERNS[$mf]}; do
    [[ "$name" =~ $re ]] && return 0
  done
  return 1
}

# nearest_makefile FILE — the Makefile in FILE's directory or the closest parent.
nearest_makefile() {
  local d
  d="$(dirname "$1")"
  while [[ "$d" != "." && "$d" != "/" ]]; do
    [[ -f "$d/Makefile" ]] && { echo "$d/Makefile"; return; }
    d="$(dirname "$d")"
  done
  echo Makefile
}

findings=0
report() { printf '%s:%s: %s: %s\n' "$1" "$2" "$3" "$4"; findings=$((findings + 1)); }

check_make() {
  local file="$1" ln="$2" args="$3" dir="" name mf
  # shellcheck disable=SC2086 # word splitting of the make argument list is intended
  set -- $args
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -C) dir="${2:-}"; shift; [[ $# -gt 0 ]] && shift ;;
      -C*) dir="${1#-C}"; shift ;;
      -*) shift ;;
      *=*) shift ;;
      *) break ;;
    esac
  done
  name="${1:-}"
  # Skip empty references, placeholders, prose ("make sure"), and shell text.
  [[ -z "$name" || "$name" == *'<'* || "$name" == *'$'* || "$name" == *'*'* ]] && return 0
  [[ "$name" =~ ^[a-z0-9][a-z0-9_.-]*$ ]] || return 0
  case "$name" in sure | it | a | an | the | this | that | them | your | changes | comprehensive | sense) return 0 ;; esac
  if [[ -n "$dir" ]]; then
    mf="$dir/Makefile"
    [[ -f "$mf" ]] || { report "$file" "$ln" make "make -C $dir: no $mf"; return 0; }
    has_target "$mf" "$name" || report "$file" "$ln" make "no target '$name' in $mf"
    return 0
  fi
  has_target Makefile "$name" && return 0
  mf="$(nearest_makefile "$file")"
  [[ "$mf" != Makefile ]] && has_target "$mf" "$name" && return 0
  [[ "$mf" == Makefile ]] && mf="" || mf=" or $mf"
  report "$file" "$ln" make "no target '$name' in Makefile$mf"
}

check_link() {
  local file="$1" ln="$2" target="$3" path frag dest
  target="${target#<}"; target="${target%>}"
  case "$target" in http://* | https://* | mailto:* | file://* | "") return 0 ;; esac
  if [[ "$target" == *' '* ]]; then
    report "$file" "$ln" space "link target has a raw space, use %20 or <...>: $target"
    return 0
  fi
  path="${target%%#*}"
  frag=""
  [[ "$target" == *'#'* ]] && frag="${target#*#}"
  # Site-absolute paths belong to a rendered site, not to the repository.
  [[ "$path" == /* ]] && return 0
  if [[ -z "$path" ]]; then
    dest="$file"
  else
    path="$(printf '%b' "${path//%/\\x}")"
    dest="$(dirname "$file")/$path"
    if [[ ! -e "$dest" ]]; then
      report "$file" "$ln" link "target does not exist: $target"
      return 0
    fi
  fi
  if [[ -n "$frag" && -f "$dest" && "$dest" == *.md ]]; then
    has_anchor "$dest" "$frag" || report "$file" "$ln" anchor "no heading '#$frag' in $dest"
  fi
}

check_prose() {
  local file="$1" ln="$2" s="$3" words low w
  if [[ "$s" == *';'* ]]; then
    report "$file" "$ln" semicolon "use two sentences: ${s:0:70}"
  fi
  read -r -a w <<<"$s"
  words=${#w[@]}
  if ((words > MAX_WORDS)); then
    report "$file" "$ln" long "$words words (max $MAX_WORDS): ${s:0:70}"
  fi
  low=" ${s,,} "
  if [[ "$low" =~ [^a-z]($BANNED)([^a-z]|$) ]]; then
    report "$file" "$ln" word "banned word '${BASH_REMATCH[1]}': ${s:0:70}"
  fi
}

for file in "${FILES[@]}"; do
  while IFS=$'\t' read -r kind ln rest; do
    case "$kind" in
      L) check_link "$file" "$ln" "$rest" ;;
      M) check_make "$file" "$ln" "$rest" ;;
      P) check_prose "$file" "$ln" "$rest" ;;
      F) report "$file" "$ln" fence "code fence opened here is never closed" ;;
    esac
  done < <(extract "$file")
done

# Every top-level living doc in docs/ must be reachable from the index.
if [[ " ${FILES[*]} " == *" docs/README.md "* ]]; then
  while IFS= read -r -d '' doc; do
    base="${doc#docs/}"
    [[ "$base" == README.md ]] && continue
    # A link to a name with spaces or parentheses must percent-encode them.
    enc="${base// /%20}"; enc="${enc//(/%28}"; enc="${enc//)/%29}"
    if ! rg -qF -e "($base)" -e "(<$base>)" -e "($enc)" -e "(./$base)" -e "(./$enc)" docs/README.md; then
      report docs/README.md 1 orphan "not linked from the index: $doc"
    fi
  done < <(git ls-files -z 'docs/*.md' | tr '\0' '\n' | awk -F/ 'NF == 2' | tr '\n' '\0')
fi

if ((findings > 0)); then
  echo "docs-lint: $findings finding(s). Rules: docs/documentation-style.md" >&2
  exit 1
fi
echo "docs-lint: ${#FILES[@]} file(s) clean"
