locals {
  worker_launch_hook_name = "blogapp-dev-worker-launch"
}

resource "aws_cloudwatch_event_rule" "worker_launch" {
  name        = "blogapp-dev-worker-launch"
  description = "Match new BlogApp dev workers entering the launch lifecycle hook"
  state       = "ENABLED"

  event_pattern = jsonencode({
    source        = ["aws.autoscaling"]
    "detail-type" = ["EC2 Instance-launch Lifecycle Action"]
    account       = [var.aws_account_id]
    region        = [var.aws_region]

    detail = {
      AutoScalingGroupName = [module.workers.autoscaling_group_name]
      LifecycleHookName    = [local.worker_launch_hook_name]
      LifecycleTransition  = ["autoscaling:EC2_INSTANCE_LAUNCHING"]
    }
  })
}

data "aws_iam_policy_document" "worker_launch_eventbridge_assume_role" {
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
      values   = [aws_cloudwatch_event_rule.worker_launch.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.aws_account_id]
    }
  }
}

resource "aws_iam_role" "worker_launch_eventbridge" {
  name               = "blogapp-dev-worker-launch-eventbridge"
  assume_role_policy = data.aws_iam_policy_document.worker_launch_eventbridge_assume_role.json
}

data "aws_iam_policy_document" "worker_launch_eventbridge_invoke" {
  statement {
    sid     = "StartWorkerLaunchRunbook"
    effect  = "Allow"
    actions = ["ssm:StartAutomationExecution"]

    resources = [
      "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:document/${aws_ssm_document.worker_launch.name}",
      "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:automation-execution/*",
    ]
  }

  statement {
    sid       = "PassWorkerLaunchAutomationRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.worker_launch_automation.arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ssm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "worker_launch_eventbridge_invoke" {
  name   = "blogapp-dev-worker-launch-invoke"
  role   = aws_iam_role.worker_launch_eventbridge.name
  policy = data.aws_iam_policy_document.worker_launch_eventbridge_invoke.json
}

resource "aws_cloudwatch_event_target" "worker_launch" {
  rule      = aws_cloudwatch_event_rule.worker_launch.name
  target_id = "StartWorkerLaunchAutomation"
  arn       = aws_ssm_document.worker_launch.arn
  role_arn  = aws_iam_role.worker_launch_eventbridge.arn

  input_transformer {
    input_paths = {
      instanceId     = "$.detail.EC2InstanceId"
      lifecycleToken = "$.detail.LifecycleActionToken"
    }

    input_template = <<-JSON
      {
        "InstanceId": [<instanceId>],
        "LifecycleActionToken": [<lifecycleToken>]
      }
    JSON
  }

  depends_on = [aws_iam_role_policy.worker_launch_eventbridge_invoke]
}