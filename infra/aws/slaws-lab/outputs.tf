output "role_arn" {
  description = "ARN of the cross-account read-only IAM role"
  value       = aws_iam_role.slaws_reader.arn
}

output "queue_url" {
  description = "URL of the SQS notification queue"
  value       = aws_sqs_queue.slaws_lab_notify.url
}

output "dlq_url" {
  description = "URL of the dead-letter SQS queue"
  value       = aws_sqs_queue.slaws_lab_dlq.url
}

output "bucket" {
  description = "Name of the S3 log bucket"
  value       = aws_s3_bucket.slaws_lab.id
}

output "region" {
  description = "AWS region of the lab resources"
  value       = var.region
}

output "external_id" {
  description = "External ID configured for the assumed role"
  value       = var.external_id
}
