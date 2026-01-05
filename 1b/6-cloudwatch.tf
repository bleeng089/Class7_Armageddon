# cloudwatch.tf - CloudWatch Logs, Metrics, and Alarms for Lab 1b
#
# Lab 1b monitoring stack:
# - CloudWatch Logs: Centralized application logging
# - Metric Filter: Extract DB connection errors from logs
# - Alarm: Trigger when errors >= threshold
# - SNS Topic: Incident notification channel

# -----------------------------------------------------------------------------
# CloudWatch Logs
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "app_logs" {
  name              = var.log_group_name
  retention_in_days = var.log_retention_days

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-app-logs"
  })
}

# -----------------------------------------------------------------------------
# CloudWatch Logs Metric Filter for DB Connection Errors
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_log_metric_filter" "db_connection_errors" {
  name           = "${local.name_prefix}-db-connection-errors"
  log_group_name = aws_cloudwatch_log_group.app_logs.name
  pattern        = "\"DB_CONNECTION_FAILURE\""

  metric_transformation {
    name      = "DBConnectionErrors"
    namespace = "Lab/RDSApp"
    value     = "1"
    unit      = "Count"
  }
}

# -----------------------------------------------------------------------------
# SNS Topic for Incident Notifications
# -----------------------------------------------------------------------------

resource "aws_sns_topic" "db_incidents" {
  name         = var.sns_topic_name
  display_name = "Lab DB Incidents"

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-db-incidents-topic"
  })
}

# Email subscription for SNS topic (requires email confirmation)
resource "aws_sns_topic_subscription" "email_alerts" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.db_incidents.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# -----------------------------------------------------------------------------
# CloudWatch Alarm for DB Connection Errors
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "db_connection_errors" {
  alarm_name          = "lab-db-connection-errors"
  alarm_description   = "Triggers when DB connection errors >= ${var.alarm_error_threshold} in ${var.alarm_evaluation_period} minutes"
  comparison_operator = "GreaterThanOrEqualToThreshold"

  # Metric configuration
  metric_name         = "DBConnectionErrors"
  namespace           = "Lab/RDSApp"
  statistic           = "Sum"
  threshold           = var.alarm_error_threshold
  evaluation_periods  = var.alarm_evaluation_period
  period              = 60 # 1 minute periods
  datapoints_to_alarm = 1

  # Treat missing data as not breaching (app may not be generating errors)
  treat_missing_data = "notBreaching"

  # Actions
  alarm_actions = [aws_sns_topic.db_incidents.arn]
  ok_actions    = [aws_sns_topic.db_incidents.arn]

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-db-connection-alarm"
  })
}
