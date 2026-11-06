# -------------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "blogapp-dev-alb"
  description = "Security group for the public application ALB"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name = "blogapp-dev-alb"
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "Allow public HTTPS traffic"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "tcp"
  from_port   = 443
  to_port     = 443
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  description       = "Allow public HTTP for HTTPS redirect"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "tcp"
  from_port   = 80
  to_port     = 80
}


# -------------------------------------------------------------
resource "aws_security_group" "worker" {
  name        = "blogapp-dev-workers"
  description = "Security group for Kubernetes worker nodes"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name = "blogapp-dev-workers"
  }
}

resource "aws_vpc_security_group_egress_rule" "alb_to_workers" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.worker.id
  description                  = "ALB forwards traffic to Traefik NodePort"

  ip_protocol = "tcp"
  from_port   = 30080
  to_port     = 30080
}

resource "aws_vpc_security_group_ingress_rule" "alb_to_ingress" {
  security_group_id            = aws_security_group.worker.id
  referenced_security_group_id = aws_security_group.alb.id
  description                  = "Workers receive Traefik traffic from ALB"

  ip_protocol = "tcp"
  from_port   = 30080
  to_port     = 30080
}

resource "aws_vpc_security_group_egress_rule" "worker_https" {
  security_group_id = aws_security_group.worker.id
  description       = "Workers access HTTPS repositories and AWS APIs"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "tcp"
  from_port   = 443
  to_port     = 443
}

resource "aws_vpc_security_group_egress_rule" "worker_http" {
  security_group_id = aws_security_group.worker.id
  description       = "Workers access HTTP package repositories"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "tcp"
  from_port   = 80
  to_port     = 80
}

# -------------------------------------------------------------
resource "aws_security_group" "automation" {
  name        = "blogapp-dev-automation"
  description = "Security group for the private automation host"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name = "blogapp-dev-automation"
  }
}

resource "aws_security_group" "api_nlb" {
  name        = "blogapp-dev-api-nlb"
  description = "Security group for the internal Kubernetes API NLB"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name = "blogapp-dev-api-nlb"
  }
}

resource "aws_vpc_security_group_egress_rule" "automation_to_api" {
  security_group_id            = aws_security_group.automation.id
  referenced_security_group_id = aws_security_group.api_nlb.id
  description                  = "Automation host connects to Kubernetes API NLB"

  ip_protocol = "tcp"
  from_port   = 6443
  to_port     = 6443
}

resource "aws_vpc_security_group_ingress_rule" "api_from_automation" {
  security_group_id            = aws_security_group.api_nlb.id
  referenced_security_group_id = aws_security_group.automation.id
  description                  = "API NLB receives Kubernetes API traffic from automation"

  ip_protocol = "tcp"
  from_port   = 6443
  to_port     = 6443
}


# -------------------------------------------------------------
resource "aws_security_group" "control_plane" {
  name        = "blogapp-dev-control-plane"
  description = "Security group for the Kubernetes control plane"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name = "blogapp-dev-control-plane"
  }
}

resource "aws_vpc_security_group_egress_rule" "nlb_to_control_plane" {
  security_group_id            = aws_security_group.api_nlb.id
  referenced_security_group_id = aws_security_group.control_plane.id
  description                  = "API NLB forwards traffic and health checks to control plane"

  ip_protocol = "tcp"
  from_port   = 6443
  to_port     = 6443
}

resource "aws_vpc_security_group_ingress_rule" "api_from_nlb" {
  security_group_id            = aws_security_group.control_plane.id
  referenced_security_group_id = aws_security_group.api_nlb.id
  description                  = "Control plane receives Kubernetes API traffic from NLB"

  ip_protocol = "tcp"
  from_port   = 6443
  to_port     = 6443
}

# -------------------------------------------------------------
resource "aws_vpc_security_group_egress_rule" "worker_to_api" {
  security_group_id            = aws_security_group.worker.id
  referenced_security_group_id = aws_security_group.api_nlb.id
  description                  = "Workers connect to Kubernetes API NLB"

  ip_protocol = "tcp"
  from_port   = 6443
  to_port     = 6443
}

resource "aws_vpc_security_group_ingress_rule" "api_from_workers" {
  security_group_id            = aws_security_group.api_nlb.id
  referenced_security_group_id = aws_security_group.worker.id
  description                  = "API NLB receives requests from workers"

  ip_protocol = "tcp"
  from_port   = 6443
  to_port     = 6443
}

resource "aws_vpc_security_group_egress_rule" "control_plane_to_api" {
  security_group_id            = aws_security_group.control_plane.id
  referenced_security_group_id = aws_security_group.api_nlb.id
  description                  = "Control plane connects to Kubernetes API NLB"

  ip_protocol = "tcp"
  from_port   = 6443
  to_port     = 6443
}

