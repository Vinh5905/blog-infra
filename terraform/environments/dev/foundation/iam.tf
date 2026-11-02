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