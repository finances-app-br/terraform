resource "aws_apigatewayv2_api" "service" {
  for_each = local.services

  name          = "${var.project_name}-${each.key}"
  protocol_type = "HTTP"
  description   = each.value.description

  # An empty origin list omits the CORS configuration entirely — the right
  # answer for a surface nothing calls cross-origin. These APIs accept
  # credential-bearing headers, so "*" is never valid here (see variables.tf).
  dynamic "cors_configuration" {
    for_each = length(each.value.cors_origins) > 0 ? [1] : []
    content {
      allow_origins = each.value.cors_origins
      allow_methods = ["GET", "POST", "OPTIONS"]
      allow_headers = ["content-type", "authorization", "x-user-id"]
      max_age       = 3600
    }
  }
}

resource "aws_apigatewayv2_integration" "lambda" {
  for_each = local.services

  api_id                 = aws_apigatewayv2_api.service[each.key].id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.service[each.key].invoke_arn
  payload_format_version = "2.0"
}

# Optional JWT authorizer (Cognito / Auth0 / any OIDC issuer). Only the BFF
# carries user data, so only its API gets one.
resource "aws_apigatewayv2_authorizer" "jwt" {
  for_each = { for k, s in local.services : k => s if s.jwt_protected && local.jwt_enabled == 1 }

  api_id           = aws_apigatewayv2_api.service[each.key].id
  name             = "${var.project_name}-${each.key}-jwt"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    issuer   = var.jwt_authorizer.issuer
    audience = var.jwt_authorizer.audiences
  }
}

resource "aws_apigatewayv2_route" "service" {
  for_each = local.services

  api_id    = aws_apigatewayv2_api.service[each.key].id
  route_key = each.value.route_key
  target    = "integrations/${aws_apigatewayv2_integration.lambda[each.key].id}"

  authorization_type = contains(keys(aws_apigatewayv2_authorizer.jwt), each.key) ? "JWT" : "NONE"
  authorizer_id      = try(aws_apigatewayv2_authorizer.jwt[each.key].id, null)
}

resource "aws_apigatewayv2_stage" "default" {
  for_each = local.services

  api_id      = aws_apigatewayv2_api.service[each.key].id
  name        = "$default"
  auto_deploy = true

  # Cheap standing guard against a runaway client or a scraper: API Gateway
  # sheds load here rather than letting it reach Lambda (and, for the BFF,
  # Aurora).
  default_route_settings {
    throttling_rate_limit  = var.throttling_rate_limit
    throttling_burst_limit = var.throttling_burst_limit
  }
}

resource "aws_lambda_permission" "apigw" {
  for_each = local.services

  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.service[each.key].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.service[each.key].execution_arn}/*/*"
}

# --------------------------------------------------------- custom domain ---

resource "aws_apigatewayv2_domain_name" "service" {
  for_each = local.domain_services

  domain_name = each.value.domain_name

  domain_name_configuration {
    certificate_arn = aws_acm_certificate_validation.service[each.key].certificate_arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }
}

resource "aws_apigatewayv2_api_mapping" "service" {
  for_each = local.domain_services

  api_id      = aws_apigatewayv2_api.service[each.key].id
  domain_name = aws_apigatewayv2_domain_name.service[each.key].id
  stage       = aws_apigatewayv2_stage.default[each.key].id
}
