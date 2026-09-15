# The site repository's GitHub Actions workflow assumes this role through OIDC
# — no long-lived keys — to sync the build into the bucket. It can touch that
# bucket and nothing else.

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 1 : 0

  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

# An account holds a single GitHub OIDC provider; reuse the existing one.
data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1

  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "deploy_assume" {
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
      values   = ["repo:${var.github_repository}:ref:refs/heads/${var.github_deploy_branch}"]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name               = "${var.project_name}-deploy"
  description        = "Assumed by GitHub Actions (${var.github_repository}@${var.github_deploy_branch}) to deploy the static site."
  assume_role_policy = data.aws_iam_policy_document.deploy_assume.json
}

data "aws_iam_policy_document" "deploy" {
  statement {
    sid       = "ListBucket"
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.site.arn]
  }

  statement {
    sid       = "SyncObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.site.arn}/*"]
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "${var.project_name}-deploy-policy"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}
