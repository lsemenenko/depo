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

variable "architecture" {
  description = "CPU architecture (x86_64 or arm64)"
  type        = string
  default     = "x86_64"
  
  validation {
    condition     = contains(["x86_64", "arm64"], var.architecture)
    error_message = "Architecture must be either x86_64 or arm64."
  }
}

variable "cache_volume_id" {
  description = "EBS volume ID for Docker cache"
  type        = string
}

variable "availability_zone" {
  description = "Availability zone for the instance (must match cache volume)"
  type        = string
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

# Get subnet in the specified AZ
data "aws_subnet" "selected" {
  vpc_id            = data.aws_vpc.default.id
  availability_zone = var.availability_zone
  default_for_az    = true
}

# Build instance (on-demand)
resource "aws_instance" "builder" {
  count = var.use_spot ? 0 : 1

  ami                    = var.ami_id
  instance_type          = var.instance_type
  key_name               = data.aws_key_pair.depo.key_name
  vpc_security_group_ids = [data.aws_security_group.depo.id]
  subnet_id              = data.aws_subnet.selected.id
  availability_zone      = var.availability_zone

  # Enable public IP
  associate_public_ip_address = true

  root_block_device {
    volume_size           = 50
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name         = "depo-builder-${var.architecture}"
    Architecture = var.architecture
    Purpose      = "docker-build"
  }

  # Wait for instance to be ready
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
  subnet_id              = data.aws_subnet.selected.id
  availability_zone      = var.availability_zone

  spot_price             = var.spot_max_price != "" ? var.spot_max_price : null
  wait_for_fulfillment   = true
  spot_type              = "one-time"

  # Enable public IP
  associate_public_ip_address = true

  root_block_device {
    volume_size           = 50
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name         = "depo-builder-${var.architecture}-spot"
    Architecture = var.architecture
    Purpose      = "docker-build"
  }

  lifecycle {
    create_before_destroy = false
  }
}

# Attach cache volume (on-demand)
resource "aws_volume_attachment" "cache_ondemand" {
  count = var.use_spot ? 0 : 1

  device_name = "/dev/xvdf"
  volume_id   = var.cache_volume_id
  instance_id = aws_instance.builder[0].id

  # Don't force detach - we want clean unmount
  force_detach = false

  # Stop instance before detaching
  stop_instance_before_detaching = true
}

# Attach cache volume (spot) - spot instances can't be stopped, must force detach
resource "aws_volume_attachment" "cache_spot" {
  count = var.use_spot ? 1 : 0

  device_name = "/dev/xvdf"
  volume_id   = var.cache_volume_id
  instance_id = aws_spot_instance_request.builder[0].spot_instance_id

  # Spot instances can't be stopped, so we must force detach
  force_detach = true

  # Not applicable for spot (can't stop)
  stop_instance_before_detaching = false
}

# Wait for instance to be ready and cache mounted
resource "null_resource" "wait_for_ready" {
  depends_on = [aws_volume_attachment.cache_ondemand, aws_volume_attachment.cache_spot]

  provisioner "local-exec" {
    command = "sleep 10"
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

output "availability_zone" {
  description = "Availability zone of the instance"
  value       = var.use_spot ? aws_spot_instance_request.builder[0].availability_zone : aws_instance.builder[0].availability_zone
}
