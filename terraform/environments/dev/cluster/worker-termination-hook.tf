resource "aws_autoscaling_lifecycle_hook" "worker_termination" {
  name                   = local.worker_termination_hook_name
  autoscaling_group_name = module.workers.autoscaling_group_name
  lifecycle_transition   = "autoscaling:EC2_INSTANCE_TERMINATING"
  heartbeat_timeout      = 300
  default_result         = "CONTINUE"

  depends_on = [aws_cloudwatch_event_target.worker_termination]
}