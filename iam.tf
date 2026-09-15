data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  for_each = local.services

  name               = "${var.project_name}-${each.key}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

# One policy per service. The Aurora statements are attached only to services
# flagged aurora_access, which is what keeps the apex and public-API functions
# from being able to read finance data at all.
data "aws_iam_policy_document" "lambda" {
  for_each = local.services

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.lambda[each.key].arn}:*"]
  }

  # X-Ray's write APIs are not resource-scopable — "*" is the only valid value.
  dynamic "statement" {
    for_each = var.enable_xray_tracing ? [1] : []
    content {
      sid       = "XRay"
      actions   = ["xray:PutTraceSegments", "xray:PutTelemetryRecords"]
      resources = ["*"]
    }
  }

  # Aurora Serverless v2 through the Data API: the statements themselves, plus
  # the master secret the Data API authenticates the connection with.
  dynamic "statement" {
    for_each = each.value.aurora_access ? [1] : []
    content {
      sid = "AuroraDataApi"
      actions = [
        "rds-data:ExecuteStatement",
        "rds-data:BatchExecuteStatement",
        "rds-data:BeginTransaction",
        "rds-data:CommitTransaction",
        "rds-data:RollbackTransaction",
      ]
      resources = [aws_rds_cluster.aurora.arn]
    }
  }

  dynamic "statement" {
    for_each = each.value.aurora_access ? [1] : []
    content {
      sid       = "AuroraSecret"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = [aws_rds_cluster.aurora.master_user_secret[0].secret_arn]
    }
  }
}

resource "aws_iam_role_policy" "lambda" {
  for_each = local.services

  name   = "${var.project_name}-${each.key}-lambda-policy"
  role   = aws_iam_role.lambda[each.key].id
  policy = data.aws_iam_policy_document.lambda[each.key].json
}