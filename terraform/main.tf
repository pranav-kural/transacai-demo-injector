terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.76"
    }
  }

  required_version = ">= 1.5.6"
}

provider "aws" {
  region     = "us-east-2"
  access_key = var.AWS_ACCESS_KEY
  secret_key = var.AWS_SECRET_KEY
}

resource "aws_iam_role" "lambda_role" {
  name = "lambda_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid    = ""
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "lambda_policy" {
  name = "lambda_policy"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "s3:GetObject",
          "sns:Publish"
        ]
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
}


resource "aws_lambda_layer_version" "lambda_layer" {
  filename   = "packages/transac_ai_injector_layer.zip"
  layer_name = "TransacAIInjectorLayer"

  compatible_runtimes = ["python3.13"]
}

data "archive_file" "lambda_code" {
  type        = "zip"
  source_file = "../lambda/core.py"
  output_path = "demo_injector_package.zip"
}

resource "aws_lambda_function" "inject_sample_transactions" {
  function_name = "inject_sample_transactions_handler"
  role          = aws_iam_role.lambda_role.arn
  handler       = "core.inject_sample_transactions_handler"
  runtime       = "python3.13"
  architectures = ["arm64"]

  filename         = "demo_injector_package.zip"
  source_code_hash = data.archive_file.lambda_code.output_base64sha256

  layers = [aws_lambda_layer_version.lambda_layer.arn]

  timeout = 10

  environment {
    variables = {
      SUPABASE_URL   = var.SUPABASE_URL
      SUPABASE_KEY   = var.SUPABASE_KEY
      SUPABASE_TABLE = var.SUPABASE_TABLE
      SNS_TOPIC_ARN  = var.SNS_TOPIC_ARN
      S3_BUCKET_NAME = var.S3_BUCKET_NAME
      S3_KEY         = var.S3_KEY
    }
  }
}

resource "aws_sns_topic" "default" {
  name = "transacai-demo-injector-job-status"
}

resource "aws_lambda_permission" "allow_sns_invoke" {
  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.inject_sample_transactions.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.default.arn
}

resource "aws_iam_role" "eventbridge_role" {
  name = "eventbridge_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "scheduler.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_policy" "eventbridge_policy" {
  name = "eventbridge_policy"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "lambda:InvokeFunction"
        ]
        Resource = [
          aws_lambda_function.inject_sample_transactions.arn,
          "${aws_lambda_function.inject_sample_transactions.arn}:*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "eventbridge_policy_attachment" {
  role       = aws_iam_role.eventbridge_role.name
  policy_arn = aws_iam_policy.eventbridge_policy.arn
}

resource "aws_scheduler_schedule" "transacai_demo_injector_schedule" {
  name       = "transacai-demo-injector-schedule"
  group_name = "default"

  flexible_time_window {
    mode = "OFF"
  }

  schedule_expression = "rate(5 minute)"

  target {
    arn      = aws_lambda_function.inject_sample_transactions.arn
    role_arn = aws_iam_role.eventbridge_role.arn
  }
}

resource "aws_lambda_permission" "allow_eventbridge_invoke" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.inject_sample_transactions.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_scheduler_schedule.transacai_demo_injector_schedule.arn
}