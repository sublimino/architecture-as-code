# Olly Sentinel: Google ADK agent runtime + A2A server. Build context is
# olly-replica/ so the committed contracts (payload schemas AND the agent
# card) bake into the image; pytest runs during the build, so an image with
# drifted contracts or a broken card cannot exist.
#
#   docker build -f apps/sentinel/Dockerfile -t olly-sentinel:dev .
FROM python:3.12-slim
WORKDIR /app

COPY apps/sentinel/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY contracts /contracts
COPY apps/sentinel /app
ENV CONTRACTS_DIR=/contracts
RUN pip install --no-cache-dir pytest && python -m pytest tests -q -W ignore::UserWarning

USER 65532:65532
ENV HOME=/tmp PYTHONUNBUFFERED=1
EXPOSE 8080
ENTRYPOINT ["python", "-m", "olly_sentinel.main"]
