terraform {
  backend "s3" {
    bucket       = "terraform-state-nickawilliams"
    key          = "525999333867/us-west-1/nickawilliams/common/mcp/terraform.tfstate"
    region       = "us-west-1"
    use_lockfile = true
  }
}
