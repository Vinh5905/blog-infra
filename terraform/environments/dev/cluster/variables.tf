variable "aws_account_id" {
  description = "AWS account ID for the BlogApp dev cluster"
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must contain exactly 12 digits."
  }
}

variable "aws_region" {
  description = "AWS region for the BlogApp dev cluster"
  type        = string
  default     = "ap-southeast-1"

  validation {
    condition     = var.aws_region == "ap-southeast-1"
    error_message = "The BlogApp dev cluster must use ap-southeast-1."
  }
}

variable "automation_ami_id" {
  description = "Pinned Ubuntu AMI ID for the BlogApp dev automation host"
  type        = string
}

variable "control_plane_ami_id" {
  description = "Pinned Ubuntu AMI ID for the BlogApp dev control plane"
  type        = string
}

variable "worker_ami_id" {
  description = "Pinned Ubuntu AMI ID for BlogApp dev workers"
  type        = string
}

variable "worker_instance_type" {
  description = "EC2 instance type for BlogApp dev workers"
  type        = string
}

variable "worker_bootstrap_commit" {
  description = "Full Git commit SHA containing the dev worker bootstrap playbook"
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{40}$", var.worker_bootstrap_commit))
    error_message = "worker_bootstrap_commit must be a full 40-character Git SHA."
  }
}