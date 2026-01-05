# variables.tf - Input variable definitions

variable "project_name" {
  description = "Project name used for resource naming and tagging"
  type        = string
  default     = "ec2-rds-notes-lab"

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.project_name))
    error_message = "Project name must contain only lowercase letters, numbers, and hyphens."
  }
}

variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "ssh_allowed_cidr" {
  description = "CIDR block allowed for SSH access. Empty string disables SSH access."
  type        = string
  default     = ""

  validation {
    condition     = var.ssh_allowed_cidr == "" || can(cidrhost(var.ssh_allowed_cidr, 0))
    error_message = "Must be a valid CIDR block or empty string to disable SSH."
  }
}

variable "allowed_http_cidrs" {
  description = "List of CIDR blocks allowed for HTTP access"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "instance_type" {
  description = "EC2 instance type (free-tier: t2.micro, t3.micro)"
  type        = string
  default     = "t3.micro"
}

variable "key_name" {
  description = "EC2 key pair name for SSH access. Null disables key pair attachment."
  type        = string
  default     = null
}

variable "db_instance_class" {
  description = "RDS instance class (free-tier: db.t3.micro, db.t4g.micro)"
  type        = string
  default     = "db.t3.micro"
}

variable "db_name" {
  description = "Name of the MySQL database to create"
  type        = string
  default     = "notesdb"

  validation {
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9_]*$", var.db_name))
    error_message = "Database name must start with a letter and contain only alphanumeric characters and underscores."
  }
}

variable "db_username" {
  description = "Master username for RDS MySQL"
  type        = string
  default     = "dbadmin"
  sensitive   = true
}

variable "db_port" {
  description = "MySQL port"
  type        = number
  default     = 3306
}

variable "db_allocated_storage" {
  description = "Allocated storage in GB for RDS (free-tier: 20)"
  type        = number
  default     = 20
}

variable "db_engine_version" {
  description = "MySQL engine version"
  type        = string
  default     = "8.0"
}

variable "secret_name" {
  description = "Name for the Secrets Manager secret"
  type        = string
  default     = "lab/rds/mysql"
}
