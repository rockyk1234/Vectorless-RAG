variable "region" {
  description = "AWS Region for regional data, compute, authentication, and AI services"
  type        = string
  default     = "us-east-1"
}

variable "enable_waf" {
  description = "Deploy AWS WAF managed protections and encrypted WAF logs for CloudFront"
  type        = bool
  default     = true
}

variable "project_name" {
  description = "Lowercase prefix for v3 resources"
  type        = string
  default     = "vectorless-v3"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{2,24}$", var.project_name))
    error_message = "project_name must be 3 to 25 lowercase letters, numbers, or hyphens and must start with a letter or number."
  }
}

variable "admin_user_email" {
  description = "Initial Cognito user invited to the private demo"
  type        = string

  validation {
    condition     = can(regex("^[^@[:space:]]+@[^@[:space:]]+\\.[^@[:space:]]+$", var.admin_user_email))
    error_message = "admin_user_email must be a valid email address."
  }
}

variable "router_model_id" {
  description = "Bedrock model or inference profile ID used for routing and summaries"
  type        = string
  default     = "global.anthropic.claude-haiku-4-5-20251001-v1:0"

  validation {
    condition     = length(trimspace(var.router_model_id)) > 0
    error_message = "router_model_id must not be empty."
  }
}

variable "answer_model_id" {
  description = "Bedrock model or inference profile ID used for grounded answers"
  type        = string
  default     = "global.anthropic.claude-sonnet-4-6"

  validation {
    condition     = length(trimspace(var.answer_model_id)) > 0
    error_message = "answer_model_id must not be empty."
  }
}

variable "log_retention_days" {
  description = "CloudWatch Logs retention period"
  type        = number
  default     = 365

  validation {
    condition     = contains([365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a supported CloudWatch Logs value of at least one year."
  }
}

variable "access_log_retention_days" {
  description = "Days to retain S3 and CloudFront access logs"
  type        = number
  default     = 365

  validation {
    condition     = var.access_log_retention_days >= 90
    error_message = "access_log_retention_days must be at least 90 days."
  }
}

variable "ingest_reserved_concurrency" {
  description = "Reserved concurrency for PDF ingest jobs"
  type        = number
  default     = 2

  validation {
    condition     = var.ingest_reserved_concurrency >= 1
    error_message = "ingest_reserved_concurrency must be at least 1."
  }
}

variable "query_reserved_concurrency" {
  description = "Reserved concurrency for interactive document queries"
  type        = number
  default     = 10

  validation {
    condition     = var.query_reserved_concurrency >= 1
    error_message = "query_reserved_concurrency must be at least 1."
  }
}

variable "cognito_deletion_protection" {
  description = "Cognito deletion protection. Keep ACTIVE except during an explicitly approved teardown"
  type        = string
  default     = "ACTIVE"

  validation {
    condition     = contains(["ACTIVE", "INACTIVE"], var.cognito_deletion_protection)
    error_message = "cognito_deletion_protection must be ACTIVE or INACTIVE."
  }
}

variable "cloudfront_aliases" {
  description = "Optional CloudFront alias. Supply one primary name with a matching us-east-1 ACM certificate"
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.cloudfront_aliases) <= 1
    error_message = "Supply at most one CloudFront alias because it becomes the Cognito callback host."
  }
}

variable "cloudfront_certificate_arn" {
  description = "Optional ACM certificate ARN in us-east-1 for CloudFront aliases"
  type        = string
  default     = null
  nullable    = true
}

variable "noncurrent_version_retention_days" {
  description = "Days to retain noncurrent S3 object versions"
  type        = number
  default     = 30

  validation {
    condition     = var.noncurrent_version_retention_days >= 1
    error_message = "noncurrent_version_retention_days must be at least 1."
  }
}

variable "multipart_abort_days" {
  description = "Days before S3 aborts an incomplete multipart upload"
  type        = number
  default     = 7

  validation {
    condition     = var.multipart_abort_days >= 1
    error_message = "multipart_abort_days must be at least 1."
  }
}

variable "ingest_dlq_retention_seconds" {
  description = "Retention period for failed asynchronous ingest events"
  type        = number
  default     = 1209600

  validation {
    condition     = var.ingest_dlq_retention_seconds >= 60 && var.ingest_dlq_retention_seconds <= 1209600
    error_message = "ingest_dlq_retention_seconds must be between 60 and 1209600."
  }
}

