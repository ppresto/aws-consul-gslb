variable "aws_alb" {
  description = "Enter AWS ALB Address or set environment variable"
  type        = string
}

resource "consul_node" "alb" {
  name    = "aws_alb_west"
  address = var.aws_alb
}

resource "consul_service" "httpbin" {
  name = "httpbin"
  node = consul_node.alb.name
  port = 80
  tags = ["v1"]
  check {
    check_id                          = "service:httpbin"
    name                              = "httpbin health check"
    # status                            = "critical"
    http                              = "http://${consul_node.alb.name}:80/status/200"
    tls_skip_verify                   = true
    method                            = "GET"
    interval                          = "5s"
    timeout                           = "1s"
    deregister_critical_service_after = "30s"
    header {
      name  = "Host"
      value = ["httpbin.example.com"]
    }
  }
}
resource "consul_service" "myservice" {
  name = "myservice"
  node = consul_node.alb.name
  port = 80
  tags = ["v1"]
  check {
    check_id                          = "service:myservice"
    name                              = "myservice health check"
    # status                            = "critical"
    http                              = "http://${consul_node.alb.name}:80/myservice"
    # tls_skip_verify                   = false
    method                            = "GET"
    interval                          = "5s"
    timeout                           = "1s"
    deregister_critical_service_after = "30s"

    header {
      name  = "foo"
      value = ["test"]
    }
  }
}