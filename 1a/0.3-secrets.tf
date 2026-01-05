# secrets.tf - AWS Secrets Manager configuration for database credentials
#
# Secret JSON structure follows RDS connection pattern:
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