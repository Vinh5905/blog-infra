output "automation_instance_id" {
  description = "EC2 instance ID of the BlogApp dev automation host"
  value       = module.automation.id
}

output "control_plane_instance_id" {
  description = "EC2 instance ID of the BlogApp dev Kubernetes control plane"
  value       = module.control_plane.id
}