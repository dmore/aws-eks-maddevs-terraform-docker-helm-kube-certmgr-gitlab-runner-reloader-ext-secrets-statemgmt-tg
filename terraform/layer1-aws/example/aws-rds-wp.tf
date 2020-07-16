# RDS Variables
variable "rds_instance_wp" {
  type        = string
  default     = "db.t3.small"
  description = "Instance class of the rds database"
}

output wp_db {
  description = "description"
  value = {
    "username"         = local.wp_db_username
    "database"         = local.wp_db_database
    "password"         = local.wp_db_password
    "address"          = module.db_wp.this_db_instance_address
    "s3_backup_bucket" = aws_s3_bucket.rds_backup_wp.id
  }
}

locals {
  # Passwords for services and secrets
  wp_db_password = random_string.mysql_password_wp.result
  wp_db_database = "d${random_string.mysql_database_wp.result}"
  wp_db_username = "u${random_string.mysql_user_wp.result}"
  wp_db_name     = "${local.name}-wp"
}

resource "random_string" "default_env" {
  length  = 4
  special = false
  upper   = false
}

resource "random_string" "mysql_password_wp" {
  length  = 20
  special = false
}

resource "random_string" "mysql_database_wp" {
  length  = 8
  special = false
}

resource "random_string" "mysql_user_wp" {
  length  = 8
  special = false
}

resource "aws_security_group_rule" "workers_to_rds" {
  description              = "Allow nodes to communicate with RDS."
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds.id
  source_security_group_id = module.eks.worker_security_group_id
  from_port                = 3306
  to_port                  = 3306
  type                     = "ingress"
}

module "db_wp" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 2.0"

  identifier = local.wp_db_name

  engine            = "mysql"
  engine_version    = "5.7.26"
  instance_class    = var.rds_instance_wp
  allocated_storage = 10
  storage_encrypted = true

  name                                = local.wp_db_database
  username                            = local.wp_db_username
  password                            = local.wp_db_password
  port                                = "3306"
  iam_database_authentication_enabled = true
  vpc_security_group_ids              = [aws_security_group.rds.id]
  subnet_ids                          = module.vpc.database_subnets
  auto_minor_version_upgrade          = false

  maintenance_window      = "Sun:00:00-Sun:03:00"
  backup_window           = "03:00-06:00"
  monitoring_interval     = "30"
  monitoring_role_name    = local.wp_db_name
  create_monitoring_role  = true
  multi_az                = false
  backup_retention_period = 0

  enabled_cloudwatch_logs_exports = ["audit", "general", "slowquery"]

  family                    = "mysql5.7"
  major_engine_version      = "5.7"
  final_snapshot_identifier = local.wp_db_name
  deletion_protection       = false

  parameters = [
    {
      name  = "character_set_client"
      value = "utf8"
    },
    {
      name  = "character_set_server"
      value = "utf8"
    }
  ]

  options = [
    {
      option_name = "MARIADB_AUDIT_PLUGIN"

      option_settings = [
        {
          name  = "SERVER_AUDIT_EVENTS"
          value = "CONNECT"
        },
        {
          name  = "SERVER_AUDIT_FILE_ROTATIONS"
          value = "37"
        },
      ]
    },
  ]

  tags = {
    Name        = local.wp_db_name
    Environment = "dev"
  }
}

resource "aws_s3_bucket" "rds_backup_wp" {
  bucket = "${local.name}-rds-backup-wp"
  acl    = "private"

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm = "aws:kms"
      }
    }
  }

  tags = {
    Name        = "${local.name}-rds-backup-wp"
    Environment = local.env
  }
}

resource "aws_s3_bucket_public_access_block" "rds_backup_wp" {
  bucket = aws_s3_bucket.rds_backup_wp.id

  # Block new public ACLs and uploading public objects
  block_public_acls = true
  # Retroactively remove public access granted through public ACLs
  ignore_public_acls = true
  # Block new public bucket policies
  block_public_policy = true
  # Retroactivley block public and cross-account access if bucket has public policies
  restrict_public_buckets = true
}