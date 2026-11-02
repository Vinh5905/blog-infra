output "state_bucket_name" {
  description = "Name of the Terraform state bucket"
  value       = module.state_bucket.s3_bucket_id
}

output "kms_key_arn" {
  description = "ARN of the KMS key used for state encryption"
  value       = aws_kms_key.state.arn
}

output "bootstrap_backend_config" {
  description = "S3 backend configuration for the bootstrap root"

  value = <<-EOT
    bucket                = "${module.state_bucket.s3_bucket_id}"
    key                   = "bootstrap/state.tfstate"
    region                = "${var.aws_region}"
    allowed_account_ids   = ["${var.aws_account_id}"]
    encrypt               = true
    kms_key_id            = "${aws_kms_key.state.arn}"
    use_lockfile          = true
  EOT
}