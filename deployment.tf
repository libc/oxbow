# This Terraform file is necessary to configure the basic
# infrastructure around the Optimize lambda function

resource "aws_lambda_function" "oxbow" {
  description   = "A simple lambda for converting parquet files to delta tables"
  filename      = "target/lambda/oxbow/bootstrap.zip"
  function_name = "oxbow-conversion"
  role          = aws_iam_role.iam_for_lambda.arn
  handler       = "provided"
  runtime       = "provided.al2"

  environment {
    variables = {
      AWS_S3_LOCKING_PROVIDER = "dynamodb"
      RUST_LOG                = "debug"
      DYNAMO_LOCK_TABLE_NAME  = aws_dynamodb_table.oxbow_locking.name
    }
  }
}

variable "s3_bucket_arn" {
  type        = string
  default     = "*"
  description = "The ARN for the S3 bucket that the optimize function will optimize"
}

variable "aws_access_key" {
  type    = string
  default = ""
}

variable "aws_secret_key" {
  type    = string
  default = ""
}

provider "aws" {
  region     = "us-west-2"
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key

  default_tags {
    tags = {
      ManagedBy   = "Terraform"
      environment = terraform.workspace
      workspace   = terraform.workspace
    }
  }
}

resource "aws_s3_bucket" "parquets" {
  bucket = "oxbow-dev-parquet"
}

resource "aws_lambda_permission" "allow_bucket" {
  statement_id  = "AllowExecutionFromS3Bucket"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.oxbow.arn
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.parquets.arn
}

resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.parquets.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.oxbow.arn
    events              = ["s3:ObjectCreated:*"]
    filter_suffix       = ".parquet"
  }

  depends_on = [aws_lambda_permission.allow_bucket]
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = [
      "sts:AssumeRole",
    ]
  }
}

resource "aws_iam_policy" "lambda_permissions" {
  name = "oxbow-permissions"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = ["dynamodb:*"]
        Resource = aws_dynamodb_table.oxbow_locking.arn
        Effect   = "Allow"
      },
      {
        Action   = ["s3:*"]
        Resource = var.s3_bucket_arn
        Effect   = "Allow"
      }
    ]
  })
}

resource "aws_iam_role" "iam_for_lambda" {
  name               = "iam_for_oxbow_lambda"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
  managed_policy_arns = [
    aws_iam_policy.lambda_permissions.arn,
    "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
  ]
}

# The DynamoDb table is used for providing safe concurrent writes to delta
# tables.
resource "aws_dynamodb_table" "oxbow_locking" {
  name         = "oxbow_lock_table"
  billing_mode = "PROVISIONED"
  # Default name of the partition key hard-coded in delta-rs
  hash_key       = "key"
  read_capacity  = 10
  write_capacity = 10

  attribute {
    name = "key"
    type = "S"
  }
}
