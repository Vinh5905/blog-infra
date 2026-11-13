# Chuẩn bị automation host

Áp dụng cho EC2 automation Ubuntu 24.04 amd64 ở `ap-southeast-1`. Máy cần hiện `Online` trong Systems Manager.

Cập nhật hồ sơ 13/11/2026. Terraform hiện truyền `scripts/bootstrap-automation.sh` vào user data để cài AWS CLI, Session Manager plugin, `unzip`, `python3-venv` và tạo venv `/opt/blogapp-ops/.venv` cho máy tạo mới. Phiên máy đã kiểm chứng trong chat vẫn chạy repo và venv tại `/home/ssm-user/blogapp-ops/`; SSM Command bootstrap worker cũng đang trỏ cố định tới đó. Với máy mới, cần chuẩn bị checkout, venv và dependency ở đường dẫn mà Command document dùng trước khi bật ASG. User data hiện chưa tự clone repo hoặc cài các dependency Ansible.

Các lệnh cài thủ công dưới đây dành cho máy cần bổ sung công cụ. Kiểm tra `aws --version`, `session-manager-plugin --version` và đường dẫn venv trước khi chạy lại.

## Mở phiên SSM từ Mac

Chạy trong root `terraform/environments/dev/cluster`:

```bash
aws ssm start-session \
  --target "$(terraform output -raw automation_instance_id)" \
  --region ap-southeast-1
```

Các lệnh còn lại chạy trong shell trên **automation host**.

## Cài gói hệ thống và AWS CLI

```bash
sudo apt-get update &&
sudo apt-get install -y unzip python3-venv
```

`unzip` dùng để giải nén bộ cài AWS CLI. `python3-venv` dùng để tạo môi trường Python cho Ansible. APT trên máy này có thể dùng kho HTTP nhờ rule outbound TCP 80 của security group automation.

```bash
install_dir="$(mktemp -d)"
curl -fsSL https://awscli.amazonaws.com/v2/install.sh \
  -o "$install_dir/install-aws-cli.sh" &&
sudo bash "$install_dir/install-aws-cli.sh" --system
aws --version
```

## Cài Session Manager plugin

```bash
install_dir="$(mktemp -d)"
curl -fsSL \
  https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb \
  -o "$install_dir/session-manager-plugin.deb" &&
sudo dpkg -i "$install_dir/session-manager-plugin.deb"
session-manager-plugin --version
```

Plugin trên automation host phục vụ các phiên SSM mà Ansible mở tới node. Bộ cài CLI và plugin ở trên lấy phiên bản AWS đang phát hành tại thời điểm chạy. Hai lệnh `--version` giúp ghi nhận bản đã cài.

## Kiểm tra role AWS

```bash
aws sts get-caller-identity --region ap-southeast-1 --query Arn --output text
```

ARN dự kiến chứa `assumed-role/blogapp-dev-automation/`. AWS CLI lấy credentials tạm thời qua instance profile của EC2.

## Tạo và kích hoạt virtualenv

```bash
mkdir -p "$HOME/blogapp-ops"
cd "$HOME/blogapp-ops"
python3 -m venv .venv
. .venv/bin/activate
python --version
python -m pip --version
```

Virtualenv giữ các gói Python của Ansible riêng với Python hệ thống. Đường dẫn pip cần nằm dưới `blogapp-ops/.venv/`.

Mỗi khi mở **phiên SSM mới**, kích hoạt lại môi trường trong cùng tài khoản Linux:

```bash
cd "$HOME/blogapp-ops"
. .venv/bin/activate
```

Bước tiếp theo là cài các dependency Ansible đã pin theo [chương Ansible và kubeadm](../02-ansible-kubeadm.md#31-chuẩn-bị-dependency-pythoncollection).
