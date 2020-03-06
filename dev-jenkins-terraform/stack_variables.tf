variable "stack-id" {
	type = string
	default = "test"
}

variable "git-commit" {
    type = string
}

variable "config-xml-filename" {
    type = string
    default = "config.xml"
}

variable "okta-metadata-description" {
    type = string
    default = "none"
}

variable "subnet-id" {
    type = string
}

variable "vpc-id" {
    type = string
}

variable "instance-profile-name" {
	type = string
}

variable "access-cidr" {
	type = string
}

variable "provisioning-cidr" {
	type = string
}

variable "stack-s3-bucket" {
	type = string
}

variable "stack-jenkins-dockerfile" {
	type = string
}

variable "cis-centos-linux-ami-id" {
	type = string
}
