locals {
  worker_launch_template_version = "1"
  worker_tags = {
    Project                             = "blogapp"
    Environment                         = "dev"
    Role                                = "worker"
    Cluster                             = "blogapp-dev"
    "kubernetes.io/cluster/blogapp-dev" = "owned"
  }
}

module "workers" {
  source  = "terraform-aws-modules/autoscaling/aws"
  version = "9.3.2"

  name                = "blogapp-dev-workers"
  vpc_zone_identifier = local.foundation.private_subnet_ids

  min_size                        = 0
  max_size                        = 4
  desired_capacity                = 0
  ignore_desired_capacity_changes = true
  health_check_type               = "EC2"

  launch_template_version   = local.worker_launch_template_version
  image_id                  = var.worker_ami_id
  instance_type             = var.worker_instance_type
  security_groups           = [local.foundation.security_group_ids.worker]
  iam_instance_profile_name = local.foundation.instance_profile_names.worker

  metadata_options = {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  enable_monitoring = false

  block_device_mappings = [
    {
      device_name = data.aws_ami.worker.root_device_name

      ebs = {
        volume_type           = "gp3"
        volume_size           = 20
        encrypted             = true
        delete_on_termination = true
      }
    }
  ]

  traffic_source_attachments = {
    ingress = {
      traffic_source_identifier = local.foundation.app_alb_target_group_arn
      traffic_source_type       = "elbv2"
    }
  }

  initial_lifecycle_hooks = [
    {
      name                 = local.worker_launch_hook_name
      lifecycle_transition = "autoscaling:EC2_INSTANCE_LAUNCHING"
      heartbeat_timeout    = 900
      default_result       = "ABANDON"
    }
  ]

  autoscaling_group_tags = merge(local.worker_tags, {
    "aws-node-termination-handler/managed" = "true"
  })
}

data "aws_ami" "worker" {
  filter {
    name   = "image-id"
    values = [var.worker_ami_id]
  }
}