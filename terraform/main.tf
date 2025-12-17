terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "ami_id" {
  description = "AMI ID for the build instance"
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.medium"
}

variable "key_pair_name" {
  description = "Name of the EC2 key pair"
  type        = string
  default     = "depo-builder"
}

variable "security_group_name" {
  description = "Name of the security group"
  type        = string
  default     = "depo-builder-sg"
}

variable "use_spot" {
  description = "Whether to use spot instances"
  type        = bool
  default     = false
}

variable "spot_max_price" {
  description = "Maximum price for spot instances (empty = on-demand price)"
  type        = string
  default     = ""
}

# Get existing security group
data "aws_security_group" "depo" {
  name = var.security_group_name
}

# Get existing key pair
data "aws_key_pair" "depo" {
  key_name = var.key_pair_name
}

# Get default VPC
data "aws_vpc" "default" {
  default = true
}

# Get a subnet in the default VPC
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

# Build instance (on-demand)
resource "aws_instance" "builder" {
  count = var.use_spot ? 0 : 1

  ami                    = var.ami_id
  instance_type          = var.instance_type
  key_name               = data.aws_key_pair.depo.key_name
  vpc_security_group_ids = [data.aws_security_group.depo.id]
  subnet_id              = data.aws_subnets.default.ids[0]

  # Enable public IP
  associate_public_ip_address = true

  # IAM role for ECR access
  iam_instance_profile = aws_iam_instance_profile.builder.name

  root_block_device {
    volume_size           = 50
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name    = "depo-builder"
    Purpose = "docker-build"
  }

  lifecycle {
    create_before_destroy = false
  }
}

# Build instance (spot)
resource "aws_spot_instance_request" "builder" {
  count = var.use_spot ? 1 : 0

  ami                    = var.ami_id
  instance_type          = var.instance_type
  key_name               = data.aws_key_pair.depo.key_name
  vpc_security_group_ids = [data.aws_security_group.depo.id]
  subnet_id              = data.aws_subnets.default.ids[0]

  spot_price           = var.spot_max_price != "" ? var.spot_max_price : null
  wait_for_fulfillment = true
  spot_type            = "one-time"

  # Enable public IP
  associate_public_ip_address = true

  # IAM role for ECR access
  iam_instance_profile = aws_iam_instance_profile.builder.name

  root_block_device {
    volume_size           = 50
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name    = "depo-builder-spot"
    Purpose = "docker-build"
  }

  lifecycle {
    create_before_destroy = false
  }
}

# IAM role for EC2 to access ECR
resource "aws_iam_role" "builder" {
  name = "depo-builder-role-${substr(md5(timestamp()), 0, 8)}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_role_policy" "ecr_access" {
  name = "ecr-access"
  role = aws_iam_role.builder.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_instance_profile" "builder" {
  name = "depo-builder-profile-${substr(md5(timestamp()), 0, 8)}"
  role = aws_iam_role.builder.name

  lifecycle {
    create_before_destroy = true
  }
}

output "instance_id" {
  description = "ID of the build instance"
  value       = var.use_spot ? aws_spot_instance_request.builder[0].spot_instance_id : aws_instance.builder[0].id
}

output "instance_public_ip" {
  description = "Public IP of the build instance"
  value       = var.use_spot ? aws_spot_instance_request.builder[0].public_ip : aws_instance.builder[0].public_ip
}

output "instance_public_dns" {
  description = "Public DNS of the build instance"
  value       = var.use_spot ? aws_spot_instance_request.builder[0].public_dns : aws_instance.builder[0].public_dns
}
