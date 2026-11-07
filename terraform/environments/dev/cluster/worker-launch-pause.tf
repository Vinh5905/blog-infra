resource "aws_iam_role" "worker_launch_pause" {
  name               = "blogapp-dev-worker-launch-pause"
  description        = "Execution role for pausing launches in the dev worker ASG"
  assume_role_policy = data.aws_iam_policy_document.worker_launch_automation_assume_role.json
}

data "aws_iam_policy_document" "worker_launch_pause" {
  statement {
    effect    = "Allow"
    actions   = ["autoscaling:SuspendProcesses"]
    resources = [module.workers.autoscaling_group_arn]
  }
}

resource "aws_iam_role_policy" "worker_launch_pause" {
  name   = "blogapp-dev-worker-launch-pause"
  role   = aws_iam_role.worker_launch_pause.name
  policy = data.aws_iam_policy_document.worker_launch_pause.json
}

resource "aws_ssm_document" "worker_launch_pause" {
  name            = "BlogAppDevPauseWorkerLaunch"
  document_type   = "Automation"
  document_format = "YAML"

  content = templatefile("${path.module}/ssm/pause-worker-launch.yml.tftpl", {
    automation_role_arn = aws_iam_role.worker_launch_pause.arn
    worker_asg_name     = module.workers.autoscaling_group_name
  })

  depends_on = [aws_iam_role_policy.worker_launch_pause]
}

# ------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "worker_launch_pause" {
  name        = "blogapp-dev-worker-launch-pause"
  description = "Pause dev worker launches when the repeated failures alarm enters ALARM"
  state       = "ENABLED"

  event_pattern = jsonencode({
    source        = ["aws.cloudwatch"]
    "detail-type" = ["CloudWatch Alarm State Change"]
    account       = [var.aws_account_id]
    region        = [var.aws_region]
    resources     = [aws_cloudwatch_metric_alarm.worker_launch_repeated_failures.arn]

    detail = {
      state = {
        value = ["ALARM"]
      }
    }
  })
}

# ------------------------------------------------------------
data "aws_iam_policy_document" "worker_launch_pause_eventbridge_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.worker_launch_pause.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.aws_account_id]
    }
  }
}

resource "aws_iam_role" "worker_launch_pause_eventbridge" {
  name               = "blogapp-dev-worker-launch-pause-eventbridge"
  assume_role_policy = data.aws_iam_policy_document.worker_launch_pause_eventbridge_assume_role.json
}

data "aws_iam_policy_document" "worker_launch_pause_eventbridge_invoke" {
  statement {
    effect  = "Allow"
    actions = ["ssm:StartAutomationExecution"]

    resources = [
      "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:document/${aws_ssm_document.worker_launch_pause.name}",
      "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:automation-execution/*",
    ]
  }

  statement {
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.worker_launch_pause.arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ssm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "worker_launch_pause_eventbridge_invoke" {
  name   = "blogapp-dev-worker-launch-pause-invoke"
  role   = aws_iam_role.worker_launch_pause_eventbridge.name
  policy = data.aws_iam_policy_document.worker_launch_pause_eventbridge_invoke.json
}

resource "aws_cloudwatch_event_target" "worker_launch_pause" {
  rule      = aws_cloudwatch_event_rule.worker_launch_pause.name
  target_id = "PauseWorkerLaunchAutomation"
  arn       = aws_ssm_document.worker_launch_pause.arn
  role_arn  = aws_iam_role.worker_launch_pause_eventbridge.arn
  input = jsonencode({
    Trigger = ["CloudWatchAlarm"]
  })

  retry_policy {
    maximum_event_age_in_seconds = 300
    maximum_retry_attempts       = 2
  }

  depends_on = [aws_iam_role_policy.worker_launch_pause_eventbridge_invoke]
}