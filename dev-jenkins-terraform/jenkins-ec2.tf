resource "tls_private_key" "provisioning-key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}
output "provisioning-private-key" {
  value = tls_private_key.provisioning-key.private_key_pem
}
resource "aws_key_pair" "generated_key" {
  key_name   = "jenkins-provisioning-key"
  public_key = "${tls_private_key.provisioning-key.public_key_openssh}"
}

data "template_cloudinit_config" "config" {
  gzip          = true
  base64_encode = true

  # user_data
  part {
    content_type = "text/x-shellscript"
    content      = file("install-docker.sh")
  }

}

resource "aws_instance" "dev-jenkins" {
  ami = "ami-02eac2c0129f6376b"
  instance_type = "m5.xlarge"
  associate_public_ip_address = true
  key_name = "jenkins-provisioning-key"

  root_block_device {
    delete_on_termination = true
    encrypted = true
    volume_size = 50
  }

  provisioner "file" {
    source      = "../jenkins-docker"
    destination = "/home/centos/jenkins"
    connection {
      type     = "ssh"
      user     = "centos"
      private_key = tls_private_key.provisioning-key.private_key_pem
      host = self.public_ip
    }
  }

  vpc_security_group_ids = [
    aws_security_group.inbound-jenkins-from-lma.id,
    aws_security_group.outbound-jenkins-to-internet.id
  ]

  subnet_id = aws_subnet.jenkins-subnet-us-east-1a.id

  tags = {
    Owner       = "Avillach_Lab"
    Environment = "development"
    Name        = "FISMA Terraform Playground - Dev Jenkins"
  }

  user_data = data.template_cloudinit_config.config.rendered

}
