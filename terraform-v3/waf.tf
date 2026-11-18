# CloudFront-scoped WAF protections and encrypted WAF logs.

data "aws_iam_policy_document" "waf_logs_key" {
  count = var.enable_waf ? 1 : 0
  # checkov:skip=CKV_AWS_109:KMS key policies require account-root administration and service-specific cryptographic grants.
  # checkov:skip=CKV_AWS_111:KMS key policy resources must use "*" because KMS evaluates permissions against the key that owns the policy.
  # checkov:skip=CKV_AWS_356:KMS key policy statements cannot scope Resource to the key ARN during key creation.
  statement {
    sid       = "EnableAccountPermissions"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.current.partition}:iam::${local.account}:root"]
    }
  }

  statement {
    sid = "AllowCloudWatchLogs"
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:Encrypt",
      "kms:GenerateDataKey*",
      "kms:ReEncrypt*",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${data.aws_region.waf.region}.${data.aws_partition.current.dns_suffix}"]
    }

    condition {
      test     = "ArnEquals"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values = [
        "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.waf.region}:${local.account}:log-group:aws-waf-logs-${local.name}",
      ]
    }
  }
}

resource "aws_kms_key" "waf_logs" {
  count                   = var.enable_waf ? 1 : 0
  provider                = aws.us_east_1
  description             = "Encrypts vectorless v3 CloudFront WAF logs"
  deletion_window_in_days = 30
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.waf_logs_key[0].json
}

resource "aws_cloudwatch_log_group" "waf" {
  count             = var.enable_waf ? 1 : 0
  provider          = aws.us_east_1
  name              = "aws-waf-logs-${local.name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.waf_logs[0].arn
}

resource "aws_wafv2_web_acl" "web" {
  count       = var.enable_waf ? 1 : 0
  provider    = aws.us_east_1
  name        = "${local.name}-web"
  description = "Managed protections for the vectorless v3 CloudFront distribution"
  scope       = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "aws-managed-common"
    priority = 10

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name}-common"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "aws-managed-known-bad-inputs"
    priority = 20

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name}-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name}-web"
    sampled_requests_enabled   = true
  }
}

resource "aws_wafv2_web_acl_logging_configuration" "web" {
  count                   = var.enable_waf ? 1 : 0
  provider                = aws.us_east_1
  resource_arn            = aws_wafv2_web_acl.web[0].arn
  log_destination_configs = [aws_cloudwatch_log_group.waf[0].arn]

  redacted_fields {
    single_header {
      name = "x-id-token"
    }
  }
}
