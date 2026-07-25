"""Configuration for the vendored Discovery Portal."""
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8")

    database_url: str = ""
    redis_url: str = ""
    environment: str = "development"
    cors_allowed_origins: list[str] = ["https://signal-loom.ai", "https://dev.signal-loom.ai"]
    log_level: str = "INFO"
    report_store_backend: str = "azure"
    azure_storage_account: str = ""
    s3_endpoint_url: str = ""
    s3_access_key_id: str = ""
    s3_secret_access_key: str = ""
    s3_region: str = "us-east-1"
    s3_bucket: str = "discovery-reports"


settings = Settings()
