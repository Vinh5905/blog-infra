variable "aws_account_id" {
  description = "AWS account allowed to host BlogApp dev"
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must contain exactly 12 digits."
  }
}

variable "aws_region" {
  description = "AWS region for BlogApp dev"
  type        = string
  default     = "ap-southeast-1"

  validation {
    condition     = var.aws_region == "ap-southeast-1"
    error_message = "This dev configuration requires ap-southeast-1."
  }
}

variable "availability_zones" {
  description = "Two available AZ names in stable subnet order"
  type        = list(string)

  validation {
    condition = (
      length(var.availability_zones) == 2 &&
      length(distinct(var.availability_zones)) == 2
    )
    error_message = "Choose exactly two distinct Availability Zones."
  }
}

variable "app_domain_name" {
  description = "Public DNS hostname for the BlogApp dev environment"
  type        = string
}