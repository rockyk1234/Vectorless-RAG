# Lambda execution roles, deployment packages, functions, and ingest trigger.

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ingest" {
  name               = "${local.name}-ingest-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role" "query" {
  name               = "${local.name}-query-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_sqs_queue" "ingest_dlq" {
  name                      = "${local.name}-ingest-dlq"
  message_retention_seconds = var.ingest_dlq_retention_seconds
  sqs_managed_sse_enabled   = true
}

data "aws_iam_policy_document" "ingest" {
  statement {
    sid       = "ReadAndWriteDocuments"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${aws_s3_bucket.documents.arn}/*"]
  }

  statement {
    sid       = "WriteMetadata"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem"]
    resources = [aws_dynamodb_table.metadata.arn]
  }

  statement {
    sid       = "AnalyzeDocuments"
    actions   = ["textract:StartDocumentAnalysis", "textract:GetDocumentAnalysis"]
    resources = ["*"]
  }

  statement {
    sid       = "InvokeRouter"
    actions   = ["bedrock:InvokeModel"]
    resources = [local.router_model_arn]
  }

  dynamic "statement" {
    for_each = local.router_is_profile ? [1] : []

    content {
      sid       = "InvokeRouterProfileModels"
      actions   = ["bedrock:InvokeModel"]
      resources = ["arn:${data.aws_partition.current.partition}:bedrock:*::foundation-model/*"]

      condition {
        test     = "StringEquals"
        variable = "bedrock:InferenceProfileArn"
        values   = [local.router_model_arn]
      }
    }
  }

  statement {
    sid       = "UseDataKey"
    actions   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey"]
    resources = [aws_kms_key.data.arn]
  }

  statement {
    sid       = "SendFailuresToDlq"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.ingest_dlq.arn]
  }

  statement {
    sid       = "WriteTraces"
    actions   = ["xray:PutTelemetryRecords", "xray:PutTraceSegments"]
    resources = ["*"]
  }

  statement {
    sid       = "WriteLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.ingest.arn}:*"]
  }
}

resource "aws_iam_role_policy" "ingest" {
  name   = "${local.name}-ingest"
  role   = aws_iam_role.ingest.id
  policy = data.aws_iam_policy_document.ingest.json
}

data "aws_iam_policy_document" "query" {
  statement {
    sid       = "ReadDocuments"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.documents.arn}/*"]
  }

  statement {
    sid       = "ReadMetadata"
    actions   = ["dynamodb:GetItem"]
    resources = [aws_dynamodb_table.metadata.arn]
  }

  statement {
    sid       = "InvokeModels"
    actions   = ["bedrock:InvokeModel"]
    resources = local.query_model_arns
  }

  dynamic "statement" {
    for_each = length(local.query_profile_arns) > 0 ? [1] : []

    content {
      sid       = "InvokeProfileModels"
      actions   = ["bedrock:InvokeModel"]
      resources = ["arn:${data.aws_partition.current.partition}:bedrock:*::foundation-model/*"]

      condition {
        test     = "StringEquals"
        variable = "bedrock:InferenceProfileArn"
        values   = local.query_profile_arns
      }
    }
  }

  statement {
    sid       = "DecryptDocuments"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.data.arn]
  }

  statement {
    sid       = "WriteTraces"
    actions   = ["xray:PutTelemetryRecords", "xray:PutTraceSegments"]
    resources = ["*"]
  }

  statement {
    sid       = "WriteLogs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.query.arn}:*"]
  }
}

resource "aws_iam_role_policy" "query" {
  name   = "${local.name}-query"
  role   = aws_iam_role.query.id
  policy = data.aws_iam_policy_document.query.json
}

data "archive_file" "imaging" {
  type        = "zip"
  source_dir  = "${local.build_dir}/img_layer"
  output_path = "${local.build_dir}/img_layer.zip"
}

resource "aws_lambda_layer_version" "imaging" {
  layer_name          = "${local.name}-imaging"
  filename            = data.archive_file.imaging.output_path
  source_code_hash    = data.archive_file.imaging.output_base64sha256
  compatible_runtimes = ["python3.12"]
}

data "archive_file" "ingest" {
  type        = "zip"
  source_dir  = "${local.build_dir}/ingest"
  output_path = "${local.build_dir}/ingest.zip"
}

data "archive_file" "query" {
  type        = "zip"
  source_dir  = "${local.build_dir}/query"
  output_path = "${local.build_dir}/query.zip"
}

resource "aws_cloudwatch_log_group" "ingest" {
  name              = "/aws/lambda/${local.name}-ingest"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.data.arn
}

resource "aws_cloudwatch_log_group" "query" {
  name              = "/aws/lambda/${local.name}-query"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.data.arn
}

resource "aws_lambda_function" "ingest" {
  # checkov:skip=CKV_AWS_117:The function calls public regional AWS APIs and a VPC would add NAT or endpoint cost without isolating a private dependency.
  function_name                  = "${local.name}-ingest"
  role                           = aws_iam_role.ingest.arn
  runtime                        = "python3.12"
  handler                        = "handler.lambda_handler"
  filename                       = data.archive_file.ingest.output_path
  source_code_hash               = data.archive_file.ingest.output_base64sha256
  timeout                        = var.ingest_lambda_timeout_seconds
  memory_size                    = var.ingest_lambda_memory_mb
  reserved_concurrent_executions = var.ingest_reserved_concurrency
  kms_key_arn                    = aws_kms_key.data.arn
  layers                         = [aws_lambda_layer_version.imaging.arn]

  dead_letter_config {
    target_arn = aws_sqs_queue.ingest_dlq.arn
  }

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      AWS_ACCOUNT_ID            = local.account
      AWS_REGION_NAME           = var.region
      DOCUMENT_BUCKET           = aws_s3_bucket.documents.bucket
      KMS_KEY_ARN               = aws_kms_key.data.arn
      MAX_FIGURES               = tostring(var.max_figures_per_manual)
      METADATA_TABLE            = aws_dynamodb_table.metadata.name
      ROUTER_MODEL_ID           = var.router_model_id
      ANSWER_MODEL_ID           = var.answer_model_id
      TEXTRACT_MAX_WAIT_SECONDS = tostring(var.textract_max_wait_seconds)
    }
  }

  lifecycle {
    precondition {
      condition     = var.textract_max_wait_seconds < var.ingest_lambda_timeout_seconds
      error_message = "textract_max_wait_seconds must be lower than ingest_lambda_timeout_seconds."
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.ingest,
    aws_iam_role_policy.ingest,
  ]
}

resource "aws_lambda_function" "query" {
  # checkov:skip=CKV_AWS_117:The function calls public regional AWS APIs and a VPC would add NAT or endpoint cost without isolating a private dependency.
  # checkov:skip=CKV_AWS_116:Function URL requests are synchronous, so Lambda asynchronous DLQ handling does not apply.
  function_name                  = "${local.name}-query"
  role                           = aws_iam_role.query.arn
  runtime                        = "python3.12"
  handler                        = "handler.lambda_handler"
  filename                       = data.archive_file.query.output_path
  source_code_hash               = data.archive_file.query.output_base64sha256
  timeout                        = var.query_lambda_timeout_seconds
  memory_size                    = var.query_lambda_memory_mb
  reserved_concurrent_executions = var.query_reserved_concurrency
  kms_key_arn                    = aws_kms_key.data.arn

  tracing_config {
    mode = "Active"
  }

  environment {
    variables = {
      AWS_ACCOUNT_ID  = local.account
      AWS_REGION_NAME = var.region
      DOCUMENT_BUCKET = aws_s3_bucket.documents.bucket
      KMS_KEY_ARN     = aws_kms_key.data.arn
      METADATA_TABLE  = aws_dynamodb_table.metadata.name
      ROUTER_MODEL_ID = var.router_model_id
      ANSWER_MODEL_ID = var.answer_model_id
      COGNITO_ISSUER  = "https://${aws_cognito_user_pool.main.endpoint}"
      USER_POOL_ID    = aws_cognito_user_pool.main.id
    }
  }

  lifecycle {
    precondition {
      condition     = var.query_lambda_timeout_seconds > var.cloudfront_origin_read_timeout_seconds
      error_message = "query_lambda_timeout_seconds must exceed cloudfront_origin_read_timeout_seconds."
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.query,
    aws_iam_role_policy.query,
  ]
}

resource "aws_lambda_function_url" "query" {
  function_name      = aws_lambda_function.query.function_name
  authorization_type = "AWS_IAM"
}

resource "aws_lambda_permission" "s3_ingest" {
  statement_id   = "AllowDocumentBucket"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.ingest.function_name
  principal      = "s3.amazonaws.com"
  source_arn     = aws_s3_bucket.documents.arn
  source_account = local.account
}

resource "aws_s3_bucket_notification" "documents" {
  bucket = aws_s3_bucket.documents.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.ingest.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "manuals/"
    filter_suffix       = ".pdf"
  }

  lambda_function {
    lambda_function_arn = aws_lambda_function.ingest.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "units/"
    filter_suffix       = ".pdf"
  }

  depends_on = [aws_lambda_permission.s3_ingest]
}
