# Amazon Cognito user pool: the identity behind the BFF's JWT authorizer.
#
# The Flutter app signs users in against this pool directly (InitiateAuth with
# USER_PASSWORD_AUTH over HTTPS, no SDK) and sends the resulting access token
# as `Authorization: Bearer` to the BFF. API Gateway validates it before the
# Lambda runs, and the BFF reads the user id from the token's `sub` claim — so
# once this pool exists the dev-only `x-user-id` header can no longer reach
# production.
#
# Essentials tier: the first 10,000 MAUs a month are free, permanently.

resource "aws_cognito_user_pool" "main" {
  count = var.enable_cognito ? 1 : 0

  name           = "${var.project_name}-users"
  user_pool_tier = "ESSENTIALS"

  # The e-mail is the username; Cognito stores it lower-cased so "Ana@x.com"
  # and "ana@x.com" are the same account.
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  username_configuration {
    case_sensitive = false
  }

  # Losing the pool would orphan every user's data in Aurora (rows are keyed by
  # `sub`), so terraform destroy has to be preceded by turning this off.
  deletion_protection = "ACTIVE"

  mfa_configuration = "OFF"

  password_policy {
    minimum_length                   = 8
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = false
    temporary_password_validity_days = 7
    # Essentials feature: refuse the last N passwords on reset.
    password_history_size = 5
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  admin_create_user_config {
    allow_admin_create_user_only = false
  }

  # Cognito's own sender: free, but capped at a small daily volume. Move to SES
  # (email_sending_account = "DEVELOPER") before the sign-up rate outgrows it.
  email_configuration {
    email_sending_account = "COGNITO_DEFAULT"
  }

  verification_message_template {
    default_email_option = "CONFIRM_WITH_CODE"
    email_subject        = "Seu código de verificação do Finances"
    email_message        = "Seu código de verificação do Finances é {####}. Ele expira em 24 horas."
  }

  tags = local.tags
}

resource "aws_cognito_user_pool_client" "app" {
  count = var.enable_cognito ? 1 : 0

  name         = "${var.project_name}-app"
  user_pool_id = aws_cognito_user_pool.main[0].id

  # A mobile app cannot keep a secret, so the client is public.
  generate_secret = false

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  # Sign-in and password reset answer the same way for unknown e-mails, so the
  # API cannot be used to discover who has an account.
  prevent_user_existence_errors = "ENABLED"
  enable_token_revocation       = true

  access_token_validity  = 60
  id_token_validity      = 60
  refresh_token_validity = 30
  auth_session_validity  = 3

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }

  read_attributes  = ["email", "email_verified"]
  write_attributes = ["email"]
}

locals {
  # The BFF's authorizer: an explicit var.jwt_authorizer (another OIDC issuer)
  # wins; otherwise the pool above, when enabled.
  jwt_config = var.jwt_authorizer != null ? {
    issuer    = var.jwt_authorizer.issuer
    audiences = var.jwt_authorizer.audiences
    } : var.enable_cognito ? {
    issuer    = "https://${aws_cognito_user_pool.main[0].endpoint}"
    audiences = [aws_cognito_user_pool_client.app[0].id]
  } : null
}
