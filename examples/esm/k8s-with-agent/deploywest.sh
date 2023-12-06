#!/bin/bash
SCRIPT_DIR=$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)

CTX1=consul1
CTX2=west
echo "Using Context: $(kubectl config current-context)"
echo

echo
CONSUL_HTTP_TOKEN="$(kubectl -n consul get secret consul-bootstrap-acl-token -o json | jq -r '.data.token'| base64 -d)"
echo "Setting CONSUL_HTTP_TOKEN=${CONSUL_HTTP_TOKEN}"

CONSUL_HTTP_ADDR="$(kubectl -n consul get svc consul-ui -o json | jq -r '.status.loadBalancer.ingress[].hostname'):80"
echo "Setting CONSUL_HTTP_ADDR=${CONSUL_HTTP_ADDR}"

ESM_DATA=$(curl ${CONSUL_HTTP_ADDR}/v1/catalog/service/consul-esm)
DATACENTER=$(curl --silent ${CONSUL_HTTP_ADDR}/v1/catalog/datacenters | jq -r '.[]')

# Get ALB Node Info
AWS_ALB="$(kubectl -n istio-ingress get ingress --context ${CTX2} -o json | jq -r '.items[].status.loadBalancer.ingress[].hostname')"
AWS_ALB_IP=$(dig +short ${AWS_ALB} | head -1)
AWS_ALB_NAME="AWS_ALB_${DATACENTER}"

deploy_esm () {
	# echo "Deploy myservice-${DATACENTER}"
	# sed "s/myservice/myservice-${DATACENTER}/g" ${SCRIPT_DIR}/myservice.yaml | kubectl apply -f -
	echo "Check if consul-esm service returns metadata..."
	curl --silent ${CONSUL_HTTP_ADDR}/v1/catalog/service/consul-esm | jq -r
	echo

	echo
	echo "Deploying consul-esm"
	sed "s/DATACENTER/${DATACENTER}/g" ${SCRIPT_DIR}/consul-esm.yaml | kubectl apply -f -
	kubectl apply -f ${SCRIPT_DIR}/consul-esm.yaml
	echo

	# echo "Deploying learn-ext.json - http-check"
	# echo "curl --silent --header \"X-Consul-Token: ${CONSUL_HTTP_TOKEN}\" --request PUT --data @${SCRIPT_DIR}/learn-ext.json ${CONSUL_HTTP_ADDR}/v1/catalog/register"
	# curl --silent --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" --request PUT --data @${SCRIPT_DIR}/learn-ext.json ${CONSUL_HTTP_ADDR}/v1/catalog/register
}

