provider "aws" {
  region     = "us-east-1" 
  profile    = "avillachlab-secure-infrastructure"
}

provider "okta" {
  org_name  = "hms-harvard-avillachlab"
  base_url  = "okta.com"
}