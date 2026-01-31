#!/bin/bash

# Watch for new/updated VulnerabilityReports and auto-generate HTML reports

set -e

# Configuration
WATCH_NAMESPACE="${WATCH_NAMESPACE:-}"  # Empty = all namespaces
OUTPUT_DIR="${OUTPUT_DIR:-./reports}"
CHECK_INTERVAL="${CHECK_INTERVAL:-60}"  # seconds
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_info() {
    echo -e "${GREEN}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"
}

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Track processed reports
PROCESSED_FILE="$OUTPUT_DIR/.processed_reports"
touch "$PROCESSED_FILE"

print_info "Starting VulnerabilityReport watcher..."
print_info "Output directory: $OUTPUT_DIR"
print_info "Check interval: ${CHECK_INTERVAL}s"
[ -z "$WATCH_NAMESPACE" ] && print_info "Watching: All namespaces" || print_info "Watching namespace: $WATCH_NAMESPACE"

while true; do
    # Get all vulnerability reports with their resource versions
    if [ -z "$WATCH_NAMESPACE" ]; then
        REPORTS=$(kubectl get vulnerabilityreports --all-namespaces -o json 2>/dev/null)
    else
        REPORTS=$(kubectl get vulnerabilityreports -n "$WATCH_NAMESPACE" -o json 2>/dev/null)
    fi
    
    if [ $? -ne 0 ]; then
        print_warning "Failed to fetch reports, retrying..."
        sleep "$CHECK_INTERVAL"
        continue
    fi
    
    # Process each report
    echo "$REPORTS" | jq -r '.items[] | "\(.metadata.namespace)|\(.metadata.name)|\(.metadata.resourceVersion)"' | while IFS='|' read -r namespace name version; do
        REPORT_KEY="${namespace}/${name}:${version}"
        
        # Check if already processed
        if grep -q "^${REPORT_KEY}$" "$PROCESSED_FILE" 2>/dev/null; then
            continue
        fi
        
        print_info "New/updated report detected: $namespace/$name"
        
        # Generate HTML report
        OUTPUT_FILE="$OUTPUT_DIR/${namespace}_${name}.html"
        
        if "$SCRIPT_DIR/trivy-report-to-html.sh" --namespace "$namespace" --report "$name" --output "$OUTPUT_FILE" >/dev/null 2>&1; then
            print_info "✓ Generated: $OUTPUT_FILE"
            echo "$REPORT_KEY" >> "$PROCESSED_FILE"
        else
            print_warning "✗ Failed to generate report for $namespace/$name"
        fi
    done
    
    sleep "$CHECK_INTERVAL"
done