register_node() {
	NODE=$(cat <<- EOF
{
    "Datacenter": "${DATACENTER}",
    "Node": "${AWS_ALB_NAME}",
    "Address": "${AWS_ALB}",
    "TaggedAddresses": {
      "lan": "52.88.25.116",
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

deregister_node () {
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

register_svc () {
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

register_svc2 () {
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
  }
EOF
	)

	echo
	echo "Deploying SVC"
	echo "curl --silent --header \"X-Consul-Token: ${CONSUL_HTTP_TOKEN}\" --request PUT --data \"${SVC}\" ${CONSUL_HTTP_ADDR}/v1/catalog/register"
	curl --silent --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" --request PUT --data "${SVC}" ${CONSUL_HTTP_ADDR}/v1/catalog/register
	sleep 2
	echo "curl -s -I -HHost:myservice.example.com http://${AWS_ALB}/myservice"
	curl -s -I -HHost:myservice.example.com http://${AWS_ALB}/myservice
}

deregister_svc () {
	SVC_JSON=$(cat <<- EOF
{"Node": ${AWS_ALB_NAME},"Address": ${AWS_ALB}}
EOF
)
	curl --silent --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" --request PUT --data "${SVC_JSON}" ${CONSUL_HTTP_ADDR}/v1/catalog/deregister
}
node_data() {
  Node=$(cat ${SCRIPT_DIR}/${FILE} | jq -r '.Node')
  Address=$(cat ${SCRIPT_DIR}/${FILE} | jq -r '.Address')
  cat <<EOF
{
  "Node": "$Node",
  "Address": "$Address"
}
EOF
}

consul_esm_data() {
  #Node="ip-10-17-1-202.us-west-2.compute.internal"
  Node=$(echo ${ESM_DATA} | jq -r '.[]."Node"')
  Address=$(echo ${ESM_DATA} | jq -r '.[].NodeMeta."host-ip"')
  ServiceID="$(echo ${ESM_DATA} | jq -r '.[].ServiceID')"
  #Instance="$(echo ${ESM_DATA} | jq -r '.[].Node')"
  cat <<EOF
{
  "Node": "$Node",
  "Address": "$Address",
  "ServiceID": "$ServiceID"
}
EOF
}
delete () {
	#Deregister learn1 as an entity (aka: node), not a service.
	# curl --silent --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" --request PUT --data '{"Node": "hashicorp","Address": "learn.hashicorp.com"}' ${CONSUL_HTTP_ADDR}/v1/catalog/deregister

	Node=$(cat ${SCRIPT_DIR}/${FILE} | jq -r '.Node')
	Address=$(cat ${SCRIPT_DIR}/${FILE} | jq -r '.Address')
	ServiceID=$(cat ${SCRIPT_DIR}/${FILE} | jq -r '.Service.ID')
	
	#recycle client so esm service can be removed.
	kubectl -n consul delete po -l component=client

	# deregister node
	echo "Deleting Service Node"
	#echo "curl --silent --header \"X-Consul-Token: ${CONSUL_HTTP_TOKEN}\" --request PUT --data '{\"Datacenter\": \"dc1\",\"Node\": \"${Node}\"}' ${CONSUL_HTTP_ADDR}/v1/catalog/deregister"
	echo "curl --silent --header \"X-Consul-Token: ${CONSUL_HTTP_TOKEN}\" --request PUT --data '{\"Node\": \"${Node}\",\"Address\": \"${Address}\"}' ${CONSUL_HTTP_ADDR}/v1/catalog/deregister"
	curl --silent --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" --request PUT --data "$(node_data)" ${CONSUL_HTTP_ADDR}/v1/catalog/deregister

	#Deregister service entity
	echo "Deleting Service consul-esm"
	curl --silent --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" --request PUT --data "$(consul_esm_data)"  ${CONSUL_HTTP_ADDR}/v1/catalog/deregister
	echo "curl --silent --header \"X-Consul-Token: ${CONSUL_HTTP_TOKEN}\" --request PUT --data "$(consul_esm_data)"  ${CONSUL_HTTP_ADDR}/v1/catalog/deregister"
	#echo $(consul_esm_data)


	echo "Checking for default learn service..."
	curl --silent ${CONSUL_HTTP_ADDR}/v1/catalog/service/learn | jq -r
	if [[ $? == 0 ]]; then
		# Deregister demo learn service if running
		curl --silent --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" --request PUT --data '{"Node": "hashicorp","Address": "learn.hashicorp.com"}' ${CONSUL_HTTP_ADDR}/v1/catalog/deregister
	fi
	sleep 2
	#curl --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" --request PUT ${CONSUL_HTTP_ADDR}/v1/agent/service/deregister/schemaRegistry
	# curl --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" --request PUT ${CONSUL_HTTP_ADDR}/v1/agent/check/deregister/http-check
	# curl --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" --request PUT ${CONSUL_HTTP_ADDR}/v1/agent/check/deregister/externalNodeHealth
	kubectl delete -f ${SCRIPT_DIR}/consul-esm.yaml
	#sed "s/myservice/myservice-${DATACENTER}/g" ../../esm/k8s-with-agent/myservice.yaml | kubectl delete -f -
}

usage() { 
    echo "Usage: $0 [-f <ext-svc-registration.json> ] [-d]" 1>&2; 
    echo
    echo "Example: $0 -f svc-ext-dc1.json"
	echo "Example: $0 -f svc-ext-dc1.json -d  #delete svc"
    exit 1; 
}

while getopts "diruf:" o; do
    case "${o}" in
        f)
            FILE="${OPTARG}"
            echo "Setting service registration file: $FILE"
            if ! [[ -f $FILE ]]; then
				echo "File does not exist [ $FILE ]"
                usage
				exit 1
            fi
            ;;
		d)
			if [[ -z $FILE ]]; then
				FILE="learn-ext.json"
			fi
            deregister_node
			deregister_svc
			delete
            ;;
		i)
			deploy_esm
			;;
		r)
			register_node
			register_svc
			register_svc2
			;;
		u)
			deregister_node
			deregister_svc
			;;
        *)
            usage
            ;;
    esac
done
shift $((OPTIND-1))

if [[ -z $FILE ]]; then
	FILE="learn-ext.json"
fi