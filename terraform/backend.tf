# terraform/backend.tf
# El key se inyecta dinámicamente según el entorno (dev/main)
# Ver orchestrator.sh -> terraform_init()

terraform {
  backend "s3" {
    bucket         = "devilhunters-terraform-state"
    key            = "lab/terraform.tfstate"  # Override via -backend-config
    region         = "us-east-1"
    dynamodb_table = "devilhunters-terraform-lock"
    encrypt        = true
  }
}
