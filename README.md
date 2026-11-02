# blog-infra

Repository hạ tầng AWS và bootstrap Kubernetes cho BlogApp, hướng tới môi trường dev dùng **kubeadm trên EC2**.

Hiện trạng ngày **02/11/2026**: repo đã có bộ tài liệu thiết kế và bài thực hành trong `docs/`; chưa có implementation Terraform/Ansible ở gốc repo. Việc nhập tài liệu không xác nhận tài nguyên AWS hay cluster đang hoạt động.

## Tài liệu và thứ tự đọc

1. [Lộ trình tổng thể và cách chia repo](docs/README.md).
2. [Terraform và module Registry](docs/01-terraform.md).
3. [Ansible, kubeadm và worker ASG](docs/02-ansible-kubeadm.md).
4. [GitOps, Argo CD, migration và observability](docs/03-gitops-dev.md).
5. [Nghiệm thu, rollback, backup và vận hành](docs/04-nghiem-thu-va-van-hanh.md).

Các tài liệu bổ trợ và code mẫu được giữ cùng trong `docs/`: [Terraform cho người mới](docs/terraform-cho-nguoi-moi.md), [bootstrap remote state từng bước](docs/01a-bootstrap-remote-state-tung-buoc.md), [foundation network từng bước](docs/01b-foundation-network-tung-buoc.md), [code mẫu network](docs/examples/foundation-network/README.md) và [bài lab AWS Console](docs/05-thuc-hanh-thu-cong-aws-console.md).

## Ranh giới ba repo

| Repo | Trách nhiệm |
|---|---|
| `blog_app_microservices` | Mã ứng dụng, CI, build/scan/sign image và xuất release candidate. |
| `blog-infra` — repo này | Terraform tạo tài nguyên AWS; Ansible quản OS, containerd, kubeadm, Calico/CCM; bootstrap Argo CD/CMP và worker lifecycle. |
| `blogapp-gitops` — repo dự kiến theo thiết kế | Helm charts/values, image digest được chọn, secret SOPS, platform Applications, dashboards và alerts do Argo CD đồng bộ. |

Tài liệu gốc dùng tên dự kiến `blogapp-infra`; trong workspace hiện tại, tên đó tương ứng với **repo `blog-infra` này**. Các đường dẫn checkout cũ trong bài thực hành cần đổi sang checkout hiện tại trước khi dùng lệnh. Những đoạn nói “chưa tạo repo” ghi lại trạng thái khi biên soạn, không phải yêu cầu tạo thêm một repo infra.

## Quy trình triển khai dự kiến

1. **D0–D1:** chốt account/profile, domain, budget và versions; bootstrap S3/KMS remote state, versioning và locking. Bootstrap, foundation và cluster có state key riêng.
2. **D2–D3:** Terraform tạo VPC/subnets, IAM, buckets, RDS, ALB public, NLB API private, automation host, control plane và worker ASG khởi đầu bằng 0. Foundation và cluster là hai root/state riêng; foundation không phụ thuộc ngược cluster.
3. **D4–D6:** Ansible chạy từ automation host qua SSM, cấu hình OS/runtime, kubeadm init, Calico/CCM và workload identity. Hoàn thiện launch workflow trước khi tăng ASG lên hai worker; kiểm DNS, topology, storage và kubelet TLS/resource metrics theo các cổng bootstrap/GitOps.
4. **D7–D9:** bootstrap Argo CD/CMP; GitOps cài platform. Chuẩn bị DB/users và config/secrets trước, chạy migration Jobs rồi triển khai đủ năm workload bằng digest: frontend, gateway, auth, post và comment.
5. **D10–D12:** thử blue-green/promote/abort/revert, metrics/logs/traces, HPA → Cluster Autoscaler → ASG tự join/drain, backup và restore; lưu evidence rồi mới nghiệm thu dev hoàn chỉnh.

Đường request dự kiến: Internet → ALB HTTPS → Traefik NodePort → frontend hoặc gateway `/api` → business services → RDS MySQL với ba database logic. Quản trị cluster đi qua SSM/automation host và NLB private.

## Các điểm cần giữ khi hiện thực

- Mỗi tài nguyên có một chủ quản rõ ràng giữa Terraform, Ansible, Argo CD, Rollouts, HPA và Cluster Autoscaler.
- Năm app image được chọn từ CI candidate đáng tin cậy bằng digest. Migration chạy bằng artifact/Job riêng; runtime tắt Flyway startup và không dùng DB master/DDL credentials.
- Workload identity trên kubeadm cần triển khai riêng; không mặc định có sẵn tính năng identity của EKS.
- Tài liệu ghi nhận các việc cần làm trong source: migration images, metrics gateway/quyền scrape và tracing instrumentation. Cần đối chiếu source hiện tại trước khi triển khai.
- Code trong `docs/examples/` và `docs/manual-aws/` là tài liệu thực hành. Lab Console dùng worker cố định và CIDR riêng; không trộn cấu hình của lab với lộ trình Terraform/ASG đầy đủ.

## Nguồn tài liệu

Nhập từ `/Users/hoangvinh/Documents/ChatGPT/Devops/blogapp-dev` và tài liệu Terraform bổ trợ ngày 02/11/2026. Các ghi nhận source, versions và kiểm thử trong tài liệu là lịch sử biên soạn; cần kiểm tra lại ở chặng implementation. Bản gốc tại thư mục Devops vẫn được giữ nguyên.
