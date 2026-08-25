# terraform/backend.tf

terraform {
  backend "s3" {
    bucket         = "devilhunters-terraform-state"
    key            = "lab/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true

    # S3-native locking (Terraform 1.11+, GA). Preferred going forward —
    # uses S3 conditional writes (If-None-Match), no DynamoDB required.
    use_lockfile = true

    # Deprecated (kept only during the migration window). Terraform will
    # acquire BOTH locks while this is present. Once we've confirmed
    # use_lockfile works cleanly across a few real applies, remove this
    # line and delete the "devilhunters-terraform-lock" DynamoDB table.
    dynamodb_table = "devilhunters-terraform-lock"
  }
}
