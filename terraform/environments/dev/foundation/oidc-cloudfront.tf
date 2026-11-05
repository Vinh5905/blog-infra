resource "aws_cloudfront_origin_access_control" "oidc" {
  provider = aws.us_east_1

  name        = "blogapp-dev-oidc"
  description = "Signed CloudFront access to OIDC documents in S3"

  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_cache_policy" "oidc" {
  provider = aws.us_east_1

  name        = "blogapp-dev-oidc"
  comment     = "Short-lived cache for OIDC discovery and JWKS"
  min_ttl     = 0
  default_ttl = 300
  max_ttl     = 300

  parameters_in_cache_key_and_forwarded_to_origin {
    enable_accept_encoding_gzip   = true
    enable_accept_encoding_brotli = true

    cookies_config {
      cookie_behavior = "none"
    }

    headers_config {
      header_behavior = "none"
    }

    query_strings_config {
      query_string_behavior = "none"
    }
  }
}

module "oidc_cdn" {
  source  = "terraform-aws-modules/cloudfront/aws"
  version = "6.7.1"

  providers = {
    aws = aws.us_east_1
  }

  aliases = [local.oidc_domain_name]
  comment = "BlogApp dev OIDC discovery and JWKS"

  enabled             = true
  is_ipv6_enabled     = true
  wait_for_deployment = true

  origin_access_control = {}

  origin = {
    oidc_s3 = {
      domain_name = module.oidc_bucket.s3_bucket_bucket_regional_domain_name

      origin_access_control_id = aws_cloudfront_origin_access_control.oidc.id
    }
  }

  default_cache_behavior = {
    target_origin_id = "oidc_s3"

    allowed_methods = ["GET", "HEAD"]
    cached_methods  = ["GET", "HEAD"]

    viewer_protocol_policy = "https-only"
    compress               = true

    cache_policy_id  = aws_cloudfront_cache_policy.oidc.id
    forwarded_values = null

    response_headers_policy_name = "Managed-SecurityHeadersPolicy"
  }

  viewer_certificate = {
    acm_certificate_arn = aws_acm_certificate_validation.oidc.certificate_arn

    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2025"
  }

  tags = {
    Name = "blogapp-dev-oidc"
  }
}