provider "aws" {
  region = "us-east-1"
}


data "archive_file" "ingestion_zip" {
  type        = "zip"
  source_dir  = "../lambdas/ingestion"
  output_path = "../build/ingestion.zip"
}

data "archive_file" "processing_zip" {
  type        = "zip"
  source_dir  = "../lambdas/processing"
  output_path = "../build/processing.zip"
}

data "archive_file" "scheduled_ingestion_zip" {
  type        = "zip"
  source_dir  = "../lambdas/scheduled_ingestion"
  output_path = "../build/scheduled_ingestion.zip"
}

data "archive_file" "ranking_zip" {
  type        = "zip"
  source_dir  = "../lambdas/ranking"
  output_path = "../build/ranking.zip"
}

data "archive_file" "layer_zip" {
  type        = "zip"
  source_dir  = "../layer"
  output_path = "../layer.zip"
}

resource "aws_lambda_layer_version" "this" {
  filename   = data.archive_file.layer_zip.output_path
  layer_name = "my-layer"

  source_code_hash = data.archive_file.layer_zip.output_base64sha256
}

resource "aws_s3_bucket" "market_data" {
  bucket = "market-data-${random_id.suffix.hex}"
}

resource "aws_s3_object" "ticker_universe" {
  bucket = aws_s3_bucket.market_data.id
  key    = "config/alpharank_universe.txt"
  source = "${path.module}/../config/alpharank_universe.txt"
  etag   = filemd5("${path.module}/../config/alpharank_universe.txt")
}

resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.market_data.id

  queue {
    queue_arn = aws_sqs_queue.processing_queue.arn
    events    = ["s3:ObjectCreated:*"]

    filter_prefix = "raw/"
  }

  depends_on = [aws_sqs_queue_policy.processing_queue_policy]
}


resource "aws_sqs_queue" "ingestion_dlq" {
  name = "ingestion-dlq"
}

resource "aws_sqs_queue" "ingestion_queue" {
  name = "ingestion-queue"

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.ingestion_dlq.arn
    maxReceiveCount     = 3
  })
}


resource "aws_sqs_queue" "processing_dlq" {
  name = "processing-dlq"
}

resource "aws_sqs_queue" "processing_queue" {
  name = "processing-queue"

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.processing_dlq.arn
    maxReceiveCount     = 3
  })
}

resource "aws_sqs_queue_policy" "processing_queue_policy" {
  queue_url = aws_sqs_queue.processing_queue.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow"
        Principal = "*"
        Action = "sqs:SendMessage"
        Resource = aws_sqs_queue.processing_queue.arn
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = aws_s3_bucket.market_data.arn
          }
        }
      }
    ]
  })
}

resource "aws_dynamodb_table" "trading_signals" {
  name         = "TradingSignals"
  billing_mode = "PAY_PER_REQUEST"

  hash_key  = "PK"
  range_key = "SK"

  attribute {
    name = "PK"
    type = "S"
  }

  attribute {
    name = "SK"
    type = "S"
  }

  attribute {
    name = "batch_id"
    type = "S"
  }

  attribute {
    name = "composite_rank"
    type = "N"
  }

  global_secondary_index {
    name            = "BatchRankIndex"
    hash_key        = "batch_id"
    range_key       = "composite_rank"
    projection_type = "ALL"
  }
}

resource "aws_dynamodb_table" "factor_snapshots" {
  name         = "FactorSnapshots"
  billing_mode = "PAY_PER_REQUEST"

  hash_key  = "PK"
  range_key = "SK"

  attribute {
    name = "PK"
    type = "S"
  }

  attribute {
    name = "SK"
    type = "S"
  }
}


resource "aws_iam_role" "lambda_role" {
  name = "ingestion-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Effect = "Allow",
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_sqs" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaSQSQueueExecutionRole"
}

resource "aws_iam_policy" "ingestion_policy" {
  name = "ingestion-policy"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = ["s3:PutObject"],
        Resource = [
            "${aws_s3_bucket.market_data.arn}/*"
            ]
      }
    ]
  })
}

resource "aws_iam_policy" "processing_policy" {
  name = "processing-policy"

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect   = "Allow",
        Action   = ["s3:GetObject"],
        Resource = ["${aws_s3_bucket.market_data.arn}/*"]
      },
      {
        Effect   = "Allow",
        Action   = ["dynamodb:PutItem"],
        Resource = [aws_dynamodb_table.factor_snapshots.arn]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ingestion_attach" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.ingestion_policy.arn
}

resource "aws_iam_role_policy_attachment" "processing_attach" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.processing_policy.arn
}

resource "aws_lambda_function" "ingestion" {
  function_name = "ingestion-lambda"
  role          = aws_iam_role.lambda_role.arn
  runtime       = "python3.11"
  handler       = "handler.ingestion_handler"

  filename = data.archive_file.ingestion_zip.output_path

  source_code_hash = data.archive_file.ingestion_zip.output_base64sha256

  environment {
    variables = {
        BUCKET_NAME = aws_s3_bucket.market_data.bucket
    }
  }

  timeout = 30
}

