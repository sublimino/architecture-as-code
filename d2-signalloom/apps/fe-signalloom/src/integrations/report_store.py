"""Provider-neutral storage for generated Discovery Portal reports."""
from __future__ import annotations

import asyncio
import io
import os
from datetime import datetime, timedelta, timezone
from typing import Any, Protocol
from urllib.parse import quote


REPORT_CONTENT_TYPE = "application/pdf"
REPORT_CONTENT_DISPOSITION = 'inline; filename="Signal Loom - Agent Discovery Report.pdf"'


class ReportStore(Protocol):
    """Persistence boundary for report bytes and their durable reference."""

    async def write(self, session_id: str, pdf_bytes: bytes) -> str: ...

    async def read(self, session_id: str) -> bytes: ...


def report_key(session_id: str) -> str:
    if not session_id or "/" in session_id or ".." in session_id:
        raise ValueError("session_id must be a non-empty path-safe identifier")
    return f"{session_id}/report.pdf"


class AzureBlobReportStore:
    """The existing managed-identity Azure Blob implementation."""

    def __init__(self, account_name: str, container: str = "discovery-reports") -> None:
        if not account_name:
            raise ValueError("Azure storage account is required")
        self.account_name = account_name
        self.container = container
        self.account_url = f"https://{account_name}.blob.core.windows.net"

    async def write(self, session_id: str, pdf_bytes: bytes) -> str:
        from azure.core.exceptions import ResourceExistsError
        from azure.identity.aio import DefaultAzureCredential
        from azure.storage.blob import BlobSasPermissions, ContentSettings, generate_blob_sas
        from azure.storage.blob.aio import BlobServiceClient

        key = report_key(session_id)
        async with DefaultAzureCredential() as credential:
            async with BlobServiceClient(self.account_url, credential=credential) as service:
                container = service.get_container_client(self.container)
                try:
                    await container.create_container()
                except ResourceExistsError:
                    pass
                await container.get_blob_client(key).upload_blob(
                    pdf_bytes,
                    overwrite=True,
                    content_settings=ContentSettings(
                        content_type=REPORT_CONTENT_TYPE,
                        content_disposition=REPORT_CONTENT_DISPOSITION,
                    ),
                )
                start = datetime.now(timezone.utc) - timedelta(minutes=15)
                expiry = start + timedelta(days=7)
                delegation_key = await service.get_user_delegation_key(start, expiry)
                sas = generate_blob_sas(
                    account_name=self.account_name,
                    container_name=self.container,
                    blob_name=key,
                    user_delegation_key=delegation_key,
                    permission=BlobSasPermissions(read=True),
                    start=start,
                    expiry=expiry,
                )
        return f"{self.account_url}/{self.container}/{key}?{sas}"

    async def read(self, session_id: str) -> bytes:
        from azure.identity.aio import DefaultAzureCredential
        from azure.storage.blob.aio import BlobServiceClient

        async with DefaultAzureCredential() as credential:
            async with BlobServiceClient(self.account_url, credential=credential) as service:
                stream = await service.get_container_client(self.container).download_blob(report_key(session_id))
                return await stream.readall()


class S3ReportStore:
    """S3-compatible store used by the local MinIO profile."""

    def __init__(self, client: Any, bucket: str, endpoint_url: str = "") -> None:
        if not bucket:
            raise ValueError("S3 report bucket is required")
        self.client = client
        self.bucket = bucket
        self.endpoint_url = endpoint_url.rstrip("/")

    async def write(self, session_id: str, pdf_bytes: bytes) -> str:
        key = report_key(session_id)
        await asyncio.to_thread(
            self.client.put_object,
            Bucket=self.bucket,
            Key=key,
            Body=pdf_bytes,
            ContentType=REPORT_CONTENT_TYPE,
            ContentDisposition=REPORT_CONTENT_DISPOSITION,
        )
        if self.endpoint_url:
            return f"{self.endpoint_url}/{quote(self.bucket)}/{quote(key)}"
        return f"s3://{self.bucket}/{key}"

    async def read(self, session_id: str) -> bytes:
        response = await asyncio.to_thread(
            self.client.get_object, Bucket=self.bucket, Key=report_key(session_id)
        )
        body = response["Body"]
        try:
            return await asyncio.to_thread(body.read)
        finally:
            close = getattr(body, "close", None)
            if close:
                await asyncio.to_thread(close)


def build_s3_client(settings: Any) -> Any:
    import boto3

    return boto3.client(
        "s3",
        endpoint_url=settings.s3_endpoint_url or None,
        aws_access_key_id=settings.s3_access_key_id or None,
        aws_secret_access_key=settings.s3_secret_access_key or None,
        region_name=settings.s3_region,
    )


def get_report_store(config: Any | None = None) -> ReportStore:
    """Select Azure by default; use S3-compatible storage for MinIO/local demos."""
    if config is None:
        from config import settings as config

    backend = config.report_store_backend.strip().lower()
    if backend == "azure":
        return AzureBlobReportStore(config.azure_storage_account or os.getenv("AZURE_STORAGE_ACCOUNT", ""))
    if backend in {"s3", "minio"}:
        return S3ReportStore(build_s3_client(config), config.s3_bucket, config.s3_endpoint_url)
    raise ValueError(f"unknown report store backend: {backend}")
