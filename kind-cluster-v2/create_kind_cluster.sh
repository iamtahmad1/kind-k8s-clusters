#!/usr/bin/env bash

set -e

# CONSTANTS
readonly KIND_NODE_IMAGE=kindest/node:v1.31.0
readonly DNSMASQ_DOMAIN=kind.cluster
readonly DNSMASQ_CONF=kind.k8s.conf

# FUNCTIONS
usage() {
  echo "Usage: $0 [CLUSTER_NAME]]"
  echo "  CLUSTER_NAME   - (Optional) Name of the Kind cluster (default: kind)"
  exit 1
}

log() {
  echo "---------------------------------------------------------------------------------------"
  echo "$1"
  echo "---------------------------------------------------------------------------------------"
}

wait_ready() {
  local NAME=${1:-pods}
  local TIMEOUT=${2:-5m}
  local SELECTOR=${3:---all}

  log "WAIT $NAME ($TIMEOUT) ..."
  kubectl wait -A --timeout=$TIMEOUT --for=condition=ready $NAME $SELECTOR
}

wait_pods_ready() {
  wait_ready pods "${1:-5m}" --field-selector=status.phase!=Succeeded
}

wait_nodes_ready() {
  wait_ready nodes "${1:-5m}"
}

network() {
  local NAME=${1:-kind}
  log "NETWORK ($NAME) ..."

  if ! docker network ls --filter name=^$NAME$ --format="{{ .Name }}" | grep -q $NAME; then
    docker network create $NAME
    echo "Network $NAME created"
  else
    echo "Network $NAME already exists, skipping"
  fi
}

proxy() {
  local NAME=$1
  local TARGET=$2
  
  if ! docker ps --filter name=^$NAME$ --format="{{ .Names }}" | grep -q $NAME; then
    docker run -d --name $NAME --restart=always --net=kind -e REGISTRY_PROXY_REMOTEURL=$TARGET registry:2
    echo "Proxy $NAME (-> $TARGET) created"
  else
    echo "Proxy $NAME already exists, skipping"
  fi
}

proxies() {
  log "REGISTRY PROXIES ..."
  proxy proxy-docker-hub https://registry-1.docker.io
  proxy proxy-quay https://quay.io
  proxy proxy-gcr https://gcr.io
  proxy proxy-k8s-gcr https://k8s.gcr.io
}

get_service_lb_ip() {
  kubectl get svc -n "$1" "$2" -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
}

get_subnet() {
  docker network inspect -f '{{(index .IPAM.Config 0).Subnet}}' "$1"
}

subnet_to_ip() {
  echo "$1" | sed "s@0.0/16@$2@"
}

root_ca() {
  log "ROOT CERTIFICATE ..."
  mkdir -p .ssl
  if [[ -f ".ssl/root-ca.pem" && -f ".ssl/root-ca-key.pem" ]]; then
    echo "Root certificate already exists, skipping"
  else
    openssl genrsa -out .ssl/root-ca-key.pem 2048
    openssl req -x509 -new -nodes -key .ssl/root-ca-key.pem -days 3650 -sha256 -out .ssl/root-ca.pem -subj "/CN=kube-ca"
    echo "Root certificate created"
  fi
}

install_ca() {
  log "INSTALL CERTIFICATE AUTHORITY ..."
  sudo mkdir -p /usr/local/share/ca-certificates/kind.cluster
  sudo cp -f .ssl/root-ca.pem /usr/local/share/ca-certificates/kind.cluster/ca.crt
  sudo update-ca-certificates
}

cluster() {
  local NAME=${1:-kind}
  
  log "CLUSTER ($NAME)..."

  docker pull $KIND_NODE_IMAGE

  cat <<EOF | kind create cluster --name $NAME --image $KIND_NODE_IMAGE --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: false
kubeadmConfigPatches:
  - |-
    kind: ClusterConfiguration
    apiServer:     
      extraVolumes:
        - name: opt-ca-certificates
          hostPath: /opt/ca-certificates/root-ca.pem
          mountPath: /opt/ca-certificates/root-ca.pem
          readOnly: true
          pathType: File
      extraArgs:
        oidc-client-id: kube
        oidc-issuer-url: https://keycloak.kind.cluster/auth/realms/master
        oidc-username-claim: email
        oidc-groups-claim: groups
        oidc-ca-file: /opt/ca-certificates/root-ca.pem
    controllerManager:
      extraArgs:
        bind-address: 0.0.0.0
    etcd:
      local:
        extraArgs:
          listen-metrics-urls: http://0.0.0.0:2381
    scheduler:
      extraArgs:
        bind-address: 0.0.0.0 
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker.io"]
      endpoint = ["http://proxy-docker-hub:5000"]
nodes:
  - role: control-plane
    extraMounts:
      - hostPath: $PWD/.ssl/root-ca.pem
        containerPath: /opt/ca-certificates/root-ca.pem
        readOnly: true
  - role: worker
    extraMounts:
      - hostPath: $PWD/.ssl/root-ca.pem
        containerPath: /opt/ca-certificates/root-ca.pem
        readOnly: true
  - role: worker
    extraMounts:
      - hostPath: $PWD/.ssl/root-ca.pem
        containerPath: /opt/ca-certificates/root-ca.pem
        readOnly: true
  - role: worker
    extraMounts:
      - hostPath: $PWD/.ssl/root-ca.pem
        containerPath: /opt/ca-certificates/root-ca.pem
        readOnly: true

EOF

}

