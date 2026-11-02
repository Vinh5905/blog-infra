locals {
  state_bucket_name = "blogapp-dev-tfstate-${var.aws_account_id}-${var.aws_region}"
}

resource "aws_kms_key" "state" {
  description             = "Encrypt BlogApp dev Terraform state"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "state" {
  name          = "alias/blogapp-dev-tfstate"
  target_key_id = aws_kms_key.state.key_id
}


module "state_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.17.0"

  bucket                = local.state_bucket_name
  expected_bucket_owner = var.aws_account_id
  force_destroy         = false

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  control_object_ownership = true
  object_ownership         = "BucketOwnerEnforced"

  attach_deny_insecure_transport_policy = true

  versioning = {
    enabled = true
  }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm     = "aws:kms"
        kms_master_key_id = aws_kms_key.state.arn
      }

      bucket_key_enabled = true
    }
  }
}