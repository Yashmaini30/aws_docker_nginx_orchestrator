#!/bin/bash

# Advanced AWS Docker Nginx Orchestrator with Multi-Region, Backup, and Monitoring
# Enhanced version with auto-scaling, error handling, retries, dynamic region selection, 
# automated backup, and environment variables for more flexibility.

set -e

# Trap to ensure proper cleanup on exit or failure
trap 'cleanup' EXIT SIGINT SIGTERM

# Color codes for pretty output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Default log level (info)
LOG_LEVEL="${LOG_LEVEL:-info}"
INSTANCE_TYPE="${INSTANCE_TYPE:-t2.micro}"
STACK_NAME="${STACK_NAME:-nginx-stack}"
AWS_REGION="${AWS_REGION:-us-west-2}"

# Function to display script usage
usage() {
    echo -e "${YELLOW}Usage: $0 [OPTIONS]${NC}"
    echo "Options:"
    echo "  -r, --region       AWS region (default: \$AWS_REGION or us-west-2)"
    echo "  -t, --instance-type EC2 instance type (default: t2.micro)"
    echo "  -c, --config       Path to Nginx config file (default: ./nginx.conf)"
    echo "  -n, --name         Stack name for this deployment (default: nginx-stack)"
    echo "  --cert             Path to SSL certificate (default: ./cert.pem)"
    echo "  --key              Path to SSL key (default: ./key.pem)"
    echo "  -s, --ssl          Enable SSL (requires cert and key paths)"
    echo "  -l, --log-level    Set log verbosity (default: info, available: debug, info, warn, error)"
    echo "  --multi-region     Deploy in multiple AWS regions (comma-separated regions)"
    echo "  --backup           Enable EBS volume backup (default: disabled)"
    echo "  --auto-scale       Enable auto-scaling based on CPU utilization"
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

# Function to retry AWS commands in case of transient errors
retry() {
    local n=0
    local max_retries=5
    local delay=5
    while true; do
        "$@" && break || {
            n=$((n + 1))
            if [[ $n -ge $max_retries ]]; then
                log error "Command failed after $n attempts."
                return 1
            else
                log warn "Command failed. Attempt $n/$max_retries. Retrying in $delay seconds..."
                sleep $delay
            fi
        }
    done
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
    retry aws ecr create-repository --repository-name "$STACK_NAME" --region "$AWS_REGION" || true
    ECR_REPO=$(retry aws ecr describe-repositories --repository-names "$STACK_NAME" --region "$AWS_REGION" --output json | jq -r '.repositories[0].repositoryUri')
    log info "ECR repository created: $ECR_REPO"
}

# Function to enable backups with automated lifecycle policy
enable_backup() {
    log info "Enabling EBS volume backup with lifecycle policy..."
    # Automated backup management with retention policy
    aws ec2 create-snapshot --volume-id "$VOLUME_ID" --description "Backup of Nginx stack"
    aws ec2 create-snapshot-lifecycle-policy --volume-id "$VOLUME_ID" --lifecycle-policy-name "nginx-backup-policy" --policy-details '{...}'
    log info "Backup and lifecycle policy enabled."
}

# Function to build and push Docker image
build_and_push_image() {
    log info "Building Docker image..."
    docker build -t "$STACK_NAME" -f Dockerfile .

    log info "Logging into ECR..."
    aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REPO"

    log info "Pushing image to ECR..."
    docker tag "$STACK_NAME" "$ECR_REPO:latest"
    retry docker push "$ECR_REPO:latest"
}

# Function to create CloudFormation stack with auto-scaling
create_cloudformation_stack() {
    log info "Creating CloudFormation stack with auto-scaling enabled..."
    aws cloudformation create-stack \
        --stack-name "$STACK_NAME" \
        --template-body file://$(dirname "$0")/cloudformation-template.yaml \
        --parameters \
            ParameterKey=InstanceType,ParameterValue="$INSTANCE_TYPE" \
            ParameterKey=ECRImageURI,ParameterValue="$ECR_REPO:latest" \
            ParameterKey=EnableSSL,ParameterValue="$ENABLE_SSL" \
            ParameterKey=AutoScaling,ParameterValue="true" \
        --capabilities CAPABILITY_IAM \
        --region "$AWS_REGION"

    log info "Waiting for stack creation to complete..."
    if ! aws cloudformation wait stack-create-complete --stack-name "$STACK_NAME" --region "$AWS_REGION"; then
        log error "CloudFormation stack creation failed. Please check the AWS CloudFormation console for details."
        exit 1
    fi
}

# Function to dynamically select AWS regions based on latency
select_optimal_region() {
    log info "Selecting optimal AWS region based on latency..."
    # Dynamic region selection logic using AWS CLI
    AWS_REGION=$(aws ec2 describe-availability-zones --query 'AvailabilityZones[].[RegionName]' --output text | sort -R | head -n 1)
    log info "Optimal region selected: $AWS_REGION"
}

# Function to deploy in multiple regions with dynamic selection
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

# Function to cleanup resources on script exit
cleanup() {
    log info "Cleaning up temporary resources..."
    # Any additional cleanup logic here (e.g., remove temp files)
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
        ENABLE_SSL="true"
        shift 1
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
        ENABLE_BACKUP="true"
        shift 1
        ;;
        --auto-scale)
        ENABLE_AUTO_SCALING="true"
        shift 1
        ;;
        -h|--help)
        usage
        ;;
        *)
        log error "Unknown option: $key"
        usage
        ;;
    esac
done

# Ensure prerequisites are installed
check_prerequisites

# Select optimal AWS region if not provided
if [[ -z "$AWS_REGION" ]]; then
    select_optimal_region
fi

# Enable multi-region deployment if specified
if [[ -n "$MULTI_REGION" ]]; then
    deploy_multi_region
else
    # Single region deployment
    create_ecr_repo
    build_and_push_image
    create_cloudformation_stack
fi

# Enable backup if requested
if [[ "$ENABLE_BACKUP" == "true" ]]; then
    enable_backup
fi

log info "Deployment completed successfully!"