cert_manager() {
  log "CERT MANAGER ..."
  helm upgrade --install --wait --timeout 15m --atomic --namespace cert-manager --create-namespace \
    --repo https://charts.jetstack.io cert-manager cert-manager --values - <<EOF
installCRDs: true
EOF
}

cert_manager_ca_secret(){
  kubectl delete secret -n cert-manager root-ca || true
  kubectl create secret tls -n cert-manager root-ca --cert=.ssl/root-ca.pem --key=.ssl/root-ca-key.pem
}

cert_manager_ca_issuer(){
  kubectl apply -n cert-manager -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ca-issuer
spec:
  ca:
    secretName: root-ca
EOF
}

metallb() {
  log "METALLB ..."
  local KIND_SUBNET=$(get_subnet kind)
  local METALLB_START=$(subnet_to_ip $KIND_SUBNET 255.200)
  local METALLB_END=$(subnet_to_ip $KIND_SUBNET 255.250)

  helm upgrade --install --wait --timeout 15m --atomic --namespace metallb-system --create-namespace \
    --repo https://metallb.github.io/metallb metallb metallb
  
  kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
    - $METALLB_START-$METALLB_END

---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - default-pool
EOF
}

deploy_argocd() {
  log "DEPLOYING ARGOCD ..."
  kubectl create namespace argocd || true

  helm upgrade --install --wait --timeout 15m --atomic --namespace argocd \
    --repo https://argoproj.github.io/argo-helm argo-cd argo-cd --values - <<EOF
dex:
  enabled: false
redis:
  enabled: true
redis-ha:
  enabled: false
repoServer:
  serviceAccount:
    create: true
server:
  volumeMounts:
    - mountPath: /etc/ssl/certs/root-ca.pem
      name: opt-ca-certificates
      readOnly: true
  volumes:
    - name: opt-ca-certificates
      hostPath:
        path: /opt/ca-certificates/root-ca.pem
        type: File
  config:
    url: https://argocd.${DNSMASQ_DOMAIN}
    application.instanceLabelKey: argocd.argoproj.io/instance
    resource.compareoptions: |
      ignoreResourceStatusField: all
  extraArgs:
    - --insecure
  ingress:
    annotations:
      cert-manager.io/cluster-issuer: ca-issuer
    enabled: true
    ingressClassName: nginx
    hostname: argocd.${DNSMASQ_DOMAIN}
    tls:
      - secretName: argocd.${DNSMASQ_DOMAIN}
        hosts:
          - argocd.${DNSMASQ_DOMAIN}
EOF

  kubectl -n argocd patch secret argocd-secret \
    -p '{"stringData": {"admin.password": "'$(htpasswd -bnBC 10 "" admin123 | tr -d ':\n')'"}}'
}

create_argo_app() {
  log "CREATING ARGOCD APPLICATION ..."

  kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: kind-clusters
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/iamtahmad1/kind-k8s-clusters.git
    targetRevision: main
    path: argocd
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF
}

ingress(){
  log "INGRESS-NGINX ..."

  helm upgrade --install --wait --timeout 15m --atomic --namespace ingress-nginx --create-namespace \
    --repo https://kubernetes.github.io/ingress-nginx ingress-nginx ingress-nginx --values - <<EOF
defaultBackend:
  enabled: true
EOF
}

dnsmasq(){
  log "DNSMASQ ..."

  local INGRESS_LB_IP=$(get_service_lb_ip ingress-nginx ingress-nginx-controller)

  echo "address=/$DNSMASQ_DOMAIN/$INGRESS_LB_IP" | sudo tee /etc/dnsmasq.d/$DNSMASQ_CONF
}

restart_service(){
  log "RESTART $1 ..."

  sudo systemctl restart $1
}

cleanup() {
  log "CLEANUP ..."
  kind delete cluster || true
  sudo rm -f /etc/dnsmasq.d/$DNSMASQ_CONF
  sudo rm -rf /usr/local/share/ca-certificates/kind.cluster
}

# RUN
if [[ "$1" == "--help" ]]; then
  usage
fi

cleanup
network
proxies
root_ca
install_ca
cluster "$@"
cert_manager
cert_manager_ca_secret
cert_manager_ca_issuer
metallb
ingress
deploy_argocd
create_argo_app
dnsmasq
restart_service   dnsmasq
log "CLUSTER READY !"
