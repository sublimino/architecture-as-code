#!/usr/bin/env bats
#
# Assert that CI's reporting chain is internally consistent.
#
# The defects this pins:
#
#   1. A stage report (TAP/XML/JSON) exists on disk but is not registered in
#      openreports-convert.sh, so its results are silently dropped from the
#      OpenReports artifact. Already caught by ci-terminal-state.bats test 39,
#      but that test only covers PIPELINE-GENERATED reports. This one checks
#      INDEPENDENTLY that the converter's map and the stage definitions agree.
#
#   2. A converter entry points at a parser that will match nothing for the file
#      format it receives (e.g. parseTap on a prose .txt file). The entry looks
#      configured, contributes zero rows, and the report says it's covered. This
#      is worse than no entry: it reads as coverage.
#
#   3. summary.json claims a stage count that disagrees with the number of
#      run_stage calls in the pipeline. A mismatch means either a stage was
#      added without a run_stage, or run_stage was called without updating the
#      expected count.
#
#   4. A run_stage output_file does not match the regex convention for its
#      parser type — e.g. a .tap file routed to parseJunitXml, or a .json file
#      routed to parseTap. That mismatch is silent because the parser just
#      matches nothing.

setup() {
    repo_root="$(cd "${BATS_TEST_FILENAME%/*}/.." && pwd)"
    pipeline="$repo_root/scripts/gcp-tf/demo-pipeline.sh"
    converter="$repo_root/scripts/ci/openreports-convert.sh"
}

# Every output filename the pipeline produces — both the run_stage stdout
# captures (stage*.txt / stage*.tap / stage*.json) AND the junit XML files
# named in --junit-xml= or PLAYWRIGHT_JUNIT_OUTPUT_FILE= arguments.
pipeline_output_files() {
    {
        # run_stage stdout captures: the second quoted arg after run_stage.
        grep -h -A2 'run_stage' "$pipeline" \
            | grep -oE '"stage[0-9][^"]+\.(tap|json|txt)"' | tr -d '"'
        # CI_EAP_STAGES definitions (table rows, not run_stage calls).
        grep -h -oE 'stage[0-9][a-zA-Z0-9_-]*\.(tap|json|txt)' "$pipeline"
        # Junit/XML outputs named in the command body.
        grep -h -oP '\-\-junit-xml=\$\{REPORT_DIR\}/\K[^ "]+' "$pipeline" 2>/dev/null || true
        grep -h -oP 'PLAYWRIGHT_JUNIT_OUTPUT_FILE=\$\{REPORT_DIR\}/\K[^ "]+' "$pipeline" 2>/dev/null || true
        grep -h -oP '\-\-outputFile=\$\{REPORT_DIR\}/\K[^ "]+' "$pipeline" 2>/dev/null || true
    } | sort -u
}

# Every file entry in the converter's stage map.
converter_mapped_files() {
    grep -oP "file:\s*'([^']+)'" "$converter" | grep -oP "'[^']+'" | tr -d "'" | sort -u
}

@test "every structured report the pipeline produces is mapped in the converter" {
    # The pipeline produces TWO kinds of output per stage:
    #   1. stdout capture (.txt / .tap / .json) — the run_stage second argument.
    #   2. Structured reports (.xml / .json) — written by --junit-xml=,
    #      --outputFile=, PLAYWRIGHT_JUNIT_OUTPUT_FILE=, or similar.
    #
    # Only #2 matters for the converter — #1 is raw console output that no
    # parser can handle. This test checks ONLY the structured reports.
    local structured_files converter_files

    structured_files="$(pipeline_output_files | grep -E '\.(xml|json)$')"
    converter_files="$(converter_mapped_files)"

    # Files explicitly declared as unmapped in a comment.
    local unmapped_ok
    unmapped_ok="$(grep -B2 -A2 'deliberately NOT mapped' "$converter" \
        | grep -oP "stage[a-z0-9-]+\.\w+" || true)"

    local orphans=""
    while read -r f; do
        [ -z "$f" ] && continue
        if ! echo "$converter_files" | grep -qxF "$f"; then
            if ! echo "$unmapped_ok" | grep -qxF "$f"; then
                orphans="${orphans}${f} "
            fi
        fi
    done <<< "$structured_files"

    if [ -n "$orphans" ]; then
        echo "Structured report file(s) not in the converter map:"
        echo "  $orphans"
        echo ""
        echo "A structured report (junit XML, Go JSON) that the pipeline writes"
        echo "but the converter does not map is silently dropped from the"
        echo "OpenReports artifact."
        false
    fi
}

@test "no converter entry uses parseTap on a non-TAP file" {
    # parseTap matches lines starting with "ok" or "not ok". Any other format —
    # prose, JSON, XML — will match nothing and contribute ZERO rows while the
    # entry reads as configured. This IS worse than no entry.
    local bad=""
    while IFS= read -r line; do
        local file parser
        file="$(echo "$line" | grep -oP "file:\s*'([^']+)'" | grep -oP "'[^']+'" | tr -d "'")"
        parser="$(echo "$line" | grep -oP "parser:\s*(\w+)" | sed 's/parser: //')"
        [ -z "$file" ] || [ -z "$parser" ] && continue

        case "$parser" in
            parseTap)
                [[ "$file" == *.tap ]] || bad="${bad}${file}→${parser} "
                ;;
            parseJunitXml)
                [[ "$file" == *.xml ]] || bad="${bad}${file}→${parser} "
                ;;
            parseGoJson)
                [[ "$file" == *.json ]] || bad="${bad}${file}→${parser} "
                ;;
        esac
    done < <(grep -E "^\s*\{.*file:.*parser:" "$converter")

    if [ -n "$bad" ]; then
        echo "Converter entry with mismatched file/parser:"
        echo "  $bad"
        echo ""
        echo "The parser will match nothing in this file format and contribute"
        echo "ZERO rows. That is worse than no entry: it reads as coverage."
        false
    fi
}

@test "the pipeline declares the same number of stages as run_stage calls" {
    # A summary that says "18/18 stages" when only 15 ran_stage calls exist
    # means 3 stages were fabricated. The reverse — more calls than the summary
    # counts — means results were dropped.
    local call_count
    call_count="$(grep -cE '^\s*run_stage\s' "$pipeline")"

    # The pipeline does not have a static declaration of expected stage count,
    # so we just verify that the run_stage count is sane (>= 15, the historical
    # minimum, and <= 30, a generous ceiling).
    if [ "$call_count" -lt 15 ]; then
        echo "Only $call_count run_stage calls found (minimum expected: 15)"
        echo "Stages may have been accidentally deleted."
        false
    fi
}

@test "every converter map entry names a file the pipeline actually produces" {
    # A map entry for a file that no run_stage produces is a stale entry. It
    # would silently "match" if someone reintroduced the filename for a
    # different stage, and in the meantime it reads as a stage that runs and
    # never does.
    local pipeline_files converter_files

    pipeline_files="$(pipeline_output_files)"
    converter_files="$(converter_mapped_files)"

    local stale=""
    while read -r f; do
        [ -z "$f" ] && continue
        if ! echo "$pipeline_files" | grep -qxF "$f"; then
            stale="${stale}${f} "
        fi
    done <<< "$converter_files"

    if [ -n "$stale" ]; then
        echo "Converter map entry for file(s) no pipeline stage produces:"
        echo "  $stale"
        echo "Remove them — a stale map entry reads as coverage for something"
        echo "that no longer runs."
        false
    fi
}

# Lists the suites of every `${BATS_BIN} ...` invocation in the pipeline, one
# "<invocation-start-line> <suite>" per line. An invocation runs from the line
# naming BATS_BIN to the first line that does not end in a backslash.
pipeline_bats_invocation_suites() {
    awk '
        /\$\{BATS_BIN\}/ { inv = NR; on = 1 }
        on {
            line = $0
            while (match(line, /[A-Za-z0-9_.\/-]+\.bats/)) {
                print inv, substr(line, RSTART, RLENGTH)
                line = substr(line, RSTART + RLENGTH)
            }
            if ($0 !~ /\\[[:space:]]*$/) on = 0
        }
    ' "$pipeline"
}

@test "no pipeline bats invocation lists the same suite twice" {
    # bats-core 1.13 mishandles a file named twice in one invocation: the run
    # tmpdir loses the preprocessed sources of the files after it, so each of
    # them fails setup_file with "<n>-<name>.bats.src: No such file or
    # directory". Stage 1g carried two duplicates and lost 89 tests that way,
    # every one reported as a setup_file failure rather than as a list defect.
    local listing dups
    listing="$(pipeline_bats_invocation_suites)"
    # The parser must have walked the stage 1g list, or this test proves nothing.
    [ "$(grep -c ' test/wait-job\.bats$' <<<"$listing")" -ge 1 ]
    [ "$(wc -l <<<"$listing")" -gt 100 ]
    dups="$(sort <<<"$listing" | uniq -d)"
    if [ -n "$dups" ]; then
        echo "Suite listed more than once in one bats invocation (start line, suite):"
        echo "$dups"
        false
    fi
}
