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
            /docker build/ && /-f / {
                df=""; ctx="";
                for (i=1;i<=NF;i++) { if ($i=="-f") df=$(i+1) }
                ctx=$NF; sub(/[[:space:]]*\\$/, "", ctx)
                if (df ~ /\$\(/ || ctx ~ /\$\(/ || ctx ~ /^-/) next
                if (mkdir != ".") { df=mkdir "/" df; ctx=mkdir "/" ctx }
                print df "\t" ctx
            }' "$mk"
    done | sort -u
}

@test "DOCKERFILE every make-built Dockerfile has at least one COPY site to check" {
    run load_sites
    [ "$status" -eq 0 ]
    [ -n "$output" ]
}

@test "DOCKERFILE every COPY source in a make-built Dockerfile exists in its build context" {
    local missing=""
    while IFS=$'\t' read -r df ctx; do
        [ -f "$df" ] || { missing+="dockerfile missing: $df"$'\n'; continue; }
        while IFS= read -r line; do
            # Skip stage copies and parse "COPY [--flags] src... dest".
            case "$line" in *--from=*) continue ;; esac
            set -- $line; shift
            while [ $# -gt 1 ]; do
                case "$1" in --*) shift; continue ;; esac
                local src="$1"; shift
                [ $# -ge 1 ] || break
                # Globs: at least one match must exist.
                local found=0 m
                for m in "$ctx"/$src; do [ -e "$m" ] && { found=1; break; }; done
                [ "$found" -eq 1 ] || missing+="$df: COPY $src (context $ctx)"$'\n'
            done
        done < <(grep -E '^[[:space:]]*COPY[[:space:]]' "$df")
    done < <(load_sites)
    if [ -n "$missing" ]; then
        printf '%s' "$missing" >&2
        return 1
    fi
}
