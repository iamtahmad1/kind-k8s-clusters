# kind-k8s-clusters

Quickly deploy Kubernetes clusters using [kind](https://kind.sigs.k8s.io/) for testing and development purposes.

## Overview

This repository provides configurations to set up local Kubernetes clusters with kind (Kubernetes IN Docker). It's designed to facilitate rapid deployment and testing of multi-node clusters in a local environment.

## Prerequisites

- **Docker**: Ensure Docker is installed and running on your system. [Install Docker](https://docs.docker.com/get-docker/)
- **kind**: Install kind by following the [installation guide](https://kind.sigs.k8s.io/docs/user/quick-start/#installation).
- **kubectl**: Install kubectl to interact with your Kubernetes clusters. [Install kubectl](https://kubernetes.io/docs/tasks/tools/)

## Cluster Configurations

This repository includes the following cluster configurations:

- **Single Control Plane Cluster**: Suitable for basic testing and development.
- **Multi-Node Cluster**: Comprises one control plane and multiple worker nodes, ideal for more complex scenarios.

## Usage

1. **Clone the Repository**:

   ```bash
   git clone https://github.com/iamtahmad1/kind-k8s-clusters.git
   cd kind-k8s-clusters
   ```

2. **Deploy a Cluster with v1**:

   v1 give a basic cluster name with desired name and n node with metallb installed:

   ```bash
   cd kind-clusters-v1
   sh create-kind-cluster.sh test 3
   ```

   Replace name and number of nodes accordingly, also update IP pool IP address.

3. **Deploy a Cluster with v2**:

   v2 gives you can kind cluster with cert manager, metallb, ingress controller, argocd server and argo app which syncs to my repo but you can change accordinly:

   ```bash
   cd kind-clusters-v2
   sh create-kind-cluster.sh test 3
   ```

4. **Delete the Cluster**:

   When you're done, delete the cluster to free up resources:

   ```bash
   kind delete cluster --name <cluster-name>
   ```

   Replace `<cluster-name>` with the name of your cluster if it's not the default `kind`.

## Contributing

Contributions are welcome! Please fork this repository, make your changes, and submit a pull request.

