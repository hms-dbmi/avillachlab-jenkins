resource "aws_vpc" "dev-jenkins-vpc" {
  cidr_block = "172.20.0.0/16"
  instance_tenancy = "default"

  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Owner       = "Avillach_Lab"
    Environment = "development"
    Name        = "FISMA Terraform Playground - Dev Jenkins VPC"
  }

}

resource "aws_subnet" "jenkins-subnet-us-east-1a" {
  availability_zone = "us-east-1a"
  cidr_block = "172.20.0.0/19"
  vpc_id = aws_vpc.dev-jenkins-vpc.id
  tags = {
    Owner       = "Avillach_Lab"
    Environment = "development"
    Name        = "FISMA Terraform Playground - Dev Jenkins VPC Subnet us-east-1a"
  }
}

resource "aws_default_security_group" "app-default" {
  vpc_id = aws_vpc.dev-jenkins-vpc.id

  tags = {
    Owner       = "Avillach_Lab"
    Environment = "development"
    Name        = "FISMA Terraform Playground - Dev Jenkins Security Group"
  }
}

resource "aws_internet_gateway" "dev-jenkins-gw" {
  vpc_id = aws_vpc.dev-jenkins-vpc.id

  tags = {
    Owner       = "Avillach_Lab"
    Environment = "development"
    Name        = "FISMA Terraform Playground - Dev Jenkins Internet Gateway"
  }  
}

resource "aws_route_table" "dev-jenkins-route-table" {
  vpc_id = aws_vpc.dev-jenkins-vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.dev-jenkins-gw.id
  }
  tags = {
    Owner       = "Avillach_Lab"
    Environment = "development"
    Name        = "FISMA Terraform Playground - Dev Jenkins Route Table"
  }
}

resource "aws_route_table_association" "dev-jenkins-route-table-association" {
  subnet_id = aws_subnet.jenkins-subnet-us-east-1a.id
  route_table_id = aws_route_table.dev-jenkins-route-table.id
}
