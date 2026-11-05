module "oidc_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.17.0"

  bucket        = local.oidc_bucket_name
  force_destroy = false

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  control_object_ownership = true
  object_ownership         = "BucketOwnerEnforced"

  attach_deny_insecure_transport_policy = true

  attach_policy = true
  policy        = data.aws_iam_policy_document.oidc_cloudfront_read.json

  versioning = {
    enabled = true
  }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm = "AES256"
      }
    }
  }

  tags = {
    Name = local.oidc_bucket_name
  }
}

data "aws_iam_policy_document" "oidc_cloudfront_read" {
  statement {
    sid     = "AllowCloudFrontReadOIDCDocuments"
    effect  = "Allow"
    actions = ["s3:GetObject"]

    resources = [
      "${module.oidc_bucket.s3_bucket_arn}/.well-known/openid-configuration",
      "${module.oidc_bucket.s3_bucket_arn}/openid/v1/jwks",
    ]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [module.oidc_cdn.cloudfront_distribution_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.aws_account_id]
    }
  }
}