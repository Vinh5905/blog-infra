# Foundation — dựng network cho BlogApp dev từng bước

Ngày đối chiếu: **18/10/2026**. Bài triển khai chi tiết mục **5. D2 — Network với module VPC** trong [01-terraform.md](01-terraform.md), nối tiếp [bài bootstrap remote state](01a-bootstrap-remote-state-tung-buoc.md).

**Bài này có code mẫu đầy đủ cho phần network, chưa được apply vào AWS.** Bạn sẽ copy code vào root foundation thật, kiểm tra danh tính/AZ/backend, review plan rồi mới quyết định chạy apply. Code tải sẵn ở [examples/foundation-network](examples/foundation-network/README.md); nội dung từng file cũng được trình bày dưới đây.

## 1. Foundation nằm ở đâu trong lộ trình?

```text
bootstrap/state
  └─ Tạo chỗ lưu state: S3 + KMS             ← Bài trước

terraform/environments/dev/foundation
  ├─ VPC, subnet, route, NAT, DB subnet group ← Bài này
  ├─ Security groups riêng                  ← Tiếp mục 5.1
  ├─ IAM, buckets phụ trợ, ALB/NLB, RDS      ← Các mục D2 tiếp theo
  └─ Outputs cho cluster

terraform/environments/dev/cluster
  └─ EC2 automation/control plane, worker ASG ← Sau foundation
```

Foundation là phần nền tảng tương đối ổn định của môi trường. Network là một phần trong foundation; hoàn tất bài này chưa có toàn bộ foundation và chưa có Kubernetes. Các phần D2 tiếp theo được thêm vào **cùng root và cùng state foundation**, không tạo root mới cho từng file.

## 2. Hiểu những thứ sắp tạo

| Thành phần | Hiểu đơn giản | Dùng ở đâu trong BlogApp |
|---|---|---|
| Region | Khu vực AWS | Singapore, mã `ap-southeast-1` |
| Availability Zone, viết tắt AZ | Một vùng hạ tầng độc lập trong region | Chọn hai AZ để bố trí subnet |
| VPC | Không gian mạng riêng của môi trường | Dải IPv4 `10.10.0.0/16` |
| Subnet | Một phần dải IP của VPC, nằm trong một AZ | Public, private node, database |
| Route table | Bảng chọn đường đi theo địa chỉ đích | Gửi ra Internet qua IGW/NAT hoặc đi nội bộ |
| Internet Gateway, IGW | Kết nối VPC với Internet | Đường Internet của public subnet |
| NAT Gateway | Cho máy private khởi tạo kết nối ra ngoài bằng địa chỉ được dịch | Node tải package/image và gọi AWS API |
| Elastic IP, EIP | Địa chỉ IPv4 public được cấp phát | Gắn với public NAT Gateway |
| DB subnet group | Danh sách subnet đủ điều kiện để RDS sử dụng sau này | Hai subnet database, chưa tạo database instance |
| Security group, SG | Các rule cho phép traffic gắn với tài nguyên/network interface được hỗ trợ | SG riêng được viết ở bước tiếp theo |

