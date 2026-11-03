resource "aws_kms_key" "ssm_transfer" {
  description             = "Encrypt BlogApp dev Ansible SSM transfer files"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  tags = {
    Name = "blogapp-dev-ssm-transfer"
  }
}

resource "aws_kms_alias" "ssm_transfer" {
  name          = "alias/blogapp-dev-ssm-transfer"
  target_key_id = aws_kms_key.ssm_transfer.key_id
}

locals {
  ssm_transfer_bucket_name = "blogapp-dev-ssm-transfer-${var.aws_account_id}-${var.aws_region}"
}

module "ssm_transfer_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.17.0"

  bucket        = local.ssm_transfer_bucket_name
  force_destroy = false

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  control_object_ownership = true
  object_ownership         = "BucketOwnerEnforced"

  attach_deny_insecure_transport_policy = true

  versioning = {
    enabled = false
  }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm     = "aws:kms"
        kms_master_key_id = aws_kms_key.ssm_transfer.arn
      }

      bucket_key_enabled = true
    }
  }

  lifecycle_rule = [
    {
      id      = "cleanup-transfer-files"
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
    Name = local.ssm_transfer_bucket_name
  }
}