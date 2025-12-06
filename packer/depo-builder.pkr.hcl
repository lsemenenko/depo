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
  
  # Install Docker
  provisioner "shell" {
    inline = [
      "sudo yum update -y",
      "sudo yum install -y docker",
      "sudo usermod -a -G docker ec2-user",
      "sudo systemctl enable docker",
      "sudo systemctl start docker",
      # Wait for docker to be ready
      "sleep 5",
      "sudo docker info"
    ]
  }
  
  # Create directory for docker cache mount
  provisioner "shell" {
    inline = [
      "sudo mkdir -p /var/lib/docker-cache",
      "sudo chown root:root /var/lib/docker-cache"
    ]
  }
  
  # Create mount script for cache volume
  provisioner "shell" {
    inline = [
      "cat << 'EOF' | sudo tee /usr/local/bin/mount-docker-cache.sh",
      "#!/bin/bash",
      "DEVICE=/dev/xvdf",
      "MOUNT_POINT=/var/lib/docker-cache",
      "",
      "# Wait for device to be available",
      "while [ ! -e $DEVICE ]; do",
      "  echo 'Waiting for cache volume...'",
      "  sleep 1",
      "done",
      "",
      "# Check if device has a filesystem",
      "if ! blkid $DEVICE; then",
      "  echo 'Creating filesystem on cache volume...'",
      "  sudo mkfs.ext4 $DEVICE",
      "fi",
      "",
      "# Mount the volume",
      "sudo mount $DEVICE $MOUNT_POINT",
      "",
      "# Configure Docker to use cache",
      "sudo mkdir -p $MOUNT_POINT/docker",
      "sudo systemctl stop docker",
      "sudo rm -rf /var/lib/docker",
      "sudo ln -s $MOUNT_POINT/docker /var/lib/docker",
      "sudo systemctl start docker",
      "",
      "echo 'Docker cache mounted successfully'",
      "EOF",
      "sudo chmod +x /usr/local/bin/mount-docker-cache.sh"
    ]
  }
  
  # Create systemd service for mounting cache on boot
  provisioner "shell" {
    inline = [
      "cat << 'EOF' | sudo tee /etc/systemd/system/docker-cache.service",
      "[Unit]",
      "Description=Mount Docker Cache Volume",
      "Before=docker.service",
      "After=local-fs.target",
      "",
      "[Service]",
      "Type=oneshot",
      "ExecStart=/usr/local/bin/mount-docker-cache.sh",
      "RemainAfterExit=yes",
      "",
      "[Install]",
      "WantedBy=multi-user.target",
      "EOF",
      "sudo systemctl daemon-reload",
      "sudo systemctl enable docker-cache.service"
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
