data "template_cloudinit_config" "config" {
  gzip          = true
  base64_encode = true

  part {
    content_type = "text/cloud-config"
    content = <<EOF
write_files:
  - content: |
      ${base64encode(file("../jenkins-docker/Dockerfile"))}
    encoding: b64
    owner: root:root
    path: /home/centos/jenkins/Dockerfile
    permissions: '0644'
  - content: |
      ${base64encode(file("../jenkins-docker/docker-compose.yml"))}
    encoding: b64
    owner: root:root
    path: /home/centos/jenkins/docker-compose.yml
    permissions: '0644'
  - content: |
      ${base64encode(file("../jenkins-docker/docker-compose-install-plugins.yml"))}
    encoding: b64
    owner: root:root
    path: /home/centos/jenkins/docker-compose-install-plugins.yml
    permissions: '0644'
  - content: |
      ${base64encode(file("../jenkins-config/plugins.txt"))}
    encoding: b64
    owner: root:root
    path: /opt/local/jenkins_home/plugins.txt
    permissions: '0644'
  - content: |
      ${base64encode(file("../jenkins-config/config.xml"))}
    encoding: b64
    owner: root:root
    path: /opt/local/jenkins_home/config.xml
    permissions: '0644'
  - content: |
      ${filebase64("../jenkins-config/jobs.tar.gz")}
    encoding: b64
    owner: root:root
    path: /opt/local/jenkins_home/jobs.tar.gz
    permissions: '0644'
EOF
  }

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
  key_name = "jps49"

  root_block_device {
    delete_on_termination = true
    encrypted = true
    volume_size = 50
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
