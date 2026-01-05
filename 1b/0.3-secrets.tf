# secrets.tf - AWS Secrets Manager and SSM Parameter Store configuration
#
# Lab 1b uses dual secret storage:
# - Secrets Manager: username, password (and full connection info for backward compatibility)
# - SSM Parameter Store: endpoint, port, dbname (for operational visibility)
#
# Secret JSON structure in Secrets Manager:
# {
#   "username": "...",
#   "password": "...",
#   "host": "<rds-endpoint>",
#   "port": 3306,
#   "dbname": "..."
# }

# Generate a random password for the database
resource "random_password" "db_password" {
  length           = 24
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

# -----------------------------------------------------------------------------
# AWS Secrets Manager - Source of truth for credentials
# -----------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "db_credentials" {
  name                    = var.secret_name
  description             = "Database credentials for ${local.name_prefix} RDS MySQL"
  recovery_window_in_days = 0 # Lab setting: immediate deletion on destroy

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-db-secret"
  })
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id

  # Using jsonencode() for proper JSON formatting
  secret_string = jsonencode(local.db_secret)
}

# -----------------------------------------------------------------------------
# Lab 1b - SSM Parameter Store for operational metadata
# -----------------------------------------------------------------------------

# DB endpoint parameter
resource "aws_ssm_parameter" "db_endpoint" {
  name        = local.ssm_param_db_endpoint
  description = "RDS MySQL endpoint hostname (without port)"
  type        = "String"
  value       = aws_db_instance.mysql.address

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-db-endpoint-param"
  })
}

# DB port parameter
resource "aws_ssm_parameter" "db_port" {
  name        = local.ssm_param_db_port
  description = "RDS MySQL port number"
  type        = "String"
  value       = tostring(var.db_port)

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-db-port-param"
  })
}

# DB name parameter
resource "aws_ssm_parameter" "db_name" {
  name        = local.ssm_param_db_name
  description = "RDS MySQL database name"
  type        = "String"
  value       = var.db_name

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-db-name-param"
  })
}