locals {
  foundation = data.terraform_remote_state.foundation.outputs
}

module "automation" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "6.4.1"

  name          = "blogapp-dev-automation"
  ami           = var.automation_ami_id
  instance_type = "t3.micro"

  subnet_id                   = local.foundation.private_subnet_ids[0]
  associate_public_ip_address = false

  create_security_group  = false
  vpc_security_group_ids = [local.foundation.security_group_ids.automation]

  create_iam_instance_profile = false
  iam_instance_profile        = local.foundation.instance_profile_names.automation

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
    Role = "automation"
  }
}