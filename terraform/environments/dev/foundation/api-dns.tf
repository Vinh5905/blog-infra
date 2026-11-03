resource "aws_route53_zone" "kube_api" {
  name = "api.${var.app_domain_name}"

  vpc {
    vpc_id = module.vpc.vpc_id
  }
}

resource "aws_route53_record" "kube_api" {
  zone_id = aws_route53_zone.kube_api.zone_id
  name    = aws_route53_zone.kube_api.name
  type    = "A"

  alias {
    name                   = module.api_nlb.dns_name
    zone_id                = module.api_nlb.zone_id
    evaluate_target_health = false
  }
}