#!/bin/bash

# Check for required arguments
if [ $# -ne 2 ]; then
  echo "Usage: $0 <cluster-name> <number-of-worker-nodes>"
  exit 1
fi

CLUSTER_NAME=$1
NUM_WORKERS=$2

# Create a cluster configuration file dynamically
cat <<EOF > cluster.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane

EOF

for i in $(seq 1 $NUM_WORKERS); do
  cat <<EOF >> cluster.yaml
  - role: worker
    extraMounts:
      - hostPath: /home/test/Desktop/Learn/kind_k8s_cluster/KIND_STORAGE
        containerPath: /mnt/storage
EOF
done


# Create the Kubernetes cluster
kind create cluster --name $CLUSTER_NAME --config cluster.yaml

# Apply MetalLB manifests
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.7/config/manifests/metallb-native.yaml

# Wait for MetalLB to be ready
kubectl wait --namespace metallb-system \
  --for=condition=ready pod \
  --selector=app=metallb \
  --timeout=90s

# Apply MetalLB configuration
kubectl apply -f metallb.yaml

# Cleanup the generated cluster configuration file
rm cluster.yaml

# install ingress-nginx
helm upgrade --install --namespace ingress-nginx --create-namespace --repo https://kubernetes.github.io/ingress-nginx ingress-nginx ingress-nginx --values - <<EOF
defaultBackend:
  enabled: true
EOF

# wait for pods to be ready
kubectl wait -A --for=condition=ready pod --field-selector=status.phase!=Succeeded --timeout=15m

# retrieve local load balancer IP address
LB_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# point kind.cluster domain (and subdomains) to our load balancer
echo "address=/kind.cluster/$LB_IP" | sudo tee /etc/dnsmasq.d/kind.k8s.conf

# restart dnsmasq
sudo systemctl restart dnsmasq

echo "Cluster '$CLUSTER_NAME' with $NUM_WORKERS worker nodes created successfully!"
