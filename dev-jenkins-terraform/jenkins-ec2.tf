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
  }
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
  ami = "ami-06dde3c94732d0811"
  instance_type = "m5.xlarge"
  associate_public_ip_address = false
  key_name = aws_key_pair.generated_key.key_name

  iam_instance_profile = var.instance-profile-name

  root_block_device {
    delete_on_termination = true
    encrypted = true
    volume_size = 1000
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
