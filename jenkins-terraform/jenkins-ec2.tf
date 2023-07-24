resource "tls_private_key" "provisioning-key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

output "provisioning-private-key" {
  value = tls_private_key.provisioning-key.private_key_pem
}

resource "aws_key_pair" "generated_key" {
  key_name   = "jenkins-provisioning-key-${var.stack_id}-${var.git_commit}"
  public_key = tls_private_key.provisioning-key.public_key_openssh
}

# See the jenkins-local-tf-variables to find how the user-script is being set
data "template_file" "jenkins-user_data" {
  template = file(local.user_script)
  vars = {
    stack_s3_bucket = var.stack_s3_bucket
    stack_id = var.stack_id
    jenkins_config_s3_location = var.jenkins_config_s3_location
    jenkins_docker_maven_distro = var.jenkins_docker_maven_distro
    jenkins_docker_terraform_distro = var.jenkins_docker_terraform_distro
  }
}

#Lookup latest AMI
data "aws_ami" "centos" {
  most_recent      = true
  executable_users = ["self"]
  name_regex       = "^srce-centos7-golden-*"
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
  ami = data.aws_ami.centos.id
  instance_type = var.jenkins_ec2_instance_type
  associate_public_ip_address = false
  key_name = aws_key_pair.generated_key.key_name

  iam_instance_profile = var.jenkins_instance_profile_name

  root_block_device {
    delete_on_termination = true
    encrypted = true
    volume_size = 1000
  }

# This should be moved to the new distro folder and handled better
  provisioner "file" {
    source      = "../jenkins-docker"
    destination = "/home/centos/jenkins"
    connection {
      type     = "ssh"
      user     = "centos"
      private_key = tls_private_key.provisioning-key.private_key_pem
      host = self.private_ip
    }
  }

  vpc_security_group_ids = [
    aws_security_group.inbound-jenkins.id,
    aws_security_group.outbound-jenkins-to-internet.id
  ]

  subnet_id = var.jenkins_subnet_id

  tags = {
    Owner       = "Avillach_Lab"
    Environment = "development"
    Name        = "BdC Jenkins - ${var.stack_id} - ${var.git_commit}"
  }

  user_data = data.template_cloudinit_config.config.rendered

}
