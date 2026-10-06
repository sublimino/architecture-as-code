FROM python:3.12-alpine

WORKDIR /app
COPY server.py /app/server.py
COPY network-test-catalogue.json /app/network-test-catalogue.json
USER 65532:65532
EXPOSE 8080
ENV PORT=8080
ENTRYPOINT ["python", "/app/server.py"]
