
variable "deployment-s3-bucket" {
  type = string
}

variable "stack-id" {
	type = string
	default = "test"
}

variable "subnet-id" {
    type = string
}

variable "instance-profile-name" {
	type = string
}

variable "access-cidr" {
	type = string
}

variable "stack-s3-bucket" {
	type = string
}
