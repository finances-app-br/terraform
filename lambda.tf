# Build the BFF bundle before packaging. Re-runs when the app sources change.
resource "null_resource" "build" {
  triggers = {
    sources = sha1(join("", [
      for f in fileset("${local.bff_path}/src", "**/*.ts") :
      filesha1("${local.bff_path}/src/${f}")
    ]))
    package = filesha1("${local.bff_path}/package.json")
  }

  provisioner "local-exec" {
    working_dir = local.bff_path
    command     = "npm ci && npm run build"
  }
}

# esbuild emits a single bundled file, so packaging is just zipping index.js.
data "archive_file" "bff" {
  type        = "zip"
  source_file = "${local.bff_path}/dist/index.js"
  output_path = "${path.module}/build/bff.zip"

  depends_on = [null_resource.build]
}

# Stub handler for the surfaces that have a domain but no application yet. It
# answers 200 so the DNS + TLS + API Gateway chain can be verified end to end;
# replace this archive with a real build when the portal exists.
data "archive_file" "placeholder" {
  for_each = local.placeholder_services

  type        = "zip"
  output_path = "${path.module}/build/${each.key}.zip"

  source {
    filename = "index.mjs"
    content  = <<-JS
      export const handler = async () => ({
        statusCode: 200,
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ service: "${each.key}", status: "placeholder" }),
      });
    JS
  }
}

resource "aws_cloudwatch_log_group" "lambda" {
  for_each = local.services

  name              = "/aws/lambda/${var.project_name}-${each.key}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "service" {
  for_each = local.services

  function_name = "${var.project_name}-${each.key}"
  description   = each.value.description
  role          = aws_iam_role.lambda[each.key].arn
  runtime       = var.lambda_runtime
  handler       = "index.handler"
  architectures = ["arm64"]

  filename         = local.lambda_package[each.key].path
  source_code_hash = local.lambda_package[each.key].hash

  memory_size                    = var.lambda_memory_size
  timeout                        = var.lambda_timeout
  reserved_concurrent_executions = var.lambda_reserved_concurrency

  dynamic "tracing_config" {
    for_each = var.enable_xray_tracing ? [1] : []
    content {
      mode = "Active"
    }
  }

  # Only the BFF is told where the cluster is; the placeholders have neither the
  # environment nor the IAM permissions to reach it.
  dynamic "environment" {
    for_each = each.value.aurora_access ? [1] : []
    content {
      variables = {
        AURORA_CLUSTER_ARN   = aws_rds_cluster.aurora.arn
        AURORA_SECRET_ARN    = aws_rds_cluster.aurora.master_user_secret[0].secret_arn
        AURORA_DATABASE_NAME = aws_rds_cluster.aurora.database_name
      }
    }
  }

  depends_on = [
    aws_iam_role_policy.lambda,
    aws_cloudwatch_log_group.lambda,
  ]
}
