#!/bin/bash
set -e

# Setup script for Depo - creates initial AWS infrastructure
# This script creates the key pair and security group needed by Depo

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
    log_info "Loading environment from ${ENV_FILE}"
    set -a
    source "$ENV_FILE"
    set +a
fi

: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID is required}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY is required}"
: "${AWS_REGION:=us-east-1}"
: "${DEPO_KEY_PAIR_NAME:=depo-builder}"
: "${DEPO_SECURITY_GROUP_NAME:=depo-builder-sg}"

export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION

log_info "Setting up Depo infrastructure in ${AWS_REGION}..."

# Create key pair if it doesn't exist
log_info "Checking for key pair: ${DEPO_KEY_PAIR_NAME}"
if aws ec2 describe-key-pairs --key-names "$DEPO_KEY_PAIR_NAME" &>/dev/null; then
    log_warn "Key pair ${DEPO_KEY_PAIR_NAME} already exists"
    
    if [[ ! -f "${SCRIPT_DIR}/${DEPO_KEY_PAIR_NAME}.pem" ]]; then
        log_error "Key pair exists in AWS but local .pem file is missing!"
        log_error "Either delete the key pair from AWS or restore the .pem file"
        exit 1
    fi
else
    log_info "Creating key pair: ${DEPO_KEY_PAIR_NAME}"
    aws ec2 create-key-pair \
        --key-name "$DEPO_KEY_PAIR_NAME" \
        --query 'KeyMaterial' \
        --output text > "${SCRIPT_DIR}/${DEPO_KEY_PAIR_NAME}.pem"
    
    chmod 600 "${SCRIPT_DIR}/${DEPO_KEY_PAIR_NAME}.pem"
    log_success "Key pair created and saved to ${DEPO_KEY_PAIR_NAME}.pem"
fi

# Create security group if it doesn't exist
log_info "Checking for security group: ${DEPO_SECURITY_GROUP_NAME}"
sg_id=$(aws ec2 describe-security-groups \
    --group-names "$DEPO_SECURITY_GROUP_NAME" \
    --query 'SecurityGroups[0].GroupId' \
    --output text 2>/dev/null || echo "")

if [[ -n "$sg_id" && "$sg_id" != "None" ]]; then
    log_warn "Security group ${DEPO_SECURITY_GROUP_NAME} already exists: ${sg_id}"
else
    log_info "Creating security group: ${DEPO_SECURITY_GROUP_NAME}"
    
    # Get default VPC
    vpc_id=$(aws ec2 describe-vpcs --filters "Name=is-default,Values=true" \
        --query 'Vpcs[0].VpcId' --output text)
    
    sg_id=$(aws ec2 create-security-group \
        --group-name "$DEPO_SECURITY_GROUP_NAME" \
        --description "Security group for Depo Docker build servers" \
        --vpc-id "$vpc_id" \
        --query 'GroupId' \
        --output text)
    
    log_info "Security group created: ${sg_id}"
    
    # Add SSH ingress rule (from anywhere - consider restricting)
    log_info "Adding SSH ingress rule..."
    aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 22 \
        --cidr 0.0.0.0/0
    
    # Add tag
    aws ec2 create-tags \
        --resources "$sg_id" \
        --tags "Key=Name,Value=${DEPO_SECURITY_GROUP_NAME}"
    
    log_success "Security group created and configured: ${sg_id}"
fi

echo ""
log_success "Setup complete!"
echo ""
echo "Next steps:"
echo "  1. Create AMIs:         ./depo manage ami create"
echo "  2. Create cache volumes: ./depo manage cache create"
echo "  3. Run a build:         ./depo build -t yourimage:tag . --push"
echo ""
echo "Check status with:        ./depo manage status"
