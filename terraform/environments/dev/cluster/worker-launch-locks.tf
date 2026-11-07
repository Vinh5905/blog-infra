resource "aws_dynamodb_table" "worker_launch_locks" {
  name         = "blogapp-dev-worker-launch-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LaunchKey"

  attribute {
    name = "LaunchKey"
    type = "S"
  }

  ttl {
    attribute_name = "ExpiresAt"
    enabled        = true
  }
}