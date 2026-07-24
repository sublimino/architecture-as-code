# LLM Guard API, vendored from ProtectAI llm-guard-api 0.3.16, built for the
# Estate 95 Security Sandbox. It runs as the in-cluster scanner on the Olly ->
# Orbit A2A hop: input scanners screen the message Olly sends, output scanners
# screen Orbit's reply. CPU-only (ONNX runtime); scanner models are pulled from
# Hugging Face on first scan (lazy_load), so the pod warms up on its first call.
FROM python:3.12-slim

LABEL org.opencontainers.image.source=https://github.com/protectai/llm-guard
LABEL org.opencontainers.image.description="LLM Guard API (Estate 95 Security Sandbox)"
LABEL org.opencontainers.image.licenses=MIT

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN useradd -m -u 1000 user
USER user
ENV HOME=/home/user \
    PATH=/home/user/.local/bin:$PATH \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR $HOME/app

COPY --chown=user:user pyproject.toml README.md ./
COPY --chown=user:user app ./app

RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir ".[cpu]"

RUN python -m spacy download en_core_web_sm

COPY --chown=user:user ./config/scanners.yml ./config/scanners.yml
COPY --chown=user:user entrypoint.sh ./entrypoint.sh
RUN chmod +x ./entrypoint.sh

ENV PYTHONPATH=$HOME/app
EXPOSE 8000
ENTRYPOINT ["./entrypoint.sh"]
