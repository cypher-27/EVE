# terraform/backend.tf

terraform {
  backend "s3" {
    bucket         = "devilhunters-terraform-state"
    key            = "lab/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "devilhunters-terraform-lock"
    encrypt        = true
  }
}
