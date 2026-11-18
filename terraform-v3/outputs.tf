output "aws_account_id" {
  value = data.aws_caller_identity.current.account_id
}

output "region" {
  value = var.region
}

output "document_bucket" {
  value = aws_s3_bucket.documents.bucket
}

output "metadata_table" {
  value = aws_dynamodb_table.metadata.name
}

output "kms_key_arn" {
  value = aws_kms_key.data.arn
}

output "ingest_function_name" {
  value = aws_lambda_function.ingest.function_name
}

output "query_function_name" {
  value = aws_lambda_function.query.function_name
}

output "web_url" {
  value = "https://${local.site_domain}"
}

output "web_bucket" {
  value = aws_s3_bucket.web.bucket
}

output "cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.web.id
}

output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.main.id
}

output "cognito_client_id" {
  value = aws_cognito_user_pool_client.spa.id
}

output "cognito_domain" {
  value = "https://${aws_cognito_user_pool_domain.main.domain}.auth.${var.region}.amazoncognito.com"
}

output "router_model_id" {
  value = var.router_model_id
}

output "answer_model_id" {
  value = var.answer_model_id
}

output "waf_enabled" {
  value = var.enable_waf
}
