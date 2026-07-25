-- 002_add_report_url_to_sessions.sql
ALTER TABLE IF EXISTS public.discovery_scan_sessions ADD COLUMN IF NOT EXISTS report_blob_url TEXT;
