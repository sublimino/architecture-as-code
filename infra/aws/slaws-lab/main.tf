provider "aws" {
  region = var.region
}

resource "aws_s3_bucket" "slaws_lab" {
  bucket_prefix = var.bucket_name == "" ? "slaws-lab-kusari-" : null
  bucket        = var.bucket_name != "" ? var.bucket_name : null
  force_destroy = true
}

resource "aws_sqs_queue" "slaws_lab_dlq" {
  name                      = "slaws-lab-dlq"
  message_retention_seconds = 1209600
}

resource "aws_sqs_queue" "slaws_lab_notify" {
  name                      = "slaws-lab-notify"
  message_retention_seconds = 86400
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.slaws_lab_dlq.arn
    maxReceiveCount     = 5
  })
}

resource "aws_sqs_queue_policy" "slaws_lab_notify_policy" {
  queue_url = aws_sqs_queue.slaws_lab_notify.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowS3ObjectCreatedNotification"
        Effect    = "Allow"
        Principal = { Service = "s3.amazonaws.com" }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.slaws_lab_notify.arn
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = aws_s3_bucket.slaws_lab.arn
          }
        }
      }
    ]
  })
}

resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.slaws_lab.id

  queue {
    queue_arn = aws_sqs_queue.slaws_lab_notify.arn
    events    = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_sqs_queue_policy.slaws_lab_notify_policy]
}

resource "aws_iam_role" "slaws_reader" {
  name = "slaws-lab-reader"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          AWS = var.signal_loom_principal_arn
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "sts:ExternalId" = var.external_id
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "slaws_reader_policy" {
  name = "slaws-lab-reader-policy"
  role = aws_iam_role.slaws_reader.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.slaws_lab.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]
        Resource = aws_sqs_queue.slaws_lab_notify.arn
      }
    ]
  })
}

resource "aws_s3_object" "cloudtrail" {
  bucket = aws_s3_bucket.slaws_lab.id
  key    = "AWSLogs/123456789012/CloudTrail/us-east-1/2026/10/02/123456789012_CloudTrail_us-east-1_20261002T0915Z_sample.json"
  source = "${path.module}/../../../d2-signalloom/apps/signal-ingest/collectors/awslogs/testdata/cloudtrail.json"
  etag   = filemd5("${path.module}/../../../d2-signalloom/apps/signal-ingest/collectors/awslogs/testdata/cloudtrail.json")
}

resource "aws_s3_object" "iam" {
  bucket = aws_s3_bucket.slaws_lab.id
  key    = "AWSLogs/123456789012/CloudTrail/us-east-1/2026/10/02/123456789012_CloudTrail_us-east-1_20261002T0915Z_iam.json"
  source = "${path.module}/../../../d2-signalloom/apps/signal-ingest/collectors/awslogs/testdata/iam.json"
  etag   = filemd5("${path.module}/../../../d2-signalloom/apps/signal-ingest/collectors/awslogs/testdata/iam.json")
}
