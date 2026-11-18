# Cognito user access and the API audience stored in DynamoDB.

resource "aws_cognito_user_pool" "main" {
  name                     = "${local.name}-users"
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  deletion_protection      = var.cognito_deletion_protection
  user_pool_tier           = "ESSENTIALS"
  mfa_configuration        = "OPTIONAL"

  software_token_mfa_configuration {
    enabled = true
  }

  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  password_policy {
    minimum_length                   = var.cognito_password_minimum_length
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = var.cognito_temporary_password_days
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }
}

resource "aws_cognito_user_pool_domain" "main" {
  domain                = "${local.name}-${random_id.suffix.hex}"
  user_pool_id          = aws_cognito_user_pool.main.id
  managed_login_version = 2
}

resource "aws_cognito_user_pool_client" "spa" {
  name                                 = "${local.name}-spa"
  user_pool_id                         = aws_cognito_user_pool.main.id
  generate_secret                      = false
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email"]
  supported_identity_providers         = ["COGNITO"]
  callback_urls = [
    "https://${local.site_domain}/",
    "http://localhost:5173/",
  ]
  logout_urls = [
    "https://${local.site_domain}/",
    "http://localhost:5173/",
  ]
  explicit_auth_flows           = ["ALLOW_REFRESH_TOKEN_AUTH"]
  prevent_user_existence_errors = "ENABLED"
  id_token_validity             = var.cognito_id_token_minutes
  access_token_validity         = var.cognito_access_token_minutes
  refresh_token_validity        = var.cognito_refresh_token_days

  token_validity_units {
    id_token      = "minutes"
    access_token  = "minutes"
    refresh_token = "days"
  }
}

resource "aws_cognito_managed_login_branding" "spa" {
  user_pool_id                = aws_cognito_user_pool.main.id
  client_id                   = aws_cognito_user_pool_client.spa.id
  use_cognito_provided_values = true

  depends_on = [aws_cognito_user_pool_domain.main]
}

resource "aws_dynamodb_table_item" "cognito_client" {
  table_name = aws_dynamodb_table.metadata.name
  hash_key   = aws_dynamodb_table.metadata.hash_key
  range_key  = aws_dynamodb_table.metadata.range_key

  item = jsonencode({
    pk    = { S = "CONFIG" }
    sk    = { S = "COGNITO_CLIENT" }
    value = { S = aws_cognito_user_pool_client.spa.id }
  })
}

resource "aws_cognito_user" "admin" {
  user_pool_id             = aws_cognito_user_pool.main.id
  username                 = var.admin_user_email
  desired_delivery_mediums = ["EMAIL"]

  attributes = {
    email          = var.admin_user_email
    email_verified = "true"
  }
}
