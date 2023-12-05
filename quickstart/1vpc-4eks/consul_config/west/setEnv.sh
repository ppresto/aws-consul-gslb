#!/bin/bash

kubectl config use-context west
export TF_VAR_aws_alb="$(kubectl -n istio-ingress get ingress -o json | jq -r '.items[].status.loadBalancer.ingress[].hostname')"

kubectl config use-context consul1
export CONSUL_HTTP_TOKEN=$(kubectl -n consul get secrets consul-bootstrap-acl-token --template "{{.data.token | base64decode }}")
export CONSUL_HTTP_ADDR=$(kubectl -n consul get svc consul-ui -o json | jq -r '.status.loadBalancer.ingress[].hostname')
export CONSUL_DATACENTER="west"