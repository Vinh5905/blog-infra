provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = {
      Project     = "blogapp"
      Environment = "dev"
      ManagedBy   = "terraform"
      Component   = "foundation"
    }
  }
}

provider "aws" {
  alias               = "us_east_1"
  region              = "us-east-1"
  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = {
      Project     = "blogapp"
      Environment = "dev"
      ManagedBy   = "terraform"
      Component   = "foundation"
    }
  }
}