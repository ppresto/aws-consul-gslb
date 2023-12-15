# Use Consul to provide Global Service Load Balancing with a minimal footprint

![Consul ESM](https://github.com/ppresto/aws-consul-gslb/blob/main/corelogic-sd.png?raw=true)


- [Use Consul to provide Global Service Load Balancing with a minimal footprint](#use-consul-to-provide-global-service-load-balancing-with-a-minimal-footprint)
- [aws-consul-gslbonly](#aws-consul-gslbonly)
  - [Getting Started](#getting-started)
    - [Pre Reqs](#pre-reqs)
  - [Provision Infrastructure](#provision-infrastructure)
  - [Install Consul](#install-consul)
    - [Upgrade consul to run agents](#upgrade-consul-to-run-agents)
    - [Review Consul UI's](#review-consul-uis)
  - [Deploy ESM on K8s with an agent](#deploy-esm-on-k8s-with-an-agent)
    - [Configure Consul DNS on EKS](#configure-consul-dns-on-eks)
  - [Setup Peering between both Datacenters for Failover](#setup-peering-between-both-datacenters-for-failover)
  - [Create Prepared Query](#create-prepared-query)
  - [Quick Start - Demo Steps](#quick-start---demo-steps)
    - [PreReq:](#prereq)
    - [Review Environment](#review-environment)
    - [Deploy and register services (West) to ESM](#deploy-and-register-services-west-to-esm)
    - [Peer West to Central](#peer-west-to-central)
      - [DNS and httpbin validation](#dns-and-httpbin-validation)
    - [Kill httpbin service (West) to show failover](#kill-httpbin-service-west-to-show-failover)
      - [Failover validation](#failover-validation)
  - [Clean Up](#clean-up)
  - [Appendix](#appendix)
    - [Consul DNS](#consul-dns)
    - [Deploy ESM on VM with Consul agent](#deploy-esm-on-vm-with-consul-agent)
# aws-consul-gslbonly
This repo builds the required AWS Networking and EKS resources

## Getting Started

### Pre Reqs
- Consul Enterprise License `./files/consul.lic`
- Setup shell with AWS credentials 
- Create AWS EC2 Key Pair (ssh key) in us-west-2 or target region
- Terraform 1.3.7+
- aws cli
- kubectl
- helm

## Provision Infrastructure
Edit the `quickstart/4vpc-2eks/my.auto.tfvars` and replace the `ec2_key_pair_name` value with your AWS key pair name.  Then use Terraform to build the required AWS Infrastructure.
```
cd quickstart/4vpc-2eks
terraform init
terraform apply -auto-approve
```

Connect to EKS using `scripts/kubectl_connect_eks.sh`.  Pass this script the path to the terraform state file used to provision the EKS cluster.  If cwd is ./1vpc-4eks like above then this command would look like the following:
```
source ../../scripts/kubectl_connect_eks.sh .
```

Install the AWS Load Balancer Controller addon to EKS from the terraform directory.
```
../../scripts/install_awslb_controller.sh .
```
This is used to create an NLB for Consul mesh gateways to enable Peering, and an external NLB for the Consul UI.

Install Istio Ingress GW to use Nodeport.  Verify `./examples/istio-ingress-gw/helm/values.yaml`
```
# change ctx to application k8s cluster
kubectl config set-context west
../../scripts/install_istio_ingress_gw.sh
```
Repeat for all application k8s clusters
```
kubectl config set-context central
../../scripts/install_istio_ingress_gw.sh
```

Deploy services | virtual services | aws ingress to route to Istio GW Nodeport
```
kubectl config set-context west
../../examples/istio-ingress-gw/deploy-nodePort-gw-with-aws-ingress.sh
```
Verify Services and routes are working. Repeat for all app k8s clusters
```
kubectl config set-context central
../../examples/istio-ingress-gw/deploy-nodePort-gw-with-aws-ingress.sh
```

## Install Consul
```
cd consul_helm_values
terraform init
terraform apply -auto-approve
```

### Upgrade consul to run agents
An agent should be deployed to K8s if using this repo's infrastructure so skip this step.  The terraform above creates a helm values file when installing Consul.  This can be found for each Consul cluster.  For example, consul1 cluster used these helm values `./quickstart/1vpc-2eks/consul_helm_values/yaml/auto-consul-vpc1-consul1-values-server-sd.yaml`.  This file can be used directly with `helm upgrade` to test various configurations.  


Example: Running helm upgrade
```
RELEASE=$(helm -n consul list -o json | jq -r '.[].name')
helm upgrade ${RELEASE} hashicorp/consul --namespace consul --values ./yaml/auto-consul-vpc1-consul1-values-server-sd.yaml
```
If you're building Consul outside of this repo ensure the helm values are set properly.

### Review Consul UI's
Login to the consul UI to see the new ext svc and consul-esm svc registered. Get the Consul URL and token for the current k8s context using the following script.  Review both Consul clusters.
```
consul1
../../scripts/setConsulEnv.sh
consul2
../../scripts/setConsulEnv.sh
```

## Deploy ESM on K8s with an agent
Connect to the EKS cluster hosting Consul and set your current K8s context to the first EKS cluster `consul1`.
The script below will register the default external learn svc if no arguments are given.  To test failover on specific ext services across DCs skip this step and there will be an option later to register an external service on VM (fake-service).
```
# swtich ctx to consul k8s cluster
kubectl config set-context consul1
../../esm/k8s-with-agent/deploy2.sh -i
# Register previously deployed aws ALB and services to consul
../../esm/k8s-with-agent/deploy2.sh -r
```

Repeat for all consul clusters
```
kubectl config set-context consul2
../../esm/k8s-with-agent/deploy2.sh -i
# Register previously deployed aws ALB and services to consul
../../esm/k8s-with-agent/deploy2.sh -r
```
If there are additional EKS Consul datacenters, switch contexts to the target DC and repeat these steps.

### Configure Consul DNS on EKS
Patch core-dns configmap to forward all .consul requests to Consul DNS.
```
kubectl config set-context west
../../scripts/patch_coredns_to_fwd_to_consul.sh
```

Verify coredns is now forwarding .consul requests to Consul
```
kc exec statefulset/consul-server -- nslookup consul.service.consul
```
Repeat on all k8s clusters that need consul DNS resolution


## Setup Peering between both Datacenters for Failover
Peer the two Consul DC's so services can discover and failover across data centers.

The peering script `./esm/peering/peer_dc1_to_dc2.sh` assumes the following:
* Consul is running on K8s
* current datacenters are dc1, dc2
* current terminal is authN to both K8s clusters
* K8s contexts are consul1, consul2
* Sets mesh defaults to Peer through Mesh Gateways
If anything is different make the necessary adjustments to the script before running.

Peer the two clusters
```
../../esm/peering/peer_dc1_to_dc2.sh
```
Note:  To peer directly from Consul servers instead of the more secure design using Mesh Gateways comment out the following lines setting up the mesh defaults to peer through MGW.
```
#kubectl -n consul --context ${CTX1} apply -f ${CUR_SCRIPT_DIR}/mesh.yaml
#kubectl -n consul --context ${CTX2} apply -f ${CUR_SCRIPT_DIR}/mesh.yaml
```

##  Create Prepared Query
Go to each EKS context and create a prepared query that will failover the service (ex: `schema-registry`) across peers.  The following script will use the current-contex, create a prepared query for that DC, and list the defined queries to verify it was created.
```
kubectl config set-context consul1
../../esm/prepared_query/deploy.sh
```
Repeat for each consul cluster that needs failover
```
kubectl config set-context consul2
../../esm/prepared_query/deploy.sh
```


## Quick Start - Demo Steps
### PreReq:
* Complete setup steps above
* Keep all services (Central) registered to ESM
* Keep all prepared Queries
* Remove Peering connection
  ```
  ../../examples/peering/peer_dc1_to_dc2.sh -d
  ```
* Remove services (West) from ESM
  ```
  ../../scripts/demo_gslb.sh -c west -u
  ```
* SSH to VM and verify Consul DNS for demo
  ```
  BASTION=$(terraform output -json | jq -r '.usw2_ec2_ip.value."vpc1-bastion"')
  IVM=$(terraform output -json | jq -r '.usw2_ec2_ip.value."vpc1-vm1"')
  ssh-add /Users/patrickpresto/.ssh/ppresto-ptfe-dev-key.pem
  ssh -A -J ubuntu@${BASTION} ubuntu@${IVM}
  ```

### Review Environment
* ../../examples/istio-ingress-gw/deploy-nodePort-gw-with-aws-ingress.sh
* istio-gateway.yaml
* httpbin-virtualservice.yaml
* myservice-virtualservice.yaml
### Deploy and register services (West) to ESM
```
../../scripts/demo_gslb.sh -c west -d
```

### Peer West to Central
Review Peering UI before running script to create
```
../../examples/peering/peer_dc1_to_dc2.sh
```

#### DNS and httpbin validation
Go to the SSH session on EC2 West instnace to verify DNS and routing
```
curl http://httpbin.query.consul/status/200
curl -I -HHost:httpbin.example.com http://httpbin.query.consul/status/200

dig +short httpbin.query.consul
# Review AWS ILB Node and lookup directly to verify IPs
```
### Kill httpbin service (West) to show failover
```
../../scripts/demo_gslb.sh -c west -k
```
Verify services are down in the UI

#### Failover validation
```
dig +short httpbin.query.consul
# Review AWS ILB Node and see the new IPs are using ILB Central.

curl -I -HHost:httpbin.example.com http://httpbin.query.consul/status/200
```

## Clean Up
Remove Consul Peering and PQ
```
../../examples/peering/peer_dc1_to_dc2.sh -d
kubectl config set-context consul1
../../examples/prepared_query/deploy.sh -d
../../examples/istio-ingress-gw/deploy-nodePort-gw-with-aws-ingress -d
kubectl config set-context consul2
../../examples/prepared_query/deploy.sh -d
../../examples/istio-ingress-gw/deploy-nodePort-gw-with-aws-ingress -d
```
Remove services
```
../../scripts/demo_gslb.sh -c west -u
../../scripts/demo_gslb.sh -c central -u
```

Uninstall all Consul datacenters using Terraform's helm provider
```
cd quickstart/1vpc-4eks/consul_helm_values
terraform destroy -auto-approve
```

Uninstall infrastructure
```
cd ../
terraform destroy -auto-approve
```

## Appendix

### Consul DNS
Setup Consul DNS on EKS to resolve the external service using Consul DNS.  Try the following Patch for a quick fix.
```
../scripts/patch_coredns_to_fwd_to_consul.sh
```
Refer to Hashicorp docs for more information on setting up DNS forwarding.

If Consul DNS is setup on EKS the new ext svc should now be resolveable from within EKS.
```
nslookup myservice.service.consul
```

### Deploy ESM on VM with Consul agent

Get Consul Information and Secrets first.
```
#Create CA Cert on VM from K8s secret
kubectl -n consul get secret consul-ca-cert --context consul1 -o json | jq -r '.data."tls.crt"' | base64 -d > /etc/consul.d/certs/ca.pem

# Set Env vars
DATACENTER="dc1"
GOSSIP_KEY=$(kubectl -n consul get secrets consul-gossip-encryption-key -o jsonpath='{.data.key}'| base64 -d)
RETRY_JOIN="$(kubectl -n consul get svc consul-expose-servers -o json | jq -r '.status.loadBalancer.ingress[].hostname')"
CONSUL_ACL_TOKEN=$(kubectl -n consul get secrets consul-bootstrap-acl-token -o jsonpath='{.data.token}'| base64 -d)
local_ip=`ip -o route get to 169.254.169.254 | sed -n 's/.*src \([0-9.]\+\).*/\1/p'`
```

Install Consul
```
## Install Consul - Ext K8s cluster requires awscli, kubctl, .kube and expose host ports
curl -fsSL https://apt.releases.hashicorp.com/gpg | apt-key add -
apt-add-repository "deb [arch=amd64] https://apt.releases.hashicorp.com $(lsb_release -cs) main"
apt update && apt install -y consul-enterprise=1.16.0+ent-1 unzip jq awscli
snap install kubectl --classic
mkdir -p /etc/consul.d/certs
```

Modify the default consul.hcl file
```
cat > /etc/consul.d/consul.hcl <<- EOF
datacenter = "$DATACENTER"
data_dir = "/opt/consul"
server = false
client_addr = "0.0.0.0"
bind_addr = "0.0.0.0"
advertise_addr = "$local_ip"
retry_join = ["$RETRY_JOIN"]
encrypt = "$GOSSIP_KEY"
encrypt_verify_incoming = true
encrypt_verify_outgoing = true
log_level = "INFO"
ui = true
enable_script_checks = true
#verify_incoming = true
#verify_outgoing = true
#verify_server_hostname = true
ca_file = "/etc/consul.d/certs/ca.pem"
#cert_file = "/etc/consul.d/certs/client-cert.pem"
#key_file = "/etc/consul.d/certs/client-key.pem"
auto_encrypt = {
  tls = true
}

connect {
  enabled = true
}

ports {
  grpc = 8502
}
EOF
```
Support ACLs if enabled.  Update CONSUL_ACL_TOKEN.
```
cat >/etc/consul.d/client_acl.hcl <<- EOF
acl = {
  enabled = true
  #down_policy = "async-cache"
  #default_policy = "deny"
  #enable_token_persistence = true
  tokens {
    agent = "${CONSUL_ACL_TOKEN}"
  }
}
EOF
```

Configure systemd
```
cat >/etc/systemd/system/consul.service << EOF
[Unit]
Description="HashiCorp Consul Ent - A service mesh solution"
Documentation=https://www.consul.io/
Requires=network-online.target
After=network-online.target
ConditionFileNotEmpty=/etc/consul.d/consul.hcl

[Service]
EnvironmentFile=-/etc/consul.d/consul.env
User=consul
Group=consul
ExecStart=/usr/bin/consul agent -config-dir=/etc/consul.d/
ExecReload=/bin/kill --signal HUP $MAINPID
KillMode=process
KillSignal=SIGTERM
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
```

Start Consul
```
# Start Consul
systemctl enable consul.service
systemctl start consul.service
```

Point DNS to Consul's DNS
```
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/consul.conf <<- EOF
[Resolve]
DNS=127.0.0.1
Domains=~consul
EOF
iptables --table nat --append OUTPUT --destination localhost --protocol udp --match udp --dport 53 --jump REDIRECT --to-ports 8600
iptables --table nat --append OUTPUT --destination localhost --protocol tcp --match tcp --dport 53 --jump REDIRECT --to-ports 8600
systemctl restart systemd-resolved
```
