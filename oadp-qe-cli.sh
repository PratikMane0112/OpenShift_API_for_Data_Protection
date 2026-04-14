#!/bin/bash

################################################################################
# OADP E2E Test Runner Script
#
# This script automates the process of:
# 1. Copying credentials from oadp-pipeline-artifacts
# 2. Logging into the OpenShift cluster
# 3. Setting up bucket configuration
# 4. Running specific OADP tests via CLI
#
# Usage:
#   ./run_test.sh [OPTIONS]
#
# Options:
#   -t, --test TEST_ID          Test ID to run (e.g., OADP-638)
#   -F, --focus PATTERN         Ginkgo focus regex (e.g., "capacity filter")
#   -p, --provider PROVIDER     Cloud provider (gcp, aws, azure) - auto-detected
#   -c, --cleanup               Delete DPAs before running tests (minimal cleanup)
#   -a, --all                   Run all tests (requires --test-folder)
#   -d, --dry-run               List tests without running them
#   -s, --setup-only            Setup prerequisites only, don't run tests
#   -h, --help                  Show this help message
#
# Advanced Options:
#   -f, --test-folder FOLDER    Override auto-detected test folder
#                               Valid values: e2e, e2e/non-admin, or e2e/oadp_cli
#
# Cleanup Options:
#   --cleanup flag:      Deletes only DPAs before tests (quick, pre-test cleanup)
#   cleanup_cluster.sh:  Complete cleanup - DPAs, backups, restores, test namespaces,
#                        test users, identities, and offers logout (post-test cleanup)
#
# Examples:
#   ./run_test.sh --test OADP-638                          # Run single test (auto-detects folder)
#   ./run_test.sh --test OADP-638 --cleanup                # Run test with DPA cleanup
#   ./run_test.sh --test OADP-638 --provider aws           # Override provider detection
#   ./run_test.sh --focus "capacity filter"                # Run tests matching focus pattern
#   ./run_test.sh --focus "capacity filter" -f e2e         # Focus + explicit test folder
#   ./run_test.sh --all --test-folder e2e/non-admin        # Run all non-admin tests
#   ./run_test.sh --all --test-folder e2e                  # Run all admin tests
#   ./run_test.sh --dry-run                                # List available tests
#   ./run_test.sh --setup-only                             # Setup environment only
################################################################################

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
ARTIFACTS_DIR="oadp-pipeline-artifacts"
TEST_SETTINGS_DIR="/tmp/test-settings"
TEST_ID=""
FOCUS_PATTERN=""
TEST_FOLDER="e2e/non-admin"
CLOUD_PROVIDER=""
DO_CLEANUP=false
RUN_ALL=false
DRY_RUN=false
SETUP_ONLY=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

################################################################################
# Helper Functions
################################################################################

print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_banner() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

show_help() {
    cat << EOF
OADP E2E Test Runner Script

Usage: $0 [OPTIONS]

Options:
  -t, --test TEST_ID          Test ID to run (e.g., OADP-638)
                              Note: Test folder is auto-detected based on test location
  -F, --focus PATTERN         Ginkgo focus regex to match test descriptions
                              Use for running groups of tests by DescribeTable name
  -p, --provider PROVIDER     Cloud provider (gcp, aws, azure) - auto-detected from cluster
  -c, --cleanup               Delete DPAs before running tests (minimal cleanup)
  -a, --all                   Run all tests in the test folder (requires --test-folder)
  -d, --dry-run               List tests without running them
  -s, --setup-only            Setup prerequisites only, don't run tests
  -h, --help                  Show this help message

Advanced Options:
  -f, --test-folder FOLDER    Override auto-detected test folder
                              Valid values: e2e, e2e/non-admin, or e2e/oadp_cli
                              Note: Do NOT use e2e/app_backup - use "e2e" instead
                              Default: auto-detected based on test ID

Cleanup Options:
  --cleanup flag:      Deletes only DPAs before tests (quick, pre-test cleanup)
  cleanup_cluster.sh:  Complete cleanup - DPAs, backups, restores, test namespaces,
                       test users, identities, and offers logout (post-test cleanup)

Examples:
  $0 --test OADP-638                          # Run single test (auto-detects folder)
  $0 --test OADP-638 --cleanup                # Run test with DPA cleanup
  $0 --test OADP-638 --provider aws           # Override provider detection
  $0 --focus "capacity filter"                # Run tests matching ginkgo focus pattern
  $0 --focus "capacity filter" -f e2e         # Focus + explicit test folder
  $0 --focus "Backup configuration"           # Run all resource policy tests
  $0 --all --test-folder e2e/non-admin        # Run all non-admin tests
  $0 --all --test-folder e2e                  # Run all admin tests
  $0 --dry-run                                # List all available tests
  $0 --dry-run --test OADP-638                # Check if specific test exists
  $0 --dry-run --focus "capacity filter"      # Dry-run tests matching focus
  $0 --setup-only                             # Setup environment without running tests

Common Test Folders:
  e2e              - Admin tests (includes app_backup, hooks, schedule, etc.)
  e2e/non-admin    - Non-admin tests
  e2e/oadp_cli     - OADP CLI tests (backup/restore via oc oadp)

Note: Tests in e2e/app_backup/ are admin tests, use --test-folder e2e (or auto-detect)

EOF
}

