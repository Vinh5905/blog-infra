resource "aws_cloudwatch_event_rule" "worker_launch_failure" {
  name        = "blogapp-dev-worker-launch-failure"
  description = "Match failed or timed-out dev worker launch executions"
  state       = "ENABLED"

  event_pattern = jsonencode({
    source        = ["aws.ssm"]
    "detail-type" = ["EC2 Automation Execution Status-change Notification"]
    account       = [var.aws_account_id]
    region        = [var.aws_region]

    detail = {
      Definition = [aws_ssm_document.worker_launch.name]
      Status     = ["Failed", "TimedOut"]
    }
  })
}

resource "aws_sns_topic" "worker_launch_alerts" {
  name = "blogapp-dev-worker-launch-alerts"
}

data "aws_iam_policy_document" "worker_launch_alerts_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.worker_launch_failure.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.aws_account_id]
    }
  }
}

resource "aws_iam_role" "worker_launch_alerts" {
  name               = "blogapp-dev-worker-launch-alerts-publisher"
  assume_role_policy = data.aws_iam_policy_document.worker_launch_alerts_assume_role.json
}

data "aws_iam_policy_document" "worker_launch_alerts_publish" {
  statement {
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.worker_launch_alerts.arn]
  }
}

resource "aws_iam_role_policy" "worker_launch_alerts_publish" {
  name   = "blogapp-dev-worker-launch-alerts-publish"
  role   = aws_iam_role.worker_launch_alerts.name
  policy = data.aws_iam_policy_document.worker_launch_alerts_publish.json
}

resource "aws_cloudwatch_event_target" "worker_launch_alerts" {
  rule      = aws_cloudwatch_event_rule.worker_launch_failure.name
  target_id = "PublishWorkerLaunchAlert"
  arn       = aws_sns_topic.worker_launch_alerts.arn
  role_arn  = aws_iam_role.worker_launch_alerts.arn

  input_transformer {
    input_paths = {
      runbook     = "$.detail.Definition"
      status      = "$.detail.Status"
      executionId = "$.detail.ExecutionId"
    }

    input_template = <<-JSON
      {
        "Runbook": <runbook>,
        "Status": <status>,
        "ExecutionId": <executionId>
      }
    JSON
  }

  depends_on = [aws_iam_role_policy.worker_launch_alerts_publish]
}