module "api_nlb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "10.5.1"

  name               = "blogapp-dev-api"
  load_balancer_type = "network"
  internal           = true

  vpc_id  = module.vpc.vpc_id
  subnets = module.vpc.private_subnets

  create_security_group = false
  security_groups       = [aws_security_group.api_nlb.id]

  enable_cross_zone_load_balancing = true

  target_groups = {
    kube_api = {
      name        = "blogapp-dev-kube-api"
      protocol    = "TCP"
      port        = 6443
      target_type = "instance"

      create_attachment  = false
      preserve_client_ip = false
      proxy_protocol_v2  = false

      health_check = {
        enabled  = true
        protocol = "TCP"
        port     = "traffic-port"
      }
    }
  }

  listeners = {
    kube_api_tcp = {
      port     = 6443
      protocol = "TCP"

      forward = {
        target_group_key = "kube_api"
      }
    }
  }
}