module "control_plane" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "6.4.1"

  name          = "blogapp-dev-control-plane"
  ami           = var.control_plane_ami_id
  instance_type = "c7i-flex.large"

  subnet_id                   = local.foundation.private_subnet_ids[0]
  associate_public_ip_address = false

  create_security_group  = false
  vpc_security_group_ids = [local.foundation.security_group_ids.control_plane]

  create_iam_instance_profile = false
  iam_instance_profile        = local.foundation.instance_profile_names.control_plane

  metadata_options = {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device = {
    type                  = "gp3"
    size                  = 20
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Role    = "control-plane"
    Cluster = "blogapp-dev"
  }
}

resource "aws_lb_target_group_attachment" "control_plane" {
  target_group_arn = local.foundation.api_nlb_target_group_arn
  target_id        = module.control_plane.id
  port             = 6443
}