Nguồn: [routing của VPC](https://docs.aws.amazon.com/vpc/latest/userguide/VPC_Route_Tables.html), [NAT Gateway](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-nat-gateway.html), [security groups](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-security-groups.html).

### 2.1 Vì sao có hai AZ và sáu subnet?

Giả sử bạn đã xác minh chọn được `ap-southeast-1a` và `ap-southeast-1b`:

| Nhóm | AZ đầu tiên | AZ thứ hai | Tài nguyên dự kiến ở các bài sau |
|---|---|---|---|
| Public | `10.10.0.0/24` | `10.10.1.0/24` | ALB; NAT chỉ ở public subnet đầu tiên |
| Private | `10.10.10.0/24` | `10.10.11.0/24` | Automation host, control plane và worker |
| Database | `10.10.20.0/24` | `10.10.21.0/24` | Subnet group cho RDS |

Một subnet nằm trong một AZ. Các phần tử có cùng chỉ số tương ứng nhau: `azs[0]` đi với `public_subnets[0]`, `private_subnets[0]`, `database_subnets[0]`. Không đảo thứ tự danh sách AZ sau triển khai mà không review kỹ plan, vì subnet có thể phải thay thế.

Hai subnet database không đồng nghĩa RDS tự thành Multi-AZ. Bài sau vẫn cấu hình RDS dev Single-AZ theo thiết kế đã chọn.

### 2.2 `/16` và `/24` là gì?

Đây là ký hiệu CIDR cho dải địa chỉ IP:

- `10.10.0.0/16`: toàn dải từ `10.10.0.0` đến `10.10.255.255`.
- `10.10.10.0/24`: dải nhỏ hơn, từ `10.10.10.0` đến `10.10.10.255`, nằm trong VPC trên.
- Với IPv4 `/24` thông thường của AWS, có 256 địa chỉ, trong đó AWS giữ lại 5 địa chỉ; còn 251 địa chỉ có thể cấp phát.

Các subnet phải nằm trong VPC và không chồng lấn nhau. Trước apply, kiểm tra `10.10.0.0/16` không chồng lấn mạng LAN/VPN hoặc VPC sẽ kết nối sau này. Pod CIDR `172.20.0.0/16` và Service CIDR `172.30.0.0/16` thuộc thiết kế Kubernetes ở bài sau, không tạo thành subnet VPC trong bài này. Xem [quy tắc subnet IPv4 của AWS](https://docs.aws.amazon.com/vpc/latest/userguide/subnet-sizing.html).

### 2.3 Public/private khác nhau ở đường đi

Sau khi apply, các route table được gắn với subnet sẽ có:

| Loại subnet | Đường nội bộ | Đường mặc định `0.0.0.0/0` |
|---|---|---|
| Public | `10.10.0.0/16 → local` | `→ Internet Gateway` |
| Private node | `10.10.0.0/16 → local` | `→ NAT Gateway` |
| Database | `10.10.0.0/16 → local` | Không có |

`local` cho phép định tuyến trong VPC. `0.0.0.0/0` là đường cho các đích IPv4 khi không có route cụ thể hơn phù hợp. Route table **không thay thế firewall**: các lớp SG/NACL và cấu hình dịch vụ vẫn quyết định traffic được phép.

Vì vậy database subnet vẫn có đường nội bộ tới subnet node. “Không có đường Internet mặc định” không có nghĩa “không ai trong VPC truy cập được database”. SG của RDS ở bước sau sẽ giới hạn nguồn và port.

Public subnet cũng không tự làm mọi EC2 trong đó truy cập được từ Internet: còn cần địa chỉ public phù hợp và rule bảo mật. Bài chủ động đặt `map_public_ip_on_launch = false` để không tự cấp public IP cho EC2. ALB public và NAT public ở bài này/bài sau có cơ chế cấp địa chỉ của dịch vụ tương ứng.

### 2.4 Traffic sau khi có node sẽ đi như nào?

```text
Worker private → route 0.0.0.0/0 → NAT trong public subnet đầu tiên
                                      → Internet Gateway → GHCR/package repos

Worker private → route local → RDS private
                               (còn cần SG và xác thực database)

Internet → ALB public → worker private
           (ALB và SG được cấu hình ở bài sau)
```

NAT phục vụ kết nối do phía private khởi tạo; không mở cổng để Internet tự kết nối vào worker. Không gắn SG trực tiếp cho NAT Gateway; SG được gắn cho tài nguyên được hỗ trợ như EC2/ALB. Xem [đặc điểm NAT Gateway](https://docs.aws.amazon.com/vpc/latest/userguide/nat-gateway-basics.html).

## 3. Chi phí và giới hạn của lựa chọn dev

**Phần bắt đầu có chi phí đáng chú ý của bài này là NAT Gateway và địa chỉ IPv4 public của nó.** NAT tính phí theo giờ được provision/available và dung lượng xử lý; public IPv4 cũng có phí theo thời gian cấp phát/sử dụng theo bảng giá hiện hành. NAT còn có thể phát sinh phí truyền dữ liệu giữa các AZ. Tắt EC2 hoặc đóng terminal không dừng phí NAT.

Đối chiếu [bảng giá VPC: NAT và public IPv4](https://aws.amazon.com/vpc/pricing/) với region **Singapore** trước apply; không lấy giá Ohio trong ví dụ trên trang giá làm giá Singapore. Bài không khẳng định account có đủ credit hay các chi phí này được miễn.

`single_nat_gateway = true` giữ **một NAT theo AZ** trong public subnet đầu tiên, không tạo regional NAT hoặc một NAT mỗi AZ. Cả hai private subnet dùng chung NAT này. Đây là lựa chọn dev trong thiết kế: nếu AZ đặt NAT mất khả dụng, node ở AZ khác cũng mất đường Internet qua NAT; đường nội bộ VPC là vấn đề riêng. Xem [hướng dẫn NAT và AZ](https://docs.aws.amazon.com/vpc/latest/userguide/nat-gateway-basics.html).

Không đổi sang hai NAT chỉ để đạt số AZ bằng nhau khi chưa chấp nhận chi phí; cũng không tắt NAT rồi kỳ vọng node vẫn tải được GHCR/package từ Internet. Thiết kế egress khác phải được làm riêng. Budget/cảnh báo là bước cần có từ D0, và cảnh báo budget không tự động dừng tài nguyên.

## 4. Xác minh điều kiện đầu vào

### 4.1 Danh tính

Bài dùng profile cầu nối đã tạo ở bài bootstrap, vẫn lấy credential từ phiên `blogapp-dev` của `kevinpham`:

```bash
export AWS_PROFILE=blogapp-dev-tf
export AWS_REGION=ap-southeast-1
aws sts get-caller-identity
```

Phải là account `947856326077`, đúng danh tính bạn đã xác nhận. Nếu chưa có profile cầu nối, làm phần `credential_process` trong [bước 2 bài bootstrap](01a-bootstrap-remote-state-tung-buoc.md#2-kiểm-tra-danh-tính-và-công-cụ). Nếu đang dùng một profile Terraform khác đã kiểm chứng thì có thể dùng profile đó, miễn STS trả đúng account/danh tính.

Credential là quyền đăng nhập; IAM policy quyết định được gọi API nào. Bài chưa xác minh quyền thật của user. Ngoài quyền backend S3/KMS, bạn cần quyền tạo/quản lý các tài nguyên VPC và DB subnet group của module. `DescribeAvailabilityZones` thành công không chứng minh có quyền `CreateVpc` hay tạo NAT/RDS subnet group.

### 4.2 Lấy hai AZ từ account thật

Lệnh chỉ đọc, không tạo tài nguyên:

```bash
aws ec2 describe-availability-zones \
  --region ap-southeast-1 \
  --filters Name=state,Values=available Name=zone-type,Values=availability-zone \
  --query 'AvailabilityZones[].{Name:ZoneName,ID:ZoneId,State:State}' \
  --output table
```

Chọn hai `Name` có trong kết quả, rồi ghi cố định vào `dev.tfvars`. Ví dụ `ap-southeast-1a` và `ap-southeast-1b` dưới đây **là giá trị cần đối chiếu**, chưa phải kết quả truy vấn account của bạn trong lần soạn bài. AZ name có thể ánh xạ tới AZ vật lý khác nhau giữa các account; trong bài một account này dùng tên trả về của chính account đó.

### 4.3 Backend bootstrap đã hoạt động

Trước khi làm foundation, bootstrap phải đã có state remote ở `bootstrap/state.tfstate`. Bạn không cần chạy lại apply bootstrap chỉ để bắt đầu foundation. Giữ nguyên thư mục bootstrap và bucket/KMS đã nghiệm thu.

Nếu còn state local trong root foundation từ một lần thực hành khác, đừng áp dụng luồng “root hoàn toàn mới” bên dưới: cần đối chiếu state trước để quyết định migration/import phù hợp.

## 5. Tạo/mở đúng root foundation

Từ **gốc repo `blogapp-infra`** bạn đã dùng:

```bash
mkdir -p terraform/environments/dev/foundation
cd terraform/environments/dev/foundation
pwd
```

Đường dẫn cuối phải kết thúc bằng `blogapp-infra/terraform/environments/dev/foundation`. Không tạo folder `foundation` bên trong `bootstrap/state`. Từ bước này, lệnh Terraform trong bài chạy **ngay tại foundation**, trừ khi ghi rõ đứng ở gốc repo.

Cấu trúc hoàn chỉnh cho bài:

```text
foundation/
├── backend.tf       # Loại backend: S3
├── backend.hcl      # Bucket/KMS từ bootstrap; key riêng foundation
├── versions.tf      # Terraform/provider và cấu hình AWS
├── variables.tf     # Khai báo đầu vào
├── az-checks.tf     # Đối chiếu AZ với AWS khi plan
├── dev.tfvars       # Giá trị hai AZ đã chọn
├── network.tf       # Module VPC và cấu hình mạng
└── outputs.tf       # Xuất ID/subnet mapping để dùng sau
```

Đây đều là file trực tiếp trong cùng thư mục; Terraform đọc các file `.tf` cùng nhau, không chạy theo thứ tự tên file. File `.tfvars` chứa giá trị cho biến đã khai báo; `backend.hcl` là cấu hình backend, không truyền bằng `-var-file`.

Bạn có thể tạo từng file bằng editor theo mục 6, hoặc copy các file `.tf` từ [thư mục code mẫu](examples/foundation-network/README.md) vào root thật. Nếu `backend.tf` đã tồn tại từ bài trước và giống nội dung dưới thì giữ nguyên. Nếu root đã có module/resource, so sánh và ghép code trước; không thêm module `vpc` thứ hai hoặc chép đè code đang dùng.

`.gitignore` ở gốc repo cần có `.terraform/`, `*.tfstate`, `*.tfstate.*`, `*.tfplan`, `*.tfvars`, `!*.tfvars.example`, `backend.hcl`; **không ignore `.terraform.lock.hcl`**. Không copy state, `.terraform/` hoặc code tạo bucket/KMS của bootstrap vào foundation.

## 6. Nội dung từng file và cách hiểu

### 6.1 `backend.tf`

<!-- example:backend.tf -->
```hcl
terraform {
  backend "s3" {}
}
```

Khai báo root này dùng S3. Bucket/key/KMS cụ thể được đọc từ `backend.hcl` lúc init. Foundation dùng bucket/KMS đã có; không tạo lại chúng trong `network.tf`.

### 6.2 `backend.hcl`

Nếu đã chuẩn bị ở mục 12 bài bootstrap, kiểm tra file hiện có. Giá trị cần giữ là bucket và ARN KMS **thật từ bootstrap**; key phải là:

```hcl
key = "dev/foundation.tfstate"
```

Nếu chưa có file, đứng ở gốc repo `blogapp-infra` và chỉ copy khi file đích chưa tồn tại:

```bash
cp -i bootstrap/state/backend.hcl terraform/environments/dev/foundation/backend.hcl
```

Sau đó dùng editor sửa key trong file foundation thành `dev/foundation.tfstate`. Giữ key bootstrap như cũ. `cp -i` hỏi khi đích tồn tại: kiểm tra trước khi ghi đè.

Quay lại thư mục foundation trước khi chạy các lệnh tiếp theo. Đối chiếu nội dung với bảng:

| Trường | Giá trị |
|---|---|
| `bucket` | Tên bucket đã tạo ở bootstrap |
| `key` | `dev/foundation.tfstate` |
| `region` | `ap-southeast-1` |
| `allowed_account_ids` | `["947856326077"]` |
| `expected_bucket_owner` | `947856326077` dưới dạng string |
| `encrypt` | `true` |
| `kms_key_id` | ARN thật của khóa bootstrap |
| `use_lockfile` | `true` |

Không viết placeholder `<key-id>` vào file thực tế. Không copy `bootstrap/state.tfstate` thành `foundation.tfstate` và không tự upload state rỗng lên S3. Hai root quản lý hai nhóm tài nguyên khác nhau.

### 6.3 `versions.tf`

<!-- example:versions.tf -->
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
      Component   = "foundation"
    }
  }
}
```

- `required_version` kiểm Terraform CLI; phạm vi ở đây hỗ trợ S3 lockfile.
- `required_providers` chọn plugin gọi API AWS; `init` tạo lockfile cho version/checksum thực tế.
- `region = var.aws_region` đọc biến định nghĩa ở file tiếp theo.
- `allowed_account_ids` chặn dùng nhầm account, kể cả khi terminal chọn sai profile.
- `default_tags` gắn thông tin project/environment lên tài nguyên được provider hỗ trợ. `Component = foundation` khác component backend của bài bootstrap.
- Không hardcode `profile` để cùng source có thể dùng credential của operator hoặc CI về sau; hiện tại lấy từ `AWS_PROFILE` của terminal.

### 6.4 `variables.tf`

<!-- example:variables.tf -->
```hcl
variable "aws_account_id" {
  description = "AWS account allowed to host BlogApp dev."
  type        = string
  default     = "947856326077"

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "aws_account_id must contain exactly 12 digits."
  }
}

variable "aws_region" {
  description = "AWS Region for BlogApp dev."
  type        = string
  default     = "ap-southeast-1"

  validation {
    condition     = var.aws_region == "ap-southeast-1"
    error_message = "This tutorial is configured for ap-southeast-1."
  }
}

variable "availability_zones" {
  description = "Two available standard AZ names, in stable subnet order."
  type        = list(string)

  validation {
    condition = (
      length(var.availability_zones) == 2 &&
      length(distinct(var.availability_zones)) == 2
    )
    error_message = "Choose exactly two distinct Availability Zones."
  }
}
```

`variable` là khai báo đầu vào, không tạo tài nguyên AWS. `default` giúp không phải gõ lại account và region trong mọi lệnh. Với account khác, phải đổi cấu hình nhất quán cả backend và provider; không chỉ đổi một chỗ.

`availability_zones` không có default: bạn phải chọn rõ hai AZ trong `dev.tfvars`. `validation` từ chối danh sách thiếu/thừa AZ hoặc lặp cùng một AZ. Region bị giới hạn Singapore trong bài để tránh giữ CIDR/config backend Singapore nhưng vô tình triển khai region khác.

### 6.5 `az-checks.tf`

<!-- example:az-checks.tf -->
```hcl
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
      error_message = "A selected AZ is not available in this account/Region."
    }
  }
}
```

`data` đọc thông tin AWS, không tạo AZ. Bộ lọc lấy standard AZ đang available. `postcondition` so sánh hai AZ bạn chọn với danh sách thật và làm plan thất bại nếu có AZ không hợp lệ. `validate` kiểm schema nhưng không thay thế bước đọc dữ liệu live này.

### 6.6 `dev.tfvars`

Tạo file này từ `dev.tfvars.example`, sau khi đối chiếu kết quả bước 4.2:

<!-- example:dev.tfvars.example -->
```hcl
# Confirm these two AZ names with describe-availability-zones before use.
availability_zones = ["ap-southeast-1a", "ap-southeast-1b"]
```

`dev.tfvars` không phải tên Terraform tự động nạp, nên các lệnh plan trong bài luôn có `-var-file=dev.tfvars`. Đừng đổi thứ tự AZ tùy tiện sau khi đã tạo subnet.

### 6.7 `network.tf`

<!-- example:network.tf -->
```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.3"

  name = "blogapp-dev"
  cidr = "10.10.0.0/16"

  azs              = var.availability_zones
  public_subnets   = ["10.10.0.0/24", "10.10.1.0/24"]
  private_subnets  = ["10.10.10.0/24", "10.10.11.0/24"]
  database_subnets = ["10.10.20.0/24", "10.10.21.0/24"]

  enable_dns_support   = true
  enable_dns_hostnames = true
  enable_ipv6          = false

  create_igw              = true
  map_public_ip_on_launch = false

  enable_nat_gateway     = true
  single_nat_gateway     = true
  one_nat_gateway_per_az = false

  create_database_subnet_group           = true
  create_database_subnet_route_table     = true
  create_database_internet_gateway_route = false
  create_database_nat_gateway_route      = false

  manage_default_vpc             = false
  manage_default_route_table     = false
  manage_default_network_acl     = false
  manage_default_security_group  = true
  default_security_group_ingress = []
  default_security_group_egress  = []

  tags = {
    "kubernetes.io/cluster/blogapp-dev" = "owned"
  }

  depends_on = [data.aws_availability_zones.available]
}
```

Đây là phần mô tả tài nguyên chính:

| Cấu hình | Ý nghĩa / kết quả |
|---|---|
| `source`, `version` | Dùng module VPC Registry, khóa đúng `6.7.3` |
| `name` | Tên/tag để nhận diện network BlogApp dev |
| `cidr` | Dải IP của VPC; phải không chồng lấn mạng cần kết nối |
| `azs` và ba danh sách subnet | Mỗi nhóm có hai subnet, gắn theo thứ tự AZ |
| Hai cờ DNS | Bật DNS resolver và khả năng DNS hostname của VPC theo cấu hình AWS |
| `enable_ipv6 = false` | Bài này triển khai IPv4, không có route IPv6 đi Internet |
| `create_igw` | Tạo và gắn Internet Gateway cho VPC mới |
| `map_public_ip_on_launch = false` | Không tự cấp public IPv4 cho EC2 khi launch trong public subnet |
| Ba cờ NAT | Tạo đúng một NAT dùng chung, không một NAT mỗi AZ |
| `create_database_subnet_group` | Tạo nhóm subnet cho RDS sử dụng sau này |
| `create_database_subnet_route_table` | Gắn database subnet vào route table riêng, tránh dùng route NAT của node |
| Hai cờ route database `false` | Không thêm default route IGW/NAT cho database |
| `manage_default_vpc = false` | Không nhận quản lý default VPC của account |
| Default route table/NACL `false` | Không nhận quản lý hai đối tượng mặc định đó; module vẫn tạo route tables/associations riêng cho các subnet của bài |
| `manage_default_security_group = true` và hai danh sách rỗng | Quản lý default SG **của VPC mới** và bỏ các rule ingress/egress mặc định |
| Cluster tag | Metadata của thiết kế cluster; không tự cài controller hoặc tạo Kubernetes |
| `depends_on` | Chờ data source kiểm AZ, thay vì bỏ qua kết quả guard đó khi tạo module |

Module là một nhóm resource nên plan có nhiều dòng hơn số khối module bạn viết. Có cả route, association, EIP và cấu hình liên quan, không chỉ một VPC resource. Xem source đúng version [VPC module 6.7.3](https://github.com/terraform-aws-modules/terraform-aws-vpc/tree/v6.7.3).

NACL mặc định của VPC mới giữ cấu hình AWS mặc định. Bài chưa thiết kế NACL hạn chế riêng; các SG workload sẽ làm ở mục 5.1 tiếp theo. Default SG rỗng không có nghĩa chặn tuyệt đối mọi gói tin đặc biệt của AWS, và không chứng minh firewall cho workload đã hoàn chỉnh. Không gắn EC2 vào default SG này rồi kỳ vọng tải package được.

### 6.8 `outputs.tf`

<!-- example:outputs.tf -->
```hcl
output "vpc_id" {
  value = module.vpc.vpc_id
}

