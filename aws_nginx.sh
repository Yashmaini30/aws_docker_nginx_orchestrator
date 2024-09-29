#!/bin/bash

# Advanced AWS Docker Nginx Orchestrator
# This script provides a comprehensive solution for deploying and managing
# Nginx containers on AWS, with advanced features and user-friendly interface.

set -e

# Color codes for pretty output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

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
    echo "  -h, --help         Display this help message"
    exit 1
}

# Function to log messages
log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

# Function to log errors
error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}" >&2
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
        error "Missing prerequisites: ${missing_prereqs[*]}"
        echo "Please install the missing prerequisites and try again."
        exit 1
    fi

    # Verify AWS credentials are configured
    if ! aws sts get-caller-identity &> /dev/null; then
        error "AWS credentials not configured. Run 'aws configure' to set up your credentials."
        exit 1
    fi
}

# Function to create ECR repository
create_ecr_repo() {
    log "Creating ECR repository..."
    aws ecr create-repository --repository-name "$STACK_NAME" --region "$AWS_REGION" || true
    ECR_REPO=$(aws ecr describe-repositories --repository-names "$STACK_NAME" --region "$AWS_REGION" --output json | jq -r '.repositories[0].repositoryUri')
    log "ECR repository created: $ECR_REPO"
}

# Function to build and push Docker image
build_and_push_image() {
    log "Building Docker image..."
    docker build -t "$STACK_NAME" -f Dockerfile .

    log "Logging into ECR..."
    aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$ECR_REPO"

    log "Pushing image to ECR..."
    docker tag "$STACK_NAME" "$ECR_REPO:latest"
    docker push "$ECR_REPO:latest"
}

# Function to create CloudFormation stack
create_cloudformation_stack() {
    log "Creating CloudFormation stack..."
    aws cloudformation create-stack \
        --stack-name "$STACK_NAME" \
        --template-body file://$(dirname "$0")/cloudformation-template.yaml \
        --parameters \
            ParameterKey=InstanceType,ParameterValue="$INSTANCE_TYPE" \
            ParameterKey=ECRImageURI,ParameterValue="$ECR_REPO:latest" \
            ParameterKey=EnableSSL,ParameterValue="$ENABLE_SSL" \
        --capabilities CAPABILITY_IAM \
        --region "$AWS_REGION"

    log "Waiting for stack creation to complete..."
    if ! aws cloudformation wait stack-create-complete --stack-name "$STACK_NAME" --region "$AWS_REGION"; then
        error "CloudFormation stack creation failed. Please check the AWS CloudFormation console for details."
        exit 1
    fi
}

# Function to display deployment info
display_deployment_info() {
    log "Fetching deployment information..."
    local elb_dns=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" --query "Stacks[0].Outputs[?OutputKey=='LoadBalancerDNS'].OutputValue" --output text)
    local instance_id=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$AWS_REGION" --query "Stacks[0].Outputs[?OutputKey=='EC2InstanceId'].OutputValue" --output text)

    if [ -z "$elb_dns" ] || [ -z "$instance_id" ]; then
        error "Failed to fetch deployment details. Check CloudFormation console."
        exit 1
    fi

    echo -e "\n${YELLOW}Deployment Information:${NC}"
    echo "Stack Name: $STACK_NAME"
    echo "EC2 Instance ID: $instance_id"
    echo "Load Balancer DNS: $elb_dns"
    echo -e "Access your Nginx server at: ${GREEN}http://$elb_dns${NC}"
    [ "$ENABLE_SSL" = true ] && echo -e "For SSL access: ${GREEN}https://$elb_dns${NC}"
}

# Default values
AWS_REGION="${AWS_DEFAULT_REGION:-us-west-2}"
INSTANCE_TYPE="t2.micro"
NGINX_CONFIG_PATH="./nginx.conf"
STACK_NAME="nginx-stack-$(date +%Y%m%d%H%M%S)"
CERT_PATH="./cert.pem"
KEY_PATH="./key.pem"
ENABLE_SSL=false

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
        -h|--help)
        usage
        ;;
        *)
        error "Unknown option: $1"
        usage
        ;;
    esac
done

# Main execution
log "Starting Advanced AWS Docker Nginx Orchestrator"

check_prerequisites

# Check if Nginx config file exists
if [ ! -f "$NGINX_CONFIG_PATH" ]; then
    error "Nginx configuration file not found: $NGINX_CONFIG_PATH"
    exit 1
fi

# Check for SSL files if SSL is enabled
if [ "$ENABLE_SSL" = true ]; then
    if [ ! -f "$CERT_PATH" ] || [ ! -f "$KEY_PATH" ]; then
        error "SSL is enabled but cert.pem or key.pem is missing in the specified paths"
        exit 1
    fi
fi

create_ecr_repo
build_and_push_image
create_cloudformation_stack
display_deployment_info

log "Deployment completed successfully!"
