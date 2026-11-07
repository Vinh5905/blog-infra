locals {
  worker_termination_oidc_host = trimprefix(local.foundation.oidc_issuer_url, "https://")
}

data "aws_iam_openid_connect_provider" "worker_termination" {
  url = local.foundation.oidc_issuer_url
}

data "aws_iam_policy_document" "worker_termination_assume_role" {
  statement {
    sid     = "AllowNodeTerminationHandlerServiceAccount"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.worker_termination.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.worker_termination_oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.worker_termination_oidc_host}:sub"
      values   = ["system:serviceaccount:kube-system:aws-node-termination-handler"]
    }
  }
}

resource "aws_iam_role" "worker_termination_handler" {
  name               = "blogapp-dev-node-termination-handler"
  description        = "IAM role for the dev Kubernetes AWS Node Termination Handler"
  assume_role_policy = data.aws_iam_policy_document.worker_termination_assume_role.json
}

data "aws_iam_policy_document" "worker_termination_handler_permissions" {
  statement {
    sid       = "ReadAndDeleteTerminationMessages"
    effect    = "Allow"
    actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage"]
    resources = [aws_sqs_queue.worker_termination.arn]
  }

  statement {
    sid    = "ReadInstanceAndLifecycleHook"
    effect = "Allow"
    actions = [
      "ec2:DescribeInstances",
      "autoscaling:DescribeLifecycleHooks",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }

  statement {
    sid    = "ManageDevWorkerLifecycleAction"
    effect = "Allow"
    actions = [
      "autoscaling:RecordLifecycleActionHeartbeat",
      "autoscaling:CompleteLifecycleAction",
    ]
    resources = [module.workers.autoscaling_group_arn]
  }
}

resource "aws_iam_role_policy" "worker_termination_handler" {
  name   = "blogapp-dev-node-termination-handler"
  role   = aws_iam_role.worker_termination_handler.name
  policy = data.aws_iam_policy_document.worker_termination_handler_permissions.json
}