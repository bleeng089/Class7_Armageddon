# iam.tf - IAM role and policies for EC2 instance
#
# Least-privilege policy grants:
# - secretsmanager:GetSecretValue on the specific secret ARN only
# - ssm:GetParameter on specific parameter paths
# - logs:CreateLogStream, PutLogEvents for CloudWatch Logs 
# - cloudwatch:PutMetricData for custom metrics (if using custom metric approach)
# - No KMS permissions needed (using AWS-managed keys)

# IAM policy document for EC2 assume role
data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    sid     = "EC2AssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# IAM role for EC2 instances
resource "aws_iam_role" "ec2" {
  name               = "${local.name_prefix}-ec2-role"
  description        = "IAM role for EC2 instances to access Secrets Manager, SSM, and CloudWatch"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-ec2-role"
  })
}

# IAM policy document for Secrets Manager access - least privilege
data "aws_iam_policy_document" "secrets_access" {
  statement {
    sid    = "GetDBSecret"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue"
    ]
    # Scoped to the specific secret ARN only
    resources = [aws_secretsmanager_secret.db_credentials.arn]
  }
}

# IAM policy for Secrets Manager access
resource "aws_iam_policy" "secrets_access" {
  name        = "${local.name_prefix}-secrets-access"
  description = "Allow EC2 to read database credentials from Secrets Manager"
  policy      = data.aws_iam_policy_document.secrets_access.json

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-secrets-access"
  })
}

# Lab 1b - IAM policy document for SSM Parameter Store access
data "aws_iam_policy_document" "ssm_params_access" {
  statement {
    sid    = "GetDBParameters"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters"
    ]
    # Scoped to the specific parameter paths only
    resources = [
      aws_ssm_parameter.db_endpoint.arn,
      aws_ssm_parameter.db_port.arn,
      aws_ssm_parameter.db_name.arn
    ]
  }
}

# Lab 1b - IAM policy for SSM Parameter Store access
resource "aws_iam_policy" "ssm_params_access" {
  name        = "${local.name_prefix}-ssm-params-access"
  description = "Allow EC2 to read database parameters from SSM Parameter Store"
  policy      = data.aws_iam_policy_document.ssm_params_access.json

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-ssm-params-access"
  })
}

# Lab 1b - IAM policy document for CloudWatch Logs access
data "aws_iam_policy_document" "cloudwatch_logs_access" {
  statement {
    sid    = "WriteLogsToGroup"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams"
    ]
    # Scoped to the specific log group and its streams 
    resources = [
      "${aws_cloudwatch_log_group.app_logs.arn}",
      "${aws_cloudwatch_log_group.app_logs.arn}:*"
    ]
  }
}

# Lab 1b - IAM policy for CloudWatch Logs access
resource "aws_iam_policy" "cloudwatch_logs_access" {
  name        = "${local.name_prefix}-cloudwatch-logs-access"
  description = "Allow EC2 to write logs to CloudWatch Logs"
  policy      = data.aws_iam_policy_document.cloudwatch_logs_access.json

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-cloudwatch-logs-access"
  })
}

# Lab 1b - IAM policy document for CloudWatch Metrics (for custom metric approach)
data "aws_iam_policy_document" "cloudwatch_metrics_access" {
  statement {
    sid    = "PutCustomMetrics"
    effect = "Allow"
    actions = [
      "cloudwatch:PutMetricData"
    ]
    # Scoped to custom namespace only
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["Lab/RDSApp"]
    }
  }
}

# Lab 1b - IAM policy for CloudWatch Metrics
resource "aws_iam_policy" "cloudwatch_metrics_access" {
  name        = "${local.name_prefix}-cloudwatch-metrics-access"
  description = "Allow EC2 to publish custom metrics to CloudWatch"
  policy      = data.aws_iam_policy_document.cloudwatch_metrics_access.json

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-cloudwatch-metrics-access"
  })
}

# Attach secrets access policy to EC2 role
resource "aws_iam_role_policy_attachment" "secrets_access" {
  role       = aws_iam_role.ec2.name
  policy_arn = aws_iam_policy.secrets_access.arn
}

# Lab 1b - Attach SSM params access policy to EC2 role
resource "aws_iam_role_policy_attachment" "ssm_params_access" {
  role       = aws_iam_role.ec2.name
  policy_arn = aws_iam_policy.ssm_params_access.arn
}

# Lab 1b - Attach CloudWatch Logs access policy to EC2 role
resource "aws_iam_role_policy_attachment" "cloudwatch_logs_access" {
  role       = aws_iam_role.ec2.name
  policy_arn = aws_iam_policy.cloudwatch_logs_access.arn
}

# Lab 1b - Attach CloudWatch Metrics access policy to EC2 role
resource "aws_iam_role_policy_attachment" "cloudwatch_metrics_access" {
  role       = aws_iam_role.ec2.name
  policy_arn = aws_iam_policy.cloudwatch_metrics_access.arn
}

# Instance profile to attach role to EC2
resource "aws_iam_instance_profile" "ec2" {
  name = "${local.name_prefix}-ec2-profile"
  role = aws_iam_role.ec2.name

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-ec2-profile"
  })
}