output "vpc_cidr_block" {
  value = module.vpc.vpc_cidr_block
}

output "availability_zones" {
  value = var.availability_zones
}

output "public_subnet_ids" {
  value = module.vpc.public_subnets
}

output "private_subnet_ids" {
  value = module.vpc.private_subnets
}

output "database_subnet_ids" {
  value = module.vpc.database_subnets
}

output "database_subnet_group_name" {
  value = module.vpc.database_subnet_group_name
}

output "subnets_by_az" {
  value = {
    for index, az in var.availability_zones : az => {
      public_subnet_id   = module.vpc.public_subnets[index]
      private_subnet_id  = module.vpc.private_subnets[index]
      database_subnet_id = module.vpc.database_subnets[index]
    }
  }
}

output "internet_gateway_id" {
  value = module.vpc.igw_id
}

output "nat_gateway_ids" {
  value = module.vpc.natgw_ids
}

output "nat_public_ips" {
  value = module.vpc.nat_public_ips
}

output "route_table_ids" {
  value = {
    public   = module.vpc.public_route_table_ids
    private  = module.vpc.private_route_table_ids
    database = module.vpc.database_route_table_ids
  }
}

output "default_security_group_id" {
  value = module.vpc.default_security_group_id
}
```

Outputs là các giá trị Terraform xuất sau khi có tài nguyên. Chúng không cấp quyền AWS và không tự tạo file input cho cluster.

`subnets_by_az` tạo bản đồ dễ đọc: mỗi AZ có ba subnet ID tương ứng. Chỉ số trong ba danh sách khớp `availability_zones`. Việc giữ mapping rõ giúp sau này chọn subnet của control plane/ASG và kiểm AZ của volume EBS.

`database_subnet_group_name` là tên nhóm subnet, không phải database endpoint. `nat_public_ips` là IP NAT, không phải public IP của node. Các outputs chưa có SG, ALB/NLB, DB endpoint hay instance profile vì các tài nguyên đó chưa được tạo trong bài.

## 7. Init — dùng backend foundation ngay từ đầu

Đứng trong `terraform/environments/dev/foundation`, giữ đúng profile của bước 4:

```bash
terraform init -backend-config=backend.hcl
terraform fmt
terraform validate
```

Foundation hoàn toàn mới dùng S3 backend ngay vì bucket đã tồn tại từ bootstrap; không cần apply local rồi migration lần thứ hai. Nếu bạn đã init foundation trước đó với đúng backend, chạy lại init bình thường là được. Nếu Terraform báo đổi backend/đã có state, đối chiếu nguyên nhân trước; không tự thêm `-migrate-state` hoặc `-reconfigure` cho qua lỗi.

`init` tải module/provider và cấu hình backend; chưa tạo VPC/NAT. `fmt` định dạng code, `validate` kiểm schema. Giữ `.terraform.lock.hcl` để commit. Không chạy `init -upgrade` mặc định trong các lần triển khai bình thường.

Nếu code trước đó dùng provider version thấp hơn phạm vi yêu cầu của bài, xử lý nâng version có chủ đích và review lockfile; không xóa lockfile chỉ để mất thông báo lỗi.

## 8. Plan — đọc kỹ trước khi tạo network

```bash
terraform plan -var-file=dev.tfvars -out=foundation-network.tfplan
```

Plan đọc state remote và thông tin AWS, chạy guard AZ và tính thay đổi. Nó chưa tạo network. `-out` lưu kế hoạch đã xem để apply đúng kế hoạch đó. File plan cần bảo vệ và không commit.

Với một root foundation mới, dự kiến có:

- Một VPC `10.10.0.0/16`, DNS support/hostnames bật.
- Sáu subnet ở đúng hai AZ, mỗi nhóm public/private/database có hai subnet.
- Một Internet Gateway.
- Một **zonal public NAT Gateway** đặt ở public subnet đầu tiên và một Elastic IP đi kèm.
- Route tables, routes và subnet associations phù hợp bảng ở mục 2.3.
- Một DB subnet group gồm hai database subnet.
- Default SG của VPC mới được nhận quản lý và đóng rule thông thường.

Chưa có EC2, ASG, ALB/NLB, RDS instance, IAM role hoặc bucket/KMS mới. Trong plan có `aws_db_subnet_group` là bình thường; nó không phải `aws_db_instance`. Resource default SG dùng để quản lý đối tượng AWS sinh sẵn trong VPC mới, nên đọc cả phần thay đổi rule của nó.

Kiểm số NAT/EIP và tên/CIDR/AZ thực tế trong plan. Không cố khớp một con số tổng resource cứng, vì tổng bao gồm các cấu hình phụ của module. Nếu root đã có tài nguyên từ trước, phạm vi plan phải được đọc theo hiện trạng đó; không áp tiêu chí “chỉ add” một cách máy móc. Nếu đây là lần đầu mà plan lại muốn xóa/thay bucket/KMS bootstrap hoặc tài nguyên ngoài network, dừng để kiểm tra đúng thư mục và key state.

Nếu sửa code/tfvars sau khi review, lập plan mới. Nếu session hết hạn hoặc AWS đã thay đổi đáng kể, xác thực lại và lập plan mới thay vì cố dùng một plan cũ.

## 9. Apply — tạo tài nguyên thật và bắt đầu tính phí NAT/EIP

Sau khi plan và chi phí đã đúng mong muốn:

```bash
terraform apply foundation-network.tfplan
```

**Lệnh apply saved plan này chạy ngay, không hỏi `yes` thêm lần nữa.** NAT có thể cần thời gian tạo; giữ nguyên state và đọc lỗi nếu thất bại. Không xóa state để chạy lại nếu một phần tài nguyên đã được tạo. Sửa nguyên nhân, plan lại trong cùng root rồi mới tiếp tục.

Apply thành công chưa chứng minh worker ra Internet được, vì bài chưa có worker. Bước tiếp theo kiểm cấu hình network đã tạo.

## 10. Nghiệm thu cấu hình sau apply

### 10.1 Terraform outputs và plan lần nữa

```bash
terraform state list
terraform output
terraform output subnets_by_az
terraform plan -var-file=dev.tfvars
```

Danh sách state phải là tài nguyên network ở root foundation. Outputs phải có ID thật; plan dự kiến `No changes` nếu không có thay đổi ngoài dự kiến. State của foundation ở S3 key `dev/foundation.tfstate`, còn bootstrap vẫn ở key cũ.

### 10.2 Kiểm tra VPC và subnet bằng AWS CLI

Các lệnh dưới chỉ đọc. Đứng trong root foundation để lấy output:

```bash
BLOGAPP_VPC_ID=$(terraform output -raw vpc_id)

