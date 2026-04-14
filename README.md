  
# 🛡️ **OADP-QE CLI**

```bash
################################################################################
## oadp-qe cli tool (work in progress...)
################################################################################
#
# This tool automates the process of:
# 1. Copying credentials from oadp-pipeline-artifacts
# 2. Logging into the OpenShift cluster
# 3. Setting up bucket configuration
# 4. Running specific OADP tests via CLI
#
# Usage:
#   oadp-qe [OPTIONS]
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
#   oadp-qe  --test OADP-638                          # Run single test (auto-detects folder)
#   oadp-qe  --test OADP-638 --cleanup                # Run test with DPA cleanup
#   oadp-qe  --test OADP-638 --provider aws           # Override provider detection
#   oadp-qe  --focus "capacity filter"                # Run tests matching focus pattern
#   oadp-qe  --focus "capacity filter" -f e2e         # Focus + explicit test folder
#   oadp-qe  --all --test-folder e2e/non-admin        # Run all non-admin tests
#   oadp-qe  --all --test-folder e2e                  # Run all admin tests
#   oadp-qe  --dry-run                                # List available tests
#   oadp-qe  --setup-only                             # Setup environment only
#
################################################################################
```
