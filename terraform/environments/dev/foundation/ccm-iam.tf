data "aws_iam_policy_document" "ccm_assume_role" {
  statement {
    sid     = "AllowCCMServiceAccount"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type = "Federated"

      identifiers = [
        aws_iam_openid_connect_provider.cluster.arn,
      ]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_domain_name}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_domain_name}:sub"

      values = [
        "system:serviceaccount:kube-system:aws-cloud-controller-manager",
      ]
    }
  }
}

resource "aws_iam_role" "ccm" {
  name        = "blogapp-dev-ccm"
  description = "IAM role for the dev Kubernetes AWS cloud controller manager"

  assume_role_policy = data.aws_iam_policy_document.ccm_assume_role.json

  tags = {
    Name = "blogapp-dev-ccm"
  }
}

data "aws_iam_policy_document" "ccm_node_read" {
  statement {
    sid    = "ReadEC2NodeMetadata"
    effect = "Allow"

    actions = [
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceTopology",
    ]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }
}

resource "aws_iam_role_policy" "ccm_node_read" {
  name   = "blogapp-dev-ccm-node-read"
  role   = aws_iam_role.ccm.name
  policy = data.aws_iam_policy_document.ccm_node_read.json
}