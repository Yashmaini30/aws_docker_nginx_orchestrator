#!/bin/bash

# Advanced AWS Docker Nginx Orchestrator with Multi-Region, Backup, and Monitoring
# This script provides a comprehensive solution for deploying and managing
# Nginx containers on AWS, with advanced features and user-friendly interface.

set -e

# Color codes for pretty output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default log level (info)
LOG_LEVEL="info"

# Function to display script usage
usage() {
    echo -e "${YELLOW}Usage: $0 [OPTIONS]${NC}"
    echo "Options:"
    echo "  -r, --region       AWS region (default: \$AWS_DEFAULT_REGION or us-west-2)"
    echo "  -t, --instance-type EC2 instance type (default: t2.micro)"
    echo "  -c, --config       Path to Nginx config file (default: ./nginx.conf)"
    echo "  -n, --name         Stack name for this deployment (default: nginx-stack)"
    echo "  --cert             Path to SSL certificate (default: ./cert.pem)"
    echo "  --key              Path to SSL key (default: ./key.pem)"
    echo "  -s, --ssl          Enable SSL (requires cert and key paths)"
    echo "  -l, --log-level    Set log verbosity (default: info, available: debug, info, warn, error)"
    echo "  --multi-region     Deploy in multiple AWS regions (comma-separated regions)"
    echo "  --backup           Enable EBS volume backup (default: disabled)"
    echo "  -h, --help         Display this help message"
    exit 1
}

# Function to log messages based on log level
log() {
    local level="$1"
    shift
    case $level in
        debug) [[ $LOG_LEVEL == "debug" ]] && echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] DEBUG: $*${NC}" ;;
        info)  [[ $LOG_LEVEL =~ (info|debug) ]] && echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $*${NC}" ;;
        warn)  [[ $LOG_LEVEL =~ (warn|info|debug) ]] && echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $*${NC}" ;;
        error) [[ $LOG_LEVEL =~ (error|warn|info|debug) ]] && echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*${NC}" >&2 ;;
    esac
}

# Function to check prerequisites
check_prerequisites() {
    local missing_prereqs=()

    if ! command -v aws &> /dev/null; then
        missing_prereqs+=("AWS CLI")
    fi
    if ! command -v docker &> /dev/null; then
        missing_prereqs+=("Docker")
    fi
    if ! command -v jq &> /dev/null; then
        missing_prereqs+=("jq")
    fi

    if [ ${#missing_prereqs[@]} -ne 0 ]; then
        log error "Missing prerequisites: ${missing_prereqs[*]}"
        echo "Please install the missing prerequisites and try again."
        exit 1
    fi

    # Verify AWS credentials are configured
    if ! aws sts get-caller-identity &> /dev/null; then
        log error "AWS credentials not configured. Run 'aws configure' to set up your credentials."
        exit 1
    fi
}

# Function to create ECR repository
create_ecr_repo() {
    log info "Creating ECR repository..."
    aws ecr create-repository --repository-name "$STACK_NAME" --region "$AWS_REGION" || true
    ECR_REPO=$(aws ecr describe-repositories --repository-names "$STACK_NAME" --region "$AWS_REGION" --output json | jq -r '.repositories[0].repositoryUri')
    log info "ECR repository created: $ECR_REPO"
}

# Function to enable backups
enable_backup() {
    log info "Enabling EBS volume backup..."
    aws ec2 create-snapshot --volume-id "$VOLUME_ID" --description "Backup of Nginx stack"
    log info "Backup completed."
}

# Function to build and push Docker image
build_and_push_image() {
    log info "Building Docker image..."
    docker build -t "$STACK_NAME" -f Dockerfile .

    log info "Logging into ECR..."
    aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REPO"

    log info "Pushing image to ECR..."
    docker tag "$STACK_NAME" "$ECR_REPO:latest"
    docker push "$ECR_REPO:latest"
}

# Function to create CloudFormation stack
create_cloudformation_stack() {
    log info "Creating CloudFormation stack..."
    aws cloudformation create-stack \
        --stack-name "$STACK_NAME" \
        --template-body file://$(dirname "$0")/cloudformation-template.yaml \
        --parameters \
            ParameterKey=InstanceType,ParameterValue="$INSTANCE_TYPE" \
            ParameterKey=ECRImageURI,ParameterValue="$ECR_REPO:latest" \
            ParameterKey=EnableSSL,ParameterValue="$ENABLE_SSL" \
        --capabilities CAPABILITY_IAM \
        --region "$AWS_REGION"

    log info "Waiting for stack creation to complete..."
    if ! aws cloudformation wait stack-create-complete --stack-name "$STACK_NAME" --region "$AWS_REGION"; then
        log error "CloudFormation stack creation failed. Please check the AWS CloudFormation console for details."
        exit 1
    fi
}

# Function to handle multi-region deployment
deploy_multi_region() {
    IFS=',' read -ra regions <<< "$MULTI_REGION"
    for region in "${regions[@]}"; do
        log info "Deploying to region $region..."
        AWS_REGION="$region"
        create_ecr_repo
        build_and_push_image
        create_cloudformation_stack
    done
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -r|--region)
        AWS_REGION="$2"
        shift 2
        ;;
        -t|--instance-type)
        INSTANCE_TYPE="$2"
        shift 2
        ;;
        -c|--config)
        NGINX_CONFIG_PATH="$2"
        shift 2
        ;;
        -n|--name)
        STACK_NAME="$2"
        shift 2
        ;;
        --cert)
        CERT_PATH="$2"
        shift 2
        ;;
        --key)
        KEY_PATH="$2"
        shift 2
        ;;
        -s|--ssl)
        ENABLE_SSL=true
        shift
        ;;
        -l|--log-level)
        LOG_LEVEL="$2"
        shift 2
        ;;
        --multi-region)
        MULTI_REGION="$2"
        shift 2
        ;;
        --backup)
        ENABLE_BACKUP=true
        shift
        ;;
        -h|--help)
        usage
        ;;
        *)
        log error "Unknown option: $1"
        usage
        ;;
    esac
done

# Main execution
log info "Starting Advanced AWS Docker Nginx Orchestrator"

check_prerequisites

# Check if Nginx config file exists
if [ ! -f "$NGINX_CONFIG_PATH" ]; then
    log error "Nginx configuration file not found: $NGINX_CONFIG_PATH"
    exit 1
fi

# Check for SSL files if SSL is enabled
if [ "$ENABLE_SSL" = true ]; then
    if [ ! -f "$CERT_PATH" ] || [ ! -f "$KEY_PATH" ]; then
        log error "SSL is enabled but cert.pem or key.pem is missing in the specified paths"
        exit 1
    fi
fi

create_ecr_repo
build_and_push_image
create_cloudformation_stack

# Handle multi-region deployment
if [ -n "$MULTI_REGION" ]; then
    deploy_multi_region
fi

# Enable backup if requested
if [ "$ENABLE_BACKUP" = true ]; then
    enable_backup
fi

log info "Deployment completed successfully!"
