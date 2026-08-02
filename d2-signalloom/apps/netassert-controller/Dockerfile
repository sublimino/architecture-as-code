FROM python:3.12-alpine

WORKDIR /app
COPY server.py /app/server.py
USER 65532:65532
EXPOSE 8080
ENV PORT=8080
ENTRYPOINT ["python", "/app/server.py"]