################################################################################
# Auto-Detect Test Folder
################################################################################

auto_detect_test_folder() {
    local test_id="$1"
    
    # If test folder was explicitly provided, don't auto-detect
    if [[ "$TEST_FOLDER" != "e2e/non-admin" ]]; then
        return 0
    fi
    
    # If no test ID provided (running all tests), keep default
    if [[ -z "$test_id" ]]; then
        return 0
    fi
    
    # Search for test ID in different folders
    # Priority order: e2e/app_backup, e2e/non-admin, other e2e subdirs, then e2e root
    
    # Check if test exists in e2e/app_backup/ (admin tests)
    if grep -r "\[tc-id:$test_id\]" e2e/app_backup/ 2>/dev/null | grep -q "\.go:"; then
        TEST_FOLDER="e2e"
        print_info "Auto-detected test folder: e2e (admin test in app_backup)"
        return 0
    fi
    
    # Check if test exists in e2e/non-admin/ (non-admin tests)
    if grep -r "\[tc-id:$test_id\]" e2e/non-admin/ 2>/dev/null | grep -q "\.go:"; then
        TEST_FOLDER="e2e/non-admin"
        print_info "Auto-detected test folder: e2e/non-admin"
        return 0
    fi
    
    # Check if test exists in e2e/oadp_cli/ (CLI tests - separate ginkgo suite)
    if grep -r "\[tc-id:$test_id\]" e2e/oadp_cli/ 2>/dev/null | grep -q "\.go:"; then
        TEST_FOLDER="e2e/oadp_cli"
        print_info "Auto-detected test folder: e2e/oadp_cli (CLI test)"
        return 0
    fi

    # Check other common e2e subdirectories
    for subdir in hooks schedule security dpa_deploy credentials incremental_restore must-gather operator resource_limits subscription cacert; do
        if [ -d "e2e/$subdir" ] && grep -r "\[tc-id:$test_id\]" "e2e/$subdir/" 2>/dev/null | grep -q "\.go:"; then
            TEST_FOLDER="e2e"
            print_info "Auto-detected test folder: e2e (test found in $subdir)"
            return 0
        fi
    done
    
    # Check e2e root directory (tests directly in e2e/)
    if grep "\[tc-id:$test_id\]" e2e/*.go 2>/dev/null | grep -q ":"; then
        TEST_FOLDER="e2e"
        print_info "Auto-detected test folder: e2e (test in root)"
        return 0
    fi
    
    # If not found, keep default and warn user
    print_warning "Test $test_id not found via auto-detection, using default: $TEST_FOLDER"
    print_info "If this is incorrect, specify --test-folder explicitly"
}

################################################################################
# Auto-Detect Test Folder for Focus Pattern
################################################################################

auto_detect_focus_folder() {
    local pattern="$1"
    
    if [[ "$TEST_FOLDER" != "e2e/non-admin" ]]; then
        return 0
    fi
    
    if [[ -z "$pattern" ]]; then
        return 0
    fi
    
    # Check OADP CLI tests
    if grep -r "$pattern" e2e/oadp_cli/ 2>/dev/null | grep -q "\.go:"; then
        TEST_FOLDER="e2e/oadp_cli"
        print_info "Auto-detected test folder: e2e/oadp_cli (CLI test matching focus pattern)"
        return 0
    fi

    # Search for focus pattern in e2e/ (admin tests)
    if grep -r "$pattern" e2e/app_backup/ e2e/hooks/ e2e/schedule/ e2e/dpa_deploy/ e2e/credentials/ e2e/incremental_restore/ 2>/dev/null | grep -q "\.go:"; then
        TEST_FOLDER="e2e"
        print_info "Auto-detected test folder: e2e (admin test matching focus pattern)"
        return 0
    fi
    
    # Check non-admin
    if grep -r "$pattern" e2e/non-admin/ 2>/dev/null | grep -q "\.go:"; then
        TEST_FOLDER="e2e/non-admin"
        print_info "Auto-detected test folder: e2e/non-admin"
        return 0
    fi
    
    # Default to e2e for broad patterns
    TEST_FOLDER="e2e"
    print_warning "Could not pinpoint focus pattern location, using: $TEST_FOLDER"
    print_info "If this is incorrect, specify --test-folder explicitly"
}

################################################################################
# Parse Command Line Arguments
################################################################################

parse_args() {
    local original_test_folder="$TEST_FOLDER"
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -t|--test)
                TEST_ID="$2"
                shift 2
                ;;
            -F|--focus)
                FOCUS_PATTERN="$2"
                shift 2
                ;;
            -f|--test-folder)
                TEST_FOLDER="$2"
                # Validate test folder
                if [[ "$TEST_FOLDER" != "e2e" ]] && [[ "$TEST_FOLDER" != "e2e/non-admin" ]] && [[ "$TEST_FOLDER" != "e2e/oadp_cli" ]]; then
                    print_error "Invalid test folder: $TEST_FOLDER"
                    print_info "Valid options: e2e, e2e/non-admin, or e2e/oadp_cli"
                    print_info "Note: For tests in e2e/app_backup/, use --test-folder e2e (or omit for auto-detect)"
                    exit 1
                fi
                shift 2
                ;;
            -p|--provider)
                CLOUD_PROVIDER="$2"
                shift 2
                ;;
            -c|--cleanup)
                DO_CLEANUP=true
                shift
                ;;
            -a|--all)
                RUN_ALL=true
                shift
                ;;
            -d|--dry-run)
                DRY_RUN=true
                shift
                ;;
            -s|--setup-only)
                SETUP_ONLY=true
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done

    # Validate arguments
    if [[ "$SETUP_ONLY" == false ]] && [[ "$DRY_RUN" == false ]]; then
        if [[ "$RUN_ALL" == false ]] && [[ -z "$TEST_ID" ]] && [[ -z "$FOCUS_PATTERN" ]]; then
            print_error "Either --test, --focus, or --all must be specified"
            show_help
            exit 1
        fi
    fi

    # --test and --focus are mutually exclusive
    if [[ -n "$TEST_ID" ]] && [[ -n "$FOCUS_PATTERN" ]]; then
        print_error "--test and --focus cannot be used together"
        exit 1
    fi
    
    # Auto-detect test folder if not explicitly set
    if [[ -n "$TEST_ID" ]] && [[ "$TEST_FOLDER" == "$original_test_folder" ]]; then
        auto_detect_test_folder "$TEST_ID"
    fi
    
    # Auto-detect test folder for --focus if not explicitly set
    if [[ -n "$FOCUS_PATTERN" ]] && [[ "$TEST_FOLDER" == "$original_test_folder" ]]; then
        auto_detect_focus_folder "$FOCUS_PATTERN"
    fi
    
    # Set RUN_ALL to true if doing dry-run without specific test or focus
    if [[ "$DRY_RUN" == true ]] && [[ -z "$TEST_ID" ]] && [[ -z "$FOCUS_PATTERN" ]]; then
        RUN_ALL=true
    fi
    
    # For dry-run without existing setup, set defaults
    if [[ "$DRY_RUN" == true ]] && ! check_existing_setup; then
        CLOUD_PROVIDER="gcp"
        BUCKET_NAME="dummy-bucket"
        CREDS_SUFFIX="gcp"
        export CLOUD_PROVIDER="$CLOUD_PROVIDER"
        export BUCKET="$BUCKET_NAME"
    fi
}

################################################################################
# Check Prerequisites
################################################################################

check_prerequisites() {
    print_banner "Checking Prerequisites"
    
    local missing_tools=()
    
    # Check for required tools
    for tool in oc go ginkgo jq; do
        if ! command -v $tool &> /dev/null; then
            missing_tools+=($tool)
        else
            print_success "$tool is installed"
        fi
    done
    
    if [ ${#missing_tools[@]} -gt 0 ]; then
        print_error "Missing required tools: ${missing_tools[*]}"
        print_info "Please install missing tools and try again"
        exit 1
    fi
    
    # Check if artifacts directory exists
    if [ ! -d "$ARTIFACTS_DIR" ]; then
        print_error "Artifacts directory not found: $ARTIFACTS_DIR"
        print_info "Please ensure oadp-pipeline-artifacts directory exists"
        exit 1
    fi
    
    print_success "All prerequisites met"
    echo
}

################################################################################
# Check if Setup Already Done
################################################################################

check_existing_setup() {
    # Check if setup is already complete
    # Use the cached kubeconfig (not ambient) to verify cluster connectivity
    if [ -f "$TEST_SETTINGS_DIR/.setup_complete" ] && \
       [ -f "$TEST_SETTINGS_DIR/kubeconfig" ] && \
       [ -f "$TEST_SETTINGS_DIR/credentials" ] && \
       KUBECONFIG="$TEST_SETTINGS_DIR/kubeconfig" oc whoami &> /dev/null; then
        return 0  # Setup is complete
    else
        return 1  # Setup needed
    fi
}

################################################################################
# Setup Test Settings Directory
################################################################################

setup_test_settings() {
    print_banner "Setting Up Test Environment"
    
    # Check if setup already done
    if check_existing_setup; then
        print_success "Setup already completed, using existing configuration"
        print_info "Settings directory: $TEST_SETTINGS_DIR"
        print_info "Current user: $(oc whoami 2>/dev/null || echo 'unknown')"
        print_info "To force fresh setup, delete: $TEST_SETTINGS_DIR/.setup_complete"
        echo
        return 0
    fi
    
    # Create test settings directory
    mkdir -p "$TEST_SETTINGS_DIR"
    print_success "Created test settings directory: $TEST_SETTINGS_DIR"
    
    # Check for required files in artifacts directory
    local required_files=("kubeconfig" "credentials" "bucket.json" "login.txt")
    local missing_files=()
    
    for file in "${required_files[@]}"; do
        if [ ! -f "$ARTIFACTS_DIR/$file" ]; then
            missing_files+=($file)
        fi
    done
    
    if [ ${#missing_files[@]} -gt 0 ]; then
        print_error "Missing required files in $ARTIFACTS_DIR: ${missing_files[*]}"
        exit 1
    fi
    
    print_success "All required artifact files found"
    echo
}

################################################################################
# Copy Credentials
################################################################################

copy_credentials() {
    print_banner "Copying Credentials"
    
    # Copy kubeconfig
    cp "$ARTIFACTS_DIR/kubeconfig" "$TEST_SETTINGS_DIR/kubeconfig"
    chmod 600 "$TEST_SETTINGS_DIR/kubeconfig"
    print_success "Copied kubeconfig"
    
    # Copy credentials
    cp "$ARTIFACTS_DIR/credentials" "$TEST_SETTINGS_DIR/credentials"
    chmod 600 "$TEST_SETTINGS_DIR/credentials"
    print_success "Copied cloud credentials"
    
    # Export KUBECONFIG
    export KUBECONFIG="$TEST_SETTINGS_DIR/kubeconfig"
    print_success "Set KUBECONFIG environment variable"
    
    echo
}

################################################################################
# Extract Bucket Name
################################################################################

extract_bucket_name() {
    print_banner "Extracting Bucket Configuration"
    
    if [ ! -f "$ARTIFACTS_DIR/bucket.json" ]; then
        print_error "bucket.json not found in $ARTIFACTS_DIR"
        exit 1
    fi
    
    BUCKET_NAME=$(jq -r '.bucket_name' "$ARTIFACTS_DIR/bucket.json")
    
    if [ -z "$BUCKET_NAME" ] || [ "$BUCKET_NAME" == "null" ]; then
        print_error "Failed to extract bucket name from bucket.json"
        exit 1
    fi
    
    print_success "Extracted bucket name: $BUCKET_NAME"
    echo
}

################################################################################
# Login to Cluster
################################################################################

login_to_cluster() {
    print_banner "Logging Into OpenShift Cluster"
    
    if [ ! -f "$ARTIFACTS_DIR/login.txt" ]; then
        print_error "login.txt not found in $ARTIFACTS_DIR"
        exit 1
    fi
    
    # Extract and execute login command
    LOGIN_CMD=$(cat "$ARTIFACTS_DIR/login.txt")
    print_info "Executing: $LOGIN_CMD"
    
    # Execute login command
    if eval "$LOGIN_CMD"; then
        print_success "Successfully logged into cluster"
    else
        print_error "Failed to login to cluster"
        exit 1
    fi
    
    # Verify login
    print_info "Current user: $(oc whoami)"
    print_info "Cluster info:"
    oc cluster-info | head -3
    
    echo
}

################################################################################
# Detect Cloud Provider
################################################################################

detect_cloud_provider() {
    print_banner "Detecting Cloud Provider"
    
    if [ -z "$CLOUD_PROVIDER" ]; then
        # Auto-detect from cluster
        CLOUD_PROVIDER=$(oc get infrastructures cluster -o jsonpath='{.status.platform}' 2>/dev/null | tr '[:upper:]' '[:lower:]')
        
        if [ -z "$CLOUD_PROVIDER" ]; then
            print_error "Failed to auto-detect cloud provider"
            print_info "Please specify provider using --provider option"
            exit 1
        fi
        
        # Remove -arm suffix if present
        CLOUD_PROVIDER="${CLOUD_PROVIDER//-arm/}"
        # Remove -fips suffix if present
        CLOUD_PROVIDER="${CLOUD_PROVIDER//-fips/}"
        
        print_success "Auto-detected cloud provider: $CLOUD_PROVIDER"
    else
        print_success "Using specified cloud provider: $CLOUD_PROVIDER"
    fi
    
    # Determine credentials file name based on provider
    case "$CLOUD_PROVIDER" in
        gcp)
            CREDS_SUFFIX="gcp"
            ;;
        aws)
            CREDS_SUFFIX="aws"
            ;;
        azure)
            CREDS_SUFFIX="azure"
            ;;
        *)
            print_warning "Unknown cloud provider: $CLOUD_PROVIDER, using generic credentials"
            CREDS_SUFFIX="${CLOUD_PROVIDER}"
            ;;
    esac
    
    # Copy credentials with provider-specific name
    cp "$TEST_SETTINGS_DIR/credentials" "$TEST_SETTINGS_DIR/${CREDS_SUFFIX}_creds"
    print_success "Created provider-specific credentials file: ${CREDS_SUFFIX}_creds"
    
    # Copy credentials for VSL (same credentials work for volume snapshots)
    cp "$TEST_SETTINGS_DIR/credentials" "$TEST_SETTINGS_DIR/${CREDS_SUFFIX}_vsl_creds"
    print_success "Created VSL credentials file: ${CREDS_SUFFIX}_vsl_creds"
    
    echo
}

################################################################################
# Check OADP Installation
################################################################################

check_oadp_installation() {
    print_banner "Checking OADP Installation"
    
    # Check if openshift-adp namespace exists
    if ! oc get namespace openshift-adp &> /dev/null; then
        print_error "openshift-adp namespace does not exist"
        print_info "Please install OADP operator first"
        exit 1
    fi
    
    print_success "openshift-adp namespace exists"
    
    # Check OADP pods
    print_info "OADP pods status:"
    oc get pods -n openshift-adp
    
    # Check for existing DPAs
    DPA_COUNT=$(oc get dpa -n openshift-adp --no-headers 2>/dev/null | wc -l)
    
    if [ "$DPA_COUNT" -gt 0 ]; then
        print_warning "Found $DPA_COUNT existing DPA(s)"
        oc get dpa -n openshift-adp
        
        if [ "$DO_CLEANUP" == true ]; then
            print_info "Cleaning up existing DPAs (--cleanup flag)..."
            oc delete dpa --all -n openshift-adp
            print_success "Deleted all DPAs"
            print_info "Note: For complete cleanup after testing, run: ./cleanup_cluster.sh"
        else
            print_warning "Use --cleanup flag to remove existing DPAs before testing"
            print_info "Or run ./cleanup_cluster.sh for complete cleanup after testing"
        fi
    else
        print_success "No existing DPAs found"
    fi
    
    echo
}

################################################################################
# Mark Setup as Complete
################################################################################

mark_setup_complete() {
    echo "# Setup completed at: $(date)" > "$TEST_SETTINGS_DIR/.setup_complete"
    echo "CLOUD_PROVIDER=$CLOUD_PROVIDER" >> "$TEST_SETTINGS_DIR/.setup_complete"
    echo "BUCKET=$BUCKET_NAME" >> "$TEST_SETTINGS_DIR/.setup_complete"
    echo "CREDS_SUFFIX=$CREDS_SUFFIX" >> "$TEST_SETTINGS_DIR/.setup_complete"
}

################################################################################
# Load Existing Setup
################################################################################

load_existing_setup() {
    if [ -f "$TEST_SETTINGS_DIR/.setup_complete" ]; then
        source "$TEST_SETTINGS_DIR/.setup_complete"
        export KUBECONFIG="$TEST_SETTINGS_DIR/kubeconfig"
        BUCKET_NAME="$BUCKET"
        
        # Ensure VSL credentials file exists (same creds work for volume snapshots)
        if [ -n "$CREDS_SUFFIX" ] && [ -f "$TEST_SETTINGS_DIR/${CREDS_SUFFIX}_creds" ] && \
           [ ! -f "$TEST_SETTINGS_DIR/${CREDS_SUFFIX}_vsl_creds" ]; then
            cp "$TEST_SETTINGS_DIR/${CREDS_SUFFIX}_creds" "$TEST_SETTINGS_DIR/${CREDS_SUFFIX}_vsl_creds"
        fi
        
        return 0
    fi
    return 1
}

################################################################################
# Display Test Configuration
################################################################################

display_test_config() {
    print_banner "Test Configuration"
    
    cat << EOF
${BLUE}Cloud Provider:${NC}     $CLOUD_PROVIDER
${BLUE}Bucket Name:${NC}        $BUCKET_NAME
${BLUE}Test Folder:${NC}        $TEST_FOLDER
${BLUE}Test ID:${NC}            ${TEST_ID:-"N/A"}
${BLUE}Focus Pattern:${NC}      ${FOCUS_PATTERN:-"N/A"}
${BLUE}Target:${NC}             ${TEST_ID:-${FOCUS_PATTERN:-"All tests"}}
${BLUE}Credentials File:${NC}   $TEST_SETTINGS_DIR/${CREDS_SUFFIX}_creds
${BLUE}Kubeconfig:${NC}         $TEST_SETTINGS_DIR/kubeconfig
${BLUE}Cleanup DPAs:${NC}       $DO_CLEANUP
${BLUE}Run All Tests:${NC}      $RUN_ALL
${BLUE}Dry Run:${NC}            $DRY_RUN
${BLUE}Setup Only:${NC}         $SETUP_ONLY

EOF
}

################################################################################
# Run Tests
################################################################################

run_tests() {
    if [ "$DRY_RUN" == true ]; then
        print_banner "Listing Available OADP Tests (Dry Run)"
    else
        print_banner "Running OADP Tests"
    fi
    
    cd "$SCRIPT_DIR"
    
    # Build environment variables
    export CLOUD_PROVIDER="$CLOUD_PROVIDER"
    export BUCKET="$BUCKET_NAME"
    export TESTS_FOLDER="$TEST_FOLDER"
    export OADP_CREDS_FILE="$TEST_SETTINGS_DIR/${CREDS_SUFFIX}_creds"
    export BACKUP_LOCATION="$CLOUD_PROVIDER"
    
    # Determine the ginkgo focus string
    # Note: test_runner.sh splits EXTRA_GINKGO_PARAMS by spaces (tr ' ' '\n'),
    # so spaces in focus values must be replaced with regex '.' to survive the split.
    local focus_value=""
    local focus_label=""
    if [ -n "$TEST_ID" ]; then
        focus_value="$TEST_ID"
        focus_label="test: $TEST_ID"
    elif [ -n "$FOCUS_PATTERN" ]; then
        focus_value="${FOCUS_PATTERN// /.}"
        focus_label="focus: $FOCUS_PATTERN (regex: $focus_value)"
    fi

    # Set focus parameter if specific test or focus is requested
    if [ -n "$focus_value" ]; then
        if [ "$DRY_RUN" == true ]; then
            export EXTRA_GINKGO_PARAMS="--ginkgo.dry-run --focus=$focus_value"
            print_info "Listing $focus_label"
        else
            export EXTRA_GINKGO_PARAMS="--focus=$focus_value"
            print_info "Running $focus_label"
        fi
    elif [ "$RUN_ALL" == true ]; then
        if [ "$DRY_RUN" == true ]; then
            export EXTRA_GINKGO_PARAMS="--ginkgo.dry-run"
            print_info "Listing all tests in: $TEST_FOLDER"
        else
            export EXTRA_GINKGO_PARAMS=""
            print_info "Running all tests in: $TEST_FOLDER"
        fi
    fi
    
    # Display environment
    print_info "Environment variables:"
    echo "  CLOUD_PROVIDER=$CLOUD_PROVIDER"
    echo "  BUCKET=$BUCKET"
    echo "  TESTS_FOLDER=$TESTS_FOLDER"
    echo "  OADP_CREDS_FILE=$OADP_CREDS_FILE"
    echo "  BACKUP_LOCATION=$BACKUP_LOCATION"
    echo "  EXTRA_GINKGO_PARAMS=$EXTRA_GINKGO_PARAMS"
    echo
    
    if [ "$DRY_RUN" == true ]; then
        print_info "Starting dry run (listing tests only)..."
    else
        print_info "Starting test execution..."
    fi
    echo
    
    # Run tests using make and capture exit code
    set +e  # Don't exit immediately on error
    make run
    TEST_EXIT_CODE=$?
    set -e
    
    return $TEST_EXIT_CODE
}

################################################################################
# Display Results
################################################################################

display_results() {
    local exit_code=$1
    print_banner "Test Results"
    
    # Look for JUnit reports
    JUNIT_REPORT="$SCRIPT_DIR/$TEST_FOLDER/junit_report.xml"
    
    if [ -f "$JUNIT_REPORT" ]; then
        print_success "JUnit report generated: $JUNIT_REPORT"
        
        # Extract basic stats if xmllint is available
        if command -v xmllint &> /dev/null; then
            print_info "Test Summary:"
            xmllint --xpath "string(//testsuite/@tests)" "$JUNIT_REPORT" 2>/dev/null && echo " tests total"
            xmllint --xpath "string(//testsuite/@failures)" "$JUNIT_REPORT" 2>/dev/null && echo " failures"
            xmllint --xpath "string(//testsuite/@errors)" "$JUNIT_REPORT" 2>/dev/null && echo " errors"
        fi
    else
        print_warning "JUnit report not found at expected location"
    fi
    
    echo
    if [ $exit_code -eq 0 ]; then
        print_success "Test execution completed!"
    else
        print_error "Test execution failed with exit code: $exit_code"
    fi
}

################################################################################
# Post-Execution Cleanup (for failed tests)
################################################################################

post_execution_cleanup() {
    local test_failed=$1
    
    if [ "$test_failed" -ne 0 ]; then
        print_banner "Post-Execution Cleanup"
        print_warning "Tests failed. Checking for leftover resources..."
        
        # Check for hanging namespaces
        TEST_NAMESPACES=$(oc get ns --no-headers 2>/dev/null | grep -E "test-oadp-|oadp-test-" | awk '{print $1}')
        if [ -n "$TEST_NAMESPACES" ]; then
            print_info "Found test namespaces:"
            echo "$TEST_NAMESPACES"
            
            read -p "Do you want to clean up these test namespaces? (y/N) " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                for ns in $TEST_NAMESPACES; do
                    print_info "Deleting namespace: $ns"
                    oc delete ns "$ns" --wait=false 2>/dev/null || true
                done
                print_success "Initiated namespace cleanup"
            fi
        fi
        
        # Check for multiple DPAs
        DPA_COUNT=$(oc get dpa -n openshift-adp --no-headers 2>/dev/null | wc -l)
        if [ "$DPA_COUNT" -gt 1 ]; then
            print_warning "Found $DPA_COUNT DPAs (more than expected)"
            oc get dpa -n openshift-adp
            
            read -p "Do you want to delete all DPAs? (y/N) " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                oc delete dpa --all -n openshift-adp
                print_success "Deleted all DPAs"
            fi
        fi
        
        # Check for stuck pods
        STUCK_PODS=$(oc get pods -n openshift-adp --no-headers 2>/dev/null | grep -E "Error|CrashLoopBackOff|ImagePullBackOff" || true)
        if [ -n "$STUCK_PODS" ]; then
            print_warning "Found pods in error state:"
            echo "$STUCK_PODS"
        fi
        
        echo
        print_info "For complete cleanup, run: ./cleanup_cluster.sh"
    fi
}

################################################################################
# Cleanup Function
################################################################################

cleanup_on_exit() {
    local exit_code=$?
    
    if [ $exit_code -ne 0 ]; then
        echo
        print_error "Script exited with error code: $exit_code"
        print_info "Check the logs above for details"
    fi
}

################################################################################
# Main Execution
################################################################################

main() {
    # Set trap for cleanup
    trap cleanup_on_exit EXIT
    
    if [ "$SETUP_ONLY" == true ]; then
        print_banner "OADP E2E Test Environment Setup"
    elif [ "$DRY_RUN" == true ]; then
        print_banner "OADP E2E Test Listing (Dry Run)"
    else
        print_banner "OADP E2E Test Runner"
    fi
    echo
    
    # Parse command line arguments
    parse_args "$@"
    
    # For dry-run without setup, skip directly to test listing
    if [ "$DRY_RUN" == true ] && ! check_existing_setup; then
        print_info "Running dry-run without cluster setup"
        print_info "Test folder: $TEST_FOLDER"
        echo
        
        cd "$SCRIPT_DIR"
        
        # Create minimal dummy kubeconfig for dry-run
        DUMMY_KUBECONFIG="/tmp/.oadp-dryrun-kubeconfig"
        cat > "$DUMMY_KUBECONFIG" << 'EOF'
apiVersion: v1
kind: Config
clusters:
- cluster:
    server: https://localhost:6443
  name: dry-run-cluster
contexts:
- context:
    cluster: dry-run-cluster
    user: dry-run-user
  name: dry-run-context
current-context: dry-run-context
users:
- name: dry-run-user
  user:
    token: dry-run-token
EOF
        export KUBECONFIG="$DUMMY_KUBECONFIG"
        
        # Call ginkgo directly to bypass test_runner.sh cluster checks
        if [ -n "$TEST_ID" ]; then
            GINKGO_FOCUS="--focus=$TEST_ID"
            print_info "Listing test: $TEST_ID"
        elif [ -n "$FOCUS_PATTERN" ]; then
            GINKGO_FOCUS="--focus=${FOCUS_PATTERN// /.}"
            print_info "Listing tests matching: $FOCUS_PATTERN"
        else
            GINKGO_FOCUS=""
            print_info "Listing all tests in: $TEST_FOLDER"
        fi
        
        echo
        print_info "Using dummy kubeconfig for dry-run (no cluster connection)"
        print_info "Running: ginkgo --dry-run $GINKGO_FOCUS $TEST_FOLDER/"
        echo
        
        set +e
        if command -v ginkgo &> /dev/null; then
            ginkgo --dry-run $GINKGO_FOCUS "$TEST_FOLDER/" 2>&1 | grep -v "Setting up clients" | grep -v "KUBERNETES_SERVICE" || true
            TEST_EXIT_CODE=${PIPESTATUS[0]}
        else
            print_error "ginkgo command not found"
            print_info "Please install ginkgo: go install github.com/onsi/ginkgo/v2/ginkgo@latest"
            TEST_EXIT_CODE=1
        fi
        set -e
        
        # Clean up dummy kubeconfig
        rm -f "$DUMMY_KUBECONFIG"
        
        echo
        if [ $TEST_EXIT_CODE -eq 0 ]; then
            print_banner "Test Listing Completed"
            print_info "To run these tests, first do: ./run_test.sh --setup-only"
        else
            print_banner "Test Listing Completed (with warnings)"
            print_info "Some warnings are expected during dry-run without cluster"
            print_info "To run these tests, first do: ./run_test.sh --setup-only"
        fi
        exit 0
    fi
    
    # Check if setup already exists and load it
    if check_existing_setup && [ "$SETUP_ONLY" == false ]; then
        print_info "Using existing setup configuration"
        load_existing_setup
        
        # Quick validation
        print_info "Current user: $(oc whoami)"
        print_info "Cloud provider: $CLOUD_PROVIDER"
        print_info "Bucket: $BUCKET"
        echo
        
        # Skip to configuration display
        display_test_config
    else
        # Execute full setup workflow
        check_prerequisites
        setup_test_settings
        
        # Only continue with setup if not already complete
        if ! check_existing_setup; then
            copy_credentials
            extract_bucket_name
            login_to_cluster
            detect_cloud_provider
            check_oadp_installation
            mark_setup_complete
        else
            load_existing_setup
        fi
        
        display_test_config
    fi
    
    # If setup-only mode, exit here
    if [ "$SETUP_ONLY" == true ]; then
        echo
        print_banner "Verifying Setup"
        
        # Verify cluster login
        print_info "Checking cluster connectivity..."
        if oc whoami &> /dev/null; then
            print_success "Logged in as: $(oc whoami)"
            print_success "Cluster: $(oc whoami --show-server)"
        else
            print_error "Not logged into cluster!"
            print_info "Please login using: $(cat $ARTIFACTS_DIR/login.txt 2>/dev/null || echo 'oc login ...')"
            exit 1
        fi
        
        # Verify OADP namespace
        print_info "Checking OADP installation..."
        if oc get namespace openshift-adp &> /dev/null; then
            print_success "OADP namespace exists"
        else
            print_warning "OADP namespace not found - please install OADP operator"
        fi
        
        echo
        print_banner "Setup Completed Successfully"
        echo
        print_success "Environment is ready for testing!"
        echo
        echo "Configuration:"
        echo "  Cloud Provider: $CLOUD_PROVIDER"
        echo "  Bucket: $BUCKET_NAME"
        echo "  Settings: $TEST_SETTINGS_DIR"
        echo
        echo "To run tests, use:"
        echo "  ./run_test.sh --test OADP-638"
        echo "  ./run_test.sh --dry-run  # List available tests"
        echo "  ./run_test.sh --all      # Run all tests"
        echo
        exit 0
    fi
    
    # Run tests and capture exit code
    set +e
    run_tests
    TEST_EXIT_CODE=$?
    set -e
    
    # Display results with exit code
    if [ "$DRY_RUN" == false ]; then
        display_results $TEST_EXIT_CODE
        
        # Post-execution cleanup if tests failed
        post_execution_cleanup $TEST_EXIT_CODE
    fi
    
    if [ $TEST_EXIT_CODE -eq 0 ]; then
        if [ "$DRY_RUN" == true ]; then
            print_banner "Test Listing Completed"
        else
            print_banner "All Operations Completed Successfully"
        fi
    else
        if [ "$DRY_RUN" == true ]; then
            print_banner "Test Listing Failed - Review Output Above"
        else
            print_banner "Tests Failed - Review Logs Above"
        fi
        exit $TEST_EXIT_CODE
    fi
}

# Run main function
main "$@"
