variable "region" {
  description = "The AWS region where the S3 bucket will be created."
  type        = string
  default     = "us-east-1"
}

variable "bucket_name" {
  description = "The name of the S3 bucket."
  type        = string
}

variable "versioning_enabled" {
  description = "Enable versioning for the S3 bucket."
  type        = bool
  default     = true
}

variable "object_lock_enabled" {
  description = "Enable object lock for the S3 bucket."
  type        = bool
  default     = true
}

variable "additional_tags" {
  description = "Additional tags to apply to the S3 bucket."
  type        = map(string)
  default     = {}
}

variable "bucket_policy_json" {
  description = "The JSON representation of the S3 bucket policy. Pass an empty string if not using a bucket policy."
  type        = string
  default     = ""
}
