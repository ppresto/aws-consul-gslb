#!/bin/bash

SCRIPT_DIR=$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)

install () {
    # Download
    helm repo add istio https://istio-release.storage.googleapis.com/charts
    helm repo update

    kubectl create namespace istio-system
    # CRDs required by the control plane
    helm install istio-base istio/base -n istio-system --set defaultRevision=default
    #verify CRD installation
    helm ls -n istio-system
    helm install istiod istio/istiod -n istio-system --debug --wait
    #verify istio discovery chart installation
    helm ls -n istio-system
    helm status istiod -n istio-system
    #verify istiod service
    kubectl get deployments -n istio-system --output wide


    #Install Istio Ingress Gateway
    kubectl create namespace istio-ingress
    kubectl label namespace istio-ingress istio-injection=enabled
    kubectl get namespace -L istio-injection
    helm install istio-ingress istio/gateway -n istio-ingress -f ${SCRIPT_DIR}/../examples/istio-ingress-gw/helm/values.yaml --debug --wait
}

deploy_httpbin () {
# deploy httpbin istio sample app
# curl https://raw.githubusercontent.com/istio/istio/release-1.20/samples/httpbin/httpbin.yaml | kubectl apply -f -
kubectl apply -f - <<EOF
# Copyright Istio Authors
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.

##################################################################################################
# httpbin service
##################################################################################################
apiVersion: v1
kind: ServiceAccount
metadata:
  name: httpbin
---
apiVersion: v1
kind: Service
metadata:
  name: httpbin
  labels:
    app: httpbin
    service: httpbin
spec:
  ports:
  - name: http
    port: 8000
    targetPort: 80
  selector:
    app: httpbin
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpbin
spec:
  replicas: 1
  selector:
    matchLabels:
      app: httpbin
      version: v1
  template:
    metadata:
      labels:
        app: httpbin
        version: v1
    spec:
      serviceAccountName: httpbin
      containers:
      - image: docker.io/kong/httpbin
        imagePullPolicy: IfNotPresent
        name: httpbin
        ports:
        - containerPort: 80
EOF
    kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: Gateway
metadata:
  name: httpbin-gateway
spec:
  # The selector matches the ingress gateway pod labels.
  # If you installed Istio using Helm following the standard documentation, this would be "istio=ingress"
  selector:
    istio: ingress
  servers:
  - port:
      number: 80
      name: http
      protocol: HTTP
    hosts:
    - "httpbin.example.com"
EOF

    kubectl apply -f - <<EOF
apiVersion: networking.istio.io/v1alpha3
kind: VirtualService
metadata:
  name: httpbin
spec:
  hosts:
  - "httpbin.example.com"
  gateways:
  - httpbin-gateway
  http:
  - match:
    - uri:
        prefix: /status
    - uri:
        prefix: /delay
    route:
    - destination:
        port:
          number: 8000
        host: httpbin
EOF
    
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

    echo "INGRESS_HOST=$INGRESS_HOST, INGRESS_PORT=$INGRESS_PORT"
    # kubectl get gateways --all-namespaces
    # kubectl get ingress --all-namespaces
}

delete () {
    helm delete istio-ingress -n istio-ingress --debug
    kubectl delete namespace istio-ingress
    helm delete istiod -n istio-system --debug
    helm delete istio-base -n istio-system
    kubectl delete namespace istio-system
    # Delete Istio CRDs
    kubectl get crd -oname | grep --color=never 'istio.io' | xargs kubectl delete
}

#Cleanup if any param is given on CLI
if [[ ! -z $1 ]]; then
    echo "Deleting Services"
    delete
else
    echo "Deploying Services"
    install
    #deploy_httpbin
fi