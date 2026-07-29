  
# 🛡️ **OADP-QE CLI**

```bash
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
#   -b, --backup-location LOC   Override auto-detected backup location
#                               Values: mcg, minio, rgw, cos, gcps3, azure_sak
#                               Usually not needed - auto-detected from credentials file
#   -c, --cleanup               Delete DPAs before running tests (minimal cleanup)
#   -a, --all                   Run all tests (requires --test-folder)
#   -d, --dry-run               List tests without running them
#   -s, --setup-only            Setup prerequisites only, don't run tests
#   -h, --help                  Show this help message
#
# Advanced Options:
#   -f, --test-folder FOLDER    Override auto-detected test folder
#                               Valid values: e2e, e2e/non-admin, e2e/oadp_cli,
#                               backup_lib/backup, or backup_lib/restore
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
#   ./run_test.sh --test OADP-750 --backup-location mcg   # AWS cluster with MCG/NooBaa storage
#   ./run_test.sh --focus "capacity filter"                # Run tests matching focus pattern
#   ./run_test.sh --focus "capacity filter" -f e2e         # Focus + explicit test folder
#   ./run_test.sh --all --test-folder e2e/non-admin        # Run all non-admin tests
#   ./run_test.sh --all --test-folder e2e                  # Run all admin tests
#   ./run_test.sh --dry-run                                # List available tests
#   ./run_test.sh --setup-only                             # Setup environment only
################################################################################
```
