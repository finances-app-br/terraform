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

# ------------------------------------------------ static site deploy role ---
#
# The site repository's GitHub Actions workflow assumes this role through OIDC
# — no long-lived keys — to sync the build into the bucket. It can touch that
# bucket and nothing else.

resource "aws_iam_openid_connect_provider" "github" {
  count = local.site_enabled && var.create_github_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

# An account holds a single GitHub OIDC provider; reuse the existing one.
data "aws_iam_openid_connect_provider" "github" {
  count = local.site_enabled && !var.create_github_oidc_provider ? 1 : 0

  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "site_deploy_assume" {
  count = local.site_enabled ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type = "Federated"
      identifiers = concat(
        aws_iam_openid_connect_provider.github[*].arn,
        data.aws_iam_openid_connect_provider.github[*].arn,
      )
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Pinned to one repository and branch. Without it any GitHub workflow could
    # assume the role; with a stale value the real one fails with AccessDenied.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.site_github_repository}:ref:refs/heads/${var.site_github_deploy_branch}"]
    }
  }
}

resource "aws_iam_role" "site_deploy" {
  count = local.site_enabled ? 1 : 0

  name               = "${var.project_name}-site-deploy"
  description        = "Assumed by GitHub Actions (${var.site_github_repository}@${var.site_github_deploy_branch}) to deploy the static site."
  assume_role_policy = data.aws_iam_policy_document.site_deploy_assume[0].json
}

data "aws_iam_policy_document" "site_deploy" {
  count = local.site_enabled ? 1 : 0

  statement {
    sid       = "ListBucket"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.site[0].arn]
  }

  statement {
    sid       = "SyncObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.site[0].arn}/*"]
  }
}

resource "aws_iam_role_policy" "site_deploy" {
  count = local.site_enabled ? 1 : 0

  name   = "${var.project_name}-site-deploy-policy"
  role   = aws_iam_role.site_deploy[0].id
  policy = data.aws_iam_policy_document.site_deploy[0].json
}
