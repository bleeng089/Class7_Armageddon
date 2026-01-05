terraform {
  backend "s3" {
    bucket = "walid-backend-089.com"
    key    = "terraformv2.tfstate"
    region = "us-east-1"
  }
}