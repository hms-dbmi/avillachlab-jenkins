provider "aws" {
  region = var.region
  version = "3.74"
}

resource "aws_s3_bucket" "root" {
  bucket = var.bucket_name

  acl = "private"

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

  object_lock_configuration {
    object_lock_enabled = var.object_lock_enabled
  }

}

resource "aws_s3_bucket_policy" "root_ac" {
  bucket = aws_s3_bucket.example.bucket
  policy = var.bucket_policy_json
}