resource "aws_vpc_security_group_ingress_rule" "api_from_control_plane" {
  security_group_id            = aws_security_group.api_nlb.id
  referenced_security_group_id = aws_security_group.control_plane.id
  description                  = "API NLB receives requests from control plane"

  ip_protocol = "tcp"
  from_port   = 6443
  to_port     = 6443
}

# -------------------------------------------------------------
resource "aws_vpc_security_group_egress_rule" "automation_https" {
  security_group_id = aws_security_group.automation.id
  description       = "Automation host accesses HTTPS repositories and AWS APIs"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "tcp"
  from_port   = 443
  to_port     = 443
}

resource "aws_vpc_security_group_egress_rule" "automation_http" {
  security_group_id = aws_security_group.automation.id
  description       = "Automation host accesses HTTP package repositories"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "tcp"
  from_port   = 80
  to_port     = 80
}

resource "aws_vpc_security_group_egress_rule" "control_plane_https" {
  security_group_id = aws_security_group.control_plane.id
  description       = "Control plane accesses HTTPS repositories and AWS APIs"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "tcp"
  from_port   = 443
  to_port     = 443
}

resource "aws_vpc_security_group_egress_rule" "control_plane_http" {
  security_group_id = aws_security_group.control_plane.id
  description       = "Control plane accesses HTTP package repositories"

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "tcp"
  from_port   = 80
  to_port     = 80
}

# -------------------------------------------------------------
resource "aws_vpc_security_group_egress_rule" "control_plane_to_worker_kubelet" {
  security_group_id            = aws_security_group.control_plane.id
  referenced_security_group_id = aws_security_group.worker.id
  description                  = "Control plane connects to worker kubelet API"

  ip_protocol = "tcp"
  from_port   = 10250
  to_port     = 10250
}

resource "aws_vpc_security_group_ingress_rule" "worker_kubelet_from_control_plane" {
  security_group_id            = aws_security_group.worker.id
  referenced_security_group_id = aws_security_group.control_plane.id
  description                  = "Workers receive kubelet API requests from control plane"

  ip_protocol = "tcp"
  from_port   = 10250
  to_port     = 10250
}

# -------------------------------------------------------------
resource "aws_vpc_security_group_egress_rule" "worker_vxlan_to_workers" {
  security_group_id            = aws_security_group.worker.id
  referenced_security_group_id = aws_security_group.worker.id
  description                  = "Workers send Calico VXLAN traffic to other workers"

  ip_protocol = "udp"
  from_port   = 4789
  to_port     = 4789
}

resource "aws_vpc_security_group_ingress_rule" "worker_vxlan_from_workers" {
  security_group_id            = aws_security_group.worker.id
  referenced_security_group_id = aws_security_group.worker.id
  description                  = "Workers receive Calico VXLAN traffic from other workers"

  ip_protocol = "udp"
  from_port   = 4789
  to_port     = 4789
}

# -------------------------------------------------------------
resource "aws_vpc_security_group_egress_rule" "control_plane_vxlan_to_workers" {
  security_group_id            = aws_security_group.control_plane.id
  referenced_security_group_id = aws_security_group.worker.id
  description                  = "Control plane sends Calico VXLAN traffic to workers"

  ip_protocol = "udp"
  from_port   = 4789
  to_port     = 4789
}

resource "aws_vpc_security_group_ingress_rule" "worker_vxlan_from_control_plane" {
  security_group_id            = aws_security_group.worker.id
  referenced_security_group_id = aws_security_group.control_plane.id
  description                  = "Workers receive Calico VXLAN traffic from control plane"

  ip_protocol = "udp"
  from_port   = 4789
  to_port     = 4789
}

resource "aws_vpc_security_group_egress_rule" "worker_vxlan_to_control_plane" {
  security_group_id            = aws_security_group.worker.id
  referenced_security_group_id = aws_security_group.control_plane.id
  description                  = "Workers send Calico VXLAN traffic to control plane"

  ip_protocol = "udp"
  from_port   = 4789
  to_port     = 4789
}

resource "aws_vpc_security_group_ingress_rule" "control_plane_vxlan_from_workers" {
  security_group_id            = aws_security_group.control_plane.id
  referenced_security_group_id = aws_security_group.worker.id
  description                  = "Control plane receives Calico VXLAN traffic from workers"

  ip_protocol = "udp"
  from_port   = 4789
  to_port     = 4789
}

# -------------------------------------------------------------
resource "aws_vpc_security_group_egress_rule" "worker_to_worker_kubelet" {
  security_group_id            = aws_security_group.worker.id
  referenced_security_group_id = aws_security_group.worker.id
  description                  = "Workers query kubelet metrics on other workers"

  ip_protocol = "tcp"
  from_port   = 10250
  to_port     = 10250
}

resource "aws_vpc_security_group_ingress_rule" "worker_kubelet_from_workers" {
  security_group_id            = aws_security_group.worker.id
  referenced_security_group_id = aws_security_group.worker.id
  description                  = "Worker kubelets receive metrics requests from workers"

  ip_protocol = "tcp"
  from_port   = 10250
  to_port     = 10250
}

