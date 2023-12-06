#!/bin/bash
#
# Deploy k8s service, virtual service, and register service with the ALB address and custom health check
#
#
SCRIPT_DIR=$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)
unset CONSUL_HTTP_TOKEN
unset CONSUL_HTTP_ADDR
unset DATACENTER
CTX1=""
CTX2=""
TYPE=""
env() {
  kubectl config use-context "${CTX1}"
  export CONSUL_HTTP_TOKEN="$(kubectl -n consul get secret consul-bootstrap-acl-token -o json | jq -r '.data.token'| base64 -d)"
  echo "Setting CONSUL_HTTP_TOKEN=${CONSUL_HTTP_TOKEN}"

  export CONSUL_HTTP_ADDR="$(kubectl -n consul get svc consul-ui -o json | jq -r '.status.loadBalancer.ingress[].hostname'):80"
  echo "Setting CONSUL_HTTP_ADDR=${CONSUL_HTTP_ADDR}"

  export DATACENTER=$(curl --silent ${CONSUL_HTTP_ADDR}/v1/catalog/datacenters | jq -r '.[]')
  echo "Datacenter = ${DATACENTER}"

  # Get ALB Node Info
  export AWS_ALB="$(kubectl -n istio-ingress get ingress --context ${CTX2} -o json | jq -r '.items[].status.loadBalancer.ingress[].hostname')"
  export AWS_ALB_IP=$(dig +short ${AWS_ALB} | head -1)
  export AWS_ALB_NAME="AWS_ALB_${DATACENTER}"
  echo "Env Complete"
}

register_alb() {
  kubectl config use-context "${CTX1}"
	NODE=$(cat <<- EOF
{
  "Datacenter": "${DATACENTER}",
  "Node": "${AWS_ALB_NAME}",
  "Address": "${AWS_ALB}",
  "TaggedAddresses": {
    "lan": "${AWS_ALB_IP}",
    "wan": "${AWS_ALB_IP}"
  },
  "NodeMeta": {
    "external-node": "true",
    "external-probe": "true"
  },
  "Check": {
    "Node": "${AWS_ALB_NAME}",
    "CheckID": "node:health",
    "Name": "node health check",
    "Notes": "TCP health check",
    "Definition": {
      "TCP": "${AWS_ALB}:80",
      "Interval": "5s",
      "Timeout": "1s",
      "DeregisterCriticalServiceAfter": "30s"
    },
    "Namespace": "default"
  },
  "SkipNodeUpdate": false
},
EOF
)
	curl \
		--request PUT \
		--data "${NODE}" \
		--header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" \
		--header "X-Consul-Namespace: default"  \
		http://${CONSUL_HTTP_ADDR}/v1/catalog/register
}

deregister_alb () {
  kubectl config use-context "${CTX1}"
	NODE=$(cat <<- EOF
{
  "Datacenter": "${DATACENTER}",
  "Node": "${AWS_ALB_NAME}"
}
EOF
)
	curl \
		--request PUT \
		--data "${NODE}" \
		--header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" \
		http://${CONSUL_HTTP_ADDR}/v1/catalog/deregister
}

deregister_svc () {
  kubectl config use-context "${CTX2}"
  kubectl delete -f ${SCRIPT_DIR}/../examples/istio-ingress-gw/httpbin.yaml
  kubectl delete -f ${SCRIPT_DIR}/../examples/istio-ingress-gw/httpbin-virtualservice.yaml
  kubectl delete -f ${SCRIPT_DIR}/../examples/istio-ingress-gw/myservice.yaml
  kubectl delete -f ${SCRIPT_DIR}/../examples/istio-ingress-gw/myservice-virtualservice.yaml
}

