
# Terraform cho người mới bắt đầu

Tài liệu này giải thích Terraform từ nền tảng đến workflow production: kiến trúc, provider, module, state, HCL syntax, plan/apply và kiểm tra bằng TFLint, Checkov, Trivy.

---

## 1. Terraform là gì?

Terraform là công cụ Infrastructure as Code (IaC). Bạn mô tả **trạng thái mong muốn** của hạ tầng bằng file cấu hình có thể commit vào Git, review, tái sử dụng và chạy lặp lại.

Terraform là **declarative**: mô tả kết quả cần có, không phải chuỗi bước thủ công để tạo ra kết quả đó.

~~~hcl
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
}

resource "aws_subnet" "private" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "10.0.1.0/24"
}
~~~

Reference aws_vpc.main.id tạo dependency ngầm. Terraform biết VPC phải tồn tại trước subnet và có thể chạy song song các resource độc lập.

Terraform không phải:

- Công cụ cấu hình bên trong máy chủ như Ansible.
- Hệ thống CI/CD, dù thường được gọi từ CI/CD.
- Nơi lưu secret an toàn. State có thể chứa dữ liệu nhạy cảm.
- Cơ chế tự rollback toàn bộ khi apply thất bại.

---

## 2. Kiến trúc Terraform

~~~text
                    Terraform CLI / HCP Terraform
                                │
       ┌────────────────────────┼────────────────────────┐
       ▼                        ▼                        ▼
  HCL configuration        State / backend        Variables / secrets
  *.tf, *.tfvars           tfstate + lock          env / CI / vault
                                │
                                ▼
                       ┌──────────────────┐
                       │  Terraform Core  │
                       │ parse/evaluate   │
                       │ graph/plan/apply │
                       └────────┬─────────┘
                                │ plugin protocol
                   ┌────────────┴────────────┐
                   ▼                         ▼
             Provider plugins            Module sources
             AWS/Azure/GCP/...           Registry/Git/local
                   │
                   ▼
             Cloud/service APIs
~~~

### Terraform Core

Core đọc và parse HCL, đánh giá expression, xử lý variable/local/data/module, dựng dependency graph, đọc state, tạo plan, điều phối apply và ghi state.

### Provider

Provider là plugin giúp Terraform gọi API của nền tảng/dịch vụ:

- hashicorp/aws: AWS;
- hashicorp/azurerm: Azure;
- hashicorp/google: Google Cloud;
- hashicorp/kubernetes: Kubernetes;
- integrations/github: GitHub.

Provider định nghĩa resource và data source. Provider là API client; module là cấu hình tái sử dụng.

### Module

Module là tập hợp resource được quản lý cùng nhau. Thư mục hiện tại là root module; module được gọi qua block module là child module.

Module có thể lấy từ local path, Terraform Registry, Git hoặc nguồn Terraform hỗ trợ.

### State và backend

State ánh xạ địa chỉ resource trong code với object thật trên cloud, lưu metadata và giúp Terraform biết lần trước đã tạo gì.

Mặc định state nằm local ở terraform.tfstate. Team nên dùng remote backend hoặc HCP Terraform để chia sẻ state, locking, phân quyền, backup và audit.

Không commit state lên Git; state có thể chứa password, token hoặc connection string.

---

## 3. Desired state, current state và plan

| Thành phần | Vai trò |
|---|---|
| Configuration | Trạng thái mong muốn |
| State | Terraform ghi nhận resource nào tương ứng với resource nào |
| Remote objects | Hạ tầng đang tồn tại trên cloud |

Trong một lần chạy, Terraform thường:

1. Đọc configuration.
2. Đọc state.
3. Refresh thông tin từ remote system.
4. So sánh desired state với current state.
5. Dựng dependency graph.
6. Tạo execution plan.
7. Apply create, update, replace hoặc destroy.
8. Ghi kết quả về state.

Nếu ai đó sửa cloud object ngoài Terraform, đó là **drift**. Lần plan sau có thể phát hiện chênh lệch.

---

## 4. Workflow Terraform thật sự

~~~text
Write → Init → Format/Validate/Lint/Scan → Plan → Review → Apply → Observe
~~~

