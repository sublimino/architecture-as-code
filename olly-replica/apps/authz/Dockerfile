# olly-authz: the in-cluster ARC identity chain (COIN / PlainID / EEMS).
# Pure stdlib python3, no third-party dependency, so the image is tiny and the
# control plane starts in well under a second.
FROM python:3.12-slim

WORKDIR /app
COPY authz/ /app/authz/

# COIN :8001, PlainID PDP :8002, EEMS PIP :8003 (co-located; internal calls stay
# on loopback, the Service exposes all three).
EXPOSE 8001 8002 8003

USER 65532:65532
ENTRYPOINT ["python", "-m", "authz.serve"]