resource "aws_lambda_event_source_mapping" "ingestion_trigger" {
  event_source_arn = aws_sqs_queue.ingestion_queue.arn
  function_name    = aws_lambda_function.ingestion.arn
}


resource "aws_lambda_function" "processing" {
  function_name = "processing-lambda"
  role          = aws_iam_role.lambda_role.arn
  runtime       = "python3.11"
  handler       = "handler.processing_handler"

  filename         = data.archive_file.processing_zip.output_path
  source_code_hash = data.archive_file.processing_zip.output_base64sha256

  timeout = 30

  layers = [aws_lambda_layer_version.this.arn]

  environment {
    variables = {
      FACTOR_SNAPSHOTS_TABLE = aws_dynamodb_table.factor_snapshots.name
    }
  }
}

resource "aws_lambda_event_source_mapping" "processing_trigger" {
  event_source_arn = aws_sqs_queue.processing_queue.arn
  function_name    = aws_lambda_function.processing.arn

  batch_size = 1
}

resource "aws_secretsmanager_secret" "alpha_vantage" {
  name = "alpha-vantage-api-key"
}


resource "aws_iam_policy" "secrets_policy" {
  name = "secrets-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = aws_secretsmanager_secret.alpha_vantage.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "secrets_attach" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.secrets_policy.arn
}

resource "aws_iam_policy" "scheduled_ingestion_policy" {
  name = "scheduled-ingestion-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["${aws_s3_bucket.market_data.arn}/config/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = ["${aws_s3_bucket.market_data.arn}/raw/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = [aws_lambda_function.scheduled_ingestion.arn]
      }
    ]
  })
}

resource "aws_iam_policy" "ranking_policy" {
  name = "ranking-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:Query",
          "dynamodb:Scan",
        ]
        Resource = [aws_dynamodb_table.factor_snapshots.arn]
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:BatchWriteItem",
        ]
        Resource = [aws_dynamodb_table.trading_signals.arn]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "scheduled_ingestion_attach" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.scheduled_ingestion_policy.arn
}

resource "aws_iam_role_policy_attachment" "ranking_attach" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.ranking_policy.arn
}

resource "aws_lambda_function" "scheduled_ingestion" {
  function_name = "scheduled-ingestion-lambda"
  role          = aws_iam_role.lambda_role.arn
  runtime       = "python3.11"
  handler       = "handler.scheduled_ingestion_handler"

  filename         = data.archive_file.scheduled_ingestion_zip.output_path
  source_code_hash = data.archive_file.scheduled_ingestion_zip.output_base64sha256

  timeout = 900

  environment {
    variables = {
      BUCKET_NAME            = aws_s3_bucket.market_data.bucket
      TICKER_UNIVERSE_S3_KEY = aws_s3_object.ticker_universe.key
      THROTTLE_SECONDS       = "12"
      CHUNK_SIZE             = "70"
    }
  }

  depends_on = [aws_s3_object.ticker_universe]
}

resource "aws_cloudwatch_event_rule" "ingestion_schedule" {
  name                = "scheduled-ingestion-daily"
  description         = "Batch-fetch market data after US market close"
  schedule_expression = "cron(30 21 * * ? *)"
}

resource "aws_cloudwatch_event_target" "ingestion_target" {
  rule      = aws_cloudwatch_event_rule.ingestion_schedule.name
  target_id = "scheduled-ingestion-lambda"
  arn       = aws_lambda_function.scheduled_ingestion.arn
}

resource "aws_lambda_permission" "ingestion_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.scheduled_ingestion.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.ingestion_schedule.arn
}

resource "aws_lambda_function" "ranking" {
  function_name = "ranking-lambda"
  role          = aws_iam_role.lambda_role.arn
  runtime       = "python3.11"
  handler       = "handler.ranking_handler"

  filename         = data.archive_file.ranking_zip.output_path
  source_code_hash = data.archive_file.ranking_zip.output_base64sha256

  timeout = 60

  layers = [aws_lambda_layer_version.this.arn]

  environment {
    variables = {
      FACTOR_SNAPSHOTS_TABLE    = aws_dynamodb_table.factor_snapshots.name
      SIGNALS_TABLE             = aws_dynamodb_table.trading_signals.name
      MIN_TICKERS               = "2"
      RANKING_BATCH_OFFSET_DAYS = "1"
      SIGNAL_TOP_PCT            = "90"
      SIGNAL_BUY_PCT            = "70"
      SIGNAL_SELL_PCT           = "30"
      SIGNAL_BOTTOM_PCT         = "10"
    }
  }
}

