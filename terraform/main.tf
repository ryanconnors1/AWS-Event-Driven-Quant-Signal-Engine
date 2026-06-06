provider "aws" {
  region = "us-east-1"
}


data "archive_file" "ingestion_zip" {
  type        = "zip"
  source_dir  = "../lambdas/ingestion"
  output_path = "../build/ingestion.zip"
}


resource "aws_s3_bucket" "market_data" {
  bucket = "market-data-${random_id.suffix.hex}"
}

resource "random_id" "suffix" {
  byte_length = 4
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
        Resource = "*"
      },
      {
        Effect = "Allow",
        Action = ["sqs:SendMessage"],
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ingestion_attach" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = aws_iam_policy.ingestion_policy.arn
}

resource "aws_lambda_function" "ingestion" {
  function_name = "ingestion-lambda"
  role          = aws_iam_role.lambda_role.arn
  runtime       = "python3.11"
  handler       = "handler.ingestion_handler"

  filename = data.archive_file.ingestion_zip.output_path

  source_code_hash = data.archive_file.ingestion_zip.output_base64sha256

  timeout = 30
}

resource "aws_lambda_event_source_mapping" "ingestion_trigger" {
  event_source_arn = aws_sqs_queue.ingestion_queue.arn
  function_name    = aws_lambda_function.ingestion.arn
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
