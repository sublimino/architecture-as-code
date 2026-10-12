variable "region" {
  type        = string
  description = "AWS region for the SLAWS live lab"
  default     = "us-east-1"
}

variable "signal_loom_principal_arn" {
  type        = string
  description = "ARN of the Signal Loom principal authorized to assume the reader role"
  default     = "arn:aws:iam::123456789012:role/signal-loom-collector"
}

variable "external_id" {
  type        = string
  description = "External ID required to assume the cross-account role (confused-deputy guard)"
  default     = "slaws-lab-external-id-2026q3"
}

variable "bucket_name" {
  type        = string
  description = "Name for the lab S3 bucket (or left blank for bucket_prefix)"
  default     = ""
}