deploy_myservice () {
  kubectl config use-context "${CTX2}"
  kubectl apply -f ${SCRIPT_DIR}/../examples/istio-ingress-gw/myservice.yaml
  kubectl apply -f ${SCRIPT_DIR}/../examples/istio-ingress-gw/myservice-virtualservice.yaml

  SVC=$(cat <<- EOF
{
  "Node": "${AWS_ALB_NAME}",
  "Address": "${AWS_ALB}",
  "NodeMeta": {
    "external-node": "true",
    "external-probe": "true"
  },
  "Service": {
    "ID": "myservice-${CTX2}",
    "Service": "myservice",
    "Port": 80
  },
  "Checks": [
    {
      "Name": "http-myservice",
      "status": "passing",
      "Definition": {
        "http": "http://${AWS_ALB}/myservice",
        "header": { "Host": ["myservice.example.com"] },
        "interval": "1s",
        "timeout": "5s"
      }
    }
  ],
"SkipNodeUpdate": true
},
EOF
  )

	echo
	echo "Register myservice to Consul"
	echo "curl --silent --header \"X-Consul-Token: ${CONSUL_HTTP_TOKEN}\" --request PUT --data \"${SVC}\" ${CONSUL_HTTP_ADDR}/v1/catalog/register"
	curl --silent --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" --request PUT --data "${SVC}" ${CONSUL_HTTP_ADDR}/v1/catalog/register
	sleep 2
  echo
	echo "Validate myservice : curl -s -I -HHost:myservice.example.com http://${AWS_ALB}/myservice"
	curl -s -I -HHost:myservice.example.com http://${AWS_ALB}/myservice
}

deploy_httpbin () {
  kubectl config use-context "${CTX2}"
  kubectl apply -f ${SCRIPT_DIR}/../examples/istio-ingress-gw/httpbin.yaml
  kubectl apply -f ${SCRIPT_DIR}/../examples/istio-ingress-gw/httpbin-virtualservice.yaml
	SVC=$(cat <<- EOF
{
  "Node": "${AWS_ALB_NAME}",
  "Address": "${AWS_ALB}",
  "NodeMeta": {
    "external-node": "true",
    "external-probe": "true"
  },
  "Service": {
    "ID": "httpbin-${CTX2}",
    "Service": "httpbin",
    "Port": 80
  },
  "Checks": [
    {
      "Name": "http-httpbin",
      "status": "critical",
      "serviceID": "httpbin-${CTX2}",
      "interval": "1s",
      "timeout": "5s",
      "Definition": {
        "http": "http://${AWS_ALB}/status/200",
        "header": { "Host": ["httpbin.example.com"] },
        "interval": "1s",
        "timeout": "5s"
      }
    }
  ],
  "SkipNodeUpdate": true
}
EOF
	)

	echo
	echo "Deploying SVC"
	echo "curl --silent --header \"X-Consul-Token: ${CONSUL_HTTP_TOKEN}\" --request PUT --data \"${SVC}\" ${CONSUL_HTTP_ADDR}/v1/catalog/register"
	curl --silent --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" --request PUT --data "${SVC}" ${CONSUL_HTTP_ADDR}/v1/catalog/register
	sleep 2
	echo "curl -s -I -HHost:httpbin.example.com http://${AWS_ALB}/status/200"
	curl -s -I -HHost:httpbin.example.com http://${AWS_ALB}/status/200
}

usage() { 
  echo "Usage: $0 [-c K8s_appCluster_context ] [-d] [-u]" 1>&2; 
  echo
  echo "Example Deploy: $0 -c west -d"
  echo "Example Undeploy: $0 -c west -u"
  echo "Example Kill httpbin svc in west:  $0 -c west -k"
  exit 1; 
}

while getopts "drkc:" o; do
  case "${o}" in
    d)
      TYPE="deploy"
      ;;
    u)
      TYPE="remove"
      ;;
    c)
      export CTX2="${OPTARG}"
      if [[ ${CTX2} == "west" ]]; then
        echo "Setting K8s CTX1=consul1"
        export CTX1="consul1"
      else
        echo "Setting K8s CTX1=consul2"
        export CTX1="consul2"
      fi
      echo "Setting K8s CTX2=${CTX2}"
      ;;
    k)
      kubectl config use-context west
      kubectl delete deployment httpbin
      ;;
    *)
      usage
      ;;
  esac
done
shift $((OPTIND-1))

if [[ -z $CTX2 ]]; then
	usage
  exit 1
fi

#set Env
env

if [[ ${TYPE} == "deploy" ]]; then
  register_alb
  deploy_myservice
  deploy_httpbin
elif [[ ${TYPE} == "remove" ]]; then
  echo "calling deregister_svc"
  deregister_svc
  deregister_alb
else
  usage
  exit 1
fi

