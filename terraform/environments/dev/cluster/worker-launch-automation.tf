data "aws_iam_policy_document" "worker_launch_automation_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ssm.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [var.aws_account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:automation-execution/*"]
    }
  }
}

resource "aws_iam_role" "worker_launch_automation" {
  name               = "blogapp-dev-worker-launch-automation"
  description        = "Execution role for the BlogApp dev worker launch runbook"
  assume_role_policy = data.aws_iam_policy_document.worker_launch_automation_assume_role.json
}

data "aws_iam_policy_document" "worker_launch_automation_read" {
  statement {
    effect = "Allow"
    actions = [
      "autoscaling:DescribeAutoScalingInstances",
      "ec2:DescribeInstances",
      "ssm:DescribeInstanceInformation",
      "ssm:GetCommandInvocation",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }
}

resource "aws_iam_role_policy" "worker_launch_automation_read" {
  name   = "blogapp-dev-worker-launch-read"
  role   = aws_iam_role.worker_launch_automation.name
  policy = data.aws_iam_policy_document.worker_launch_automation_read.json
}

resource "aws_ssm_document" "worker_launch" {
  name            = "BlogAppDevWorkerLaunch"
  document_type   = "Automation"
  document_format = "YAML"

  content = templatefile("${path.module}/ssm/worker-launch.yml.tftpl", {
    automation_role_arn            = aws_iam_role.worker_launch_automation.arn
    worker_asg_name                = module.workers.autoscaling_group_name
    worker_launch_template_id      = module.workers.launch_template_id
    worker_launch_template_version = local.worker_launch_template_version
    worker_launch_hook_name        = local.worker_launch_hook_name
    worker_tag_filters = jsonencode([
      for key, value in local.worker_tags : {
        Name   = "tag:${key}"
        Values = [value]
      }
    ])
    worker_launch_lock_table_name = aws_dynamodb_table.worker_launch_locks.name
    automation_instance_id        = module.automation.id
    bootstrap_document_name       = aws_ssm_document.bootstrap_worker.name
    bootstrap_document_version    = aws_ssm_document.bootstrap_worker.default_version
  })
}

data "aws_iam_policy_document" "worker_launch_automation_lifecycle" {
  statement {
    effect = "Allow"
    actions = [
      "autoscaling:RecordLifecycleActionHeartbeat",
      "autoscaling:CompleteLifecycleAction",
    ]
    resources = [module.workers.autoscaling_group_arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["dynamodb:PutItem"]
    resources = [aws_dynamodb_table.worker_launch_locks.arn]
  }
}

resource "aws_iam_role_policy" "worker_launch_automation_lifecycle" {
  name   = "blogapp-dev-worker-launch-lifecycle"
  role   = aws_iam_role.worker_launch_automation.name
  policy = data.aws_iam_policy_document.worker_launch_automation_lifecycle.json
}

resource "aws_ssm_document" "bootstrap_worker" {
  name            = "BlogAppDevBootstrapWorker"
  document_type   = "Command"
  document_format = "YAML"

  content = templatefile("${path.module}/ssm/bootstrap-worker-command.yml.tftpl", {
    worker_bootstrap_commit = var.worker_bootstrap_commit
  })
}

data "aws_iam_policy_document" "worker_launch_automation_command" {
  statement {
    effect  = "Allow"
    actions = ["ssm:SendCommand"]
    resources = [
      aws_ssm_document.bootstrap_worker.arn,
      "arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:instance/${module.automation.id}",
    ]
  }
}

resource "aws_iam_role_policy" "worker_launch_automation_command" {
  name   = "blogapp-dev-worker-launch-command"
  role   = aws_iam_role.worker_launch_automation.name
  policy = data.aws_iam_policy_document.worker_launch_automation_command.json
}