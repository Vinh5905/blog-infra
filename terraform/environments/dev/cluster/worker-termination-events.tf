locals {
  worker_termination_hook_name = "blogapp-dev-worker-termination"
}

resource "aws_cloudwatch_event_rule" "worker_termination" {
  name        = "blogapp-dev-worker-termination"
  description = "Match dev workers entering the termination lifecycle hook"
  state       = "ENABLED"

  event_pattern = jsonencode({
    source        = ["aws.autoscaling"]
    "detail-type" = ["EC2 Instance-terminate Lifecycle Action"]
    account       = [var.aws_account_id]
    region        = [var.aws_region]

    detail = {
      AutoScalingGroupName = [module.workers.autoscaling_group_name]
      LifecycleHookName    = [local.worker_termination_hook_name]
      LifecycleTransition  = ["autoscaling:EC2_INSTANCE_TERMINATING"]
      Destination          = ["EC2"]
    }
  })
}

data "aws_iam_policy_document" "worker_termination_queue" {
  statement {
    sid       = "AllowWorkerTerminationRuleToSend"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.worker_termination.arn]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.worker_termination.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "worker_termination" {
  queue_url = aws_sqs_queue.worker_termination.url
  policy    = data.aws_iam_policy_document.worker_termination_queue.json
}

resource "aws_cloudwatch_event_target" "worker_termination" {
  rule      = aws_cloudwatch_event_rule.worker_termination.name
  target_id = "SendWorkerTerminationToQueue"
  arn       = aws_sqs_queue.worker_termination.arn

  depends_on = [aws_sqs_queue_policy.worker_termination]
}