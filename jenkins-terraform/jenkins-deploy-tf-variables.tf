#  local / dynamic variables can be found in jenkins-local-tf-variables.tf

variable "stack_id" {
  type    = string
  default = "test"
}

variable "git_commit" {
  type = string
}

variable "jenkins_vpc_id" {
  type = string
}

variable "jenkins_instance_profile_name" {
  type = string
}

variable "stack_s3_bucket" {
  type = string
}

variable "jenkins_subnet_id" {
  type = string
}

variable "jenkins_sg_egress_allow_all_cidr_blocks" {
  type = list(any)
}

variable "jenkins_sg_ingress_https_cidr_blocks" {
  type = list(any)
}

variable "jenkins_config_s3_location" {
  type = string
}

variable "jenkins_ec2_instance_type" {
  type = string
}

variable "jenkins_tf_local_var_OS_dist" {
  type = string

  # in terraform .13 variable validations are no longer experimental and is production ready.
  # use this validations when upgrading to terraform .13
  # will not implement .12 experimental features
  #validation {
  #  condition = contains(local.valid_os,var.jenkins_tf_local_var_OS_dist)
  #  error_message = "Unsupported OS Distribution - Check the Terraform accepted valid_os list"
  #}
}

variable "jenkins_ec2_ebs_volume_size" {
  type = number
}

variable "jenkins_docker_maven_distro" {
  type = string
}

variable "jenkins_docker_terraform_distro" {
  type = string
}

variable "jenkins_git_repo" {
  type = string
}

variable "program" {
  type = string
}

variable "env_is_open_access" {
  type = bool
}

variable "environment_name" {
  type    = string
  default = "dev"
}
