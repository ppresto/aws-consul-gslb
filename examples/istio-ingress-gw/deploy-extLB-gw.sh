#!/bin/bash
#
#  PREREQ - install Istio Ingress GW
#   ../../scripts/install_istio_ingress_gw.sh
#
TYPE_CHECK=$(kubectl -n istio-ingress get svc istio-ingress -o json | jq -r '.spec.type')
if [[ $TYPE_CHECK == "LoadBalancer" ]]; then
  echo "SUCCESSFUL CHECK... istio-ingress Type = 'LoadBalancer'"
else
  echo "ERROR - istio-ingress Type is not LoadBalancer!  Type = $TYPE_CHECK"
  echo "Reconfigure istio-ingress Type to LoadBalancer"
  exit
fi

SCRIPT_DIR=$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)

deploy_istioingressgateway () {
  kubectl apply -f ${SCRIPT_DIR}/istio-gateway.yaml
}

deploy_myservice () {
    kubectl apply -f ${SCRIPT_DIR}/myservice.yaml
    kubectl apply -f ${SCRIPT_DIR}/myservice-virtualservice.yaml
}

deploy_httpbin () {
# deploy httpbin istio sample app
# curl https://raw.githubusercontent.com/istio/istio/release-1.20/samples/httpbin/httpbin.yaml | kubectl apply -f -
  kubectl apply -f ${SCRIPT_DIR}/httpbin.yaml
  kubectl apply -f ${SCRIPT_DIR}/httpbin-virtualservice.yaml
}

get_aws_ingress () {
  export INGRESS_NAME=istio-ingress
  export INGRESS_NS=istio-ingress
  # For ingress-GW type:NodePort Setup host and ports.  Recommend using type:LoadBalancer for ingress-gw
  # export INGRESS_HOST=$(kubectl get po -l istio=ingress -n "${INGRESS_NS}" -o jsonpath='{.items[0].status.hostIP}')
  # export INGRESS_PORT=$(kubectl -n "${INGRESS_NS}" get service "${INGRESS_NAME}" -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}')
  # export SECURE_INGRESS_PORT=$(kubectl -n "${INGRESS_NS}" get service "${INGRESS_NAME}" -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')
  # export TCP_INGRESS_PORT=$(kubectl -n "${INGRESS_NS}" get service "${INGRESS_NAME}" -o jsonpath='{.spec.ports[?(@.name=="tcp")].nodePort}')
  
  # For ingress-GW type:LoadBalancer
  export INGRESS_HOST=$(kubectl -n "$INGRESS_NS" get service "$INGRESS_NAME" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
  export INGRESS_PORT=$(kubectl -n "$INGRESS_NS" get service "$INGRESS_NAME" -o jsonpath='{.spec.ports[?(@.name=="http2")].port}')
  export SECURE_INGRESS_PORT=$(kubectl -n "$INGRESS_NS" get service "$INGRESS_NAME" -o jsonpath='{.spec.ports[?(@.name=="https")].port}')
  export TCP_INGRESS_PORT=$(kubectl -n "$INGRESS_NS" get service "$INGRESS_NAME" -o jsonpath='{.spec.ports[?(@.name=="tcp")].port}')

  echo "Calling httpbin - curl -s -I -HHost:httpbin.example.com http://$INGRESS_HOST:$INGRESS_PORT/status/200"
  curl -s -I -HHost:httpbin.example.com "http://$INGRESS_HOST:$INGRESS_PORT/status/200"
  echo
  echo "Calling myservice - curl -s -I -HHost:httpbin.example.com http://$INGRESS_HOST:$INGRESS_PORT/myservice"
  curl -s -I -HHost:httpbin.example.com "http://$INGRESS_HOST:$INGRESS_PORT/myservice"
  echo
  # kubectl get gateways --all-namespaces
  # kubectl get ingress --all-namespaces
}

delete () {
  kubectl delete -f ${SCRIPT_DIR}/istio-gateway.yaml
  kubectl delete -f ${SCRIPT_DIR}/myservice.yaml
  kubectl delete -f ${SCRIPT_DIR}/myservice-virtualservice.yaml
   # curl https://raw.githubusercontent.com/istio/istio/release-1.20/samples/httpbin/httpbin.yaml | kubectl delete --ignore-not-found=true -f -
  kubectl delete -f ${SCRIPT_DIR}/httpbin.yaml
  kubectl delete -f ${SCRIPT_DIR}/httpbin-virtualservice.yaml
}

#Cleanup if any param is given on CLI
if [[ ! -z $1 ]]; then
    echo "Deleting Services"
    delete
else
    echo "Deploying Services"
    deploy_istioingressgateway
    deploy_myservice
    deploy_httpbin
    get_aws_ingress
fi