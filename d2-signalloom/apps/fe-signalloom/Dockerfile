FROM python:3.12-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends wget \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY src/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY src/ .

# Build identity, for scripts/check-deployed-staleness.sh.
#
# Declared HERE rather than beside the base image so that a new commit does not
# invalidate the pip layer above: SOURCE_ID changes on every source edit, and an
# ARG placed earlier would reinstall every dependency each time.
#
# Written before `USER appuser` because /etc is root-owned, and read back with
# nothing but `cat` — the guard must not require jq or python inside a runtime
# image. Absence of this file is itself a finding (an image predating the
# guard), which is why the readback distinguishes "missing" from "exec failed"
# rather than treating both as unknown.
ARG SOURCE_ID
ARG GIT_REF
RUN test -n "$SOURCE_ID" \
    && printf 'workload=fe-signalloom\nsource_id=%s\ngit_ref=%s\n' \
       "$SOURCE_ID" "${GIT_REF:-unknown}" > /etc/osramp-build-id

RUN groupadd --system appgroup \
    && useradd --system --gid appgroup appuser \
    && chown -R appuser:appgroup /app

USER appuser
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --retries=3 CMD wget --no-verbose --tries=1 --spider http://localhost:8000/health || exit 1
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
