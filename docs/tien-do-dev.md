# Tiến độ dev và điểm tiếp tục

Ngày rà hồ sơ **13/11/2026**. Đối chiếu code local tại commit infra `2f37d8d` và GitOps `9c4c148`, cùng output/ảnh người vận hành đã gửi trong chat. Lần rà này chưa gọi AWS API hoặc truy cập cluster để xác nhận trạng thái đang chạy ngày 13/11.

## Cách đọc trạng thái

- **Có code** nghĩa là file đã tồn tại trong checkout.
- **Đã nhận bằng chứng** nghĩa là người vận hành đã gửi output/ảnh phù hợp trong chat. Không suy ra mọi tài nguyên vẫn đang bật hôm nay.
- **Còn chờ** nghĩa là chưa có implementation hoặc chưa nhận được kết quả kiểm chứng tương ứng.

Các chương 01–04 tiếp tục là hướng dẫn thiết kế. Khi chúng khác implementation, đọc file code được dẫn dưới đây và tạo plan/render mới trước khi thao tác. Phần audit source app ngày 18/10 giữ ngữ cảnh lịch sử.

## Repo thực tế

| Repo | Trách nhiệm và trạng thái |
|---|---|
| [blog-infra](https://github.com/Vinh5905/blog-infra) | Terraform, Ansible, worker lifecycle và bootstrap Argo CD/CMP. Code hiện tới playbook 50. |
| [blog-gitops](https://github.com/Vinh5905/blog-gitops) | Repo public đã kết nối Argo CD. Checkout hiện chỉ có README và commit khởi tạo. |
| `blog_app_microservices` | Source ứng dụng, CI/images/migration/instrumentation cần đối chiếu trước chặng app; lần rà này chưa audit lại source. |

Tên `blogapp-infra` và `blogapp-gitops` trong tài liệu cũ là tên dự kiến. Workspace thực tế dùng `blog-infra` và `blog-gitops`.

## Đã làm và đã nhận kết quả

| Phần | Code chính | Bằng chứng đã nhận / giới hạn |
|---|---|---|
| State Terraform | `bootstrap/state/` | S3/KMS, versioning và remote state bootstrap đã apply; foundation và cluster có state riêng. |
| Network/IAM/DB | `terraform/environments/dev/foundation/` | Đã gửi output VPC, subnets, NAT, SG, IAM, RDS, ALB và API NLB private. |
| DNS/TLS/OIDC public | `foundation/api-dns.tf`, `app-certificate.tf`, `oidc*.tf` | DNS API trả IP private, issuer public qua S3 private + CloudFront, publish hai tài liệu và so khớp thành công. |
| Máy cluster | `terraform/environments/dev/cluster/` | Automation/control plane SSM Online; ASG đã được scale để kiểm thử. Số worker thay đổi theo phiên vận hành. |
| OS/runtime | [10-os-runtime.yml](../ansible/playbooks/10-os-runtime.yml) | Swap/kernel/containerd/CRI và các gói Kubernetes đã kiểm tra. |
| Init control plane | [20-control-plane.yml](../ansible/playbooks/20-control-plane.yml) | API ready, cấu hình encryption/audit đã dùng; chạy lại có guards và tái sử dụng khóa. |
| Publish OIDC | [25-oidc-documents.yml](../ansible/playbooks/25-oidc-documents.yml) | Đọc từ API trên control plane, kiểm tra rồi ghi/upload trên automation bằng role automation; URL public khớp. |
| Network/CCM | [30-network-ccm.yml](../ansible/playbooks/30-network-ccm.yml) | Calico healthy, control plane Ready, CCM có leader Lease, providerID và bỏ cloud taint. |
| Worker join | [40-worker-join.yml](../ansible/playbooks/40-worker-join.yml), [41-bootstrap-worker.yml](../ansible/playbooks/41-bootstrap-worker.yml) | Worker Ready, đúng IP/zone/providerID; gọi API NLB private. Đã thử giao tiếp Pod qua node khác. |
| Launch tự động | `cluster/worker-launch*.tf`, `cluster/ssm/` | EventBridge → SSM Automation → SendCommand trên automation → Ansible; worker đã tự join và vào InService. |
| Cảnh báo launch | `worker-launch-alerts.tf`, `worker-launch-pause.tf` | Đã nhận email lỗi; đã kiểm nhánh bootstrap exit lỗi và thử đường alarm gọi pause. Cần kiểm tra Launch có đang suspended khi mở lại môi trường. |
| Graceful termination | `worker-termination*.tf`, [45-node-termination-handler.yml](../ansible/playbooks/45-node-termination-handler.yml) | Log NTH đã nhận event, heartbeat, cordon/drain/evict probe và hoàn tất hook. |
| Workload identity | `foundation/ccm-iam.tf`, `cluster/worker-termination-iam.tf` | CCM/NTH dùng OIDC role; probe bằng default ServiceAccount nhận AccessDenied như kỳ vọng. |
| Kubelet TLS | `kubeadm-init-yml.j2`, output OpenSSL trong chat | Control plane 10.10.10.15 vượt qua CA/IP verification. Chưa có kết quả tương ứng cho worker cuối cùng. |
| Argo CD cơ bản | [50-argocd.yml](../ansible/playbooks/50-argocd.yml), [argocd-values.yml](../ansible/files/argocd-values.yml) | Render qua, cài qua; ảnh cho thấy các Pod lâu dài 1/1 Running trên worker, Service ClusterIP. Người vận hành đăng nhập UI và kết nối blog-gitops Successful. |

Redis secret-init `Completed` là Job đã kết thúc. Việc repo báo Successful xác nhận đường đọc Git; chưa chứng minh đã có Application sync hoặc deployment BlogApp.

## Giá trị cần tra lại khi mở phiên mới

| Mục | Giá trị ghi nhận |
|---|---|
| Account / region | `947856326077` / `ap-southeast-1` |
| Cluster | `blogapp-dev`, kubeadm trên EC2 |
| Pod CIDR / Service CIDR | `172.20.0.0/16` / `172.30.0.0/16` |
| Kubernetes | `v1.36.6`, package `1.36.6-1.1` |
| Runtime | containerd `2.2.1-0ubuntu1~24.04.4`, runc `1.3.4-0ubuntu1~24.04.1` |
| Ansible / collection | ansible-core `2.20.11`, amazon.aws `11.4.0` |
| Calico / CCM | `v3.33.0` / `v1.36.2` |
| Helm / Argo chart / Argo app | `v4.3.1` / `10.17.1` / `v3.6.1` |
| NTH chart / app | `0.27.6` / `v1.25.6` |
| Kube API | `api.dev.blogapp.todicode.tech:6443`, API NLB internal |
| OIDC issuer | `https://oidc.dev.blogapp.todicode.tech` |
| Worker ASG ghi nhận | `blogapp-dev-workers-a12a4633e335c7b4578d7b00af` |
| Control plane ghi nhận | `i-0d771914a601b65ce`, `10.10.10.15` |
| Automation ghi nhận | `i-0927cd65cc13302d8`; ưu tiên lấy output Terraform hiện tại |
| Worker trong ảnh cài Argo cuối | Node `ip-10-10-11-148.ap-southeast-1.compute.internal`; IP thay đổi khi ASG tạo máy khác |
| Service Argo trong ảnh | `argocd-server.argocd`, ClusterIP `172.30.144.70`; tra lại sau khi tạo lại Service |

Không đưa credentials, tfstate, saved plan, kubeconfig, private key hay JWT vào trang tiến độ.

## Các quyết định implementation quan trọng

- ASG đặt initial desired 0, max 4 và Terraform ignore desired capacity changes. Hiện scale thủ công để kiểm thử; Cluster Autoscaler vẫn chưa được cài.
- Launch hook chờ 900 giây, mặc định ABANDON. Chờ SSM Online tối đa 300 giây. Nhánh SSM readiness lỗi và bootstrap Failed có exit code lỗi xử lý ABANDON; những lỗi khác có thể dừng runbook và chờ hook hết hạn.
- Lock DynamoDB dùng instance ID + hash lifecycle token, owner AutomationExecutionId, TTL 72 giờ. TTL không phải thao tác giải phóng lock tức thời.
- Run Command chạy trên automation host, input là WorkerInstanceId. Script lấy Ansible từ full Git SHA trong `worker_bootstrap_commit`; pull main không tự thay SHA đã pin trong SSM document.
- SSM command dùng `/home/ssm-user/blogapp-ops/.venv` và checkout `/home/ssm-user/blogapp-ops/blog-infra`. User data tạo venv tại `/opt/blogapp-ops/.venv`; lần tạo automation host mới còn cần chuẩn bị đúng checkout/venv/dependencies theo Command document.
- Alarm đếm `AWS/Events MatchedEvents` của failure rule, Sum ≥ 3 trong 900 giây, evaluation periods 1. Rule bắt Failed/TimedOut; đếm event match, không khẳng định là số EC2 duy nhất.
- Alarm ALARM gọi runbook suspend tiến trình Launch. Alarm về OK không tự resume Launch.
- Termination hook 300 giây, mặc định CONTINUE. NTH poll SQS, heartbeat 30 giây tối đa 600 giây; hook hết hạn vẫn có thể cho EC2 terminate khi drain chưa xong.
- SQS chính giữ message 1 ngày, DLQ giữ 4 ngày, maxReceiveCount 5.
- Playbook 50 mặc định chỉ đọc/render trên automation host. `-e argocd_install=true` bật block kiểm worker → copy Helm/values → Helm upgrade trên control plane bằng admin.conf. Lần gọi upgrade thực hiện thao tác release, có thể tăng revision dù values giữ nguyên.
- Playbook 50 tái sử dụng Helm mà playbook 45 chuẩn bị trên automation host. Nó dùng async 1200 giây/poll 15 giây cho lệnh Helm chờ 10 phút.
- RDS hiện `backup_retention_period = 1`, private, master password do Secrets Manager quản. Chưa kiểm chứng DB/users/migration của app; giá trị retention 1 không tự chứng minh toàn bộ RDS miễn phí.
- Argo UI từng mở bằng SSM tunnel từ Mac qua control plane tới Service port 443, local port 8443. Cert mặc định tự ký; đã hướng dẫn lấy public cert qua kênh quản trị để xác minh/tin cậy. Chưa có xác nhận cuối về xử lý cảnh báo trình duyệt hoặc đổi/xóa mật khẩu khởi tạo.
- Repo GitOps được thêm bằng UI và public HTTPS. Cấu hình kết nối đang nằm trong cluster, chưa được ghi thành bootstrap manifest trong Git.

## Điểm tiếp tục

1. Hướng dẫn người học tự tạo `blog-gitops/projects/blogapp-dev.yml`. File này đã được đưa mẫu trong chat; checkout kiểm tra ngày 13/11 vẫn chỉ có README. Đọc repo trước khi yêu cầu viết lại.
2. Giải thích AppProject giới hạn sourceRepos, destination và kinds. Chọn URL thật `https://github.com/Vinh5905/blog-gitops.git`.
3. Chuẩn bị project platform/root bootstrap và cơ chế apply ban đầu, rồi Application chỉ rõ path/branch. Đảm bảo project cho phép đúng kinds mà chart render; mẫu app hiện ưu tiên Rollouts.
4. Quay lại infra cho CMP/SOPS/age và kiểm thử renderer trước khi sync secret.
5. Platform theo chương GitOps, kiểm từng child. CSI/metrics-server cần identity/TLS gates; worker serving certificate vẫn cần xác minh.
6. DB/users, migration artifacts, 5 app images theo digest, ingress và observability tiếp tục theo kế hoạch.

D7 mới xong Argo CD cơ bản và kiểm repo. Chưa đánh dấu D6 đầy đủ vì CSI/PVC/metrics-server còn chờ. Những phần lifecycle đã được làm sớm hơn thứ tự D11 trong bảng thiết kế.

## Phần chưa có bằng chứng hoàn tất

- AppProject/root Application/platform Application và lần sync GitOps đầu.
- CMP image/sidecar, age key bootstrap/restore, SOPS renderer và negative tests.
- EBS CSI, StorageClass, PVC gắn AZ đúng, Metrics Server, kubectl top.
- Traefik NodePort và đường app qua ALB, Rollouts, app Helm chart và 5 workload.
- DB bootstrap/users, migration Job, GHCR pull/image digest, app smoke.
- Prometheus/Grafana, Loki/Alloy, Tempo/OTel, HPA/Cluster Autoscaler.
- Backup/restore thử và nghiệm thu toàn bộ dev.

## Bản đồ đọc code

- Terraform nền và outputs trong `terraform/environments/dev/foundation/`.
- Compute, launch/termination, alert/pause trong `terraform/environments/dev/cluster/`.
- SSM Automation và Run Command templates trong `cluster/ssm/`.
- Playbooks `10 → 20 → 25 → 30 → 40/41 → 45 → 50` trong `ansible/playbooks/`; thứ tự tạo tài nguyên IAM/OIDC vẫn theo phụ thuộc thực tế.
- Inventory động, group_vars và host_vars/localhost trong `ansible/inventories/dev/`.
- [Runbook automation](runbooks/01-automation-host.md) và [publish OIDC](runbooks/02-oidc-public-documents.md).
- [Hình ASG launch](images/dev/asg/1.png), [alert/pause](images/dev/asg/2.png), [termination](images/dev/asg/3.png).
