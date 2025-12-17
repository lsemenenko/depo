#!/bin/bash
set -e

# Cleanup script for Depo - removes all AWS infrastructure
# WARNING: This will delete AMIs, cache volumes, key pairs, and security groups

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Load environment
if [[ -f "$ENV_FILE" ]]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID is required}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY is required}"
: "${AWS_REGION:=us-east-1}"
: "${DEPO_KEY_PAIR_NAME:=depo-builder}"
: "${DEPO_SECURITY_GROUP_NAME:=depo-builder-sg}"
: "${DEPO_ECR_REPO_NAME:=depo-cache}"

export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION

echo -e "${RED}WARNING: This will delete all Depo infrastructure!${NC}"
echo ""
echo "This includes:"
echo "  - All Depo AMIs (x86_64 and arm64)"
echo "  - ECR cache repository: ${DEPO_ECR_REPO_NAME}"
echo "  - Key pair: ${DEPO_KEY_PAIR_NAME}"
echo "  - Security group: ${DEPO_SECURITY_GROUP_NAME}"
echo "  - Local key file: ${DEPO_KEY_PAIR_NAME}.pem"
echo ""
read -p "Are you sure you want to continue? (type 'yes' to confirm): " confirm

if [[ "$confirm" != "yes" ]]; then
    log_info "Cleanup cancelled"
    exit 0
fi

echo ""
log_info "Starting cleanup in ${AWS_REGION}..."

# Delete AMIs
for arch in x86_64 arm64; do
    log_info "Looking for ${arch} AMIs..."
    ami_ids=$(aws ec2 describe-images \
        --owners self \
        --filters "Name=name,Values=depo-builder-${arch}-*" \
        --query 'Images[*].[ImageId,BlockDeviceMappings[*].Ebs.SnapshotId]' \
        --output text 2>/dev/null || echo "")
    
    if [[ -n "$ami_ids" ]]; then
        while read -r line; do
            ami_id=$(echo "$line" | awk '{print $1}')
            snapshot_ids=$(echo "$line" | awk '{for(i=2;i<=NF;i++) print $i}')
            
            if [[ -n "$ami_id" && "$ami_id" != "None" ]]; then
                log_info "Deleting AMI: ${ami_id}"
                aws ec2 deregister-image --image-id "$ami_id" || true
                
                for snap_id in $snapshot_ids; do
                    if [[ -n "$snap_id" && "$snap_id" != "None" ]]; then
                        log_info "Deleting snapshot: ${snap_id}"
                        aws ec2 delete-snapshot --snapshot-id "$snap_id" || true
                    fi
                done
            fi
        done <<< "$ami_ids"
    else
        log_info "No ${arch} AMIs found"
    fi
done

# Delete ECR repository
log_info "Looking for ECR repository: ${DEPO_ECR_REPO_NAME}"
ecr_repo=$(aws ecr describe-repositories --repository-names "$DEPO_ECR_REPO_NAME" \
    --query 'repositories[0].repositoryUri' --output text 2>/dev/null || echo "None")

if [[ "$ecr_repo" != "None" && -n "$ecr_repo" ]]; then
    log_info "Deleting ECR repository: ${DEPO_ECR_REPO_NAME}"
    aws ecr delete-repository --repository-name "$DEPO_ECR_REPO_NAME" --force || true
else
    log_info "No ECR repository found"
fi

# Delete key pair
log_info "Deleting key pair: ${DEPO_KEY_PAIR_NAME}"
aws ec2 delete-key-pair --key-name "$DEPO_KEY_PAIR_NAME" 2>/dev/null || true

# Delete local key file
if [[ -f "${SCRIPT_DIR}/${DEPO_KEY_PAIR_NAME}.pem" ]]; then
    log_info "Deleting local key file..."
    rm -f "${SCRIPT_DIR}/${DEPO_KEY_PAIR_NAME}.pem"
fi

# Delete security group
log_info "Deleting security group: ${DEPO_SECURITY_GROUP_NAME}"
sg_id=$(aws ec2 describe-security-groups \
    --group-names "$DEPO_SECURITY_GROUP_NAME" \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null || echo "None")

if [[ "$sg_id" != "None" && -n "$sg_id" ]]; then
    aws ec2 delete-security-group --group-id "$sg_id" 2>/dev/null || true
fi

# Clean up Terraform state
if [[ -d "${SCRIPT_DIR}/terraform" ]]; then
    log_info "Cleaning Terraform state..."
    rm -rf "${SCRIPT_DIR}/terraform/.terraform"
    rm -f "${SCRIPT_DIR}/terraform/terraform.tfstate"*
    rm -f "${SCRIPT_DIR}/terraform/.terraform.lock.hcl"
fi

echo ""
log_success "Cleanup complete!"