variable "ingest_lambda_memory_mb" {
  description = "Memory allocated to the PDF ingest Lambda"
  type        = number
  default     = 2048

  validation {
    condition     = var.ingest_lambda_memory_mb >= 128 && var.ingest_lambda_memory_mb <= 10240
    error_message = "ingest_lambda_memory_mb must be between 128 and 10240."
  }
}

variable "ingest_lambda_timeout_seconds" {
  description = "Maximum PDF ingest Lambda runtime"
  type        = number
  default     = 900

  validation {
    condition     = var.ingest_lambda_timeout_seconds >= 60 && var.ingest_lambda_timeout_seconds <= 900
    error_message = "ingest_lambda_timeout_seconds must be between 60 and 900."
  }
}

variable "textract_max_wait_seconds" {
  description = "Textract polling deadline within the ingest Lambda timeout"
  type        = number
  default     = 840

  validation {
    condition     = var.textract_max_wait_seconds >= 30 && var.textract_max_wait_seconds <= 840
    error_message = "textract_max_wait_seconds must be between 30 and 840."
  }
}

variable "query_lambda_memory_mb" {
  description = "Memory allocated to the interactive query Lambda"
  type        = number
  default     = 512

  validation {
    condition     = var.query_lambda_memory_mb >= 128 && var.query_lambda_memory_mb <= 10240
    error_message = "query_lambda_memory_mb must be between 128 and 10240."
  }
}

variable "query_lambda_timeout_seconds" {
  description = "Maximum interactive query Lambda runtime"
  type        = number
  default     = 90

  validation {
    condition     = var.query_lambda_timeout_seconds >= 60 && var.query_lambda_timeout_seconds <= 900
    error_message = "query_lambda_timeout_seconds must be between 60 and 900."
  }
}

variable "cloudfront_origin_read_timeout_seconds" {
  description = "CloudFront wait time for the Lambda Function URL origin"
  type        = number
  default     = 60

  validation {
    condition     = var.cloudfront_origin_read_timeout_seconds >= 1 && var.cloudfront_origin_read_timeout_seconds <= 60
    error_message = "cloudfront_origin_read_timeout_seconds must be between 1 and 60."
  }
}

variable "hsts_max_age_seconds" {
  description = "Strict-Transport-Security max-age returned by CloudFront"
  type        = number
  default     = 31536000

  validation {
    condition     = var.hsts_max_age_seconds >= 31536000
    error_message = "hsts_max_age_seconds must be at least one year."
  }
}

variable "cognito_password_minimum_length" {
  description = "Minimum password length for invited Cognito users"
  type        = number
  default     = 12

  validation {
    condition     = var.cognito_password_minimum_length >= 12
    error_message = "cognito_password_minimum_length must be at least 12."
  }
}

variable "cognito_temporary_password_days" {
  description = "Days before an unused temporary Cognito password expires"
  type        = number
  default     = 7

  validation {
    condition     = var.cognito_temporary_password_days >= 1 && var.cognito_temporary_password_days <= 365
    error_message = "cognito_temporary_password_days must be between 1 and 365."
  }
}

variable "cognito_id_token_minutes" {
  description = "Cognito ID token validity in minutes"
  type        = number
  default     = 60

  validation {
    condition     = var.cognito_id_token_minutes >= 5 && var.cognito_id_token_minutes <= 1440
    error_message = "cognito_id_token_minutes must be between 5 and 1440."
  }
}

variable "cognito_access_token_minutes" {
  description = "Cognito access token validity in minutes"
  type        = number
  default     = 60

  validation {
    condition     = var.cognito_access_token_minutes >= 5 && var.cognito_access_token_minutes <= 1440
    error_message = "cognito_access_token_minutes must be between 5 and 1440."
  }
}

variable "cognito_refresh_token_days" {
  description = "Cognito refresh token validity in days"
  type        = number
  default     = 1

  validation {
    condition     = var.cognito_refresh_token_days >= 1 && var.cognito_refresh_token_days <= 3650
    error_message = "cognito_refresh_token_days must be between 1 and 3650."
  }
}

variable "max_figures_per_manual" {
  description = "Maximum figure crops stored for one manual revision"
  type        = number
  default     = 400

  validation {
    condition     = var.max_figures_per_manual >= 1
    error_message = "max_figures_per_manual must be at least 1."
  }
}
