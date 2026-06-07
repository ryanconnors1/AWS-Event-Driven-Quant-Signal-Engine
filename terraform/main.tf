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
  key    = "config/sp500_tickers.txt"
  source = "${path.module}/../config/sp500_tickers.txt"
  etag   = filemd5("${path.module}/../config/sp500_tickers.txt")
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
