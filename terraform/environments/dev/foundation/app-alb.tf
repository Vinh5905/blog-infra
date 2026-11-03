module "edge" {
  source  = "terraform-aws-modules/alb/aws"
  version = "10.5.1"

  name               = "blogapp-dev-edge"
  load_balancer_type = "application"
  internal           = false

  vpc_id  = module.vpc.vpc_id
  subnets = module.vpc.public_subnets

  create_security_group = false
  security_groups       = [aws_security_group.alb.id]

  target_groups = {
    traefik = {
      name              = "blogapp-dev-traefik"
      protocol          = "HTTP"
      port              = 30080
      target_type       = "instance"
      create_attachment = false

      health_check = {
        enabled  = true
        protocol = "HTTP"
        port     = "traffic-port"
        path     = "/ping"
        matcher  = "200"
      }
    }
  }

  listeners = {
    http = {
      port     = 80
      protocol = "HTTP"

      redirect = {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }

    https = {
      port            = 443
      protocol        = "HTTPS"
      certificate_arn = aws_acm_certificate_validation.app.certificate_arn
      ssl_policy      = "ELBSecurityPolicy-TLS13-1-2-2021-06"

      forward = {
        target_group_key = "traefik"
      }
    }
  }
}