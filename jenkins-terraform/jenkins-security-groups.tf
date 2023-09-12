resource "aws_security_group" "inbound-jenkins" {
  name        = "allow_inbound_to_jenkins_vpc_${var.stack_id}_${var.git_commit}"
  description = "Allow inbound traffic on Ports 80 and 443"
  vpc_id      = var.jenkins_vpc_id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.jenkins_sg_ingress_https_cidr_blocks
  }

  tags = {
    Owner       = "Avillach_Lab"
    Environment = var.environment_name
    Project     = local.project
    Name        = "inbound-jenkins-from-lma Security Group - ${var.stack_id}"
  }
}

resource "aws_security_group" "outbound-jenkins-to-internet" {
  name        = "allow_jenkins_outbound_to_internet_${var.stack_id}_${var.git_commit}"
  description = "Allow outbound traffic from Jenkins"
  vpc_id      = var.jenkins_vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = -1
    cidr_blocks = var.jenkins_sg_egress_allow_all_cidr_blocks
  }

  tags = {
    Owner       = "Avillach_Lab"
    Environment = var.environment_name
    Project     = local.project
    Name        = "outbound-jenkins-to-internet Security Group - ${var.stack_id}"
  }
}
