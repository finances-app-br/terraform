# Monthly cost guard for the whole AWS account. Aurora Serverless v2 only bills
# compute while awake, but a client that polls more often than
# `aurora_seconds_until_auto_pause` keeps it at >= 0.5 ACU all month (~US$ 44),
# so this alert is the safety net. Budgets are global, whatever the provider region.

resource "aws_budgets_budget" "monthly" {
  count = var.enable_cost_budget ? 1 : 0

  name         = "${var.project_name}-monthly"
  budget_type  = "COST"
  time_unit    = "MONTHLY"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"

  # Heads-up before the limit is reached.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.budget_alert_emails
  }

  # The limit was actually crossed.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.budget_alert_emails
  }

  # AWS projects the month will end above the limit — usually fires days earlier.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = var.budget_alert_emails
  }

  tags = var.tags
}
