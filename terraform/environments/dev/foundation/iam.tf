data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    sid     = "AllowEC2AssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# -------------------------------------------------------------
resource "aws_iam_role" "automation" {
  name        = "blogapp-dev-automation"
  description = "IAM role for the private automation host"

  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = {
    Name = "blogapp-dev-automation"
  }
}

resource "aws_iam_role_policy_attachment" "automation_ssm" {
  role       = aws_iam_role.automation.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "automation" {
  name = "blogapp-dev-automation"
  role = aws_iam_role.automation.name

  tags = {
    Name = "blogapp-dev-automation"
  }
}

# -------------------------------------------------------------
resource "aws_iam_role" "control_plane" {
  name        = "blogapp-dev-control-plane"
  description = "IAM role for the Kubernetes control plane host"

  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = {
    Name = "blogapp-dev-control-plane"
  }
}

resource "aws_iam_role_policy_attachment" "control_plane_ssm" {
  role       = aws_iam_role.control_plane.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "control_plane" {
  name = "blogapp-dev-control-plane"
  role = aws_iam_role.control_plane.name

  tags = {
    Name = "blogapp-dev-control-plane"
  }
}

# -------------------------------------------------------------
resource "aws_iam_role" "worker" {
  name        = "blogapp-dev-worker"
  description = "IAM role for Kubernetes worker nodes"

  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = {
    Name = "blogapp-dev-worker"
  }
}

resource "aws_iam_role_policy_attachment" "worker_ssm" {
  role       = aws_iam_role.worker.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "worker" {
  name = "blogapp-dev-worker"
  role = aws_iam_role.worker.name

  tags = {
    Name = "blogapp-dev-worker"
  }
}

# -------------------------------------------------------------
data "aws_iam_policy_document" "automation_ssm_transfer" {
  statement {
    sid = "ReadTransferBucketMetadata"

    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket",
    ]

    resources = [module.ssm_transfer_bucket.s3_bucket_arn]
  }

  statement {
    sid = "ManageTransferObjects"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]

    resources = ["${module.ssm_transfer_bucket.s3_bucket_arn}/*"]
  }

  statement {
    sid = "UseTransferKeyThroughS3"

    actions = [
      "kms:GenerateDataKey",
      "kms:Decrypt",
    ]

    resources = [aws_kms_key.ssm_transfer.arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.aws_region}.amazonaws.com"]
    }
  }
}

# -------------------------------------------------------------
resource "aws_iam_role_policy" "automation_ssm_transfer" {
  name   = "blogapp-dev-ssm-transfer"
  role   = aws_iam_role.automation.name
  policy = data.aws_iam_policy_document.automation_ssm_transfer.json
}

data "aws_iam_policy_document" "automation_ssm_sessions" {
  statement {
    sid     = "StartSessionOnBlogAppDevNodes"
    effect  = "Allow"
    actions = ["ssm:StartSession"]

    resources = [
      "arn:aws:ec2:${var.aws_region}:${var.aws_account_id}:instance/*",
    ]

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Project"
      values   = ["blogapp"]
    }

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Environment"
      values   = ["dev"]
    }

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Role"
      values   = ["control-plane", "worker"]
    }
  }

  statement {
    sid     = "UseDefaultShellSessionDocument"
    effect  = "Allow"
    actions = ["ssm:StartSession"]

    resources = [
      "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:document/SSM-SessionManagerRunShell",
    ]
  }

  statement {
    sid     = "TerminateOwnSessions"
    effect  = "Allow"
    actions = ["ssm:TerminateSession"]

    resources = [
      "arn:aws:ssm:${var.aws_region}:${var.aws_account_id}:session/*",
    ]

    condition {
      test     = "StringLike"
      variable = "ssm:resourceTag/aws:ssmmessages:session-id"
      values   = ["&{aws:userid}*"]
    }
  }

  statement {
    sid     = "DiscoverEC2InstancesForInventory"
    effect  = "Allow"
    actions = ["ec2:DescribeInstances"]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }
}

resource "aws_iam_role_policy" "automation_ssm_sessions" {
  name   = "blogapp-dev-ssm-sessions"
  role   = aws_iam_role.automation.name
  policy = data.aws_iam_policy_document.automation_ssm_sessions.json
}