Trong team:

~~~text
Branch → quality gates → pull request + plan → review
      → merge → final plan + approval → apply → remote state
~~~

### 4.1 Viết configuration

Terraform đọc mọi file .tf trong root module. Tên file không quyết định thứ tự chạy; reference và graph mới quyết định dependency.

~~~text
infra/
├── versions.tf
├── providers.tf
├── main.tf
├── variables.tf
├── locals.tf
├── data.tf
├── outputs.tf
├── terraform.tfvars
├── modules/
│   └── network/
│       ├── main.tf
│       ├── variables.tf
│       └── outputs.tf
└── .gitignore
~~~

Đây là convention, không bắt buộc.

### 4.2 Init

~~~bash
terraform init
~~~

init tải provider, module, khởi tạo backend và tạo/kiểm tra dependency lock file .terraform.lock.hcl.

Cần chạy lại init khi đổi provider constraint, module source/version hoặc backend.

~~~text
.terraform/             # cache; không commit
.terraform.lock.hcl     # lock version/checksum; nên commit
terraform.tfstate       # local state; không commit
~~~

### 4.3 Format, validate, lint, scan

~~~bash
terraform fmt -recursive
terraform validate

tflint --init
tflint

checkov -d .

trivy config .
~~~

- fmt chuẩn hóa style.
- validate kiểm tra syntax/schema/reference cơ bản.
- TFLint tìm lỗi tiềm ẩn, deprecated syntax và best practice.
- Checkov kiểm tra policy-as-code và cloud misconfiguration.
- Trivy scan misconfiguration của IaC.

### 4.4 Plan

~~~bash
terraform plan
~~~

plan không thay đổi cloud. Nó đọc state/remote, so sánh với configuration và mô tả action dự kiến.

Trong automation:

~~~bash
terraform plan -out=tfplan
terraform show tfplan
terraform apply tfplan
~~~

Saved plan giúp apply đúng nội dung đã review, nhưng có thể chứa dữ liệu nhạy cảm.

~~~text
+ create
- destroy
~ update in-place
-/+ replace: destroy rồi create
<= read: đọc data source
~~~

Dừng lại nếu thấy replacement trên resource quan trọng mà bạn không chủ ý.

### 4.5 Apply

~~~bash
terraform apply
~~~

Không truyền saved plan thì apply tự tạo plan mới, hỏi confirmation rồi chạy. Trong CI thường apply saved plan.

Terraform gọi provider; provider gọi cloud API. Resource độc lập có thể chạy song song, resource có dependency được xếp đúng thứ tự.

Apply thất bại không tự rollback toàn bộ. Terraform ghi state cho phần đã hoàn tất rồi dừng; sửa nguyên nhân và chạy lại.

### 4.6 Inspect và destroy

~~~bash
terraform output
terraform state list
terraform show

terraform plan -destroy
terraform destroy
~~~

Destroy chỉ nên dùng trong lab hoặc production có approval rõ ràng.

---

## 5. Lab đầu tiên không cần cloud credentials

Dùng provider random để học init, resource, variable, output, plan và state mà không tạo resource AWS.

