#!/usr/bin/env bats
# @id     dockerfile-copy-sources
# @target Makefile, d2-signalloom/Makefile (every `docker build -f <Dockerfile> ... <context>` site)
# @doc    docs/signalloom/sltm-governor-log.md (2026-10-03 cold rebuild: fleet-manager COPY pointed at a directory the rename retired)
# @spec   Every COPY source in a Dockerfile that make builds must exist inside that build's context.
#
# Why: a blanket text rename can rewrite a COPY source to a directory that does not exist, and a
# host that still carries the previously built image never notices. Only a cold build does.
# This suite is offline and needs no cluster.

load_sites() {
    # Emit "dockerfile<TAB>context" for every make site that runs docker build with -f.
    local mk
    for mk in Makefile d2-signalloom/Makefile; do
        [ -f "$mk" ] || continue
        awk -v mkdir="$(dirname "$mk")" '
            /docker build/ {
                if ($0 ~ /echo/) next
                sub(/[[:space:]]*&.*$/, "")   # backgrounded builds: drop the "& PID=$$!" tail
                df=""; ctx="";
                for (i=1;i<=NF;i++) { if ($i=="-f") df=$(i+1) }
                ctx=$NF; sub(/[[:space:]]*\\$/, "", ctx); sub(/\/$/, "", ctx)
                if (ctx == "" || ctx == "\\" || df ~ /\$\(/ || ctx ~ /\$\(/ || ctx ~ /^-/ || ctx ~ /^\$\$/) next
                # `docker build -t x <dir>`: the Dockerfile is <dir>/Dockerfile.
                if (df == "") df=ctx "/Dockerfile"
                if (mkdir != ".") { df=mkdir "/" df; ctx=mkdir "/" ctx }
                print df "\t" ctx
            }' "$mk"
    done | sort -u
}

# Sites whose Dockerfile or context is a make variable cannot be resolved by a
# text parse; they are listed here by name so a new one fails loudly instead of
# being skipped. Update this list when a make-variable build site is added.
SKIPPED_SITES_EXPECTED=2   # $(CPAI_CLI_ROOT)/Dockerfile.runtime (make variable) and the
                           # sentinel build whose context is on a continuation line
                           # (covered by sentinel-image-publish). The echo that only
                           # mentioned "docker build" moved to scripts/sentinel-image-tag.sh.

@test "DOCKERFILE the parser sees every docker build site: all resolved but the make-variable site skipped by name" {
    run load_sites
    [ "$status" -eq 0 ]
    local resolved; resolved="$(printf '%s\n' "$output" | grep -c .)"
    [ "$resolved" -ge 15 ]
    local all; all="$(grep -h 'docker build' Makefile d2-signalloom/Makefile | grep -vc '^#')"
    [ "$((all - resolved))" -eq "$SKIPPED_SITES_EXPECTED" ]
    grep -q 'docker build -f \$(CPAI_CLI_ROOT)/Dockerfile.runtime' Makefile
}

@test "DOCKERFILE every COPY source in a make-built Dockerfile exists in its build context" {
    local missing=""
    while IFS=$'\t' read -r df ctx; do
        [ -f "$df" ] || { missing+="dockerfile missing: $df"$'\n'; continue; }
        while IFS= read -r line; do
            # Skip stage copies and parse "COPY [--flags] src... dest".
            case "$line" in *--from=*) continue ;; esac
            set -- $line; shift
            # Docker's rule: a literal source must exist; a wildcard may match
            # nothing as long as some source on the line matched.
            local matched=0 literal_missing="" src m
            while [ $# -gt 1 ]; do
                case "$1" in --*) shift; continue ;; esac
                src="$1"; shift
                [ $# -ge 1 ] || break
                local found=0
                for m in "$ctx"/$src; do [ -e "$m" ] && { found=1; break; }; done
                if [ "$found" -eq 1 ]; then matched=1
                else case "$src" in *\**|*\?*) ;; *) literal_missing+=" $src" ;; esac
                fi
            done
            if [ "$matched" -eq 0 ] || [ -n "$literal_missing" ]; then
                missing+="$df: COPY${literal_missing:-$line} (context $ctx)"$'\n'
            fi
        done < <(grep -E '^[[:space:]]*COPY[[:space:]]' "$df")
    done < <(load_sites)
    if [ -n "$missing" ]; then
        printf '%s' "$missing" >&2
        return 1
    fi
}
