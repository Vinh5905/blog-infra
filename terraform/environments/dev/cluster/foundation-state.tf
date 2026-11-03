data "terraform_remote_state" "foundation" {
  backend = "s3"

  config = {
    bucket              = "blogapp-dev-tfstate-${var.aws_account_id}-${var.aws_region}"
    key                 = "dev/foundation.tfstate"
    region              = var.aws_region
    allowed_account_ids = [var.aws_account_id]
  }
}