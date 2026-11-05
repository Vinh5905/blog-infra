module "oidc_logs_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.17.0"

  bucket = "blogapp-dev-oidc-logs-${var.aws_account_id}-${var.aws_region}"

  force_destroy = false

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  control_object_ownership = true
  object_ownership         = "BucketOwnerEnforced"

  attach_deny_insecure_transport_policy = true

  attach_policy = true
  policy        = data.aws_iam_policy_document.oidc_logs_delivery.json

  versioning = {
    enabled = false
  }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }

  lifecycle_rule = [
    {
      id      = "expire-access-logs"
      enabled = true

      filter = {
        prefix = ""
      }

      expiration = {
        days = 1
      }

      abort_incomplete_multipart_upload_days = 1
    }
  ]

  tags = {
    Name = "blogapp-dev-oidc-logs"
  }
}

resource "aws_cloudwatch_log_delivery_source" "oidc" {
  provider = aws.us_east_1

  name         = "blogapp-dev-oidc"
  log_type     = "ACCESS_LOGS"
  resource_arn = module.oidc_cdn.cloudfront_distribution_arn
}

data "aws_iam_policy_document" "oidc_logs_delivery" {
  statement {
    sid     = "AllowOIDCAccessLogDelivery"
    effect  = "Allow"
    actions = ["s3:PutObject"]

    resources = [
      "${module.oidc_logs_bucket.s3_bucket_arn}/AWSLogs/${var.aws_account_id}/*",
    ]

    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.aws_account_id]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_log_delivery_source.oidc.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
}

resource "aws_cloudwatch_log_delivery_destination" "oidc" {
  provider = aws.us_east_1

  name          = "blogapp-dev-oidc-s3"
  output_format = "json"

  delivery_destination_configuration {
    destination_resource_arn = module.oidc_logs_bucket.s3_bucket_arn
  }
}

resource "aws_cloudwatch_log_delivery" "oidc" {
  provider = aws.us_east_1

  delivery_source_name     = aws_cloudwatch_log_delivery_source.oidc.name
  delivery_destination_arn = aws_cloudwatch_log_delivery_destination.oidc.arn

  record_fields = [
    "date",
    "time",
    "c-ip",
    "cs-method",
    "cs(Host)",
    "cs-uri-stem",
    "sc-status",
    "x-edge-result-type",
    "x-edge-detailed-result-type",
    "time-taken",
    "x-edge-request-id",
  ]

  depends_on = [
    module.oidc_logs_bucket,
  ]
}