module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.3"

  name = "blogapp-dev"
  cidr = "10.10.0.0/16"

  azs = var.availability_zones

  public_subnets = [
    "10.10.0.0/24",
    "10.10.1.0/24",
  ]

  private_subnets = [
    "10.10.10.0/24",
    "10.10.11.0/24",
  ]

  database_subnets = [
    "10.10.20.0/24",
    "10.10.21.0/24",
  ]

  enable_dns_support   = true
  enable_dns_hostnames = true
  enable_ipv6          = false

  create_igw              = true
  map_public_ip_on_launch = false

  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false

  create_database_subnet_group           = true
  create_database_subnet_route_table     = true
  create_database_internet_gateway_route = false
  create_database_nat_gateway_route      = false

  manage_default_vpc         = false
  manage_default_route_table = false
  manage_default_network_acl = false

  manage_default_security_group  = true
  default_security_group_ingress = []
  default_security_group_egress  = []

  tags = {
    "kubernetes.io/cluster/blogapp-dev" = "owned"
  }

  depends_on = [data.aws_availability_zones.available]
}