~~~hcl
terraform {
  required_version = ">= 1.6.0, < 2.0.0"

  required_providers {
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "random" {}

variable "project" {
  type    = string
  default = "terraform-demo"
}

resource "random_pet" "name" {
  prefix    = var.project
  length    = 2
  separator = "-"
}

output "generated_name" {
  value = random_pet.name.id
}
~~~

Chạy:

~~~bash
terraform init
terraform fmt
terraform validate
terraform plan
terraform apply
terraform output
terraform state list
~~~

Chạy plan lần nữa mà không đổi code thường sẽ thấy không có thay đổi.

---

## 6. HCL syntax

Mẫu block:

~~~hcl
<block_type> "<label_1>" "<label_2>" {
  argument = expression

  nested_block {
    argument = expression
  }
}
~~~

- Block: vùng có type và label.
- Argument: phép gán tên = giá trị.
- Expression: literal, reference, operator hoặc function tạo ra giá trị.

Terraform không chạy file theo thứ tự như script; hãy biểu diễn dependency bằng reference.

### 6.1 Comment và value

~~~hcl
# Comment một dòng
// Comment một dòng khác

/*
  Comment nhiều dòng
*/

name    = "web"
count   = 3
enabled = true
ports   = [80, 443]
tags    = { team = "platform", env = "dev" }
~~~

Type thường dùng:

| Type | Ví dụ |
|---|---|
| string | "ap-southeast-1" |
| number | 2, 3.14 |
| bool | true |
| list(T) | ["a", "b"] |
| set(T) | toset(["a", "b"]) |
| map(T) | { dev = "small", prod = "large" } |
| object | object có schema |
| tuple | tuple có kiểu/vị trí cố định |

### 6.2 Variable và local

~~~hcl
// Interpolation chèn expression vào string.
name = "${var.project}-web"

// Với một expression đơn, reference trực tiếp thường dễ đọc hơn.
name = var.project

variable "environment" {
  description = "Môi trường triển khai"
  type        = string

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment phải là dev, staging hoặc prod."
  }
}

locals {
  name_prefix = format("%s-%s", var.project, var.environment)

  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
~~~

Gán variable:

~~~bash
terraform plan -var='environment=dev'
terraform plan -var-file='dev.tfvars'
export TF_VAR_environment=dev
~~~

terraform.tfvars và *.auto.tfvars được Terraform tự load. Không đặt secret thật vào file tracked.

### 6.3 Resource, data, output

Resource được Terraform quản lý lifecycle:

~~~hcl
resource "aws_s3_bucket" "logs" {
  bucket = "my-example-logs-123456"
  tags   = local.common_tags
}
~~~

Data source đọc thông tin đã tồn tại:

~~~hcl
data "aws_caller_identity" "current" {}

output "account_id" {
  value = data.aws_caller_identity.current.account_id
}
~~~

Output là giao diện của module:

~~~hcl
output "bucket_arn" {
  value = aws_s3_bucket.logs.arn
}

output "password" {
  value     = var.database_password
  sensitive = true
}
~~~

sensitive chỉ hạn chế hiển thị CLI; dữ liệu vẫn có thể nằm trong state.

### 6.4 Reference, conditional, for và function

~~~hcl
var.region
local.common_tags
aws_vpc.main.id
data.aws_caller_identity.current.account_id
module.network.vpc_id

instance_type = var.environment == "prod" ? "t3.large" : "t3.micro"

locals {
  upper_names = [for name in var.names : upper(name)]
  name_map    = { for name in var.names : name => "enabled" }
  count       = length(var.availability_zones)
  first       = try(var.availability_zones[0], null)
  json_tags   = jsonencode(local.common_tags)
}
~~~

Function hay gặp: length, concat, merge, lookup, try, coalesce, contains, distinct, flatten, toset, format, join, split, replace, jsonencode, yamlencode, cidrsubnet.

---

## 7. Meta-arguments và dependency

### count

~~~hcl
resource "aws_instance" "web" {
  count = var.create_web ? 2 : 0

  ami           = var.ami_id
  instance_type = var.instance_type

  tags = {
    Name = format("web-%d", count.index)
  }
}
~~~

count phù hợp khi instance giống nhau và truy cập theo index. Đổi thứ tự list có thể gây replacement.

### for_each

~~~hcl
variable "buckets" {
  type = map(object({
    versioning = bool
  }))

  default = {
    logs = { versioning = true }
    data = { versioning = false }
  }
}

resource "aws_s3_bucket" "this" {
  for_each = var.buckets
  bucket   = format("example-%s", each.key)
}
~~~

for_each phù hợp khi mỗi instance có identity ổn định theo key.

### lifecycle

~~~hcl
resource "aws_instance" "web" {
  lifecycle {
    create_before_destroy = true
    prevent_destroy        = true
    ignore_changes         = [tags]
  }
}
~~~

Dùng cẩn thận: create_before_destroy có thể tăng chi phí; prevent_destroy có thể làm pipeline fail; ignore_changes có thể che giấu drift.

### depends_on

Ưu tiên implicit dependency:

~~~hcl
resource "aws_subnet" "private" {
  vpc_id = aws_vpc.main.id
}
~~~

Dùng explicit dependency khi Terraform không thể suy ra từ reference:

~~~hcl
resource "aws_instance" "app" {
  depends_on = [aws_iam_role_policy.app]
}
~~~

Dùng depends_on quá rộng làm graph bảo thủ và plan chậm.

Provisioner local-exec/remote-exec nên là lựa chọn cuối cùng; ưu tiên provider resource, cloud-init, image baking hoặc configuration management.

---

## 8. Provider và lock file

Khai báo provider:

~~~hcl
terraform {
  required_version = ">= 1.6.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
~~~

source là địa chỉ provider đầy đủ. version là constraint; production không nên bỏ trống. Commit .terraform.lock.hcl sau init.

Cấu hình provider:

~~~hcl
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}
~~~

Không hard-code access key trong .tf. Dùng credential chain, profile, role, OIDC hoặc secret manager.

Provider alias:

~~~hcl
provider "aws" {
  region = "ap-southeast-1"
}

provider "aws" {
  alias  = "replica"
  region = "ap-northeast-1"
}

resource "aws_s3_bucket" "replica" {
  provider = aws.replica
  bucket   = "example-replica-bucket-123456"
}
~~~

---

## 9. Module

### Module local

~~~text
modules/bucket/
├── main.tf
├── variables.tf
└── outputs.tf
~~~

~~~hcl
variable "name" {
  type        = string
  description = "Tên bucket"
}

variable "tags" {
  type    = map(string)
  default = {}
}

resource "aws_s3_bucket" "this" {
  bucket = var.name
  tags   = var.tags
}

output "arn" {
  value = aws_s3_bucket.this.arn
}
~~~

Gọi module:

~~~hcl
module "logs_bucket" {
  source = "./modules/bucket"

  name = "my-logs-bucket-123456"
  tags = {
    Purpose = "logs"
  }
}

output "logs_bucket_arn" {
  value = module.logs_bucket.arn
}
~~~

### Module từ Registry

~~~hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "example"
  cidr = "10.0.0.0/16"

  azs             = ["ap-southeast-1a", "ap-southeast-1b"]
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24"]

  enable_nat_gateway = false
}
~~~

Trước khi dùng module public:

1. Đọc README, input và output.
2. Kiểm tra provider/module version.
3. Đọc resource module thực sự tạo.
4. Pin version.
5. Xem plan trước khi apply.

Resource bên trong module vẫn xuất hiện trong state, ví dụ module.vpc.aws_vpc.this[0].

~~~bash
terraform state list
terraform state show 'module.vpc.aws_vpc.this[0]'
~~~

---

## 10. State, backend, locking và drift

### Local state

Local state tiện cho lab nhưng khó chia sẻ, dễ mất, khó locking và có thể chứa secret.

### Remote backend

Production nên có storage bền vững, encryption, access control, locking và backup/audit.

Backend S3 cần thiết kế bucket, encryption, versioning, IAM và locking theo cơ chế được version Terraform/provider hỗ trợ. Đọc tài liệu backend tương ứng trước khi dùng.

Không commit terraform.tfstate, kể cả repository private, trừ workflow đặc biệt đã đánh giá bảo mật.

### Locking

Locking ngăn hai phiên Terraform cùng ghi state. Nếu lock bị treo, kiểm tra run khác trước. Chỉ force-unlock khi chắc chắn lock không còn hợp lệ.

### Drift

~~~text
Terraform config ──────┐
                       ├─ plan → phát hiện chênh lệch
State ─────────────────┤
                       │
Remote cloud object ───┘
~~~

Cách xử lý: sửa code rồi apply; hoặc dùng plan refresh-only khi thay đổi ngoài Terraform là có chủ ý và bạn đã hiểu hậu quả.

### Import

~~~bash
terraform import aws_s3_bucket.logs my-existing-bucket
~~~

Import chỉ đưa object vào state; không tự viết configuration hoàn chỉnh. Sau import, viết code khớp rồi chạy plan.

---

## 11. Ví dụ AWS tối giản

> Cảnh báo: có thể tạo tài nguyên và phát sinh chi phí. Chỉ chạy khi hiểu account/profile/region đang dùng.

~~~hcl
terraform {
  required_version = ">= 1.6.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "ap-southeast-1"
}

variable "project" {
  type    = string
  default = "terraform-demo"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

provider "aws" {
  region = var.aws_region
}

locals {
  common_tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr

  tags = merge(local.common_tags, {
    Name = format("%s-vpc", var.project)
  })
}

resource "aws_subnet" "private" {
  for_each = toset(slice(data.aws_availability_zones.available.names, 0, 2))

  vpc_id            = aws_vpc.main.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, index(data.aws_availability_zones.available.names, each.key))

  tags = merge(local.common_tags, {
    Name = format("%s-%s-private", var.project, each.key)
  })
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "private_subnet_ids" {
  value = { for az, subnet in aws_subnet.private : az => subnet.id }
}
~~~

Chạy:

~~~bash
aws sts get-caller-identity
terraform init
terraform fmt -recursive
terraform validate
terraform plan -out=tfplan
terraform show tfplan
terraform apply tfplan
terraform output
~~~

Ví dụ chỉ minh họa VPC/subnet, chưa phải network production hoàn chỉnh. Sau lab:

~~~bash
terraform destroy
~~~

---

## 12. Security và quality gates

### Không commit secret

~~~gitignore
.terraform/
*.tfstate
*.tfstate.*
*.tfvars
*.tfvars.json
crash.log
crash.*.log
tfplan
*.plan
~~~

Có thể commit terraform.tfvars.example nếu chỉ có giá trị mẫu. Nếu lộ secret, rotate/revoke trước rồi xử lý Git và state/backend.

### TFLint

~~~bash
tflint --init
tflint --recursive
~~~

TFLint là linter có plugin, tìm lỗi tiềm ẩn, deprecated syntax, unused declaration và best practice.

### Checkov

~~~bash
checkov -d .
checkov -d . --framework terraform
~~~

Checkov là policy-as-code scanner cho Terraform và nhiều dạng IaC. Suppress finding phải có lý do, owner và thời hạn review.

### Trivy

~~~bash
trivy config .
trivy config --severity HIGH,CRITICAL .
~~~

Trivy scan misconfiguration của Terraform. Nếu scan plan/config sau khi render biến/module, đọc hướng dẫn của phiên bản Trivy đang dùng.

### Pipeline mẫu

~~~bash
set -euo pipefail

terraform fmt -check -recursive
terraform init -backend=false
terraform validate

tflint --init
tflint --recursive

checkov -d .
trivy config --severity HIGH,CRITICAL .

terraform init
terraform plan -out=tfplan
terraform show -no-color tfplan > tfplan.txt
~~~

Production nên thêm approval, policy chặn finding nghiêm trọng, bảo vệ plan/log, giới hạn account/region, kiểm tra destructive change và bảo vệ backend.

---

## 13. Lỗi thường gặp

### Đổi tên resource làm destroy/create

Tên resource là một phần của địa chỉ state:

~~~hcl
resource "aws_s3_bucket" "old" {}
~~~

Đổi thành aws_s3_bucket.new có thể bị hiểu là destroy cũ và create mới. Cân nhắc:

~~~hcl
moved {
  from = aws_s3_bucket.old
  to   = aws_s3_bucket.new
}
~~~

### Sửa Console rồi Terraform đổi ngược

Đó là drift. Chọn Terraform làm source of truth và đưa thay đổi vào code.

### Resource bị replace

Đọc plan để tìm immutable field, thay đổi count/for_each hoặc provider behavior. Không đoán chỉ từ dòng cuối.

### Plan/apply bị lock

Kiểm tra run khác, process crash hoặc backend. Chỉ force-unlock khi chắc chắn không còn run hợp lệ.

### Dùng target như workflow thường xuyên

-target dành cho phục hồi/debug đặc biệt; không thay thế plan/apply toàn bộ configuration.

### Dùng workspace cho mọi environment

Workspace không tự tạo isolation về account, credential, backend policy hay blast radius. Production cần environment/account/state boundary rõ ràng.

---

## 14. Checklist trước khi merge/apply

~~~text
[ ] fmt pass
[ ] Terraform/provider/module version có constraint
[ ] .terraform.lock.hcl được commit
[ ] validate pass
[ ] TFLint pass hoặc finding đã được giải thích
[ ] Checkov/Trivy pass hoặc exception có owner/thời hạn
[ ] Không có secret trong code, tfvars, plan artifact hoặc log
[ ] Đã đọc toàn bộ plan, đặc biệt -/+ và destroy
[ ] Đúng account, region, workspace và backend
[ ] Backend có encryption, access control và locking
[ ] Có approval nếu production/destructive
[ ] Biết cách recover nếu apply thất bại
~~~

---

## 15. Lộ trình học

1. HCL block/argument/expression.
2. init, fmt, validate, plan, apply, destroy.
3. resource, data, variable, output, local.
4. Đọc plan và hiểu state.
5. Làm project VPC/service nhỏ.
6. Dùng for_each, count, lifecycle và module.
7. Import resource và xử lý drift.
8. Remote backend, locking, CI plan/apply.
9. TFLint, Checkov, Trivy, OIDC và policy.

Khi đọc module community:

~~~text
README → versions.tf → variables.tf → main.tf → outputs.tf → examples → CHANGELOG
~~~

Đừng chỉ copy README. Hãy đọc plan để biết module tạo gì, có mở public access, tạo NAT Gateway tốn phí hay bật logging/encryption ra sao.

---

## 16. Cheat sheet

~~~bash
terraform fmt -recursive
terraform validate
terraform init
terraform init -upgrade

terraform plan
terraform plan -out=tfplan
terraform show tfplan

terraform apply
terraform apply tfplan

terraform output
terraform state list
terraform state show ADDRESS

terraform plan -refresh-only
terraform import ADDRESS ID
terraform state mv SOURCE DESTINATION

terraform plan -destroy
terraform destroy

TF_LOG=INFO terraform plan
~~~

Không bật DEBUG log bừa bãi trong CI/production vì log có thể chứa dữ liệu nhạy cảm.

---

## 17. Tài liệu và nguồn học tiếp

### Tài liệu chính thức

- [Terraform Documentation](https://developer.hashicorp.com/terraform/docs)
- [What is Terraform?](https://developer.hashicorp.com/terraform/intro)
- [Configuration Language](https://developer.hashicorp.com/terraform/language)
- [Providers](https://developer.hashicorp.com/terraform/language/providers)
- [Modules](https://developer.hashicorp.com/terraform/language/modules)
- [State](https://developer.hashicorp.com/terraform/language/state)
- [terraform init](https://developer.hashicorp.com/terraform/cli/init)
- [terraform plan](https://developer.hashicorp.com/terraform/cli/commands/plan)
- [terraform apply](https://developer.hashicorp.com/terraform/cli/commands/apply)
- [depends_on](https://developer.hashicorp.com/terraform/language/meta-arguments/depends_on)
- [Terraform Registry - Providers](https://registry.terraform.io/browse/providers)
- [Terraform Registry - Modules](https://registry.terraform.io/browse/modules)

### Module và ví dụ

- [terraform-aws-modules](https://github.com/terraform-aws-modules)
- [terraform-docs của tuan-devops](https://github.com/tuan-devops/terraform-docs)
- [terraform-aws-examples của tuan-devops](https://github.com/tuan-devops/terraform-aws-examples)
- [awesome-tf của tuan-devops](https://github.com/tuan-devops/awesome-tf)

### Quality và security

- [TFLint](https://github.com/terraform-linters/tflint)
- [Checkov](https://www.checkov.io/)
- [Trivy - Terraform misconfiguration scanning](https://trivy.dev/docs/latest/tutorials/misconfiguration/terraform/)

---

## Tóm tắt

Terraform đọc configuration khai báo trạng thái mong muốn, dùng provider để nói chuyện với API, dùng state để biết mình đang quản lý gì, tạo dependency graph và plan, rồi apply thay đổi cần thiết để hạ tầng tiến gần đến trạng thái mong muốn.
