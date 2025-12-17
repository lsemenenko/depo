packer {
  required_plugins {
    amazon = {
      version = ">= 1.2.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "architecture" {
  type    = string
  default = "x86_64"
  validation {
    condition     = contains(["x86_64", "arm64"], var.architecture)
    error_message = "Architecture must be either x86_64 or arm64."
  }
}

locals {
  timestamp = formatdate("YYYYMMDD-hhmmss", timestamp())

  # Source AMI filters based on architecture
  source_ami_filters = {
    x86_64 = {
      name                = "al2023-ami-*-x86_64"
      virtualization_type = "hvm"
      architecture        = "x86_64"
    }
    arm64 = {
      name                = "al2023-ami-*-arm64"
      virtualization_type = "hvm"
      architecture        = "arm64"
    }
  }

  # Instance types for building
  instance_types = {
    x86_64 = "t3.medium"
    arm64  = "t4g.medium"
  }
}

# Data source to find the latest Amazon Linux 2023 AMI
data "amazon-ami" "al2023-x86_64" {
  filters = {
    name                = local.source_ami_filters["x86_64"].name
    virtualization-type = local.source_ami_filters["x86_64"].virtualization_type
    architecture        = local.source_ami_filters["x86_64"].architecture
    root-device-type    = "ebs"
  }
  owners      = ["amazon"]
  most_recent = true
  region      = var.aws_region
}

data "amazon-ami" "al2023-arm64" {
  filters = {
    name                = local.source_ami_filters["arm64"].name
    virtualization-type = local.source_ami_filters["arm64"].virtualization_type
    architecture        = local.source_ami_filters["arm64"].architecture
    root-device-type    = "ebs"
  }
  owners      = ["amazon"]
  most_recent = true
  region      = var.aws_region
}

# x86_64 AMI build
source "amazon-ebs" "depo-builder-x86_64" {
  ami_name        = "depo-builder-x86_64-${local.timestamp}"
  ami_description = "Depo Docker builder AMI for x86_64"
  instance_type   = local.instance_types["x86_64"]
  region          = var.aws_region
  source_ami      = data.amazon-ami.al2023-x86_64.id
  ssh_username    = "ec2-user"

  ami_block_device_mappings {
    device_name           = "/dev/xvda"
    volume_size           = 20
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name         = "depo-builder-x86_64"
    Architecture = "x86_64"
    Builder      = "packer"
    CreatedAt    = local.timestamp
  }
}

# arm64 AMI build
source "amazon-ebs" "depo-builder-arm64" {
  ami_name        = "depo-builder-arm64-${local.timestamp}"
  ami_description = "Depo Docker builder AMI for arm64"
  instance_type   = local.instance_types["arm64"]
  region          = var.aws_region
  source_ami      = data.amazon-ami.al2023-arm64.id
  ssh_username    = "ec2-user"

  ami_block_device_mappings {
    device_name           = "/dev/xvda"
    volume_size           = 20
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name         = "depo-builder-arm64"
    Architecture = "arm64"
    Builder      = "packer"
    CreatedAt    = local.timestamp
  }
}

build {
  sources = [
    "source.amazon-ebs.depo-builder-x86_64",
    "source.amazon-ebs.depo-builder-arm64"
  ]

  # Install Docker and buildx
  provisioner "shell" {
    inline = [
      "sudo yum update -y",
      "sudo yum install -y docker",
      "sudo usermod -a -G docker ec2-user",
      "sudo systemctl enable docker",
      "sudo systemctl start docker",
      # Wait for docker to be ready
      "sleep 5",
      "sudo docker info",
      # Install docker-buildx plugin
      "ARCH=$(uname -m)",
      "if [ \"$ARCH\" = \"x86_64\" ]; then ARCH=\"amd64\"; elif [ \"$ARCH\" = \"aarch64\" ]; then ARCH=\"arm64\"; fi",
      "sudo curl -sL https://github.com/docker/buildx/releases/latest/download/buildx-v0.30.1.linux-$ARCH -o /usr/libexec/docker/cli-plugins/docker-buildx",
      "sudo chmod +x /usr/libexec/docker/cli-plugins/docker-buildx",
      "sudo systemctl restart docker",
      "docker buildx version"
    ]
  }

  # Install AWS CLI for ECR authentication
  provisioner "shell" {
    inline = [
      "sudo yum install -y aws-cli"
    ]
  }

  # Clean up
  provisioner "shell" {
    inline = [
      "sudo yum clean all",
      "sudo rm -rf /var/cache/yum",
      "rm -rf ~/.ssh/authorized_keys"
    ]
  }
}
