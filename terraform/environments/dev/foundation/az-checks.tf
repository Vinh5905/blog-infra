data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "zone-type"
    values = ["availability-zone"]
  }

  lifecycle {
    postcondition {
      condition = alltrue([
        for az in var.availability_zones : contains(self.names, az)
      ])

      error_message = "A selected AZ is not available in this account/region."
    }
  }
}