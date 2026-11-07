resource "aws_sqs_queue" "worker_termination_dlq" {
  name                      = "blogapp-dev-worker-termination-dlq"
  message_retention_seconds = 345600
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "worker_termination" {
  name                      = "blogapp-dev-worker-termination"
  message_retention_seconds = 86400
  sqs_managed_sse_enabled   = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.worker_termination_dlq.arn
    maxReceiveCount     = 5
  })
}