resource "aws_kms_key" "database" {
  description             = "Encrypt BlogApp dev RDS storage"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  tags = {
    Name = "blogapp-dev-rds"
  }
}

resource "aws_kms_alias" "database" {
  name          = "alias/blogapp-dev-rds"
  target_key_id = aws_kms_key.database.key_id
}

module "database" {
  source  = "terraform-aws-modules/rds/aws"
  version = "7.2.2"

  identifier     = "blogapp-dev"
  engine         = "mysql"
  engine_version = var.mysql_engine_version
  family         = "mysql8.4"
  instance_class = var.db_instance_class
  port           = 3306

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.database.arn

  multi_az            = false
  publicly_accessible = false

  create_db_subnet_group = false
  db_subnet_group_name   = module.vpc.database_subnet_group_name
  vpc_security_group_ids = [aws_security_group.database.id]

  create_db_option_group    = false
  create_db_parameter_group = true

  parameters = [
    {
      name         = "require_secure_transport"
      value        = "ON"
      apply_method = "immediate"
    }
  ]

  username                    = "blogapp_bootstrap"
  manage_master_user_password = true

  backup_retention_period = 1

  deletion_protection              = true
  skip_final_snapshot              = false
  final_snapshot_identifier_prefix = "final"
  copy_tags_to_snapshot            = true
}