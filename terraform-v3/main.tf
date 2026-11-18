data "aws_caller_identity" "current" {}

data "aws_region" "waf" {
  provider = aws.us_east_1
}

data "aws_partition" "current" {}

resource "random_id" "suffix" {
  byte_length = 6
}

locals {
  build_dir = "${path.module}/../lambdas/build-v3-portable"
  name      = var.project_name
  account   = data.aws_caller_identity.current.account_id

  router_is_profile = can(regex("^(us|eu|apac|au|jp|in|ca|global)\\.", var.router_model_id))
  answer_is_profile = can(regex("^(us|eu|apac|au|jp|in|ca|global)\\.", var.answer_model_id))

  router_model_arn = local.router_is_profile ? (
    "arn:${data.aws_partition.current.partition}:bedrock:${var.region}:${local.account}:inference-profile/${var.router_model_id}"
    ) : (
    "arn:${data.aws_partition.current.partition}:bedrock:${var.region}::foundation-model/${var.router_model_id}"
  )
  answer_model_arn = local.answer_is_profile ? (
    "arn:${data.aws_partition.current.partition}:bedrock:${var.region}:${local.account}:inference-profile/${var.answer_model_id}"
    ) : (
    "arn:${data.aws_partition.current.partition}:bedrock:${var.region}::foundation-model/${var.answer_model_id}"
  )
  query_model_arns = distinct([local.router_model_arn, local.answer_model_arn])
  query_profile_arns = distinct(compact([
    local.router_is_profile ? local.router_model_arn : "",
    local.answer_is_profile ? local.answer_model_arn : "",
  ]))
  site_domain = length(var.cloudfront_aliases) > 0 ? var.cloudfront_aliases[0] : aws_cloudfront_distribution.web.domain_name
}
