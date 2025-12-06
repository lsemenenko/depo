# Depo - Self-Hosted Remote Docker Build System

A self-hosted alternative to [depot.dev](https://depot.dev) that runs Docker builds on ephemeral AWS EC2 instances with persistent cache volumes.

## Features

- **Multi-architecture support**: Build for x86_64 and arm64 natively
- **Persistent Docker cache**: EBS volumes persist between builds, avoiding redundant layer downloads
- **Ephemeral build servers**: Instances are created for each build and destroyed afterward
- **Cost efficient**: Pay only for compute time during builds
- **Simple CLI**: Drop-in replacement syntax similar to `docker build`

## Architecture

```
┌─────────────────┐     ┌──────────────────────────────────────────────┐
│   Local Machine │     │                    AWS                       │
│                 │     │                                              │
│  ┌───────────┐  │     │  ┌─────────────┐     ┌──────────────────┐   │
│  │   depo    │──┼─────┼─▶│ EC2 Instance│────▶│   Docker Hub     │   │
│  │   CLI     │  │     │  │  (x86/arm)  │     │   (--push)       │   │
│  └───────────┘  │     │  └──────┬──────┘     └──────────────────┘   │
│       │         │     │         │                                    │
│       │         │     │         ▼                                    │
│       ▼         │     │  ┌──────────────┐                           │
│  Build Context  │     │  │ Cache EBS    │                           │
│  (tarball)      │     │  │ Volume       │                           │
│                 │     │  │ (persistent) │                           │
└─────────────────┘     │  └──────────────┘                           │
                        └──────────────────────────────────────────────┘
```

## Prerequisites

- **AWS CLI** v2+ configured with credentials
- **Packer** v1.8+ (for building AMIs)
- **Terraform** v1.0+ (for deploying build instances)
- **Docker Hub account** (or other registry)
- **AWS account** with permissions for:
  - EC2 (instances, AMIs, key pairs, security groups)
  - EBS (volumes)

### Installing Prerequisites

```bash
# macOS
brew install awscli packer terraform

# Linux (Ubuntu/Debian)
# AWS CLI
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip && sudo ./aws/install

# Packer
wget https://releases.hashicorp.com/packer/1.10.0/packer_1.10.0_linux_amd64.zip
unzip packer_1.10.0_linux_amd64.zip && sudo mv packer /usr/local/bin/

# Terraform
wget https://releases.hashicorp.com/terraform/1.7.0/terraform_1.7.0_linux_amd64.zip
unzip terraform_1.7.0_linux_amd64.zip && sudo mv terraform /usr/local/bin/
```

## Installation

1. **Clone or copy the depo directory to your preferred location:**

   ```bash
   git clone <repo> ~/depo
   # or
   cp -r depo ~/depo
   ```

2. **Make scripts executable:**

   ```bash
   chmod +x ~/depo/depo
   chmod +x ~/depo/scripts/*.sh
   ```

3. **Add to PATH (optional):**

   ```bash
   echo 'export PATH="$HOME/depo:$PATH"' >> ~/.bashrc
   source ~/.bashrc
   ```

4. **Create configuration file:**

   ```bash
   cp ~/depo/.env.example ~/depo/.env
   ```

5. **Edit `.env` with your credentials:**

   ```bash
   # Required
   AWS_ACCESS_KEY_ID=AKIAXXXXXXXXXXXXXXXX
   AWS_SECRET_ACCESS_KEY=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
   AWS_REGION=us-east-1
   
   DOCKERHUB_USER=yourusername
   DOCKERHUB_PASSWORD=your_access_token
   ```

## Initial Setup

Run the setup script to create the AWS key pair and security group:

```bash
./scripts/setup.sh
```

This creates:
- EC2 key pair (`depo-builder`) - saved as `depo-builder.pem`
- Security group (`depo-builder-sg`) - allows SSH from anywhere

## Building the Infrastructure

### 1. Create AMIs (Packer Images)

Build Amazon Machine Images with Docker pre-installed:

```bash
# Build both x86_64 and arm64 AMIs concurrently
depo manage ami create

# Build only x86_64
depo manage ami create --arch=x86_64

# Build only arm64
depo manage ami create --arch=arm64
```

This takes approximately 5-10 minutes per architecture.

### 2. Create Cache EBS Volumes

Create persistent volumes for Docker layer cache:

```bash
# Create both volumes
depo manage cache create

# Create only x86_64 cache
depo manage cache create --arch=x86_64
```

### 3. Verify Setup

Check the status of your infrastructure:

```bash
depo manage status
```

Expected output:
```
=== AMIs ===
  x86_64: ami-0123456789abcdef0
  arm64: ami-0fedcba9876543210

=== Cache EBS Volumes ===
  x86_64: vol-0123456789abcdef0 (available)
  arm64: vol-0fedcba9876543210 (available)

=== Key Pair ===
  depo-builder: exists

=== Security Group ===
  depo-builder-sg: sg-0123456789abcdef0
```

## Usage

### Basic Build

```bash
# Build and push x86_64 image
depo build -t yourusername/myimage:latest . --push

# Build arm64 image
depo build --arch=arm64 -t yourusername/myimage:arm64 . --push
```

### Build with Arguments

```bash
# With build arguments
depo build -t yourusername/myimage:latest . \
  --push \
  --build-arg NODE_VERSION=18 \
  --build-arg ENV=production

# Multi-platform build (run separately for each arch)
CPU_ARCHITECTURE=amd64
depo build -t yourusername/base:${CPU_ARCHITECTURE} . \
  --push \
  --platform=linux/amd64 \
  --build-arg CPU_ARCHITECTURE=${CPU_ARCHITECTURE}
```

### Full Workflow Example

```bash
#!/bin/bash
# build-multiarch.sh - Build for both architectures

set -e

IMAGE_NAME="yourusername/myapp"
TAG="v1.0.0"

# Build x86_64
echo "Building x86_64..."
depo build --arch=x86_64 \
  -t ${IMAGE_NAME}:${TAG}-amd64 \
  -t ${IMAGE_NAME}:latest-amd64 \
  . --push --platform=linux/amd64

# Build arm64
echo "Building arm64..."
depo build --arch=arm64 \
  -t ${IMAGE_NAME}:${TAG}-arm64 \
  -t ${IMAGE_NAME}:latest-arm64 \
  . --push --platform=linux/arm64

# Create manifest (requires local docker)
echo "Creating multi-arch manifest..."
docker manifest create ${IMAGE_NAME}:${TAG} \
  ${IMAGE_NAME}:${TAG}-amd64 \
  ${IMAGE_NAME}:${TAG}-arm64
docker manifest push ${IMAGE_NAME}:${TAG}

echo "Done!"
```

## Command Reference

### `depo build`

Run a remote Docker build.

```
depo build [options] [docker build arguments]

Options:
  --arch=ARCH    Target architecture: x86_64 or arm64 (default: x86_64)

All other arguments are passed directly to `docker build`.
```

### `depo manage`

Manage Depo infrastructure.

```
depo manage <subcommand> [options]

Subcommands:
  ami create      Create/update Packer AMIs
  ami delete      Delete Packer AMIs  
  cache create    Create cache EBS volumes
  cache delete    Delete cache EBS volumes
  status          Show infrastructure status

Options:
  --arch=ARCH    Target architecture: x86_64, arm64, or all (default: all)
```

## Configuration

### Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `AWS_ACCESS_KEY_ID` | Yes | - | AWS access key |
| `AWS_SECRET_ACCESS_KEY` | Yes | - | AWS secret key |
| `AWS_REGION` | No | `us-east-1` | AWS region |
| `DOCKERHUB_USER` | Yes | - | Docker Hub username |
| `DOCKERHUB_PASSWORD` | Yes | - | Docker Hub password/token |
| `DEPO_KEY_PAIR_NAME` | No | `depo-builder` | EC2 key pair name |
| `DEPO_SECURITY_GROUP_NAME` | No | `depo-builder-sg` | Security group name |
| `DEPO_INSTANCE_TYPE_X86` | No | `t3.medium` | Instance type for x86 builds |
| `DEPO_INSTANCE_TYPE_ARM` | No | `t4g.medium` | Instance type for arm builds |
| `DEPO_CACHE_VOLUME_SIZE` | No | `50` | Cache volume size in GB |

### Instance Types

Choose instance types based on your build requirements:

| Type | vCPUs | Memory | Use Case |
|------|-------|--------|----------|
| `t3.medium` | 2 | 4 GB | Light builds |
| `t3.large` | 2 | 8 GB | Medium builds |
| `t3.xlarge` | 4 | 16 GB | Heavy builds |
| `c6i.xlarge` | 4 | 8 GB | CPU-intensive builds |
| `t4g.medium` | 2 | 4 GB | Light arm64 builds |
| `t4g.large` | 2 | 8 GB | Medium arm64 builds |
| `c6g.xlarge` | 4 | 8 GB | CPU-intensive arm64 builds |

Update in `.env`:
```bash
DEPO_INSTANCE_TYPE_X86=t3.xlarge
DEPO_INSTANCE_TYPE_ARM=t4g.xlarge
```

## Cost Estimation

Approximate costs (us-east-1, as of 2024):

| Resource | Cost | Notes |
|----------|------|-------|
| t3.medium | ~$0.0416/hr | x86_64 build instance |
| t4g.medium | ~$0.0336/hr | arm64 build instance |
| gp3 50GB | ~$4/month | Cache volume (each arch) |
| Data transfer | ~$0.09/GB | Outbound to Docker Hub |

**Example monthly cost** (100 builds/month, 10 min each):
- Compute: 100 × (10/60) × $0.04 = ~$0.67
- Storage: 2 × $4 = $8
- **Total: ~$9/month**

## Troubleshooting

### SSH Connection Timeout

If builds fail waiting for SSH:

1. Check security group allows port 22
2. Verify key pair exists and `.pem` file is present
3. Ensure instances can get public IPs (VPC settings)

### Build Context Too Large

The entire build context is transferred to the build server. Use `.dockerignore`:

```dockerignore
.git
node_modules
*.log
.env
```

### Cache Not Working

Verify the cache volume is mounting correctly:

```bash
# SSH into a running build instance (before it terminates)
ssh -i depo-builder.pem ec2-user@<instance-ip>

# Check mount
df -h /var/lib/docker-cache
ls -la /var/lib/docker
```

### AMI Build Fails

Check Packer output for errors. Common issues:

- Insufficient IAM permissions
- Region doesn't have the base AMI
- Rate limiting on AWS API

## Cleanup

To remove all Depo infrastructure:

```bash
./scripts/cleanup.sh
```

This deletes:
- All Depo AMIs and snapshots
- Cache EBS volumes
- Key pair (AWS and local `.pem`)
- Security group
- Terraform state

## Security Considerations

1. **SSH Access**: The default security group allows SSH from anywhere (0.0.0.0/0). Consider restricting to your IP.

2. **Credentials**: The `.env` file contains sensitive credentials. Never commit it to version control.

3. **Docker Hub Token**: Use a Docker Hub access token instead of your password.

4. **IAM Permissions**: Use an IAM user/role with minimal required permissions.

### Minimal IAM Policy

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeImages",
        "ec2:DescribeInstances",
        "ec2:DescribeVolumes",
        "ec2:DescribeKeyPairs",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeSubnets",
        "ec2:DescribeVpcs",
        "ec2:DescribeAvailabilityZones",
        "ec2:CreateImage",
        "ec2:RegisterImage",
        "ec2:DeregisterImage",
        "ec2:CreateSnapshot",
        "ec2:DeleteSnapshot",
        "ec2:CreateVolume",
        "ec2:DeleteVolume",
        "ec2:AttachVolume",
        "ec2:DetachVolume",
        "ec2:RunInstances",
        "ec2:TerminateInstances",
        "ec2:StopInstances",
        "ec2:CreateKeyPair",
        "ec2:DeleteKeyPair",
        "ec2:CreateSecurityGroup",
        "ec2:DeleteSecurityGroup",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:CreateTags"
      ],
      "Resource": "*"
    }
  ]
}
```

## License

MIT License - Use at your own risk.
