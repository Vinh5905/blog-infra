# Bootstrap remote state — thực hành từng bước cho BlogApp

Ngày soạn: 18/10/2026. Bài bổ sung cho mục 4 của [01-terraform.md](01-terraform.md).

Đầu vào theo phiên làm việc hiện tại: account `947856326077`, IAM user `kevinpham`, profile đăng nhập `blogapp-dev`, region `ap-southeast-1`. Đây là thông tin cấu hình, không phải access key. Nếu thực hành ở account khác, phải thay account trong code trước khi chạy.

**Tài liệu này chưa được thực thi vào AWS.** Các block dưới là nội dung để bạn tạo file và chạy từng chặng. Bắt đầu tạo tài nguyên thật tại bước 6, sau khi xem plan. Không chạy toàn bộ bài như một script.

## 1. Hiểu bốn khái niệm trước

| Khái niệm | Hiểu trong bài này |
|---|---|
| Terraform configuration (`.tf`) | Bản mô tả tài nguyên bạn muốn có, ví dụ bucket tên gì, mã hóa thế nào |
| State | Sổ ghi nhận Terraform đang quản lý tài nguyên nào và thông tin lần gần nhất biết về chúng |
| Backend | Cách và nơi Terraform lưu sổ state |
| Bootstrap | Tạo nền tảng cần có trước khi các phần khác dùng được nó |

Ví dụ minh họa, không phải nội dung để bạn tự viết vào state:

```text
module.state_bucket.aws_s3_bucket.this[0]
    ↔ bucket thật trên AWS có tên blogapp-dev-tfstate-947856326077-ap-southeast-1
```

Terraform dùng liên hệ này để biết resource trong code tương ứng tài nguyên thật nào. Code `.tf` và state là hai thứ khác nhau. State không phải bản sao lưu database hay ổ đĩa EC2. Terraform cũng đọc AWS khi plan để kiểm tra hiện trạng; state không bảo đảm luôn phản ánh tức thời mọi thay đổi ngoài Terraform.

