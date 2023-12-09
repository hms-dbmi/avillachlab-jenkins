provider "aws" {
  region = var.region
  version = "5.30.0"
}

resource "aws_s3_bucket" "this" {
  bucket = var.bucket_name

  acl = "private"
  
  object_lock_enabled = true
  
  versioning {
    enabled = var.versioning_enabled
  }

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        sse_algorithm = "AES256"
      }
    }
  }
}

resource "aws_s3_bucket_object_lock_configuration" "this" {
  bucket = aws_s3_bucket.this.id
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.bucket
  policy = var.bucket_policy_json
}