resource "aws_cloudwatch_event_rule" "ranking_schedule" {
  name                = "ranking-daily"
  description         = "Cross-sectional factor ranking after the full ingestion throttle + processing window"
  schedule_expression = "cron(0 0 * * ? *)"
}

resource "aws_cloudwatch_event_target" "ranking_target" {
  rule      = aws_cloudwatch_event_rule.ranking_schedule.name
  target_id = "ranking-lambda"
  arn       = aws_lambda_function.ranking.arn
}

resource "aws_lambda_permission" "ranking_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridgeRanking"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ranking.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.ranking_schedule.arn
}

# ---------------------------------------------------------------------------
# AlphaRank read API (API Gateway HTTP API + Lambda over DynamoDB)
# ---------------------------------------------------------------------------

variable "budget_alert_email" {
  description = "Email for the cost budget alert. Leave empty to skip alert notifications."
  type        = string
  default     = "ryannumber3@gmail.com"
}

data "archive_file" "api_zip" {
  type        = "zip"
  source_dir  = "../lambdas/api"
  output_path = "../build/api.zip"
}

resource "aws_iam_policy" "api_policy" {
  name = "alpharank-api-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:Query"]
        Resource = [
          aws_dynamodb_table.trading_signals.arn,
          "${aws_dynamodb_table.trading_signals.arn}/index/BatchRankIndex",
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "api_attach" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.api_policy.arn
}

resource "aws_lambda_function" "api" {
  function_name = "alpharank-api-lambda"
  role          = aws_iam_role.lambda_role.arn
  runtime       = "python3.11"
  handler       = "handler.api_handler"

  filename         = data.archive_file.api_zip.output_path
  source_code_hash = data.archive_file.api_zip.output_base64sha256

  timeout = 30

  environment {
    variables = {
      SIGNALS_TABLE    = aws_dynamodb_table.trading_signals.name
      BATCH_RANK_INDEX = "BatchRankIndex"
    }
  }
}

resource "aws_apigatewayv2_api" "http" {
  name          = "alpharank-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "OPTIONS"]
    allow_headers = ["*"]
    max_age       = 3600
  }
}

resource "aws_apigatewayv2_integration" "api" {
  api_id                 = aws_apigatewayv2_api.http.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api.invoke_arn
  payload_format_version = "2.0"
}

locals {
  api_routes = [
    "GET /api/batches",
    "GET /api/universe",
    "GET /api/universe/latest",
    "GET /api/tickers/{ticker}",
  ]
}

resource "aws_apigatewayv2_route" "routes" {
  for_each  = toset(local.api_routes)
  api_id    = aws_apigatewayv2_api.http.id
  route_key = each.value
  target    = "integrations/${aws_apigatewayv2_integration.api.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.http.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowExecutionFromApiGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http.execution_arn}/*/*"
}

# ---------------------------------------------------------------------------
# AlphaRank static site hosting (S3 + CloudFront, always-free tier)
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "dashboard" {
  bucket = "alpharank-dashboard-${random_id.suffix.hex}"
}

resource "aws_s3_bucket_public_access_block" "dashboard" {
  bucket                  = aws_s3_bucket.dashboard.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "dashboard" {
  name                              = "alpharank-dashboard-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "dashboard" {
  enabled             = true
  default_root_object = "index.html"
  price_class         = "PriceClass_100"
  comment             = "AlphaRank dashboard"

  origin {
    domain_name              = aws_s3_bucket.dashboard.bucket_regional_domain_name
    origin_id                = "s3-dashboard"
    origin_access_control_id = aws_cloudfront_origin_access_control.dashboard.id
  }

  default_cache_behavior {
    target_origin_id       = "s3-dashboard"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    # Managed CachingOptimized policy
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  # SPA fallback: serve index.html for client-side routes / missing keys.
  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }
  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

resource "aws_s3_bucket_policy" "dashboard" {
  bucket = aws_s3_bucket.dashboard.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "cloudfront.amazonaws.com" }
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.dashboard.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.dashboard.arn
          }
        }
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# Cost guardrail
# ---------------------------------------------------------------------------

resource "aws_budgets_budget" "monthly" {
  name         = "alpharank-monthly"
  budget_type  = "COST"
  limit_amount = "1.0"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = var.budget_alert_email == "" ? [] : [1]
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = 80
      threshold_type             = "PERCENTAGE"
      notification_type          = "FORECASTED"
      subscriber_email_addresses = [var.budget_alert_email]
    }
  }
}

output "api_base_url" {
  description = "Base URL for the AlphaRank read API (set as VITE_API_BASE_URL)."
  value       = aws_apigatewayv2_api.http.api_endpoint
}

output "dashboard_url" {
  description = "Public AlphaRank dashboard URL."
  value       = "https://${aws_cloudfront_distribution.dashboard.domain_name}"
}

output "dashboard_bucket" {
  description = "S3 bucket hosting the dashboard build."
  value       = aws_s3_bucket.dashboard.bucket
}