aws ec2 describe-vpcs \
  --vpc-ids "$BLOGAPP_VPC_ID" \
  --query 'Vpcs[].{ID:VpcId,CIDR:CidrBlock,State:State,Default:IsDefault}' \
  --output table

aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$BLOGAPP_VPC_ID" \
  --query 'Subnets[].{ID:SubnetId,AZ:AvailabilityZone,CIDR:CidrBlock,AutoPublicIP:MapPublicIpOnLaunch}' \
  --output table
```

Cần thấy VPC mới không phải default, CIDR đúng, sáu subnet đúng bảng và auto public IP là false. Biến `BLOGAPP_VPC_ID` chỉ giữ ID VPC để đỡ chép tay, không phải credential.

Kiểm DNS:

```bash
aws ec2 describe-vpc-attribute --vpc-id "$BLOGAPP_VPC_ID" --attribute enableDnsSupport
aws ec2 describe-vpc-attribute --vpc-id "$BLOGAPP_VPC_ID" --attribute enableDnsHostnames
```

Cả hai giá trị cần là `true`.

### 10.3 Kiểm tra NAT và route table

```bash
aws ec2 describe-nat-gateways \
  --filter "Name=vpc-id,Values=$BLOGAPP_VPC_ID" \
  --query 'NatGateways[].{ID:NatGatewayId,State:State,Subnet:SubnetId,Type:ConnectivityType,PublicIPs:NatGatewayAddresses[].PublicIp}'

aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$BLOGAPP_VPC_ID" \
  --query 'RouteTables[].{ID:RouteTableId,Associations:Associations[].{Subnet:SubnetId,Main:Main},Routes:Routes[].{Destination:DestinationCidrBlock,Gateway:GatewayId,NAT:NatGatewayId,State:State}}'
```

Cần có một NAT của bài ở trạng thái `available`, loại `public`, thuộc subnet public đầu tiên và có địa chỉ public. Nếu trước đó từng tạo/xóa NAT trong cùng VPC, kết quả có thể còn bản ghi `deleted`; đếm gateway đang active của cấu hình hiện tại.

Đối chiếu `terraform output route_table_ids` và `subnets_by_az` với associations/routes. Với module `6.7.3` và cấu hình single NAT ở bài này, hai public subnet dùng chung một public route table, hai private subnet dùng chung một private route table, hai database subnet dùng chung một database route table. AWS còn có main route table của VPC; không nhầm nó với route table custom đã gắn cho subnet.

Kiểm cụ thể:

1. Public có default route tới `igw-...`.
2. Private có default route tới đúng `nat-...`.
3. Database có local route và **không có** default route tới IGW/NAT.
4. Mỗi subnet được associate với đúng nhóm route table; chỉ nhìn thấy route table tồn tại là chưa đủ.

### 10.4 Kiểm DB subnet group và default SG

```bash
BLOGAPP_DB_SUBNET_GROUP=$(terraform output -raw database_subnet_group_name)
aws rds describe-db-subnet-groups \
  --db-subnet-group-name "$BLOGAPP_DB_SUBNET_GROUP" \
  --query 'DBSubnetGroups[].{Name:DBSubnetGroupName,VPC:VpcId,Subnets:Subnets[].{ID:SubnetIdentifier,AZ:SubnetAvailabilityZone.Name}}'

