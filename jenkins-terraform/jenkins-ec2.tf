# See the jenkins-local-tf-variables to find how the user-script is being set
data "template_file" "jenkins-user_data" {
  template = file(local.user_script)
  vars = {
    jenkins_tf_state_bucket         = var.jenkins_tf_state_bucket
    stack_id                        = var.stack_id
    jenkins_config_s3_location      = var.jenkins_config_s3_location
    jenkins_docker_maven_distro     = var.jenkins_docker_maven_distro
    jenkins_docker_terraform_distro = var.jenkins_docker_terraform_distro
    jenkins_git_repo                = var.jenkins_git_repo
    git_commit                      = var.git_commit
  }
}

#Lookup latest AMI
data "aws_ami" "this" {
  most_recent = true
  owners      = ["752463128620"]
  name_regex  = "^srce-rhel9-with-docker-golden-*"
}

data "template_cloudinit_config" "config" {
  gzip          = true
  base64_encode = true

  # user_data
  part {
    content_type = "text/x-shellscript"
    content      = data.template_file.jenkins-user_data.rendered
  }
}

resource "aws_instance" "jenkins" {
  ami           = data.aws_ami.this.id
  instance_type = var.jenkins_ec2_instance_type

  iam_instance_profile = var.jenkins_instance_profile_name

  root_block_device {
    delete_on_termination = true
    encrypted             = true
    volume_size           = 1000
  }

  vpc_security_group_ids = [
    aws_security_group.inbound-jenkins.id,
    aws_security_group.outbound-jenkins-to-internet.id
  ]

  subnet_id = var.jenkins_subnet_id

  tags = {
    Owner       = "Avillach_Lab"
    Environment = var.environment_name
    Project     = local.project
    Program     = var.program
    Name        = "${var.program} Jenkins ${local.project} - ${var.stack_id} - ${var.git_commit}"
    InitComplete = "${var.is_initialized}"
  }

  user_data = data.template_cloudinit_config.config.rendered

  lifecycle {
     create_before_destroy = true
  }

}

output "jenkins-ec2-id" {
  value =  aws_instance.jenkins.id
}

output "jenkins-ec2-ip" {
  value =  aws_instance.jenkins.private_ip
}
