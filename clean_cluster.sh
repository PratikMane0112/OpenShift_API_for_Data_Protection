#!/bin/bash

################################################################################
# OADP E2E Cluster Cleanup Script
#
# Removes all stale resources left behind by previous test runs.
# Works for every test case in this project (admin, non-admin, CSI, datamover,
# kubevirt, schedule, multi-namespace, cross-cluster, etc.).
#
# Usage:
#   ./cleanup_cluster.sh              # Interactive (prompts before destructive steps)
#   ./cleanup_cluster.sh --force      # Non-interactive (skips prompts)
#   ./cleanup_cluster.sh --dry-run    # Show what would be deleted without deleting
#
# What it cleans:
#   1. Velero CRs       - Backups, Restores, Schedules, DeleteBackupRequests,
#                          DownloadRequests, DataUploads, DataDownloads,
#                          BackupRepositories
#   2. OADP CRs         - DataProtectionApplications, CloudStorage
#   3. Non-Admin CRs    - NonAdminBackups, NonAdminRestores,
#                          NonAdminBackupStorageLocations
#   4. Snapshot CRs      - VolumeSnapshots (namespaced), VolumeSnapshotContents
#                          (cluster-scoped), test VolumeSnapshotClass
#   5. Test namespaces   - test-oadp-*, oadp-test-*, kubevirt-velero-*
#   6. Parallel OADP ns  - openshift-adp-2, openshift-adp-3, ...,
#                          openshift-adp-100, openshift-adp-200,
#                          openshift-adp-100000000000000000000000
#   7. Test ConfigMaps   - resource-policy CMs, node-agent-config,
#                          change-storageclass-config in OADP namespace
#   8. Non-admin users   - Test users, identities from htpasswd provider
################################################################################

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

OADP_NAMESPACE="${OADP_NAMESPACE:-openshift-adp}"
FORCE=false
DRY_RUN=false
ERRORS=0

for arg in "$@"; do
    case $arg in
        --force|-f)  FORCE=true ;;
        --dry-run|-n) DRY_RUN=true ;;
        --help|-h)
            head -33 "$0" | tail -30
            exit 0
            ;;
        *)
            echo "Unknown option: $arg"
            exit 1
            ;;
    esac
done

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()     { echo -e "${RED}[ERR]${NC}  $*"; }

confirm() {
    if $FORCE || $DRY_RUN; then return 0; fi
    read -p "$(echo -e "${YELLOW}$1 (y/N)${NC} ")" -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]]
}

run() {
    if $DRY_RUN; then
        echo -e "  ${BLUE}[dry-run]${NC} $*"
        return 0
    fi
    eval "$@" 2>/dev/null || true
}

strip_finalizers() {
    local resource_type=$1
    local namespace=$2

    local items
    items=$(oc get "$resource_type" -n "$namespace" \
        -o jsonpath='{range .items[?(@.metadata.deletionTimestamp)]}{.metadata.name}{"\n"}{end}' 2>/dev/null) || return 0

    for item in $items; do
        info "  Stripping finalizers from $resource_type/$item"
        run "oc patch '$resource_type' '$item' -n '$namespace' --type=merge -p '{\"metadata\":{\"finalizers\":null}}'"
    done
}

strip_ns_finalizers() {
    local ns=$1
    local phase
    phase=$(oc get ns "$ns" -o jsonpath='{.status.phase}' 2>/dev/null) || return 0
    if [ "$phase" = "Terminating" ]; then
        info "  Stripping finalizers from namespace/$ns (stuck Terminating)"
        run "oc patch namespace '$ns' --type=merge -p '{\"metadata\":{\"finalizers\":null},\"spec\":{\"finalizers\":[]}}'"
    fi
}

################################################################################