resource "aws_vpc_security_group_egress_rule" "worker_to_control_plane_kubelet" {
  security_group_id            = aws_security_group.worker.id
  referenced_security_group_id = aws_security_group.control_plane.id
  description                  = "Workers query control plane kubelet metrics"

  ip_protocol = "tcp"
  from_port   = 10250
  to_port     = 10250
}

resource "aws_vpc_security_group_ingress_rule" "control_plane_kubelet_from_workers" {
  security_group_id            = aws_security_group.control_plane.id
  referenced_security_group_id = aws_security_group.worker.id
  description                  = "Control plane kubelet receives metrics requests from workers"

  ip_protocol = "tcp"
  from_port   = 10250
  to_port     = 10250
}

# -------------------------------------------------------------
resource "aws_vpc_security_group_egress_rule" "control_plane_to_metrics_server" {
  security_group_id            = aws_security_group.control_plane.id
  referenced_security_group_id = aws_security_group.worker.id
  description                  = "Control plane queries metrics-server on workers"

  ip_protocol = "tcp"
  from_port   = 4443
  to_port     = 4443
}

resource "aws_vpc_security_group_ingress_rule" "metrics_server_from_control_plane" {
  security_group_id            = aws_security_group.worker.id
  referenced_security_group_id = aws_security_group.control_plane.id
  description                  = "Workers receive metrics-server requests from control plane"

  ip_protocol = "tcp"
  from_port   = 4443
  to_port     = 4443
}

# -------------------------------------------------------------
resource "aws_vpc_security_group_egress_rule" "worker_to_internal_api" {
  security_group_id            = aws_security_group.worker.id
  referenced_security_group_id = aws_security_group.control_plane.id
  description                  = "Worker hosted components access internal Kubernetes API"

  ip_protocol = "tcp"
  from_port   = 6443
  to_port     = 6443
}

resource "aws_vpc_security_group_ingress_rule" "internal_api_from_workers" {
  security_group_id            = aws_security_group.control_plane.id
  referenced_security_group_id = aws_security_group.worker.id
  description                  = "Control plane receives internal API requests from workers"

  ip_protocol = "tcp"
  from_port   = 6443
  to_port     = 6443
}


# -------------------------------------------------------------
resource "aws_security_group" "database" {
  name        = "blogapp-dev-database"
  description = "Security group for the private RDS MySQL instance"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name = "blogapp-dev-database"
  }
}

resource "aws_vpc_security_group_egress_rule" "worker_to_database" {
  security_group_id            = aws_security_group.worker.id
  referenced_security_group_id = aws_security_group.database.id
  description                  = "Workers connect to RDS MySQL"

  ip_protocol = "tcp"
  from_port   = 3306
  to_port     = 3306
}

resource "aws_vpc_security_group_ingress_rule" "database_from_workers" {
  security_group_id            = aws_security_group.database.id
  referenced_security_group_id = aws_security_group.worker.id
  description                  = "RDS receives MySQL connections from workers"

  ip_protocol = "tcp"
  from_port   = 3306
  to_port     = 3306
}

resource "aws_vpc_security_group_egress_rule" "automation_to_database" {
  security_group_id            = aws_security_group.automation.id
  referenced_security_group_id = aws_security_group.database.id
  description                  = "Automation host connects to RDS MySQL"

  ip_protocol = "tcp"
  from_port   = 3306
  to_port     = 3306
}

resource "aws_vpc_security_group_ingress_rule" "database_from_automation" {
  security_group_id            = aws_security_group.database.id
  referenced_security_group_id = aws_security_group.automation.id
  description                  = "RDS receives MySQL connections from automation"

  ip_protocol = "tcp"
  from_port   = 3306
  to_port     = 3306
}


# -------------------------------------------------------------
locals {
  calico_typha_paths = {
    worker_to_control_plane = {
      source      = aws_security_group.worker.id
      destination = aws_security_group.control_plane.id
    }
    control_plane_to_worker = {
      source      = aws_security_group.control_plane.id
      destination = aws_security_group.worker.id
    }
    worker_to_worker = {
      source      = aws_security_group.worker.id
      destination = aws_security_group.worker.id
    }
  }
}

resource "aws_vpc_security_group_egress_rule" "calico_typha" {
  for_each = local.calico_typha_paths

  security_group_id            = each.value.source
  referenced_security_group_id = each.value.destination
  description                  = "Connect to Calico Typha"

  ip_protocol = "tcp"
  from_port   = 5473
  to_port     = 5473
}

resource "aws_vpc_security_group_ingress_rule" "calico_typha" {
  for_each = local.calico_typha_paths

  security_group_id            = each.value.destination
  referenced_security_group_id = each.value.source
  description                  = "Receive Calico Felix connections"

  ip_protocol = "tcp"
  from_port   = 5473
  to_port     = 5473
}