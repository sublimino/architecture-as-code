import asyncio
import io
from types import SimpleNamespace

import pytest

from integrations.report_store import S3ReportStore, get_report_store


class FakeS3:
    def __init__(self):
        self.objects = {}
        self.put_calls = []

    def put_object(self, **kwargs):
        self.put_calls.append(kwargs)
        self.objects[(kwargs["Bucket"], kwargs["Key"])] = kwargs["Body"]

    def get_object(self, **kwargs):
        return {"Body": io.BytesIO(self.objects[(kwargs["Bucket"], kwargs["Key"])])}


@pytest.mark.asyncio
async def test_s3_store_writes_reads_and_returns_minio_url():
    client = FakeS3()
    store = S3ReportStore(client, "reports", "http://minio:9000")

    url = await store.write("session-1", b"%PDF-demo")

    assert url == "http://minio:9000/reports/session-1/report.pdf"
    assert await store.read("session-1") == b"%PDF-demo"
    assert client.put_calls[0]["ContentType"] == "application/pdf"


def test_default_store_is_azure_and_minio_is_explicit(monkeypatch):
    azure = SimpleNamespace(report_store_backend="azure", azure_storage_account="account")
    assert type(get_report_store(azure)).__name__ == "AzureBlobReportStore"

    minio = SimpleNamespace(report_store_backend="minio", s3_bucket="reports", s3_endpoint_url="http://minio:9000", s3_access_key_id="key", s3_secret_access_key="secret", s3_region="us-east-1")
    monkeypatch.setattr("integrations.report_store.build_s3_client", lambda config: FakeS3())
    assert type(get_report_store(minio)).__name__ == "S3ReportStore"


def test_unknown_store_backend_is_rejected():
    with pytest.raises(ValueError, match="unknown report store backend"):
        get_report_store(SimpleNamespace(report_store_backend="unknown"))
