variable "stack-id" {
	type = string
	default = "test"
}

variable "git-commit" {
    type = string
}

variable "jenkins-vpc-id" {
    type = string
}

variable "jenkins-instance-profile-name" {
	type = string
}

variable "stack-s3-bucket" {
	type = string
}

variable "jenkins-subnet-id" {
	type = string
}

variable "ami-id" {
	type = string
}

variable "dsm-url" {
	type = string
}

variable "jenkins-sg-ingress-http-cidr-blocks" {
	type = list
}

variable "jenkins-sg-ingress-https-cidr-blocks" {
	type = list
}

variable "jenkins-sg-ingress-ssh-cidr-blocks" {
	type = list
}

variable "jenkins-config-s3-location" {
	type = string
}
