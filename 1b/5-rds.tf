# rds.tf - RDS MySQL instance configuration
#
# Key security properties:
# - Not publicly accessible (publicly_accessible = false)
# - Deployed in private subnets
# - Security group allows access only from EC2 SG
# - Lab-friendly settings: no deletion protection, skip final snapshot

resource "aws_db_instance" "mysql" {
  identifier = "${local.name_prefix}-mysql"

  # Engine configuration
  engine            = "mysql"
  engine_version    = var.db_engine_version
  instance_class    = var.db_instance_class
  allocated_storage = var.db_allocated_storage
  storage_type      = "gp2"
  storage_encrypted = true

  # Database configuration
  db_name  = var.db_name
  username = var.db_username
  password = random_password.db_password.result
  port     = var.db_port

  # Network configuration - PRIVATE subnets, NOT publicly accessible
  db_subnet_group_name   = aws_db_subnet_group.mysql.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false # Critical: RDS not exposed to internet
  multi_az               = false # Single AZ for lab cost savings

  # Parameter group
  parameter_group_name = "default.mysql8.0"

  # Backup and maintenance - minimal for lab
  backup_retention_period = 0
  skip_final_snapshot     = true  # Lab setting: allows quick teardown
  deletion_protection     = false # Lab setting: allows terraform destroy

  # Performance Insights disabled for free tier
  performance_insights_enabled = false

  # Auto minor version upgrade
  auto_minor_version_upgrade = true

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-mysql"
  })
}