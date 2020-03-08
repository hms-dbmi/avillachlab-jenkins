resource "tls_private_key" "provisioning-key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}
output "provisioning-private-key" {
  value = tls_private_key.provisioning-key.private_key_pem
}
resource "aws_key_pair" "generated_key" {
  key_name   = "jenkins-provisioning-key-${var.stack-id}-${var.git-commit}"
  public_key = tls_private_key.provisioning-key.public_key_openssh
}


data "template_file" "jenkins-user_data" {
  template = file("install-docker.sh")
  vars = {
    stack_s3_bucket = var.stack-s3-bucket
    stack_id = var.stack-id
    stack_jenkins_dockerfile = var.stack-jenkins-dockerfile
  }
}

data "entity_id" {
  value = regex("[[:alnum:]]+$", "${data.okta_app_metadata_saml.jenkins-saml.entity_id}")

}

data "template_file" "jenkins-config-xml" {
  template = file("../jenkins-docker/${var.config-xml-filename}")
  vars = {
   // okta_saml_app_id = regex("[[:alnum:]]+$", "${data.okta_app_metadata_saml.jenkins-saml.entity_id}")
    okta_saml_app_id = data.entity_id
    aws_account_app = var.aws-account-app
    arn_role_app = var.arn-role-app
    arn_role_cnc = var.arn-role-cnc
    arn_role_data = var.arn-role-data
    git_branch_avillachlab_secure_infrastructure = var.git-branch-avillachlab-secure-infrastructure
    git_branch_avillachlab_jenkins_dev_release_control = var.git-branch-avillachlab-jenkins-dev-release-control
    stack_s3_bucket = var.stack-s3-bucket
    jenkins_role_admin_name = var.jenkins-role-admin-name
  }
  //depends_on = [okta_app_metadata_saml.jenkins-saml]
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

resource "aws_instance" "dev-jenkins" {
  ami = var.cis-centos-linux-ami-id
  instance_type = "m5.xlarge"
  associate_public_ip_address = true
  key_name = aws_key_pair.generated_key.key_name

  iam_instance_profile = var.instance-profile-name

  root_block_device {
    delete_on_termination = true
    encrypted = true
    volume_size = 500
  }

output "jenkins_public_dns" {
  value = aws_instance.dev-jenkins.public_dns
}

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

  provisioner "file" {
    content = data.template_file.jenkins-config-xml.rendered
    destination = "/home/centos/jenkins/config.xml"
    connection {
      type     = "ssh"
      user     = "centos"
      private_key = tls_private_key.provisioning-key.private_key_pem
      host = self.private_ip
    }
  }

  vpc_security_group_ids = [
    aws_security_group.inbound-jenkins-from-lma.id,
    aws_security_group.outbound-jenkins-to-internet.id
  ]

  subnet_id = var.subnet-id

  tags = {
    Owner       = "Avillach_Lab"
    Environment = "development"
    Name        = "FISMA Terraform Playground - Dev Jenkins - ${var.stack-id} - ${var.git-commit}"
  }

  user_data = data.template_cloudinit_config.config.rendered

}
