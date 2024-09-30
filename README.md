# Advanced AWS Docker Nginx Orchestrator with Multi-Region, Backup, and Monitoring

This script provides a comprehensive solution for deploying and managing Nginx containers on AWS, with advanced features like multi-region deployment, EBS volume backup, and SSL support. The script allows easy orchestration with Docker, AWS services, and CloudFormation.

## Features

- **AWS Region Deployment**: Deploy to a single or multiple AWS regions.
- **SSL Support**: Easily enable SSL with your own certificate and key.
- **Backup**: Optionally enable automatic EBS volume backups.
- **Monitoring**: Log levels to track actions, including debug mode.
- **User-Friendly Interface**: Offers a set of command-line options for flexible use.

## Prerequisites

Ensure the following tools are installed and configured before running the script:

- AWS CLI
- Docker
- `jq` (for parsing JSON)
- AWS credentials (`aws configure`)

## Script Usage

```bash
./aws_nginx.sh [OPTIONS]
```

## AWS Docker Nginx Orchestrator Options


| Option             | Description                                                  | Default      |
|--------------------|--------------------------------------------------------------|--------------|
| -r, --region       | AWS region to deploy (use \$AWS_DEFAULT_REGION or specify)    | us-west-2    |
| -t, --instance-type| EC2 instance type for CloudFormation stack                    | t2.micro     |
| -c, --config       | Path to the Nginx configuration file                         | ./nginx.conf |
| -n, --name         | Stack name for this deployment                                | nginx-stack  |
| --cert             | Path to SSL certificate file                                  | ./cert.pem   |
| --key              | Path to SSL private key file                                  | ./key.pem    |
| -s, --ssl          | Enable SSL (requires --cert and --key options)                | Disabled     |
| -l, --log-level    | Set log verbosity (available: debug, info, warn, error)       | info         |
| --multi-region     | Deploy to multiple AWS regions (comma-separated list)         | None         |
| --backup           | Enable EBS volume backup                                      | Disabled     |
| -h, --help         | Display the help message                                      |              |

## Logging Levels

The script provides different levels of logging:

- **debug**: Provides detailed output for each step of the process.
- **info**: General information about the progress.
- **warn**: Warnings for any potential issues that don't stop the script.
- **error**: Critical errors that stop the script.

## Prerequisite Checks

Before starting the deployment, the script checks for:

- AWS CLI installation.
- Docker installation.
- `jq` tool installation (used for parsing JSON).
- AWS credentials are properly configured.

If any of the prerequisites are missing, the script will terminate and notify you.

## Functions Overview

### `check_prerequisites()`
Checks if required tools are installed and if AWS credentials are configured.

### `create_ecr_repo()`
Creates an ECR (Elastic Container Registry) repository to store Docker images. If the repository already exists, it uses the existing one.

### `build_and_push_image()`
Builds the Docker image using the Dockerfile in the current directory and pushes the image to the AWS ECR.

### `create_cloudformation_stack()`
Creates a CloudFormation stack using a predefined template file to provision the necessary resources, including EC2 instances running Nginx.

### `deploy_multi_region()`
Deploys the stack across multiple AWS regions if specified.

### `enable_backup()`
Creates an EBS volume snapshot as a backup for the deployment.

## SSL Configuration

If SSL is enabled (`--ssl` option), you must provide the paths to the SSL certificate and private key files using `--cert` and `--key`.

## AWS CloudFormation Template

Make sure the CloudFormation template (`cloudformation-template.yaml`) is present in the same directory as the script. This template provisions the necessary AWS resources for running Nginx with Docker on EC2 instances.

## License

Copyright (c) 2024 Yash wMaini

Permission is granted to use, copy, modify, merge, and distribute this software. 
