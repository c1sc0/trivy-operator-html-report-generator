#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Check if required commands are available
check_requirements() {
    local missing_deps=()
    
    if ! command -v kubectl &> /dev/null; then
        missing_deps+=("kubectl")
    fi
    
    if ! command -v jq &> /dev/null; then
        missing_deps+=("jq")
    fi
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        print_error "Missing required dependencies: ${missing_deps[*]}"
        echo "Please install them before running this script."
        exit 1
    fi
}

# Function to list vulnerability reports
list_reports() {
    local namespace=$1
    
    print_info "Fetching VulnerabilityReports..."
    
    if [ -n "$namespace" ]; then
        kubectl get vulnerabilityreports -n "$namespace" -o custom-columns=NAME:.metadata.name,NAMESPACE:.metadata.namespace,CRITICAL:.report.summary.criticalCount,HIGH:.report.summary.highCount,MEDIUM:.report.summary.mediumCount,AGE:.metadata.creationTimestamp
    else
        kubectl get vulnerabilityreports --all-namespaces -o custom-columns=NAME:.metadata.name,NAMESPACE:.metadata.namespace,CRITICAL:.report.summary.criticalCount,HIGH:.report.summary.highCount,MEDIUM:.report.summary.mediumCount,AGE:.metadata.creationTimestamp
    fi
}

# Function to convert a single report to HTML
convert_report() {
    local report_name=$1
    local namespace=$2
    local output_file=$3
    
    print_info "Extracting report: $report_name from namespace: $namespace"
    
    # Create temporary directory for processing
    local tmp_dir=$(mktemp -d)
    local k8s_report="$tmp_dir/k8s-report.json"
    
    # Extract the full K8s report
    if ! kubectl get vulnerabilityreport "$report_name" -n "$namespace" -o json > "$k8s_report"; then
        print_error "Failed to extract report"
        rm -rf "$tmp_dir"
        return 1
    fi
    
    # Extract just the report section
    local report_only="$tmp_dir/report-only.json"
    if ! jq '.report' "$k8s_report" > "$report_only"; then
        print_error "Failed to parse report"
        rm -rf "$tmp_dir"
        return 1
    fi
    
    # Check if report is empty
    if [ ! -s "$report_only" ] || [ "$(cat "$report_only")" = "null" ]; then
        print_warning "Report is empty or null"
        rm -rf "$tmp_dir"
        return 1
    fi
    
    print_info "Generating HTML report..."
    
    # Get the script directory
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local html_generator="$script_dir/generate-html.sh"
    
    # Check if HTML generator exists
    if [ ! -f "$html_generator" ]; then
        print_error "HTML generator not found at: $html_generator"
        rm -rf "$tmp_dir"
        return 1
    fi
    
    # Generate HTML template and replace placeholder with JSON
    # Use a temp file to avoid sed delimiter issues
    local html_template="$tmp_dir/template.html"
    "$html_generator" > "$html_template"
    
    # Use awk to replace the placeholder, which handles special chars better than sed
    awk -v json="$(cat "$report_only" | jq -c '.')" '
        {gsub(/REPORT_DATA_PLACEHOLDER/, json); print}
    ' "$html_template" > "$output_file"
    
    if [ -f "$output_file" ] && [ -s "$output_file" ]; then
        print_info "HTML report saved to: $output_file"
        rm -rf "$tmp_dir"
        return 0
    else
        print_error "Failed to generate HTML report"
        print_warning "Debug info - report file: $report_only"
        return 1
    fi
}

# Function to convert all reports in a namespace
convert_all_reports() {
    local namespace=$1
    local output_dir=$2
    
    mkdir -p "$output_dir"
    
    print_info "Getting all VulnerabilityReports in namespace: $namespace"
    
    # Get all report names
    local reports=$(kubectl get vulnerabilityreports -n "$namespace" -o jsonpath='{.items[*].metadata.name}')
    
    if [ -z "$reports" ]; then
        print_warning "No VulnerabilityReports found in namespace: $namespace"
        return 1
    fi
    
    local count=0
    for report in $reports; do
        local output_file="$output_dir/${report}.html"
        if convert_report "$report" "$namespace" "$output_file"; then
            ((count++))
        fi
    done
    
    print_info "Successfully converted $count reports"
    print_info "Reports saved in: $output_dir"
}

# Show usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Convert Trivy Operator VulnerabilityReports to HTML format

OPTIONS:
    -n, --namespace NAMESPACE    Kubernetes namespace (required for -r, optional for -l)
    -r, --report NAME           Convert specific report by name
    -a, --all                   Convert all reports in namespace
    -o, --output FILE/DIR       Output file (for single report) or directory (for all reports)
    -l, --list                  List all vulnerability reports
    -h, --help                  Show this help message

EXAMPLES:
    # List all reports across all namespaces
    $0 --list

    # List reports in specific namespace
    $0 --list --namespace default

    # Convert a specific report
    $0 --namespace default --report deployment-nginx-xxxxx --output report.html

    # Convert all reports in a namespace
    $0 --namespace default --all --output ./reports

EOF
    exit 0
}

# Main script
main() {
    check_requirements
    
    local namespace=""
    local report_name=""
    local output=""
    local list_mode=false
    local all_mode=false
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -n|--namespace)
                namespace="$2"
                shift 2
                ;;
            -r|--report)
                report_name="$2"
                shift 2
                ;;
            -o|--output)
                output="$2"
                shift 2
                ;;
            -l|--list)
                list_mode=true
                shift
                ;;
            -a|--all)
                all_mode=true
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                print_error "Unknown option: $1"
                usage
                ;;
        esac
    done
    
    # List mode
    if [ "$list_mode" = true ]; then
        list_reports "$namespace"
        exit 0
    fi
    
    # Convert all reports in namespace
    if [ "$all_mode" = true ]; then
        if [ -z "$namespace" ]; then
            print_error "Namespace is required when using --all"
            exit 1
        fi
        
        if [ -z "$output" ]; then
            output="./trivy-reports-$(date +%Y%m%d-%H%M%S)"
        fi
        
        convert_all_reports "$namespace" "$output"
        exit 0
    fi
    
    # Convert single report
    if [ -n "$report_name" ]; then
        if [ -z "$namespace" ]; then
            print_error "Namespace is required when converting a specific report"
            exit 1
        fi
        
        if [ -z "$output" ]; then
            output="${report_name}.html"
        fi
        
        convert_report "$report_name" "$namespace" "$output"
        exit 0
    fi
    
    # No valid options provided
    print_error "No valid operation specified"
    usage
}

main "$@"
