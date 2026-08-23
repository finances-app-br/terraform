# Build the BFF bundle before packaging. Re-runs when the app sources change.
resource "null_resource" "build" {
  triggers = {
    sources = sha1(join("", [
      for f in fileset("${path.module}/../app/src", "**/*.ts") :
      filesha1("${path.module}/../app/src/${f}")
    ]))
    package = filesha1("${path.module}/../app/package.json")
  }

  provisioner "local-exec" {
    working_dir = "${path.module}/../app"
    command     = "npm ci && npm run build"
  }
}

# esbuild emits a single bundled file, so packaging is just zipping index.js.
data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/../app/dist/index.js"
  output_path = "${path.module}/build/lambda.zip"

  depends_on = [null_resource.build]
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.project_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "bff" {
  function_name = var.project_name
  role          = aws_iam_role.lambda.arn
  runtime       = var.lambda_runtime
  handler       = "index.handler"
  architectures = ["arm64"]

  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  memory_size = var.lambda_memory_size
  timeout     = var.lambda_timeout

  environment {
    variables = {
      AURORA_CLUSTER_ARN   = aws_rds_cluster.aurora.arn
      AURORA_SECRET_ARN    = aws_rds_cluster.aurora.master_user_secret[0].secret_arn
      AURORA_DATABASE_NAME = aws_rds_cluster.aurora.database_name
    }
  }

  depends_on = [
    aws_iam_role_policy.lambda,
    aws_cloudwatch_log_group.lambda,
  ]
}
