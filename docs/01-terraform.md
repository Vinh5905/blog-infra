# Terraform — Từ AWS trống đến nền tảng dev của BlogApp

Đọc [README](README.md) trước. **Các block HCL trong chương là ví dụ giải thích, chưa phải bộ code hoàn chỉnh để apply.** Biến, outputs, policy và liên kết state cần được triển khai thành file trong repo ở chặng tương ứng. Chưa có lệnh nào trong chương được chạy vào AWS.

## 1. Hiểu đúng module Registry

Provider `hashicorp/aws` là thành phần gọi AWS API. Resource như `aws_security_group` mô tả một loại tài nguyên. Module là một gói resource/logic nhận inputs và trả outputs. Module VPC có thể tạo nhiều subnet, route table, NAT và gateway từ vài inputs.

Ưu tiên module giúp dùng lại kinh nghiệm và giảm phần lặp. Nó **không tự bảo đảm tối ưu chi phí hoặc an toàn**: đặt sai inputs vẫn tạo nhiều NAT, mở quyền rộng hoặc xóa dữ liệu. Luôn đọc README, `variables.tf`, `outputs.tf`, requirements, changelog và plan của **đúng version**.

### 1.1 Bộ module đã kiểm tra metadata ngày 18/10/2026


| Mục đích                    | Source Registry                          | Version được kiểm tra | AWS provider tối thiểu theo metadata version đó |
| -------------------------------- | ------------------------------------------ | --------------------------- | ----------------------------------------------------- |
| Network                        | `terraform-aws-modules/vpc/aws`          | `6.7.3`                   | `6.28`                                              |
| EC2 cố định                 | `terraform-aws-modules/ec2-instance/aws` | `6.4.1`                   | `6.37`                                              |
| Worker ASG/LT                  | `terraform-aws-modules/autoscaling/aws`  | `9.3.2`                   | `6.56`                                              |
| ALB và internal NLB           | `terraform-aws-modules/alb/aws`          | `10.5.1`                  | `6.28`                                              |
| RDS MySQL                      | `terraform-aws-modules/rds/aws`          | `7.2.2`                   | `6.28`                                              |
| State/backup/telemetry buckets | `terraform-aws-modules/s3-bucket/aws`    | `5.17.0`                  | `6.44`                                              |
| IAM hỗ trợ, khi phù hợp    | `terraform-aws-modules/iam/aws`          | `6.8.2`                   | Kiểm requirements của submodule cụ thể          |

Nguồn metadata: API công khai `https://registry.terraform.io/v1/modules/terraform-aws-modules/<module>/aws`, trường `version` và `root.provider_dependencies`. Bảng ghi version đã đọc, **chưa phải compatibility test của cả hệ thống**. Không tự thay module sang bản mới nhất mỗi lần init.

