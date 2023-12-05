provider "aws" {
  region = "us-west-2"
}

provider "aws" {
  alias  = "usw2"
  region = "us-west-2"
}

terraform {
  required_version = ">= 1.3.7"

  required_providers {
    consul = {
      source  = "hashicorp/consul"
      version = "~> 2.20.0"
    }
  }
}

provider "consul" {
  alias = "usw2"
  datacenter = "west"
  # address    = module.hcp_consul_use1[local.hvn_list_use1[0]].consul_public_endpoint_url
  # token      = module.hcp_consul_use1[local.hvn_list_use1[0]].consul_root_token_secret_id
}