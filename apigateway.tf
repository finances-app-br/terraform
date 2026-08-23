resource "aws_apigatewayv2_api" "this" {
  name          = "${var.project_name}-api"
  protocol_type = "HTTP"
  description   = "GraphQL sync BFF for the finance_app Flutter application."

  cors_configuration {
    allow_origins = var.cors_allow_origins
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["content-type", "authorization", "x-user-id"]
    max_age       = 3600
  }
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.this.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.bff.invoke_arn
  payload_format_version = "2.0"
}

# Optional JWT authorizer (Cognito / Auth0 / any OIDC issuer).
resource "aws_apigatewayv2_authorizer" "jwt" {
  count            = local.jwt_enabled
  api_id           = aws_apigatewayv2_api.this.id
  name             = "${var.project_name}-jwt"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    issuer   = var.jwt_authorizer.issuer
    audience = var.jwt_authorizer.audiences
  }
}

resource "aws_apigatewayv2_route" "graphql" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "POST /graphql"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"

  authorization_type = local.jwt_enabled == 1 ? "JWT" : "NONE"
  authorizer_id      = one(aws_apigatewayv2_authorizer.jwt[*].id)
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.bff.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.this.execution_arn}/*/*"
}

# --------------------------------------------------------- custom domain ---

resource "aws_apigatewayv2_domain_name" "this" {
  count       = local.custom_domain_enabled
  domain_name = var.domain_name

  domain_name_configuration {
    certificate_arn = aws_acm_certificate_validation.this[0].certificate_arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }
}

resource "aws_apigatewayv2_api_mapping" "this" {
  count       = local.custom_domain_enabled
  api_id      = aws_apigatewayv2_api.this.id
  domain_name = aws_apigatewayv2_domain_name.this[0].id
  stage       = aws_apigatewayv2_stage.default.id
}
