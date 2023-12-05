#!/bin/bash
#
#  PREREQ - install Istio Ingress GW configured with NodePort (not LoadBalancer).
#   ../../scripts/install_istio_ingress_gw.sh
#

TYPE_CHECK=$(kubectl -n istio-ingress get svc istio-ingress -o json | jq -r '.spec.type')
if [[ $TYPE_CHECK == "NodePort" ]]; then
  echo "SUCCESSFUL CHECK... istio-ingress Type = 'NodePort'"
else
  echo "ERROR - istio-ingress Type is not NodePort!  Type = $TYPE_CHECK"
  echo "Reconfigure istio-ingress Type to NodePort"
  exit
fi
SCRIPT_DIR=$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)

deploy_istioingressgateway () {
  kubectl apply -f ${SCRIPT_DIR}/istio-gateway.yaml
}

deploy_ingress_controller () {
  kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: "istio-ingress"
  namespace: "istio-ingress"
  labels:
    istio: ingress
    app: istio-ingress
  annotations: 
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/target-type: instance
    alb.ingress.kubernetes.io/scheme: internet-facing
spec:
  ingressClassName: alb
  rules:
    - host:
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: "istio-ingress"
                port:
                  number: 80
EOF

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

validate_aws_ingress () {
  export INGRESS_NAME=istio-ingress
  export INGRESS_NS=istio-ingress
  # For ingress-GW type:NodePort Setup host and ports.  This assumes an ALB is routing traffic to the NodePort.
  export INGRESS_HOST=$(kubectl get po -l istio=ingress -n "${INGRESS_NS}" -o jsonpath='{.items[0].status.hostIP}')
  export INGRESS_PORT=$(kubectl -n "${INGRESS_NS}" get service "${INGRESS_NAME}" -o jsonpath='{.spec.ports[?(@.name=="http2")].nodePort}')
  export SECURE_INGRESS_PORT=$(kubectl -n "${INGRESS_NS}" get service "${INGRESS_NAME}" -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')
  export TCP_INGRESS_PORT=$(kubectl -n "${INGRESS_NS}" get service "${INGRESS_NAME}" -o jsonpath='{.spec.ports[?(@.name=="tcp")].nodePort}')
  
  # # For ingress-GW type:LoadBalancer
  # export INGRESS_HOST=$(kubectl -n "$INGRESS_NS" get service "$INGRESS_NAME" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
  # export INGRESS_PORT=$(kubectl -n "$INGRESS_NS" get service "$INGRESS_NAME" -o jsonpath='{.spec.ports[?(@.name=="http2")].port}')
  # export SECURE_INGRESS_PORT=$(kubectl -n "$INGRESS_NS" get service "$INGRESS_NAME" -o jsonpath='{.spec.ports[?(@.name=="https")].port}')
  # export TCP_INGRESS_PORT=$(kubectl -n "$INGRESS_NS" get service "$INGRESS_NAME" -o jsonpath='{.spec.ports[?(@.name=="tcp")].port}')
  sleep 5
  echo "Validate NodePort - httpbin: kubectl exec -it deploy/myservice-deployment -- curl -s -I -HHost:httpbin.example.com http://$INGRESS_HOST:$INGRESS_PORT/status/200"
  kubectl exec -it deploy/myservice-deployment -- curl -s -I -HHost:httpbin.example.com http://$INGRESS_HOST:$INGRESS_PORT/status/200
  echo
  echo "Validate NodePort - myservice:  kubectl exec -it deploy/myservice-deployment -- curl -s -I -HHost:httpbin.example.com http://$INGRESS_HOST:$INGRESS_PORT/myservice"
  kubectl exec -it deploy/myservice-deployment -- curl -s -I -HHost:httpbin.example.com http://$INGRESS_HOST:$INGRESS_PORT/myservice
  echo
  Ingress_URL=$(kubectl -n istio-ingress get ingress -o json | jq -r '.items[].status.loadBalancer.ingress[].hostname')
  echo "Wait a Minute - Validate AWS ALB to Istio Ingress GW after Ext DNS is resolvable"
  echo "    nslookup ${Ingress_URL}"
  echo "    curl -s -I -HHost:httpbin.example.com http://${Ingress_URL}/status/200"
  echo "    curl -s http://${Ingress_URL}/"
  curl -s -I -HHost:httpbin.example.com http://${Ingress_URL}/status/200
  curl -s -I http://${Ingress_URL}/
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
  kubectl -n istio-ingress delete ingress istio-ingress
}

#Cleanup if any param is given on CLI
if [[ ! -z $1 ]]; then
    echo "Deleting Services"
    delete
else
    echo "Deploying Services"
    deploy_ingress_controller
    deploy_istioingressgateway
    deploy_myservice
    deploy_httpbin
    validate_aws_ingress
fi