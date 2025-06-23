#!/bin/bash

# Usage: ./create-cluster.sh <cluster-name> <api-server-port>

set -e

# CONSTANTS
readonly KIND_NODE_IMAGE=kindest/node:v1.31.0
readonly DNSMASQ_DOMAIN=kind.cluster

# Validate input
if [ $# -ne 2 ]; then
  echo "Usage: $0 <cluster-name> <api-server-port>"
  exit 1
fi

CLUSTER_NAME=$1
API_SERVER_PORT=$2

# Validate port is a number between 1024-65535
if ! [[ "$API_SERVER_PORT" =~ ^[0-9]+$ ]] || [ "$API_SERVER_PORT" -lt 1024 ] || [ "$API_SERVER_PORT" -gt 65535 ]; then
  echo "Error: API server port must be a number between 1024 and 65535."
  exit 1
fi

# Create KIND cluster config dynamically
echo "Creating KIND cluster $CLUSTER_NAME on port $API_SERVER_PORT ..."  
cat <<EOF | kind create cluster --name "$CLUSTER_NAME" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
networking:
  disableDefaultCNI: false
  apiServerAddress: "127.0.0.1"
  apiServerPort: $API_SERVER_PORT
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

echo "✅ KIND cluster '$CLUSTER_NAME' created with API server on port $API_SERVER_PORT."

# Setup dnsmasq entries
DNSMASQ_FILE="/etc/dnsmasq.d/${CLUSTER_NAME}.conf"

echo "Configuring dnsmasq for cluster $CLUSTER_NAME ..."
sudo bash -c "cat > $DNSMASQ_FILE" <<EOF
address=/api.${CLUSTER_NAME}.${DNSMASQ_DOMAIN}/127.0.0.1
address=/keycloak.${CLUSTER_NAME}.${DNSMASQ_DOMAIN}/127.0.0.1
address=/argocd.${CLUSTER_NAME}.${DNSMASQ_DOMAIN}/127.0.0.1
address=/vault.${CLUSTER_NAME}.${DNSMASQ_DOMAIN}/127.0.0.1
EOF

echo "✅ dnsmasq config created at $DNSMASQ_FILE."

# Restart dnsmasq
sudo systemctl restart dnsmasq
echo "✅ dnsmasq restarted."

# Configure kubectl to use the new cluster by default
kind export kubeconfig --name "$CLUSTER_NAME"
echo "✅ kubeconfig updated for '$CLUSTER_NAME'."

# Setup CA certs
root_ca() {
  echo "Generating Root CA ..."
  mkdir -p .ssl
  if [[ ! -f ".ssl/root-ca.pem" || ! -f ".ssl/root-ca-key.pem" ]]; then
    openssl genrsa -out .ssl/root-ca-key.pem 2048
    openssl req -x509 -new -nodes -key .ssl/root-ca-key.pem -days 3650 -sha256 -out .ssl/root-ca.pem -subj "/CN=kube-ca"
  fi
}

install_ca() {
  echo "Installing Root CA ..."
  sudo mkdir -p /usr/local/share/ca-certificates/kind.cluster
  sudo cp -f .ssl/root-ca.pem /usr/local/share/ca-certificates/kind.cluster/ca.crt
  sudo update-ca-certificates
}

# Install Cert Manager
cert_manager() {
  echo "Installing cert-manager ..."
  helm upgrade --install --wait --timeout 15m --atomic --namespace cert-manager --create-namespace \
    --repo https://charts.jetstack.io cert-manager cert-manager --values - <<EOF
installCRDs: true
EOF
}

# Create cert-manager CA secret
cert_manager_ca_secret() {
  kubectl delete secret -n cert-manager root-ca || true
  kubectl create secret tls -n cert-manager root-ca --cert=.ssl/root-ca.pem --key=.ssl/root-ca-key.pem
}

# Apply CA Issuer to cert-manager
cert_manager_ca_issuer() {
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

# Install MetalLB
metallb() {
  echo "Installing MetalLB ..."

  local SUBNET=$(docker network inspect -f '{{(index .IPAM.Config 0).Subnet}}' kind)
  local START_IP=$(echo $SUBNET | sed "s@0.0/16@255.200@")
  local END_IP=$(echo $SUBNET | sed "s@0.0/16@255.250@")

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
    - $START_IP-$END_IP
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

# Install Ingress-Nginx
ingress() {
  echo "Installing Ingress-Nginx ..."
  helm upgrade --install --wait --timeout 15m --atomic --namespace ingress-nginx --create-namespace \
    --repo https://kubernetes.github.io/ingress-nginx ingress-nginx ingress-nginx --values - <<EOF
defaultBackend:
  enabled: true
EOF
}

# Deploy ArgoCD
deploy_argocd() {
  echo "Installing ArgoCD ..."
  kubectl create namespace argocd || true

  helm upgrade --install --wait --timeout 15m --atomic --namespace argocd \
    --repo https://argoproj.github.io/argo-helm argo-cd argo-cd --values - <<EOF
dex:
  enabled: false
redis:
  enabled: true
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
    url: https://argocd.${CLUSTER_NAME}.${DNSMASQ_DOMAIN}
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
    hostname: argocd.${CLUSTER_NAME}.${DNSMASQ_DOMAIN}
    tls:
      - secretName: argocd.${CLUSTER_NAME}.${DNSMASQ_DOMAIN}
        hosts:
          - argocd.${CLUSTER_NAME}.${DNSMASQ_DOMAIN}
EOF

  kubectl -n argocd patch secret argocd-secret \
    -p '{"stringData": {"admin.password": "'$(htpasswd -bnBC 10 "" admin123 | tr -d ':\n')'"}}'
}

# Main Script Execution
echo "Starting the cluster creation process ..."

# Call the functions in the right order
root_ca
install_ca
#cluster $CLUSTER_NAME $API_SERVER_PORT
cert_manager
cert_manager_ca_secret
cert_manager_ca_issuer
metallb
ingress
deploy_argocd

echo "🎉 Cluster '$CLUSTER_NAME' is fully set up and ready!"
