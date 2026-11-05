locals {
  oidc_domain_name = "oidc.${var.app_domain_name}"
  oidc_issuer_url  = "https://${local.oidc_domain_name}"

  oidc_bucket_name = "blogapp-dev-oidc-${var.aws_account_id}-${var.aws_region}"
}

resource "aws_acm_certificate" "oidc" {
  provider = aws.us_east_1

  domain_name       = local.oidc_domain_name
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "blogapp-dev-oidc"
  }
}

resource "aws_acm_certificate_validation" "oidc" {
  provider = aws.us_east_1

  certificate_arn = aws_acm_certificate.oidc.arn

  validation_record_fqdns = [
    for option in aws_acm_certificate.oidc.domain_validation_options :
    option.resource_record_name
  ]
}