Link từng version: [VPC](https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws/6.7.3), [EC2](https://registry.terraform.io/modules/terraform-aws-modules/ec2-instance/aws/6.4.1), [ASG](https://registry.terraform.io/modules/terraform-aws-modules/autoscaling/aws/9.3.2), [ALB/NLB](https://registry.terraform.io/modules/terraform-aws-modules/alb/aws/10.5.1), [RDS](https://registry.terraform.io/modules/terraform-aws-modules/rds/aws/7.2.2), [S3](https://registry.terraform.io/modules/terraform-aws-modules/s3-bucket/aws/5.17.0), [IAM](https://registry.terraform.io/modules/terraform-aws-modules/iam/aws/6.8.2).

Chưa dùng module EKS vì cluster là kubeadm. Với EventBridge rules, lifecycle hook, SG rule hay IAM trust nhỏ và đặc thù BlogApp, dùng resource trực tiếp dễ đọc hơn thêm wrapper nhiều tầng. `terraform/modules/` chỉ chứa composition có ý nghĩa riêng và lặp lại ở nhiều môi trường; không bọc một module bằng module khác chỉ để đổi tên input.

### 1.2 Khóa version theo hai lớp

Ví dụ dự kiến `versions.tf` của mỗi root:

```hcl
terraform {
  required_version = ">= 1.10, < 2.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.56, < 7.0"
    }
  }
}

provider "aws" {
  region              = var.aws_region
  allowed_account_ids = [var.aws_account_id]

  default_tags {
    tags = {
      Project     = "blogapp"
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}
```

- `required_version`: ngưỡng CLI; lựa chọn patch cụ thể phải ghi trong `versions.yaml` và tool installer. Terraform từ 1.10 hỗ trợ S3 lockfile theo hướng dẫn backend.
- `source`: namespace của provider, khác source của module.
- `>= 6.56, < 7.0`: đáp ứng ngưỡng lớn nhất trong các module đã chọn, không nhảy major 7.
- `allowed_account_ids`: chặn tình huống shell đang đăng nhập nhầm account.
- `default_tags`: giúp tìm tài nguyên và tổng hợp chi phí; ASG còn cần tag propagate-at-launch cho instance.
- `.terraform.lock.hcl`: commit để khóa provider version/checksum thực chọn. File này **không khóa version module Registry**; module phải ghi `version = "x.y.z"` riêng.

Khi có Mac ARM và runner Linux amd64:

```bash
terraform providers lock -platform=darwin_arm64 -platform=linux_amd64
terraform init -lockfile=readonly
```

Lệnh đầu bổ sung checksum cho các nền tảng vào lockfile; lệnh sau kiểm CI không tự đổi lockfile. Chạy sau khi root có đầy đủ provider/module configuration. CI không dùng `init -upgrade` mặc định; nâng version là một PR riêng có plan.

## 2. D0 — Chuẩn bị danh tính, công cụ và budget

Trên Mac, cần Git, AWS CLI v2, Session Manager plugin, Terraform, Python, kubectl, Helm, age/SOPS và jq. Dùng hướng dẫn vendor, kiểm checksum bản phát hành; khóa tool version trước khi viết workflow. Đừng chỉ chạy `brew upgrade` rồi coi môi trường đồng nhất với CI.

Các lệnh kiểm tra công cụ:

```bash
git --version
aws --version
session-manager-plugin --version
terraform version
python3 --version
kubectl version --client
helm version
sops --version
age --version
jq --version
```

Mỗi lệnh chỉ báo công cụ cài được; chưa chứng minh account, quyền hay kết nối private API.

Nếu tổ chức đã dùng IAM Identity Center, thiết lập profile SSO theo thông tin được cấp, sau đó kiểm tra đúng danh tính. Với profile đăng nhập Console, dùng `aws login` rồi kiểm tra danh tính theo lệnh bên dưới.

```bash
aws configure sso --profile blogapp-dev
aws sso login --profile blogapp-dev
export AWS_PROFILE=blogapp-dev
export AWS_REGION=ap-southeast-1
aws sts get-caller-identity
```

`configure sso` dùng khi profile chưa có; nếu đã cấu hình thì chỉ login. `AWS_PROFILE` chọn danh tính, `AWS_REGION` chọn vùng, STS trả account và ARN. Không ghi access key vào `terraform.tfvars`. Không dán credential/secret output vào issue hoặc chat.

Trước tạo tài nguyên: đặt budget/cảnh báo, kiểm EC2 vCPU quota, số Elastic IP/NAT, RDS engine/class có ở region và quyền quản hosted zone. Đây là cổng đầu vào, không phải một giá tiền ước lượng đã được đo.

## 3. D1 — Tạo repo và quy ước bảo vệ dữ liệu

Khi bắt đầu code, từ thư mục cha dự định chứa hai repo:

```bash
mkdir blogapp-infra blogapp-gitops
git -C blogapp-infra init -b main
git -C blogapp-gitops init -b main
```

`mkdir` tạo hai checkout; `git -C` chạy Git tại thư mục được chỉ định mà không phải đổi shell directory. Chưa cần chạy `git init` trong source repo đã có.

Sau khi có README, `.gitignore`, cấu trúc và commit ban đầu, có thể tạo remote bằng GitHub CLI đã đăng nhập đúng owner:

```bash
gh repo create Vinh5905/blogapp-infra --private --source=blogapp-infra --remote=origin --push
gh repo create Vinh5905/blogapp-gitops --private --source=blogapp-gitops --remote=origin --push
```

Hai lệnh này **tạo remote và push thật**, chỉ thực hiện ở chặng implementation. Thay owner nếu khác. Bật PR protection/required checks theo tính năng tài khoản; không tuyên bố đã enforce khi chưa thử một PR bị chặn.

Nội dung ignore dự kiến:

```gitignore
.terraform/
*.tfstate
*.tfstate.*
*.tfplan
crash.log
.env
.env.*
*.auto.tfvars
*.tfvars
!*.tfvars.example
backend.hcl
*.kubeconfig
age-key.txt
*.dec.yaml
.venv/
evidence/private/
```

Không ignore `.terraform.lock.hcl`. Các mẫu `.tfvars.example` chỉ chứa tên biến và dữ liệu giả. Với GitOps, chỉ commit file `*.enc.yaml` sau khi kiểm SOPS metadata; đuôi `enc` không chứng minh file đã mã hóa.

## 4. D1 — Bootstrap remote state

### 4.1 Tại sao có vòng bootstrap

Phần này tóm tắt thiết kế backend, các bước bootstrap và cách chuyển state lên S3.

Backend S3 cần bucket đã tồn tại để `terraform init`. Vì vậy root `bootstrap/state` ban đầu dùng local state để tạo KMS/bucket, sau đó chuyển chính state bootstrap lên một key riêng. Không để bootstrap tự đòi dùng backend chưa tạo.

Trình tự:

1. Dùng danh tính cá nhân có quyền bootstrap đúng account, qua SSO hoặc profile đăng nhập Console từ `aws login`.
2. Root bootstrap tạo KMS key có rotation, bucket state có versioning, block public access, TLS-only và IAM backend.
3. Lần đầu `terraform init` bằng local backend, plan/apply đã review.
4. Thêm `backend "s3" {}` vào root bootstrap, tạo partial configuration cho key `bootstrap/state.tfstate`.
5. `terraform init -migrate-state`; kiểm `state list` và object version ở S3.
6. Bảo vệ backend khỏi teardown cluster. Bản state local dự phòng xử lý trong kho bảo vệ, không đưa vào Git.

Ví dụ module S3 của **bootstrap**, sau khi có `aws_kms_key.state`:

```hcl
module "state_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.17.0"

  bucket        = var.state_bucket_name
  force_destroy = false

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  attach_deny_insecure_transport_policy = true
  versioning = { enabled = true }

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        sse_algorithm     = "aws:kms"
        kms_master_key_id = aws_kms_key.state.arn
      }
      bucket_key_enabled = true
    }
  }
}
```

`bucket` phải duy nhất trong namespace S3; ghép project/account/region. `force_destroy=false` tránh Terraform tự vét object khi xóa bucket. Bốn cờ public access chặn nhiều đường public hóa. `versioning` giữ phiên bản state cũ; KMS bảo vệ object trên đĩa, không thay quyền đọc object. TLS-only chặn HTTP. Module này không tự viết key policy đúng nhu cầu account; phải cấu hình quyền KMS/backend riêng.

Ví dụ `backend.hcl` của foundation:

```hcl
bucket       = "blogapp-dev-tfstate-111122223333-ap-southeast-1"
key          = "dev/foundation.tfstate"
region       = "ap-southeast-1"
encrypt      = true
kms_key_id   = "arn:aws:kms:ap-southeast-1:111122223333:key/<key-id>"
use_lockfile = true
```

Cluster dùng key `dev/cluster.tfstate`; bootstrap dùng `bootstrap/state.tfstate`. Backend config không nhận `var.*`. Credentials đi từ session của shell/CI, không nằm trong file này.

Quyền backend cần đọc/ghi state object và list prefix; lockfile cần get/put/delete object `.tflock`; KMS cần quyền phù hợp. Không cần quyền xóa state object cho luồng thường. State chứa dữ liệu nhạy cảm dù output được đánh dấu sensitive. Theo [HashiCorp S3 backend](https://developer.hashicorp.com/terraform/language/backend/s3), dùng S3 locking và versioning; không dựng DynamoDB lock table mới chỉ vì tutorial cũ dùng nó.

### 4.2 Không dùng chung bucket state với SSM file transfer

Ansible SSM dùng bucket tạm truyền module/file. Tạo bucket **riêng**, encryption/TLS-only, prefix hẹp, versioning tắt và lifecycle dọn object ngắn hạn; kiểm dữ liệu còn sót khi run bị ngắt. State bucket phải có versioning, nên hai mục đích này có chính sách khác nhau.

## 5. D2 — Network với module VPC

Các security group và phần IAM, load balancer, RDS tiếp tục được bổ sung vào root foundation sau khi hoàn tất VPC, subnet và định tuyến.

Ví dụ `foundation/network.tf`:

```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.3"

  name = "blogapp-dev"
  cidr = "10.10.0.0/16"

  azs              = var.availability_zones
  public_subnets   = ["10.10.0.0/24",  "10.10.1.0/24"]
  private_subnets  = ["10.10.10.0/24", "10.10.11.0/24"]
  database_subnets = ["10.10.20.0/24", "10.10.21.0/24"]

  enable_dns_support   = true
  enable_dns_hostnames = true

  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false

  create_database_subnet_group           = true
  create_database_subnet_route_table     = true
  create_database_internet_gateway_route = false
  create_database_nat_gateway_route      = false

  tags = { "kubernetes.io/cluster/blogapp-dev" = "owned" }
}
```

`var.availability_zones` là đúng hai AZ available đã chọn trong region; thứ tự subnet khớp thứ tự AZ. Public dành cho ALB/NAT; private dành node; DB subnet không có default route ra IGW/NAT. DNS support/hostnames phục vụ Service bootstrap và AWS private DNS. `single_nat_gateway` giới hạn một NAT cho dev; staging/prod đổi qua thiết kế đã review. `create_database_subnet_group` tạo nhóm subnet cho RDS, chưa tạo DB instance. Tag cluster hỗ trợ discovery theo cấu hình CCM; cùng tag phải được propagate tới node/ASG đúng nhu cầu. Không gắn các tag public LB chỉ để một controller chưa dùng tự tạo LB. Xem [README module VPC](https://github.com/terraform-aws-modules/terraform-aws-vpc).

Outputs cần công bố cho cluster root: VPC ID, public/private subnet IDs, AZ mapping, node SG IDs, NLB endpoint/TG ARN, ALB TG ARN, instance profile, SSM transfer bucket name; công bố RDS address và secret ARN, không công bố secret value.

Ban đầu có thể đọc outputs foundation bằng `terraform_remote_state`. Người đọc backend theo cách này có khả năng tiếp cận state rộng hơn vài output; chỉ cấp cho trusted infra workflow. Về sau xuất contract cần thiết qua Parameter Store hoặc cách chia sẻ riêng để giảm quyền. Không cho source CI đọc state.

### 5.1 Security groups — tạo trước compute


| SG                  | Inbound dự kiến                                                               |
| --------------------- | --------------------------------------------------------------------------------- |
| Public ALB          | 443 từ Internet; 80 redirect                                                   |
| API NLB             | 6443 từ automation host/VPN được phép                                      |
| Control plane       | 6443 qua NLB SG; etcd chỉ control plane; kubelet/cluster traffic theo topology |
| Worker              | 30080 từ ALB SG; kubelet 10250 từ control plane; node/CNI traffic cần thiết |
| RDS                 | 3306 từ worker SG và automation/DB bootstrap SG                               |
| Automation          | Không inbound SSH public; quản qua SSM                                        |
| Interface endpoints | 443 từ SG của node/automation được phép                                   |

Calico VXLAN cần UDP 4789 giữa node; kubelet cần 10250 cho API/metrics-server theo nguồn được phép. Với pod CIDR không thuộc VPC, kiểm đường đi và SNAT thực tế trước chốt egress/SG; không suy diễn SG theo tên Service Kubernetes. NLB SG reference và health-check path phải được xét cùng client-IP preservation; kiểm bằng target health và packet flow.

Ví dụ một rule hẹp, sau khi đã tạo hai SG:

```hcl
resource "aws_vpc_security_group_ingress_rule" "alb_to_ingress" {
  security_group_id            = aws_security_group.worker.id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 30080
  to_port                      = 30080
  description                  = "ALB forwards HTTP to Traefik NodePort"
}
```

`security_group_id` là nơi nhận traffic; `referenced_security_group_id` là nguồn. Đây chỉ là một chiều ingress; cần egress tương ứng ở ALB. Không trộn inline ingress rules và standalone rule resources quản cùng rule set. Không mở cả dải NodePort ra Internet.

## 6. D2 — IAM: bốn loại danh tính khác nhau


| Danh tính               | Công việc                                         | Không được đồng nhất với           |
| -------------------------- | ----------------------------------------------------- | -------------------------------------------- |
| Human SSO                | Bootstrap, review và xử lý khẩn cấp            | Credential hardcode trong pipeline         |
| GitHub OIDC role         | Terraform plan/apply đúng repo/environment        | Quyền mạng private hoặc Kubernetes RBAC |
| EC2 instance profile     | SSM và nhu cầu node thực sự                     | Mọi quyền S3/EBS/ASG của mọi pod       |
| Kubernetes workload role | CSI, CCM, Autoscaler, NTH, telemetry/backup theo SA | EKS Pod Identity tự có trên kubeadm     |

Root bootstrap tạo GitHub OIDC trust theo repo thật, audience `sts.amazonaws.com` và subject đúng workflow/environment. Nếu job dùng GitHub Environment, `sub` thường mang environment, khác subject branch; xác minh claim và policy theo [GitHub AWS OIDC](https://docs.github.com/en/actions/how-tos/secure-your-work/security-harden-deployments/oidc-in-aws). Tách plan/apply role; untrusted PR chỉ static checks, không phát AWS credential. Apply dùng environment approval và commit đã review.

Ưu tiên IAM module submodule khi đúng mô hình; custom trust có thể dùng `aws_iam_policy_document` và resource trực tiếp. Chưa đưa policy JSON toàn quyền vào tài liệu. Khi triển khai, lập action/resource matrix từ plan và tài liệu service, kiểm `iam:PassRole` chỉ cho instance profiles cần dùng; tránh policy `Action:*`, `Resource:*` để làm pipeline chạy được.

CCM/CSI/Autoscaler/NTH cần quyền riêng và projected web identity token; chi tiết bootstrap ở [chương Ansible](02-ansible-kubeadm.md). Instance profile cho node không chứa kubeconfig admin hoặc quyền đọc age key.

## 7. D2 — ALB ứng dụng và NLB API là hai tài nguyên riêng

### 7.1 ALB public: ví dụ cấu trúc listeners/target group

```hcl
module "edge" {
  source  = "terraform-aws-modules/alb/aws"
  version = "10.5.1"

  name               = "blogapp-dev-edge"
  load_balancer_type = "application"
  internal           = false
  vpc_id             = module.vpc.vpc_id
  subnets            = module.vpc.public_subnets
  create_security_group = false
  security_groups       = [aws_security_group.alb.id]

  listeners = {
    http = {
      port = 80
      protocol = "HTTP"
      redirect = { port = "443", protocol = "HTTPS", status_code = "HTTP_301" }
    }
    https = {
      port            = 443
      protocol        = "HTTPS"
      certificate_arn = var.validated_certificate_arn
      forward         = { target_group_key = "traefik" }
    }
  }

  target_groups = {
    traefik = {
      protocol          = "HTTP"
      port              = 30080
      target_type       = "instance"
      create_attachment = false
      health_check = {
        enabled  = true
        protocol = "HTTP"
        port     = "traffic-port"
        path     = "/ping"
        matcher  = "200"
      }
    }
  }
}
```

Listener nhận request; target group xác định đích. ACM certificate phải issued trong cùng region với ALB. `create_attachment=false` vì targets worker do ASG quản, không có một `target_id` cố định. Rule `/ping` phải được Traefik phục vụ trên đúng web entrypoint; health-check Host của ALB có thể là IP, nên không dùng route chỉ khớp hostname ứng dụng cho ping. Chọn TLS policy theo policy TLS hiện hành khi viết implementation, không để phần này là mặc định không được xem xét.

Tạo ACM certificate + DNS validation records, chờ validation resource; tạo Route 53 alias dev hostname trỏ ALB. Nếu DNS ở nhà cung cấp khác, cung cấp CNAME validation tại đó và chờ issued. Chưa sở hữu domain thì chưa tick nghiệm thu HTTPS hostname thật. Xem [module ALB](https://github.com/terraform-aws-modules/terraform-aws-alb).

### 7.2 Internal NLB cho API kubeadm

Dùng cùng module nhưng cấu hình `load_balancer_type="network"`, `internal=true`, hai private subnet, listener TCP 6443, target group TCP 6443 và health check TCP. NLB không kết thúc certificate kube-apiserver. Tạo private DNS `api.dev.<domain>` trỏ NLB, đưa tên đó vào kubeadm `controlPlaneEndpoint` và cert SAN.

NLB target group được tạo trong foundation với `create_attachment=false`; cluster root tạo attachment cho control-plane EC2 ID sau khi có instance. NLB có thể unhealthy trước kubeadm init, đây là trạng thái bootstrap dự kiến; sau init phải healthy. Không đặt điều kiện “NLB healthy trước init” tạo deadlock.

NLB nên có SG ngay lúc tạo; không dựa vào việc thêm SG sau mà không kiểm giới hạn của NLB. Không đưa 6443 ra Internet để Mac truy cập thuận tiện.

## 8. D2 — RDS MySQL

Ví dụ cấu hình cốt lõi, sau khi có subnet group, SG, KMS và engine patch được xác minh:

```hcl
module "database" {
  source  = "terraform-aws-modules/rds/aws"
  version = "7.2.2"

  identifier     = "blogapp-dev"
  engine         = "mysql"
  engine_version = var.mysql_engine_version
  family         = "mysql8.4"
  instance_class = var.db_instance_class

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = var.database_kms_key_arn

  multi_az            = false
  publicly_accessible = false
  db_subnet_group_name   = module.vpc.database_subnet_group_name
  vpc_security_group_ids = [aws_security_group.database.id]
  create_db_option_group = false

  username                    = "blogapp_bootstrap"
  manage_master_user_password = true
  backup_retention_period     = 7
  deletion_protection         = true
  skip_final_snapshot         = false

  parameters = [{
    name         = "require_secure_transport"
    value        = "ON"
    apply_method = "immediate"
  }]
}
```

Đây là cấu hình **dev**, nên `multi_az=false` theo thiết kế gốc. Không dùng nguyên cấu hình này cho prod. Engine patch phải thuộc MySQL 8.4 và được region hỗ trợ, class/storage phải có trong orderable options; chưa có bằng chứng live về engine/class của account này. `max_allocated_storage` cho phép tăng storage đến trần, không tự thu nhỏ khi hết tải. `manage_master_user_password` để RDS giữ master credential trong Secrets Manager, Terraform chỉ cần secret ARN. `deletion_protection` và final snapshot bảo vệ khi teardown; final snapshot identifier và các trường log/maintenance/monitoring phải được bổ sung trong implementation.

Tra cứu trước khi điền `mysql_engine_version` và class:

```bash
aws rds describe-db-engine-versions --engine mysql --engine-version 8.4 --region ap-southeast-1
aws rds describe-orderable-db-instance-options --engine mysql --engine-version '<patch-da-chon>' --region ap-southeast-1
```

Lệnh đầu liệt kê metadata engine; lệnh sau kiểm tổ hợp có thể tạo. Đọc output thật để chọn, không lấy giá trị giả trong tài liệu làm kết quả AWS.

Terraform tạo DB instance/subnet/parameter group. **Nó không chạy migration và không tự tạo ba database logic chỉ bằng `db_name`.** Một bước bootstrap SQL qua đường private tạo userdb/postdb/commentdb và sáu tài khoản runtime/migration. Credentials ứng dụng lưu SOPS hoặc secret store, không hardcode trong `.tf`/`user_data`. Chỉ role bootstrap DB đọc master secret; pod runtime không được quyền đó.

Enforce TLS bằng parameter group và kiểm client xác thực CA/hostname. RDS từ chối insecure connection khi bật `require_secure_transport`; xem [AWS TLS requirement](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/mysql-ssl-connections.require-ssl.html). JDBC cần `sslMode=VERIFY_IDENTITY` và truststore chứa RDS CA đúng; dùng endpoint RDS thật thay alias không nằm trong certificate. Không bê URL `useSSL=false&allowPublicKeyRetrieval=true` từ Compose sang RDS.

Xem [module RDS](https://github.com/terraform-aws-modules/terraform-aws-rds) và hướng dẫn AWS để thêm CloudWatch logs, retention, KMS log groups, Database Insights/monitoring theo tính năng và giá hiện hành; không bật audit export rồi mặc nhiên tin audit plugin đã hoạt động.

## 9. D3 — EC2 cố định và worker ASG

### 9.1 Control plane và automation host

Ví dụ EC2 control plane, **AMI/profile/SG cần có trước**:

```hcl
module "control_plane" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "6.4.1"

  name          = "blogapp-dev-cp-1"
  ami           = var.ubuntu_amd64_ami_id
  instance_type = var.control_plane_instance_type
  subnet_id     = var.control_plane_subnet_id

  associate_public_ip_address = false
  create_security_group      = false
  vpc_security_group_ids     = [var.control_plane_security_group_id]
  iam_instance_profile       = var.control_plane_instance_profile_name

  metadata_options = {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
  root_block_device = {
    encrypted = true
    type      = "gp3"
    size      = 30
  }
  tags = { Role = "control-plane", Cluster = "blogapp-dev" }
}
```

`ami` là AMI Ubuntu amd64 đã kiểm publisher và pin ID, không lấy `most_recent` để lần apply bình thường tự đổi máy. Instance profile phục vụ SSM và quyền node cần thiết. IMDSv2 required; hop limit 1 là lựa chọn chặn truy cập từ pod mạng thường, nhưng không thay NetworkPolicy hoặc isolation với hostNetwork pods. Nếu một thành phần cần IMDS qua namespace mạng, thiết kế riêng và kiểm chứng; không tăng lên 2 cho toàn node mà bỏ qua ảnh hưởng quyền.

Kiểm schema `root_block_device` theo đúng module version trước implementation. Automation host tạo bằng module tương tự, gắn SG/profile riêng và tools cần thiết; không kubeadm join vào cluster. AMI phải có SSM Agent hoạt động hoặc bootstrap tối thiểu cài agent với egress đúng, nếu không sẽ mắc vòng “cần Ansible để cài phương tiện Ansible kết nối”.

### 9.2 Worker ASG — cấu hình cuối sau bootstrap

```hcl
module "workers" {
  source  = "terraform-aws-modules/autoscaling/aws"
  version = "9.3.2"

  name                = "blogapp-dev-workers"
  vpc_zone_identifier = var.private_subnet_ids
  min_size            = 2
  max_size            = 4
  desired_capacity    = 2
  ignore_desired_capacity_changes = true
  health_check_type               = "EC2"

  image_id                  = var.worker_ami_id
  instance_type             = var.worker_instance_type
  security_groups           = [var.worker_security_group_id]
  iam_instance_profile_name = var.worker_instance_profile_name
  launch_template_version   = var.approved_launch_template_version

  traffic_source_attachments = {
    ingress = {
      traffic_source_identifier = var.traefik_target_group_arn
      traffic_source_type       = "elbv2"
    }
  }

  initial_lifecycle_hooks = [{
    name                 = "blogapp-dev-worker-launch"
    lifecycle_transition = "autoscaling:EC2_INSTANCE_LAUNCHING"
    heartbeat_timeout    = 900
    default_result       = "ABANDON"
  }]

  tags = {
    Cluster = "blogapp-dev"
    Role    = "worker"
    "kubernetes.io/cluster/blogapp-dev"       = "owned"
    "k8s.io/cluster-autoscaler/enabled"       = "true"
    "k8s.io/cluster-autoscaler/blogapp-dev"   = "owned"
  }
}
```

Các inputs trên được đối chiếu metadata module `9.3.2`; block vẫn cần bổ sung EBS mã hóa, IMDS, user_data tối thiểu/AMI bootstrap, timeouts và lifecycle orchestration. `image_id` là input ASG, khác `ami` ở EC2 module. `traffic_source_attachments` gắn cả ASG vào TG, không đóng đinh instance ID. `EC2` health tránh sự cố chung Traefik làm thay hàng loạt máy; Kubernetes NodeNotReady cần remediation riêng có giới hạn. `ignore_desired_capacity_changes=true` giao desired cho CA; min/max vẫn do Terraform quản.

**Trình tự khởi tạo:** lúc D3 đặt min=0 và desired=0, không bật CA. Hoàn tất control plane và launch workflow, rồi nâng min lên 2 để ASG tạo hai máy; với ignore-desired bật từ đầu, việc sửa riêng `desired_capacity` sau tạo không có tác dụng. Nâng `min_size` buộc ASG giữ ít nhất hai máy. Sau D11 CA có thể điều chỉnh 2–4. Không bật/tắt cờ ignore-desired tùy ý vì module dùng các resource khác nhau; plan migration cẩn thận.

`approved_launch_template_version` là số version đã kiểm tra, không dùng `$Latest` để cập nhật máy ngoài quy trình. Khi module tạo LT lần đầu, có thể bootstrap với numeric version 1 rồi ghi nhận output thực tế trước rollout version sau. Bất kỳ thay đổi nào sinh LT version mới phải review, lựa chọn version và thực hiện refresh có điều kiện Node Ready/drain, không tự coi EC2 healthy là pod đã hồi phục.

Hook khởi tạo phải được gắn trước khi worker đầu tiên launch. Module có `initial_lifecycle_hooks` cho lúc tạo ASG; với nhóm đã có, dùng resource lifecycle hook phù hợp thay vì tin thay initial hooks sẽ tác động ngược. Xem [ASG module](https://github.com/terraform-aws-modules/terraform-aws-autoscaling). Workflow và scale-in trình bày ở chương kế tiếp.

## 10. D2/D6 — Storage và identity contract

Tạo buckets tách mục đích: state, SSM transfer, etcd backup, Loki, Tempo và OIDC public documents. State/backup/telemetry giữ private; OIDC chỉ công bố discovery/JWKS public key qua HTTPS cho STS đọc, không public hóa bucket backup. Có thể dùng CloudFront OAC trước S3 private cho issuer; phải thêm certificate/DNS/access policy phù hợp, không copy lệnh ACL public-read cũ.

Terraform tạo IAM OIDC provider và role trust sau khi đã có issuer TLS + JWKS; kubeadm dùng signing key đã bootstrap bởi Ansible. Kết nối hai chiều này được chia thành cổng D4–D6: issuer URL xác định trước, public key xuất sau init, sau đó IAM provider/roles được apply. Workload AWS API chưa được bật trước identity gate.

Key mã hóa etcd, age private key và service-account signing private key được quản qua kênh bảo vệ; không dùng Terraform output để chuyển chúng. Bucket backup nhận dữ liệu đã mã hóa và có restore runbook. EBS CSI sẽ tạo EBS volumes cho PVC; Terraform không quản từng volume do CSI tạo.

## 11. Cách chạy Terraform ở mỗi root

Sau khi code của root đã hoàn chỉnh và có `backend.hcl` cùng `dev.tfvars` local:

```bash
terraform -chdir=terraform/environments/dev/foundation init -backend-config=backend.hcl
terraform -chdir=terraform/environments/dev/foundation fmt -check -diff
terraform -chdir=terraform/environments/dev/foundation validate
terraform -chdir=terraform/environments/dev/foundation plan -var-file=dev.tfvars -out=dev.tfplan
terraform -chdir=terraform/environments/dev/foundation show dev.tfplan
terraform -chdir=terraform/environments/dev/foundation apply dev.tfplan
terraform -chdir=terraform/environments/dev/foundation output
```

`-chdir` chọn root trước khi xử lý paths; `backend.hcl`, `dev.tfvars`, `dev.tfplan` ở trong root đó. `init` tải provider/module và mở backend. `fmt` kiểm style, `validate` kiểm schema/reference sau init. `plan` đọc AWS/state và tạo saved plan; `show` phục vụ review; `apply dev.tfplan` thực thi đúng plan đó. Apply saved plan không hỏi lại interactive như apply thường, vì vậy review phải diễn ra trước lệnh. `output` chỉ xuất fields được khai báo, chưa kiểm chức năng ứng dụng.

Cluster root dùng cùng quy trình sau foundation. Bootstrap root lần đầu khác ở bước local backend như mục 4. Không dùng `-target` làm thứ tự chuẩn hằng ngày; dùng root/state và cổng bootstrap rõ ràng. Sau apply bình thường, plan lại để phát hiện diff ngoài dự kiến; khi CA đã scale, desired không phải là diff bị Terraform kéo về.

Các check CI dự kiến: `fmt -check -recursive`, init backend=false/validate cho static stage, TFLint, Trivy config; trusted plan riêng có OIDC. Scan theo policy có output và exit code fail; không thêm scanner chỉ để tạo report xanh. Artifact plan có thể chứa secret, cần retention và quyền đọc hẹp.

## 12. Cổng nghiệm thu Terraform

- Account/region khớp, backend khóa được hai tiến trình cạnh tranh và recover được state version cũ trong bài thử cô lập.
- Không có public IP trên control plane/worker/automation; RDS `publicly_accessible=false`.
- ALB public đúng hai AZ, NLB internal, API 6443 không truy cập từ Internet.
- SSM Online từ đường quản trị, nodes có egress cần thiết; DB subnet không có default Internet route.
- Outputs đủ cho Ansible/GitOps bootstrap; không lộ secret value.
- Worker ASG gắn đúng TG, cờ ignore desired đúng; launch hook/workflow không chạy trước khi có control plane.
- RDS backup/TLS/deletion protection và KMS hoạt động; chưa cần app chạy để tick phần provision.
- Lưu plan/revision/output summary đã redact. Chưa đánh dấu Kubernetes hoặc GitOps hoàn thành chỉ vì Terraform apply thành công.
