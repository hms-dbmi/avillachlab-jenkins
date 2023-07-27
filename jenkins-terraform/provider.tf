provider "aws" {
  region  = "us-east-1"
  profile = "avillachlab-secure-infrastructure"
  version = "3.74"
}

# currenlty using default AES encryption
terraform {
  backend "s3" {
    encrypt = true
  }
}