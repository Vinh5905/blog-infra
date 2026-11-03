output "vpc_id" {
  value = module.vpc.vpc_id
}

output "vpc_cidr_block" {
  value = module.vpc.vpc_cidr_block
}

output "availability_zones" {
  value = var.availability_zones
}

output "public_subnet_ids" {
  value = module.vpc.public_subnets
}

output "private_subnet_ids" {
  value = module.vpc.private_subnets
}

output "database_subnet_ids" {
  value = module.vpc.database_subnets
}

output "database_subnet_group_name" {
  value = module.vpc.database_subnet_group_name
}

output "subnets_by_az" {
  value = {
    for index, az in var.availability_zones : az => {
      public_subnet_id   = module.vpc.public_subnets[index]
      private_subnet_id  = module.vpc.private_subnets[index]
      database_subnet_id = module.vpc.database_subnets[index]
    }
  }
}

output "internet_gateway_id" {
  value = module.vpc.igw_id
}

output "nat_gateway_ids" {
  value = module.vpc.natgw_ids
}

output "nat_public_ips" {
  value = module.vpc.nat_public_ips
}

output "route_table_ids" {
  value = {
    public   = module.vpc.public_route_table_ids
    private  = module.vpc.private_route_table_ids
    database = module.vpc.database_route_table_ids
  }
}

output "default_security_group_id" {
  value = module.vpc.default_security_group_id
}

output "security_group_ids" {
  description = "Security group IDs for BlogApp dev components"

  value = {
    alb           = aws_security_group.alb.id
    api_nlb       = aws_security_group.api_nlb.id
    control_plane = aws_security_group.control_plane.id
    worker        = aws_security_group.worker.id
    automation    = aws_security_group.automation.id
    database      = aws_security_group.database.id
  }
}

output "instance_profile_names" {
  description = "IAM instance profile names for BlogApp dev hosts"

  value = {
    automation    = aws_iam_instance_profile.automation.name
    control_plane = aws_iam_instance_profile.control_plane.name
    worker        = aws_iam_instance_profile.worker.name
  }
}

output "ssm_transfer_bucket_name" {
  description = "S3 bucket used by Ansible for SSM file transfers"
  value       = module.ssm_transfer_bucket.s3_bucket_id
}

output "ssm_transfer_kms_key_arn" {
  description = "KMS key ARN used to encrypt Ansible transfer files"
  value       = aws_kms_key.ssm_transfer.arn
}