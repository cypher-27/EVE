variable "eve_env" {
  type        = string
  description = "Deployment environment — used for S3 state key scoping"
  default     = "main"
}