BLOGAPP_DEFAULT_SG_ID=$(terraform output -raw default_security_group_id)
aws ec2 describe-security-groups \
  --group-ids "$BLOGAPP_DEFAULT_SG_ID" \
  --query 'SecurityGroups[].{ID:GroupId,Ingress:IpPermissions,Egress:IpPermissionsEgress}'
```

DB subnet group phải nằm trong VPC mới, chứa đúng hai subnet database thuộc hai AZ. Default SG phải có `Ingress: []`, `Egress: []` theo code. SG riêng cho workload chưa có ở bước này.

### 10.5 Kiểm state foundation tồn tại trên S3

Nếu giữ tên bucket theo bài bootstrap:

```bash
aws s3api head-object \
  --bucket blogapp-dev-tfstate-947856326077-ap-southeast-1 \
  --key dev/foundation.tfstate \
  --expected-bucket-owner 947856326077 \
  --query '{VersionId:VersionId,Encryption:ServerSideEncryption,KmsKey:SSEKMSKeyId}'
```

Nếu bạn đã chọn tên bucket khác, dùng tên thật trong `backend.hcl`. Kiểm có VersionId và mã hóa KMS đúng bootstrap. Không tải/in nội dung state để chứng minh đã có file.

## 11. Khi gặp lỗi

| Hiện tượng | Điều cần kiểm tra |
|---|---|
| Terraform hỏi nhập `availability_zones` | Quên `-var-file=dev.tfvars`, sai thư mục hoặc file chưa có giá trị |
| AZ postcondition thất bại | Chọn lại từ `describe-availability-zones` trong đúng account/region |
| `No valid credential sources found` | Profile của terminal, phiên đăng nhập và `credential_process` ở bài trước |
| Lỗi S3/KMS lúc init | Bucket/key/KMS ARN của backend và quyền dùng state, không phải cấu hình NAT |
| `AccessDenied` lúc tạo VPC/NAT/DB subnet group | User thiếu quyền cho API tương ứng; giữ state và xử lý quyền, không xóa state |
| `AddressLimitExceeded` | Quota EIP hoặc EIP đã cấp phát; xem quota và tài nguyên account, không tự xóa EIP của hệ thống khác |
| NAT tạo lỗi hoặc không available | Đọc failure code/message, subnet public, IGW, EIP và quota liên quan |
| DB subnet có default route NAT | Kiểm cả cờ route table riêng, cờ NAT/IGW database và associations, không chỉ tên subnet |
| Plan muốn tạo lại bucket/KMS bootstrap | Có thể đang ở nhầm root hoặc dùng nhầm key/source; dừng để đối chiếu |
| Chưa có EC2 để thử curl | Bình thường: bài này mới kiểm cấu hình; kiểm traffic thực hiện khi có automation/node |

Thông tin cần gửi khi hỏi lỗi: tên bước, thông báo lỗi đã bỏ secret và các ID liên quan cần thiết. Không gửi login cache, credential, state hay saved plan.

## 12. Điểm dừng và phần kế tiếp

Hoàn tất bài khi đã xác minh cấu hình network, NAT available, các route/associations đúng, state foundation riêng và plan sau apply không có thay đổi ngoài dự kiến. Đây là nghiệm thu cấu hình; chưa phải kiểm chứng traffic node/ALB/DB hoạt động.

Tiếp **mục 5.1 — Security groups**, vẫn viết file mới trong cùng thư mục foundation. Lúc đó thiết kế rule theo nguồn/đích cho ALB, API NLB, control plane, worker, automation và database; không mở SSH hoặc Kubernetes API ra Internet để thử cho nhanh. Sau SG mới tiếp IAM, load balancers và RDS theo các mục D2 còn lại.

Không init/apply cluster ở bước này. Cũng không chạy destroy foundation như thao tác “kết thúc bài”: NAT/EIP cần kế hoạch thời gian sử dụng để kiểm chi phí, nhưng network sẽ là dependency của những bài tiếp theo. Nếu cần dọn lab, lập và review destroy plan ở đúng root foundation sau khi kiểm tất cả tài nguyên hiện được root đó quản lý; root bootstrap riêng vẫn giữ backend.

## 13. Nguồn và phạm vi xác minh

Các nguồn trực tiếp được đối chiếu gồm source [VPC module `6.7.3`](https://github.com/terraform-aws-modules/terraform-aws-vpc/tree/v6.7.3), [AWS VPC routing](https://docs.aws.amazon.com/vpc/latest/userguide/VPC_Route_Tables.html), [NAT](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-nat-gateway.html), [NAT theo AZ](https://docs.aws.amazon.com/vpc/latest/userguide/nat-gateway-basics.html), [subnet sizing](https://docs.aws.amazon.com/vpc/latest/userguide/subnet-sizing.html), [SG](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-security-groups.html), [giá VPC](https://aws.amazon.com/vpc/pricing/) và [HashiCorp S3 backend](https://developer.hashicorp.com/terraform/language/backend/s3).

Đã tải module VPC `6.7.3` và AWS provider `6.69.1` vào thư mục tạm bằng `terraform init -backend=false`, sau đó `terraform validate` thành công với Terraform `1.16.5`. Các file code mẫu đã qua `terraform fmt -check`; code nhúng trong bài khớp file mẫu; các block shell đã qua `bash -n`; code fences và liên kết file nội bộ đã được kiểm tra.

Chưa chạy plan/apply, chưa kết nối backend foundation thật, chưa xác minh AZ/quyền/quota của account hoặc kiểm traffic runtime. Những kiểm tra live đó là các bước bạn thực hiện theo bài, không phải kết quả đã có từ lần soạn tài liệu.
