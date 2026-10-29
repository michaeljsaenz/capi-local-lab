#!/bin/bash
set -e

CLUSTER_NAME=$1
if [ -z "$CLUSTER_NAME" ]; then
    echo "Usage: $0 <cluster-name>"
    echo "Example: $0 local-cluster"
    exit 1
fi

echo "========================================="
echo "  Infrastructure Verification"
echo "  Cluster: $CLUSTER_NAME"
echo "========================================="

# Check if we have management cluster access
echo -e "\n[1/7] Checking cluster access..."
if ! kubectl get cluster $CLUSTER_NAME &>/dev/null; then
  echo "❌ Cannot access cluster '$CLUSTER_NAME' from current context."
  echo "   Make sure you're on the management cluster context."
  echo ""
  echo "Available contexts:"
  kubectl config get-contexts
  exit 1
fi

CURRENT_CONTEXT=$(kubectl config current-context)
echo "   Using context: $CURRENT_CONTEXT"

# Check cluster status
echo -e "\n[2/7] Checking cluster status..."
kubectl get cluster $CLUSTER_NAME -o jsonpath='{.metadata.name}{"\t"}{.status.phase}{"\t"}{.spec.topology.version}{"\n"}' | \
  awk 'BEGIN{print "NAME\t\t\tPHASE\t\tVERSION"}{print}'

# Check machines
echo -e "\n[3/7] Checking machine status..."
kubectl get machines -A -l cluster.x-k8s.io/cluster-name=$CLUSTER_NAME \
  -o custom-columns=NAME:.metadata.name,READY:.status.ready,AVAILABLE:.status.nodeRef,PHASE:.status.phase,AGE:.metadata.creationTimestamp | \
  awk '{print $1 "\t" $2 "\t" ($3!="<none>"?"True":"False") "\t" $4}'

# Check HelmChartProxy (templates)
echo -e "\n[4/7] Checking HelmChartProxy templates..."
kubectl get helmchartproxy -A -o custom-columns=NAME:.metadata.name,TYPE:.spec.chartName,VERSION:.spec.version

# Check HelmReleaseProxy (deployed releases)
echo -e "\n[5/7] Checking HelmReleaseProxy status..."
kubectl get helmreleaseproxy -A | grep "$CLUSTER_NAME" || echo "⚠️  No HelmReleaseProxy found for $CLUSTER_NAME"

# Generate kubeconfig with load balancer
echo -e "\n[6/7] Generating kubeconfig (using load balancer)..."
LB_PORT=$(docker port ${CLUSTER_NAME}-lb 6443 2>/dev/null | grep "0.0.0.0" | cut -d: -f2)

if [ -z "$LB_PORT" ]; then
  echo "❌ Load balancer not found! Cluster may not be fully provisioned yet."
  exit 1
fi

echo "   Load Balancer: 127.0.0.1:$LB_PORT"

clusterctl get kubeconfig $CLUSTER_NAME 2>/dev/null | \
  sed "s|server: https://[^:]*:6443|server: https://127.0.0.1:$LB_PORT|g" \
  > /tmp/${CLUSTER_NAME}-kubeconfig

# Verify workload cluster
echo -e "\n[7/7] Checking workload cluster..."
export KUBECONFIG=/tmp/${CLUSTER_NAME}-kubeconfig

echo "   Nodes:"
kubectl get nodes

echo -e "\n   Infrastructure Components:"

# Cilium
CILIUM_COUNT=$(kubectl get pods -n kube-system 2>/dev/null | grep cilium | grep -v operator | wc -l | tr -d ' ')
CILIUM_RUNNING=$(kubectl get pods -n kube-system 2>/dev/null | grep cilium | grep -v operator | grep -c Running || echo "0")
if [ "$CILIUM_COUNT" -gt 0 ]; then
  if [ "$CILIUM_RUNNING" -eq "$CILIUM_COUNT" ]; then
    echo "      ✅ Cilium: $CILIUM_RUNNING/$CILIUM_COUNT pods Running"
  else
    echo "      ⚠️  Cilium: $CILIUM_RUNNING/$CILIUM_COUNT pods Running"
  fi
else
  echo "      ❌ Cilium: Not deployed"
fi

# cert-manager
CERTMGR_COUNT=$(kubectl get pods -n cert-manager --no-headers 2>/dev/null | wc -l | tr -d ' ')
CERTMGR_RUNNING=$(kubectl get pods -n cert-manager --no-headers 2>/dev/null | grep -c Running || echo "0")
if [ "$CERTMGR_COUNT" -gt 0 ]; then
  if [ "$CERTMGR_RUNNING" -eq "$CERTMGR_COUNT" ]; then
    echo "      ✅ cert-manager: $CERTMGR_RUNNING/$CERTMGR_COUNT pods Running"
  else
    echo "      ⚠️  cert-manager: $CERTMGR_RUNNING/$CERTMGR_COUNT pods Running"
  fi
else
  echo "      ❌ cert-manager: Not deployed"
fi

# ingress-nginx
INGRESS_COUNT=$(kubectl get pods -n ingress-nginx --no-headers 2>/dev/null | wc -l | tr -d ' ')
INGRESS_RUNNING=$(kubectl get pods -n ingress-nginx --no-headers 2>/dev/null | grep -c Running || echo "0")
if [ "$INGRESS_COUNT" -gt 0 ]; then
  if [ "$INGRESS_RUNNING" -eq "$INGRESS_COUNT" ]; then
    echo "      ✅ ingress-nginx: $INGRESS_RUNNING/$INGRESS_COUNT pods Running"
  else
    echo "      ⚠️  ingress-nginx: $INGRESS_RUNNING/$INGRESS_COUNT pods Running"
  fi
else
  echo "      ❌ ingress-nginx: Not deployed"
fi

# CoreDNS
COREDNS_COUNT=$(kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | wc -l | tr -d ' ')
COREDNS_RUNNING=$(kubectl get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | grep -c Running || echo "0")
if [ "$COREDNS_COUNT" -gt 0 ]; then
  if [ "$COREDNS_RUNNING" -eq "$COREDNS_COUNT" ]; then
    echo "      ✅ CoreDNS: $COREDNS_RUNNING/$COREDNS_COUNT pods Running"
  else
    echo "      ⚠️  CoreDNS: $COREDNS_RUNNING/$COREDNS_COUNT pods Running"
  fi
else
  echo "      ❌ CoreDNS: Not deployed"
fi

echo -e "\n========================================="
echo "  ✅ Verification Complete"
echo "========================================="
echo ""
echo "Kubeconfig saved to: /tmp/${CLUSTER_NAME}-kubeconfig"
echo ""
echo "To access workload cluster:"
echo "  export KUBECONFIG=/tmp/${CLUSTER_NAME}-kubeconfig"
echo "  kubectl get nodes"