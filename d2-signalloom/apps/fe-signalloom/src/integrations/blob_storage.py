"""Backward-compatible report upload facade backed by ``ReportStore``."""
from .report_store import get_report_store


async def upload_report(session_id: str, pdf_bytes: bytes) -> str:
    return await get_report_store().write(session_id, pdf_bytes)
