resource "aws_security_group" "inbound-jenkins-from-lma" {
  name = "allow_inbound_from_lma_subnet_to_jenkins_vpc_${var.stack-id}_${var.git-commit}"
  description = "Allow inbound traffic from LMA on ports 22, 80 and 443"
  vpc_id = var.vpc-id

  ingress {
    from_port = 80
    to_port = 80
    protocol = "tcp"
    cidr_blocks = [
      var.access-cidr
    ]
  }

  ingress {
    from_port = 443
    to_port = 443
    protocol = "tcp"
    cidr_blocks = [
      var.access-cidr
    ]
  }

  ingress {
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = [
      var.access-cidr
    ]
  }

  ingress {
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = [
      var.provisioning-cidr
    ]
  }

  tags = {
    Owner       = "Avillach_Lab"
    Environment = "development"
    Name        = "FISMA Terraform Playground - inbound-jenkins-from-lma Security Group - ${var.stack-id}"
  }
}

resource "aws_security_group" "outbound-jenkins-to-internet" {
  name = "allow_jenkins_outbound_to_internet_${var.stack-id}_${var.git-commit}"
  description = "Allow outbound traffic from Jenkins"
  vpc_id = var.vpc-id

  egress {
    from_port = 0
    to_port = 0
    protocol = -1
    cidr_blocks = [
       "0.0.0.0/0"
    ]
  }

  tags = {
    Owner       = "Avillach_Lab"
    Environment = "development"
    Name        = "FISMA Terraform Playground - outbound-jenkins-to-internet Security Group - ${var.stack-id}"
  }
}
