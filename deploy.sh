#!/bin/bash

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="${NAMESPACE:-trivy-test}"
DOMAIN="${DOMAIN:-trivy-reports.example.com}"

print_info "Deploying Trivy HTML Report Generator to namespace: $NAMESPACE"
print_info "Domain: $DOMAIN"

# Check if scripts exist
if [ ! -f "$SCRIPT_DIR/trivy-report-to-html.sh" ]; then
    print_error "trivy-report-to-html.sh not found in $SCRIPT_DIR"
    exit 1
fi

if [ ! -f "$SCRIPT_DIR/generate-html.sh" ]; then
    print_error "generate-html.sh not found in $SCRIPT_DIR"
    exit 1
fi

# Create namespace if it doesn't exist
print_info "Creating namespace: $NAMESPACE"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Create ConfigMap from scripts
print_info "Creating ConfigMap: trivy-html-generator"
kubectl create configmap trivy-html-generator \
    --from-file=trivy-report-to-html.sh="$SCRIPT_DIR/trivy-report-to-html.sh" \
    --from-file=generate-html.sh="$SCRIPT_DIR/generate-html.sh" \
    --namespace="$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -

# Deploy CronJob and nginx
print_info "Applying Kubernetes manifests..."
if [ -f "$SCRIPT_DIR/kubernetes/cronjob.yaml" ]; then
    # Replace namespace and domain in yaml and apply
    cat "$SCRIPT_DIR/kubernetes/cronjob.yaml" | \
        sed "s/namespace: trivy-system/namespace: $NAMESPACE/g" | \
        sed "s/trivy-reports.k8s-internal.obiwan.xyz/$DOMAIN/g" | \
        kubectl apply -f -
    print_info "✓ CronJob deployed"
else
    print_warning "cronjob.yaml not found, skipping"
fi

# Optionally deploy the watcher
if [ -f "$SCRIPT_DIR/kubernetes/deployment-watcher.yaml" ]; then
    read -p "Deploy real-time watcher? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # Create trivy-scripts ConfigMap for watcher
        print_info "Creating ConfigMap: trivy-scripts"
        kubectl create configmap trivy-scripts \
            --from-file=watch.sh=<(kubectl get configmap trivy-scripts -n "$NAMESPACE" -o jsonpath='{.data.watch\.sh}' 2>/dev/null || echo '#!/bin/sh
set -e
OUTPUT_DIR="/reports"
mkdir -p "$OUTPUT_DIR"
echo "Starting real-time VulnerabilityReport watcher..."
kubectl get vulnerabilityreports --all-namespaces --watch -o json | \
while read -r event; do
  TYPE=$(echo "$event" | jq -r ".type")
  NAMESPACE=$(echo "$event" | jq -r ".object.metadata.namespace")
  NAME=$(echo "$event" | jq -r ".object.metadata.name")
  if [ "$TYPE" = "ADDED" ] || [ "$TYPE" = "MODIFIED" ]; then
    echo "[$(date)] Detected $TYPE: $NAMESPACE/$NAME"
    /scripts/trivy-report-to-html.sh --namespace "$NAMESPACE" --report "$NAME" --output "$OUTPUT_DIR/${NAMESPACE}_${NAME}.html" || true
  fi
done') \
            --namespace="$NAMESPACE" \
            --dry-run=client -o yaml | kubectl apply -f -
        
        cat "$SCRIPT_DIR/kubernetes/deployment-watcher.yaml" | \
            sed "s/namespace: trivy-system/namespace: $NAMESPACE/g" | \
            kubectl apply -f -
        print_info "✓ Watcher deployed"
    fi
fi

# Wait for PVC to be bound
print_info "Waiting for PVC to be bound..."
kubectl wait --for=jsonpath='{.status.phase}'=Bound pvc/trivy-reports-pvc -n "$NAMESPACE" --timeout=60s || print_warning "PVC not bound yet"

# Get service information
print_info "Deployment complete!"
echo ""
print_info "To access the reports web interface:"
echo ""
echo "  # Get service details:"
echo "  kubectl get svc -n $NAMESPACE trivy-reports-web"
echo ""
echo "  # Port-forward for local access:"
echo "  kubectl port-forward -n $NAMESPACE svc/trivy-reports-web 8080:80"
echo "  # Then open: http://localhost:8080"
echo ""
print_info "CronJob schedule:"
kubectl get cronjob -n "$NAMESPACE" trivy-html-report-generator -o jsonpath='{.spec.schedule}' 2>/dev/null && echo ""
echo ""
print_info "Manual report generation:"
echo "  kubectl create job --from=cronjob/trivy-html-report-generator manual-run-\$(date +%s) -n $NAMESPACE"