echo ""
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  OADP E2E Cluster Cleanup${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

if $DRY_RUN; then
    warn "DRY-RUN mode: no resources will be deleted"
    echo ""
fi

if ! oc whoami &>/dev/null; then
    err "Not logged in to OpenShift. Run 'oc login' first."
    exit 1
fi

info "Cluster: $(oc whoami --show-server 2>/dev/null)"
info "User:    $(oc whoami 2>/dev/null)"
info "OADP NS: $OADP_NAMESPACE"
echo ""

################################################################################
# Discover all OADP namespaces (base + parallel)
################################################################################
ALL_OADP_NS=("$OADP_NAMESPACE")
PARALLEL_NS=$(oc get ns --no-headers 2>/dev/null \
    | awk '{print $1}' \
    | grep -E "^${OADP_NAMESPACE}-[0-9]+" || true)
if [ -n "$PARALLEL_NS" ]; then
    while IFS= read -r ns; do
        ALL_OADP_NS+=("$ns")
    done <<< "$PARALLEL_NS"
fi

if [ "${#ALL_OADP_NS[@]}" -gt 1 ]; then
    info "Found ${#ALL_OADP_NS[@]} OADP namespaces (includes parallel-run namespaces)"
fi

################################################################################
# 1. Velero CRs (order: schedules -> backups -> restores -> data movers -> repos)
################################################################################
echo ""
info "=== Step 1: Velero Custom Resources ==="

VELERO_TYPES=(
    "schedules.velero.io"
    "deletebackuprequests.velero.io"
    "downloadrequests.velero.io"
    "backups.velero.io"
    "restores.velero.io"
    "podvolumebackups.velero.io"
    "podvolumerestores.velero.io"
    "datauploads.velero.io"
    "datadownloads.velero.io"
    "backuprepositories.velero.io"
)

for ns in "${ALL_OADP_NS[@]}"; do
    for crd in "${VELERO_TYPES[@]}"; do
        count=$(oc get "$crd" -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        if [ "$count" -gt 0 ]; then
            info "Deleting $count $crd in $ns"
            run "oc delete '$crd' --all -n '$ns' --wait=false"
            strip_finalizers "$crd" "$ns"
            run "oc delete '$crd' --all -n '$ns' --force --grace-period=0"
        fi
    done
done
success "Velero CRs cleaned"

################################################################################
# 2. VolumeSnapshots (namespaced) in OADP + test namespaces
################################################################################
echo ""
info "=== Step 2: VolumeSnapshots ==="

VS_NAMESPACES=$(oc get volumesnapshots --all-namespaces --no-headers 2>/dev/null | awk '{print $1}' | sort -u || true)
if [ -n "$VS_NAMESPACES" ]; then
    for ns in $VS_NAMESPACES; do
        count=$(oc get volumesnapshots -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        info "Deleting $count VolumeSnapshots in $ns"
        run "oc delete volumesnapshots --all -n '$ns' --force --grace-period=0"
    done
    success "VolumeSnapshots cleaned"
else
    success "No VolumeSnapshots found"
fi

################################################################################
# 3. VolumeSnapshotContents (cluster-scoped)
################################################################################
echo ""
info "=== Step 3: VolumeSnapshotContents (cluster-scoped) ==="

VSC_COUNT=$(oc get volumesnapshotcontents --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$VSC_COUNT" -gt 0 ]; then
    info "Deleting $VSC_COUNT VolumeSnapshotContents"
    run "oc delete volumesnapshotcontents --all --wait=false"

    STUCK_VSC=$(oc get volumesnapshotcontents \
        -o jsonpath='{range .items[?(@.metadata.deletionTimestamp)]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
    for vsc in $STUCK_VSC; do
        info "  Stripping finalizers from VolumeSnapshotContent/$vsc"
        run "oc patch volumesnapshotcontent '$vsc' --type=merge -p '{\"metadata\":{\"finalizers\":null}}'"
    done
    run "oc delete volumesnapshotcontents --all --force --grace-period=0"
    success "VolumeSnapshotContents cleaned"
else
    success "No VolumeSnapshotContents found"
fi

################################################################################
# 4. Test VolumeSnapshotClass
################################################################################
echo ""
info "=== Step 4: Test VolumeSnapshotClass ==="

if oc get volumesnapshotclass example-snapclass &>/dev/null; then
    info "Deleting VolumeSnapshotClass 'example-snapclass'"
    run "oc delete volumesnapshotclass example-snapclass --ignore-not-found"
    success "VolumeSnapshotClass cleaned"
else
    success "No test VolumeSnapshotClass found"
fi

################################################################################
# 5. OADP CRs (DPA, CloudStorage)
################################################################################
echo ""
info "=== Step 5: OADP Custom Resources ==="

for ns in "${ALL_OADP_NS[@]}"; do
    dpa_count=$(oc get dpa -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$dpa_count" -gt 0 ]; then
        if confirm "Delete $dpa_count DataProtectionApplication(s) in $ns?"; then
            info "Deleting DPAs in $ns"
            run "oc delete dpa --all -n '$ns'"
        fi
    fi

    cs_count=$(oc get cloudstorage -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [ "$cs_count" -gt 0 ]; then
        info "Deleting $cs_count CloudStorage in $ns"
        run "oc delete cloudstorage --all -n '$ns'"
    fi
done
success "OADP CRs cleaned"

################################################################################
# 6. Non-Admin CRs
################################################################################
echo ""
info "=== Step 6: Non-Admin Custom Resources ==="

NONADMIN_TYPES=(
    "nonadminbackups.oadp.openshift.io"
    "nonadminrestores.oadp.openshift.io"
    "nonadminbackupstoragelocations.oadp.openshift.io"
)

HAS_NONADMIN=false
for crd in "${NONADMIN_TYPES[@]}"; do
    if oc api-resources --no-headers 2>/dev/null | grep -q "$crd"; then
        HAS_NONADMIN=true
        na_items=$(oc get "$crd" --all-namespaces --no-headers 2>/dev/null | wc -l | tr -d ' ')
        if [ "$na_items" -gt 0 ]; then
            info "Deleting $na_items $crd (all namespaces)"
            NONADMIN_NS=$(oc get "$crd" --all-namespaces --no-headers 2>/dev/null | awk '{print $1}' | sort -u)
            for ns in $NONADMIN_NS; do
                run "oc delete '$crd' --all -n '$ns' --force --grace-period=0"
            done
        fi
    fi
done

if $HAS_NONADMIN; then
    success "Non-Admin CRs cleaned"
else
    success "Non-Admin CRDs not installed, skipping"
fi

################################################################################
# 7. Test ConfigMaps in OADP namespace
################################################################################
echo ""
info "=== Step 7: Test ConfigMaps ==="

TEST_CM_PATTERNS=("node-agent-config" "change-storageclass-config")

for ns in "${ALL_OADP_NS[@]}"; do
    for cm_name in "${TEST_CM_PATTERNS[@]}"; do
        if oc get configmap "$cm_name" -n "$ns" &>/dev/null; then
            info "Deleting ConfigMap $cm_name in $ns"
            run "oc delete configmap '$cm_name' -n '$ns'"
        fi
    done

    POLICY_CMS=$(oc get configmap -n "$ns" --no-headers 2>/dev/null \
        | awk '{print $1}' \
        | grep -E "resource-policy|resourcepolicy" || true)
    for cm in $POLICY_CMS; do
        info "Deleting resource-policy ConfigMap $cm in $ns"
        run "oc delete configmap '$cm' -n '$ns'"
    done
done
success "Test ConfigMaps cleaned"

################################################################################
# 8. Test namespaces
################################################################################
echo ""
info "=== Step 8: Test Namespaces ==="

TEST_NS=$(oc get ns --no-headers 2>/dev/null \
    | awk '{print $1}' \
    | grep -E "^(test-oadp-|oadp-test-|kubevirt-velero-)" || true)

if [ -n "$TEST_NS" ]; then
    NS_COUNT=$(echo "$TEST_NS" | wc -l | tr -d ' ')
    info "Found $NS_COUNT test namespaces"

    if confirm "Delete all $NS_COUNT test namespaces?"; then
        for ns in $TEST_NS; do
            info "  Deleting namespace $ns"
            run "oc delete ns '$ns' --wait=false"
        done

        if ! $DRY_RUN; then
            sleep 3
            for ns in $TEST_NS; do
                strip_ns_finalizers "$ns"
            done
        fi
        success "Test namespaces cleanup initiated"
    fi
else
    success "No test namespaces found"
fi

################################################################################
# 9. Parallel OADP namespaces (openshift-adp-N)
################################################################################
echo ""
info "=== Step 9: Parallel OADP Namespaces ==="

if [ "${#ALL_OADP_NS[@]}" -gt 1 ]; then
    PARALLEL_COUNT=$(( ${#ALL_OADP_NS[@]} - 1 ))
    info "Found $PARALLEL_COUNT parallel OADP namespaces"

    if confirm "Delete $PARALLEL_COUNT parallel OADP namespaces?"; then
        for ns in "${ALL_OADP_NS[@]}"; do
            if [ "$ns" != "$OADP_NAMESPACE" ]; then
                info "  Deleting namespace $ns"
                run "oc delete dpa --all -n '$ns' --ignore-not-found" 
                run "oc delete ns '$ns' --wait=false"
            fi
        done
        success "Parallel OADP namespaces cleanup initiated"
    fi
else
    success "No parallel OADP namespaces found"
fi

################################################################################
# 10. Non-admin test users and identities
################################################################################
echo ""
info "=== Step 10: Non-Admin Test Users ==="

TEST_USERS=$(oc get users --no-headers 2>/dev/null \
    | awk '{print $1}' \
    | grep -E "^(nonadmin|non-admin|test-user)" || true)

if [ -n "$TEST_USERS" ]; then
    USER_COUNT=$(echo "$TEST_USERS" | wc -l | tr -d ' ')
    info "Found $USER_COUNT test users"

    if confirm "Delete $USER_COUNT non-admin test users and their identities?"; then
        for user in $TEST_USERS; do
            info "  Deleting user $user"
            run "oc delete user '$user' --ignore-not-found"
            run "oc delete identity 'htpasswd_provider:$user' --ignore-not-found 2>/dev/null"
            run "oc delete identity 'my_htpasswd_provider:$user' --ignore-not-found 2>/dev/null"
        done
        success "Test users cleaned"
    fi
else
    success "No test users found"
fi

################################################################################
# 11. Error-state pods in OADP namespace
################################################################################
echo ""
info "=== Step 11: Error-state Pods ==="

for ns in "${ALL_OADP_NS[@]}"; do
    STUCK_PODS=$(oc get pods -n "$ns" --no-headers 2>/dev/null \
        | grep -E "Error|CrashLoopBackOff|ImagePullBackOff|Evicted" \
        | awk '{print $1}' || true)
    if [ -n "$STUCK_PODS" ]; then
        for pod in $STUCK_PODS; do
            info "Deleting error-state pod $pod in $ns"
            run "oc delete pod '$pod' -n '$ns' --force --grace-period=0"
        done
    fi
done
success "Error-state pods cleaned"

################################################################################
# Summary
################################################################################
echo ""
echo -e "${BLUE}============================================${NC}"
if $DRY_RUN; then
    echo -e "${YELLOW}  DRY RUN COMPLETE (nothing was deleted)${NC}"
else
    echo -e "${GREEN}  Cleanup Complete${NC}"
fi
echo -e "${BLUE}============================================${NC}"
echo ""

if ! $DRY_RUN; then
    info "Remaining resources in $OADP_NAMESPACE:"
    echo ""
    echo "  DPAs:     $(oc get dpa -n "$OADP_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    echo "  Backups:  $(oc get backups.velero.io -n "$OADP_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    echo "  Restores: $(oc get restores.velero.io -n "$OADP_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    echo "  Repos:    $(oc get backuprepositories.velero.io -n "$OADP_NAMESPACE" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    echo ""

    REMAINING_NS=$(oc get ns --no-headers 2>/dev/null \
        | awk '{print $1}' \
        | grep -E "^(test-oadp-|oadp-test-|kubevirt-velero-)" || true)
    if [ -n "$REMAINING_NS" ]; then
        warn "Some namespaces may still be terminating:"
        echo "$REMAINING_NS" | while read -r ns; do
            phase=$(oc get ns "$ns" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
            echo "    $ns ($phase)"
        done
        echo ""
        info "Re-run this script if namespaces get stuck in Terminating"
    fi
fi