Theo [HashiCorp về vai trò của state](https://developer.hashicorp.com/terraform/language/state/purpose), state lưu liên hệ và metadata phục vụ quản lý tài nguyên. Không sửa JSON state bằng tay để tạo liên hệ.

### Tại sao phải đi một vòng?

Bạn muốn lưu state trên S3. Nhưng S3 bucket chưa tồn tại, và bạn lại muốn dùng Terraform tạo chính bucket đó.

```text
Lần đầu:
Code bootstrap → Terraform → tạo bucket S3 + khóa KMS trên AWS
                         └→ lưu state vào terraform.tfstate trên máy

Sau khi bucket đã có:
terraform init -migrate-state
             └→ chuyển state trên máy vào bucket S3 vừa tạo

Các lần tiếp theo:
Terraform đọc/ghi state trên S3
```

Không có vòng tạo tài nguyên vô hạn. Chỉ đổi nơi lưu state sau lần tạo đầu tiên. Migration không tạo lại bucket.

### Kết quả cần đạt

Một bucket dùng chung làm nơi chứa các state tách biệt:

```text
blogapp-dev-tfstate-947856326077-ap-southeast-1
├── bootstrap/state.tfstate  # Sổ của bucket/KMS trong bài này
├── dev/foundation.tfstate   # Sổ của network, DB... ở chặng sau
└── dev/cluster.tfstate      # Sổ của compute cluster ở chặng sau
```

Trong bài này chỉ tạo object `bootstrap/state.tfstate`. Hai object còn lại xuất hiện khi triển khai hai root tương ứng. Dấu `/` là một phần của object key; cách hiển thị giống thư mục giúp dễ tổ chức.

Khóa `.tflock` do Terraform tạo trong quá trình cần khóa state rồi xóa khi hoàn tất. Bạn không cần tạo file khóa bằng tay. S3 Versioning giữ lịch sử phiên bản object; `use_lockfile` phối hợp việc ghi state giữa các tiến trình. Hai chức năng khác nhau. Xem [S3 backend](https://developer.hashicorp.com/terraform/language/backend/s3).

## 2. Kiểm tra danh tính và công cụ

Mở terminal. Các lệnh trong bài dùng cùng cửa sổ terminal này để giữ biến môi trường.

```bash
export AWS_PROFILE=blogapp-dev
export AWS_REGION=ap-southeast-1
aws sts get-caller-identity
terraform version
```

`export` chọn profile và region cho các chương trình chạy tiếp trong terminal. STS hỏi AWS xem danh tính thực tế là ai. Kết quả cần có account `947856326077` và user `kevinpham`. Máy đã được kiểm tra có Terraform `1.16.5`; bài yêu cầu Terraform từ `1.10` đến trước `2.0` để dùng S3 lockfile.

Nếu STS lỗi do phiên đăng nhập hết hạn, cần đăng nhập lại profile trước khi tiếp tục. Nếu sai account, dừng ở đây để sửa danh tính. Không tiếp tục apply vào account khác.

Nếu terminal đang có `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` từ công việc khác, chúng có thể làm thay đổi cách công cụ chọn credential. Có thể xem **tên biến**, không in giá trị bí mật, bằng:

```bash
env | cut -d= -f1 | rg '^AWS_(ACCESS_KEY_ID|SECRET_ACCESS_KEY|SESSION_TOKEN)$'
```

Nếu các biến đó là credential cũ và bạn muốn dùng phiên `blogapp-dev`, bỏ chúng trong terminal hiện tại rồi kiểm tra STS lại:

```bash
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
aws sts get-caller-identity --profile blogapp-dev
```

### Cầu nối từ `aws login` sang Terraform

Để tránh phụ thuộc việc phiên bản SDK bên trong từng công cụ có hiểu trực tiếp `login_session` hay không, bài dùng profile thứ hai `blogapp-dev-tf`. Nó gọi AWS CLI để lấy credential tạm thời từ profile đã đăng nhập `blogapp-dev`. Hai profile vẫn là cùng một người trong cùng account.

Các lệnh sau chỉ thêm/cập nhật cấu hình local cho profile `blogapp-dev-tf`; không tạo tài nguyên AWS và không thay profile nguồn:

```bash
aws configure set credential_process 'aws configure export-credentials --profile blogapp-dev --format process' --profile blogapp-dev-tf
aws configure set region ap-southeast-1 --profile blogapp-dev-tf
aws configure set output json --profile blogapp-dev-tf
export AWS_PROFILE=blogapp-dev-tf
aws sts get-caller-identity
```

Giả định `blogapp-dev-tf` là tên profile mới, chưa được dùng cho cấu hình assume-role hay đăng nhập khác. Nếu đã có profile đó, kiểm tra trước hoặc chọn tên mới và dùng thống nhất trong bài.

Kết quả STS vẫn phải là account/user bên trên. Không chạy riêng `export-credentials` để chép kết quả vào chat hoặc file `.tf`: nó xuất credential thật. Khi dùng `credential_process`, công cụ nhận dữ liệu qua tiến trình thay vì bạn tự chép. Đây là [cách chia sẻ login credential được AWS hướng dẫn](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sign-in.html).

Đăng nhập được không đồng nghĩa có quyền tạo bucket/KMS. Bài giả định user đã được cấp quyền bootstrap phù hợp. Quyền dùng state sau khi bucket có cũng khác quyền tạo/quản lý bucket và KMS. Nếu bị `AccessDenied`, ghi lại thao tác bị từ chối để sửa quyền; không tự gắn quyền Administrator chỉ để vượt qua lỗi.

## 3. Chuẩn bị thư mục và ignore

Chọn thư mục `blogapp-infra` bạn sẽ dùng lâu dài. Nếu đã tạo ở mục D1 trước đó, mở đúng thư mục ấy; không tạo một bản khác chỉ để chạy bài này. Nếu chưa có, ví dụ đặt bên trong workspace Devops:

```bash
mkdir -p /Users/hoangvinh/Documents/ChatGPT/Devops/blogapp-infra/bootstrap/state
cd /Users/hoangvinh/Documents/ChatGPT/Devops/blogapp-infra
```

`mkdir -p` tạo cả thư mục cha còn thiếu. `cd` đổi thư mục làm việc của terminal.

Tạo hoặc bổ sung `.gitignore` ở gốc `blogapp-infra` bằng editor, giữ các nội dung ignore đã có:

```gitignore
.terraform/
*.tfstate
*.tfstate.*
*.tfplan
backend.hcl
state-backups/
crash.log
.env
.env.*
*.tfvars
!*.tfvars.example
```

`.terraform/` chứa module/provider tải về và metadata backend. `*.tfstate` là sổ tài nguyên có thể chứa dữ liệu nhạy cảm. Saved plan cũng cần bảo vệ. **Giữ `.terraform.lock.hcl` để commit**, vì file này khóa provider version và checksum; nó khác file khóa state trên S3.

Sau đó:

```bash
cd bootstrap/state
pwd
```

`pwd` phải chỉ tới thư mục `blogapp-infra/bootstrap/state` bạn đã chọn. Từ đây đến hết bài, mọi lệnh Terraform chạy trong thư mục này.

Ban đầu tạo đúng ba file:

```text
bootstrap/state/
├── versions.tf
├── main.tf
└── outputs.tf
```

**Chưa tạo `backend.tf`.** Nếu khai báo backend S3 ngay bây giờ, Terraform sẽ tìm bucket chưa tồn tại.

## 4. Viết code bootstrap

Các khối HCL bên dưới là **nội dung file**, không phải lệnh dán trực tiếp vào terminal. Mở editor và lưu theo đúng tên. Terraform đọc chung tất cả file `.tf` trong thư mục; tên file giúp người đọc tổ chức nội dung, không quyết định thứ tự tạo.

### File `versions.tf`

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
  region              = "ap-southeast-1"
  allowed_account_ids = ["947856326077"]

  default_tags {
    tags = {
      Project     = "blogapp"
      Environment = "dev"
      ManagedBy   = "terraform"
      Component   = "state-backend"
    }
  }
}
```

`required_version` kiểm tra Terraform CLI. `required_providers` chỉ định plugin AWS và phạm vi version cho phép; `terraform init` sẽ chọn và khóa version thực tế trong lockfile. `provider` cấu hình nơi gọi AWS. `allowed_account_ids` chặn thao tác khi credential trỏ nhầm account. Credential đi từ profile trong môi trường, không đặt access key trong code.

### File `main.tf`

```hcl
locals {
  state_bucket_name = "blogapp-dev-tfstate-947856326077-ap-southeast-1"
}

resource "aws_kms_key" "state" {
  description             = "Encrypt BlogApp dev Terraform state"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "state" {
  name          = "alias/blogapp-dev-tfstate"
  target_key_id = aws_kms_key.state.key_id
}

module "state_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "5.17.0"

  bucket                = local.state_bucket_name
  expected_bucket_owner = "947856326077"
  force_destroy         = false

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  control_object_ownership = true
  object_ownership         = "BucketOwnerEnforced"

  attach_deny_insecure_transport_policy = true

  versioning = {
    enabled = true
  }

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

Giải thích từng phần:

| Code | Tác dụng |
|---|---|
| `locals` | Đặt tên dùng lại trong cùng root, không phải biến môi trường terminal |
| `aws_kms_key.state` | Khóa mã hóa do account bạn quản lý; không phải access key để đăng nhập |
| `enable_key_rotation` | Bật rotation tự động cho vật liệu khóa |
| `prevent_destroy` | Terraform từ chối plan xóa/thay thế khóa khi cấu hình bảo vệ này còn tồn tại |
| `aws_kms_alias.state` | Tên dễ nhớ trỏ tới khóa KMS |
| `module.state_bucket` | Gọi module để tạo bucket và các cấu hình liên quan |
| `version = "5.17.0"` | Khóa version module; `.terraform.lock.hcl` không khóa module Registry |
| `force_destroy = false` | Không tự vét object để xóa bucket; bucket đang trống vẫn có thể bị xóa |
| Bốn cờ public access | Chặn các đường public hóa qua ACL/policy |
| `BucketOwnerEnforced` | Tắt ACL để quản lý quyền qua policy |
| `attach_deny_insecure_transport_policy` | Thêm bucket policy từ chối request không dùng HTTPS |
| `versioning` | Giữ phiên bản cũ khi object state bị ghi đè |
| `aws:kms` | Mã hóa object bằng khóa KMS được tham chiếu |
| `bucket_key_enabled` | Sử dụng S3 Bucket Key để giảm các request KMS cho workload phù hợp |

Module phụ thuộc khóa KMS vì tham chiếu `aws_kms_key.state.arn`. Terraform suy ra phụ thuộc này; bạn không cần tự chạy “tạo KMS” trước bằng CLI.

Bài không đặt custom KMS key policy: dùng default khi tạo qua API, cho phép account ủy quyền qua IAM. Nó **không tự cấp quyền dùng khóa cho mọi IAM user**. Principal chạy bài cần có quyền IAM phù hợp. Xem [default key policy của KMS](https://docs.aws.amazon.com/kms/latest/developerguide/key-policy-default.html).

`prevent_destroy` không ngăn admin xóa khóa qua Console/API, và không bảo vệ nếu bạn bỏ cả resource block. Nó là một lớp phòng lỗi của Terraform. Root bootstrap tách khỏi root cluster để việc tháo cluster không kéo theo backend.

### File `outputs.tf`

```hcl
output "state_bucket_name" {
  value = module.state_bucket.s3_bucket_id
}

output "kms_key_arn" {
  value = aws_kms_key.state.arn
}

output "bootstrap_backend_config" {
  value = <<-EOT
    bucket               = "${module.state_bucket.s3_bucket_id}"
    key                  = "bootstrap/state.tfstate"
    region               = "ap-southeast-1"
    allowed_account_ids  = ["947856326077"]
    expected_bucket_owner = "947856326077"
    encrypt              = true
    kms_key_id           = "${aws_kms_key.state.arn}"
    use_lockfile         = true
  EOT
}
```

Outputs giúp lấy tên bucket, ARN khóa và sinh nội dung backend sau khi tạo tài nguyên. Đây là thông tin định danh, không phải vật liệu khóa KMS. Block output chưa tạo file `backend.hcl`; bước 8 mới dùng nó.

### Chi phí trước khi chạy

Theo [bảng giá KMS](https://aws.amazon.com/kms/pricing/) đã đối chiếu ngày 18/10/2026, một customer managed key có phí lưu trữ **1 USD/tháng**, tính theo giờ; rotation có thể làm tăng phí sau các lần rotation tính phí. S3 tính lưu trữ, request và các chiều sử dụng liên quan theo [bảng giá S3](https://aws.amazon.com/s3/pricing/); version cũ cũng chiếm dung lượng. Không coi bước này miễn phí chỉ vì state nhỏ. Credit/ưu đãi thực tế tùy account.

Thiết kế bài giữ KMS như tài liệu gốc. Nếu muốn dùng SSE-S3 để bỏ khóa KMS riêng cho bài lab, cần đổi đồng bộ phần bucket và backend; không chỉ xóa khóa khỏi code sau khi đã dùng nó mã hóa state.

## 5. Init, format, validate và plan

```bash
terraform init
terraform fmt
terraform validate
terraform plan -out=bootstrap.tfplan
```

| Lệnh | Làm gì | Kết quả cần thấy |
|---|---|---|
| `init` | Tải module/provider, khởi tạo local backend mặc định | Khởi tạo thành công; chưa tạo bucket trên AWS |
| `fmt` | Căn lại định dạng code | Có thể in tên file được format |
| `validate` | Kiểm cấu hình theo schema | `Success! The configuration is valid.` |
| `plan -out=...` | Đọc thông tin cần thiết từ AWS, lập dự kiến thay đổi và lưu kế hoạch | Có các tài nguyên bootstrap sẽ được tạo |

`validate` không chứng minh user đủ quyền trên AWS. `plan` thành công cũng không chứng minh mọi API tạo/cập nhật sẽ được cho phép khi apply.

Xem kỹ plan: phải là bucket, cấu hình bucket, khóa KMS và alias đã mô tả. Module tạo nhiều resource nên tổng số không nhất thiết chỉ là hai. Nếu thấy xóa/thay thế tài nguyên đang có hoặc tài nguyên ngoài phạm vi bài, dừng để đối chiếu. Trên lần đầu với state mới, không nên có thay đổi xóa tài nguyên.

`bootstrap.tfplan` là file kế hoạch, không phải state. Không commit hoặc chia sẻ file này. Nếu sửa code sau khi plan, tạo plan mới và review lại.

## 6. Apply — điểm bắt đầu tạo tài nguyên thật

**Lệnh sau tạo tài nguyên trên AWS và bắt đầu có các chi phí nêu trên.** Chỉ chạy sau khi danh tính và plan đã đúng:

```bash
terraform apply bootstrap.tfplan
```

Vì đã chỉ định saved plan, Terraform **không hỏi gõ `yes` lần nữa**. Hành động chạy lệnh này là chấp nhận thực hiện kế hoạch bạn đã review.

Sau khi hoàn tất:

```bash
terraform state list
terraform output state_bucket_name
terraform output kms_key_arn
ls -l terraform.tfstate
```

`state list` hiển thị địa chỉ tài nguyên Terraform đang quản lý, không phải quét tất cả tài nguyên trong account. `output` lấy giá trị từ state. `terraform.tfstate` lúc này nằm trong thư mục hiện tại: đó chính là **local state** của bước tạo đầu tiên.

Nếu apply lỗi giữa chừng, có thể một số tài nguyên đã được tạo. Giữ nguyên thư mục/state, đọc lỗi và lập plan lại sau khi sửa nguyên nhân. Không xóa state để “làm lại từ đầu”.

## 7. Kiểm tra bucket trước khi chuyển state

```bash
aws s3api get-bucket-versioning \
  --bucket blogapp-dev-tfstate-947856326077-ap-southeast-1 \
  --expected-bucket-owner 947856326077

aws s3api get-public-access-block \
  --bucket blogapp-dev-tfstate-947856326077-ap-southeast-1 \
  --expected-bucket-owner 947856326077

aws s3api get-bucket-encryption \
  --bucket blogapp-dev-tfstate-947856326077-ap-southeast-1 \
  --expected-bucket-owner 947856326077
```

Cần thấy Versioning `Enabled`, bốn cờ public access đều `true`, và mã hóa mặc định `aws:kms` trỏ đúng khóa. Các lệnh này chỉ đọc cấu hình bucket. `--expected-bucket-owner` giúp từ chối request nếu bucket không thuộc account mong đợi.

## 8. Chuẩn bị backend S3 và bản dự phòng

Trước hết sinh `backend.hcl` từ outputs khi Terraform vẫn đang dùng local backend:

```bash
terraform output -raw bootstrap_backend_config > backend.hcl
cat backend.hcl
```

`-raw` bỏ lớp biểu diễn string của Terraform. Dấu `>` ghi nội dung output vào file. Kiểm tra bucket, key, region, account và KMS ARN đúng. File này không chứa credential, nhưng bài vẫn ignore vì là cấu hình theo account.

Tạo bản dự phòng local trước migration:

```bash
umask 077
mkdir -p state-backups
cp -p terraform.tfstate "state-backups/pre-migration-$(date +%Y%m%d-%H%M%S).tfstate"
chmod 700 state-backups
chmod 600 terraform.tfstate state-backups/*.tfstate
```

`umask` giới hạn quyền của file mới; `chmod` giới hạn truy cập bản state đã có. Đây là bản dự phòng local cần giữ trong nơi lưu trữ được bảo vệ, không phải file để gửi chat hay commit. Quyền file không thay thế mã hóa ổ đĩa/backup bảo mật. Nếu chạy lại, tên theo thời gian giúp không ghi đè bản dự phòng cũ.

Bây giờ tạo file thứ tư `backend.tf`:

```hcl
terraform {
  backend "s3" {}
}
```

Block này chọn loại backend. Các giá trị cụ thể được truyền từ `backend.hcl` khi init. Cấu hình backend được xử lý trước khi provider/resource hoạt động nên không thể viết `bucket = module.state_bucket.s3_bucket_id` hoặc `kms_key_id = aws_kms_key.state.arn` trong backend block. Đó là lý do ta lấy outputs ra file trước.

## 9. Chuyển state từ máy lên S3

```bash
terraform init -migrate-state -backend-config=backend.hcl
```

`-backend-config` đọc thông tin nơi lưu. `-migrate-state` yêu cầu Terraform chuyển state đang có sang backend mới. Terraform sẽ hỏi có sao chép state hiện tại sang backend mới không. Kiểm tra đó là chuyển từ local sang đúng bucket/key của bài rồi nhập `yes`.

Nếu Terraform báo state đích đã tồn tại và có xung đột, dừng để đối chiếu; không đồng ý ghi đè theo thói quen. Không dùng `-force-copy` để bỏ qua câu hỏi. Không thay bằng `-reconfigure`: cờ đó không thực hiện việc chuyển state cũ giúp bạn. Xem [tài liệu `terraform init`](https://developer.hashicorp.com/terraform/cli/commands/init).

Sau migration thành công, remote state đang chứa cả thông tin bucket và KMS dùng để lưu nó. Các tài nguyên không bị tạo lại và không bị di chuyển region.

## 10. Nghiệm thu sau migration

```bash
terraform state list
terraform plan
```

Danh sách tài nguyên phải còn đầy đủ. Plan dự kiến `No changes` nếu code và AWS không thay đổi. Một mình `No changes` chưa chứng minh đang dùng S3; kiểm thêm object trên AWS:

```bash
aws s3api head-object \
  --bucket blogapp-dev-tfstate-947856326077-ap-southeast-1 \
  --key bootstrap/state.tfstate \
  --expected-bucket-owner 947856326077 \
  --query '{VersionId:VersionId,Encryption:ServerSideEncryption,KmsKey:SSEKMSKeyId,Size:ContentLength}'

aws s3api list-object-versions \
  --bucket blogapp-dev-tfstate-947856326077-ap-southeast-1 \
  --prefix bootstrap/state.tfstate \
  --expected-bucket-owner 947856326077 \
  --query 'Versions[].{Key:Key,VersionId:VersionId,Latest:IsLatest}'
```

Cần thấy object `bootstrap/state.tfstate`, mã hóa `aws:kms`, đúng ARN khóa, và VersionId. Một version đầu tiên là bình thường: không cần tạo thay đổi giả để có nhiều version. Các lệnh chỉ hiển thị metadata, không in nội dung state.

File `.tflock` có thể không còn khi bạn kiểm tra vì Terraform đã nhả khóa. Điều đó bình thường. Các bản state local cũ sau migration là bản dự phòng/lịch sử; không tiếp tục dùng chúng để ghi quản lý song song. Giữ chúng trong nơi bảo vệ cho đến khi hoàn tất xác minh và áp dụng chính sách lưu giữ backup của bạn.

## 11. Quyền backend và quyền tạo tài nguyên khác nhau thế nào?

| Nhóm quyền | Mục đích |
|---|---|
| Bootstrap | Tạo/quản lý bucket, versioning, cấu hình public access, policy bucket, encryption, khóa KMS và alias |
| Backend thông thường | List bucket, đọc/ghi state object, đọc/ghi/xóa lockfile và dùng khóa KMS tương ứng |
| Triển khai foundation/cluster | Tạo network, EC2, RDS, IAM... theo root thực tế; backend access không tự cấp các quyền này |

Theo [HashiCorp S3 backend](https://developer.hashicorp.com/terraform/language/backend/s3), state cần `s3:GetObject`, `s3:PutObject`; lockfile cần thêm `s3:DeleteObject` trên chính object `.tflock`; dùng KMS cần `kms:Encrypt`, `kms:Decrypt`, `kms:GenerateDataKey` trên đúng khóa. Không cần quyền xóa state object cho luồng backend thông thường. List bucket áp dụng ở ARN bucket, quyền object áp dụng ở ARN object.

Bài này **chưa tạo policy/role IAM backend mới và chưa gắn thêm quyền cho user**. Nó dùng quyền bootstrap đã có của `kevinpham`. Trước khi giao cho người khác hoặc CI, cần tạo/cấp policy riêng theo đúng bucket/key/KMS; không phát credential của user cho pipeline. Thiết kế IAM backend trong mục 4 tài liệu gốc vì thế là phần còn phải triển khai khi tách principal/CI, không được đánh dấu đã hoàn thành chỉ nhờ tạo bucket.

## 12. Từ đây sang foundation/cluster

Ở đây **root là một thư mục cấu hình Terraform chạy độc lập**, không phải AWS root user. Bạn tạo thư mục/file cấu hình trên máy; Terraform sẽ ghi state vào S3. Không tự tạo file JSON state hoặc “thư mục dev” trong S3 Console.

### 12.1 Tạo hai thư mục trên máy

Mở terminal ở **gốc repo `blogapp-infra`** bạn đã dùng trong bài, không phải bên trong `bootstrap/state`. Chạy `pwd` để kiểm tra, rồi:

```bash
mkdir -p terraform/environments/dev/foundation
mkdir -p terraform/environments/dev/cluster
```

Các đường dẫn trong lệnh này tính từ thư mục hiện tại. Kết quả cần có:

```text
blogapp-infra/
├── bootstrap/
│   └── state/
│       ├── versions.tf
│       ├── main.tf
│       ├── outputs.tf
│       ├── backend.tf
│       └── backend.hcl
└── terraform/
    └── environments/
        └── dev/
            ├── foundation/
            │   ├── backend.tf
            │   └── backend.hcl
            └── cluster/
                ├── backend.tf
                └── backend.hcl
```

### 12.2 Tạo `backend.tf` trong từng thư mục mới

Dùng editor tạo `terraform/environments/dev/foundation/backend.tf` và `terraform/environments/dev/cluster/backend.tf`. Nội dung hai file giống nhau:

```hcl
terraform {
  backend "s3" {}
}
```

Đây là khai báo “root này dùng backend S3”. Nó chưa nói cụ thể bucket nào và state key nào.

### 12.3 Copy cấu hình backend rồi đổi đúng key

Vẫn đứng ở gốc repo `blogapp-infra`, nếu hai file đích **chưa tồn tại**, copy file cấu hình đã dùng thành công cho bootstrap:

```bash
cp -i bootstrap/state/backend.hcl terraform/environments/dev/foundation/backend.hcl
cp -i bootstrap/state/backend.hcl terraform/environments/dev/cluster/backend.hcl
```

`cp -i` sẽ hỏi nếu file đích đã tồn tại. Nếu hỏi, dừng để xem nội dung file đích trước khi quyết định ghi đè.

Mở file của **foundation**, đổi dòng `key` thành:

```hcl
key = "dev/foundation.tfstate"
```

Mở file của **cluster**, đổi dòng `key` thành:

```hcl
key = "dev/cluster.tfstate"
```

Giữ các dòng bucket, region, account, KMS ARN, `encrypt` và `use_lockfile` theo cấu hình bootstrap đã nghiệm thu. Không thay key trong `bootstrap/state/backend.hcl`.

Chỉ copy **cấu hình `backend.hcl`**. Code tạo bucket/KMS (`main.tf` của bootstrap), state, saved plan và `.terraform/` thuộc root bootstrap; không copy chúng sang root mới. Foundation và cluster sẽ có code resource riêng ở các chương tiếp theo.

### 12.4 Hiểu ba key và khi nào init

Mỗi root dùng cùng bucket/KMS, khác `key`:

| Root | Key |
|---|---|
| `bootstrap/state` | `bootstrap/state.tfstate` |
| `terraform/environments/dev/foundation` | `dev/foundation.tfstate` |
| `terraform/environments/dev/cluster` | `dev/cluster.tfstate` |

Không dùng một key cho cả ba root: chúng sẽ tranh quản lý cùng một state. Với foundation hoàn toàn mới chưa có local state, init bình thường với backend config tương ứng; không lấy state bootstrap chuyển tiếp vào foundation.

Khi bắt đầu chương foundation, từ gốc repo có thể init root đó bằng:

```bash
terraform -chdir=terraform/environments/dev/foundation init -backend-config=backend.hcl
```

`-chdir` yêu cầu Terraform làm việc trong thư mục foundation. `backend.hcl` được tìm trong thư mục đó. Giữ `AWS_PROFILE=blogapp-dev-tf` trong terminal theo bước 2. Root mới chưa có state cần chuyển nên không thêm `-migrate-state`.

Sau này tới chương cluster mới init tương tự:

```bash
terraform -chdir=terraform/environments/dev/cluster init -backend-config=backend.hcl
```

`init` kết nối/cấu hình backend, không tạo VPC hay EC2. Chỉ có `backend.tf` và `backend.hcl` thì root vẫn chưa mô tả tài nguyên hạ tầng nào. Không chạy plan/apply với kỳ vọng sẽ có network/cluster cho đến khi viết code của chặng tương ứng. Object state trên S3 được Terraform tạo/cập nhật khi ghi state, nên không yêu cầu nó xuất hiện ngay chỉ sau init.

Các file source `.tf` và `.terraform.lock.hcl` là thứ lưu trong Git. S3 giữ state; máy vẫn giữ source code và credential/session local. Remote state không thay thế Git.

## 13. Một số lỗi hay gặp

| Hiện tượng | Kiểm tra / xử lý |
|---|---|
| `No valid credential sources found` | Profile của terminal, phiên login còn hiệu lực, profile cầu nối và đường dẫn lệnh `aws` trong PATH |
| `AccessDenied` lúc tạo bucket/KMS hoặc cấu hình bucket | User có quyền bootstrap cho đúng API/resource không; giữ state nếu đã tạo được một phần |
| STS được nhưng migration lỗi S3/KMS | Quyền đọc/ghi state, lockfile và dùng khóa; key policy cũng tham gia quyết định quyền |
| `BucketAlreadyExists` | Tên bucket trong global namespace đã được dùng; chọn tên khác trong `locals`, plan lại trước apply |
| Bucket đã có sẵn do lần apply trước | Giữ state cũ và kiểm tra trước; không xóa state hoặc tạo một root mới trỏ cùng tài nguyên |
| `NoSuchBucket` trong lần init đầu | Đã khai báo S3 backend quá sớm; trong bài mới chưa có state đích, chỉ thêm `backend.tf` sau khi apply local thành công |
| Migration hỏi ghi đè state đích | Dừng để so sánh state nguồn/đích và kiểm tra bucket/key |
| Plan muốn xóa KMS/bucket | Kiểm tra đúng root, source và state; không bỏ bảo vệ hoặc bật `force_destroy` để làm lệnh chạy qua |

Khi cần hỗ trợ, gửi thông báo lỗi đã bỏ credential/secret và tên bước đang làm; không gửi nội dung state, saved plan hay login cache.

## 14. Điểm dừng của bài

- Đúng account và danh tính đã xác minh bằng STS.
- Bucket/KMS và cấu hình bảo vệ đã tạo thành công.
- State bootstrap đã chuyển lên đúng S3 key, có version và mã hóa KMS.
- `state list` vẫn đầy đủ và plan sau migration không có thay đổi ngoài dự kiến.
- State/plan/backup không nằm trong Git.
- Chưa provision network/EC2/RDS; đó là chặng foundation/cluster sau.

Không cần chạy `terraform destroy` sau bài: backend là nền để giữ state cho các chặng tiếp theo.

### Phạm vi kiểm tra tài liệu

Đã trích code ví dụ vào thư mục tạm, kiểm `terraform fmt -check`, tải module `s3-bucket` đúng version `5.17.0` và AWS provider `6.69.1` bằng `init -backend=false`, sau đó `terraform validate` thành công với block backend S3. Các block shell đã qua `bash -n`; code fences và liên kết file nội bộ đã được kiểm tra. Không chạy `plan`, `apply` hoặc migration vào account thật; chưa xác minh quyền thực tế của `kevinpham` và chưa nghiệm thu tài nguyên AWS.
