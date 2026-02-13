#!/bin/bash

# ==========================================
# Docker Installation Script (YUM Method)
# ==========================================

echo "========================================="
echo "   Docker Installation Started"
echo "========================================="

# Step 1 - Install required utilities
echo "➡ Installing yum-utils, device mapper & lvm packages..."
yum install yum-utils device-mapper-persistent-data lvm2 -y

# Step 2 - Add Docker official repository
echo "➡ Adding Docker CE repository..."
yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

# Step 3 - Install Docker Engine
echo "➡ Installing Docker CE..."
yum install docker-ce -y

# Step 4 - Verify Docker Version
echo "➡ Checking Docker version..."
docker --version

# Step 5 - Start & Enable Docker Service
echo "➡ Starting and enabling Docker service..."
systemctl start docker
systemctl enable docker

# Step 6 - Check Service Status
echo "➡ Docker service status:"
systemctl status docker --no-pager

echo "========================================="
echo "   Docker Installation Completed"
echo "========================================="