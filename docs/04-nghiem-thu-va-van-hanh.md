# Nghiệm thu dev, xử lý lỗi và vận hành

Chương này là checklist thực hành sau khi implementation và deploy. **Tất cả ô nghiệm thu hiện để trống** vì chưa chạy AWS/Kubernetes trong lần soạn tài liệu. Lệnh tác động tới workload như promote, revert, drain hay teardown chỉ dùng ở bài tập/chặng tương ứng.

## 1. Ghi evidence thế nào?

Mỗi chặng có một bản ghi: thời gian, account/region/cluster, source/infra/GitOps SHA, versions, lệnh thực chạy, kết quả kỳ vọng/thực tế và kết luận. Tách evidence public đã redact với tài liệu private. Không lưu tfstate, plan chứa secret, kubeconfig, decrypted values, password, JWT hay age key trong Git.

Ví dụ mẫu ghi chép:

```text
Milestone: D9 app runtime
Time: <ISO-8601>
Account / Region / Cluster: <dev> / ap-southeast-1 / blogapp-dev
Infra commit: <sha>
GitOps commit / release: <sha> / <id>
Application source / CI run: <sha> / <url>
Command: BLOG_URL=https://<dev-domain> sh scripts/smoke-test.sh
Expected: signup/login/post/comment, malformed JWT=401, cross-user delete=403
Actual: <output redacted + status>
Result: PASS hoặc FAIL, không ghi PASS nếu chưa chạy
```

CI scan/test histories trong source changelog là dữ liệu nền; không tự thay bằng chứng deployment trên AWS.

## 2. D9 — Kiểm tra đường request xuyên suốt

### 2.1 Kiểm từng lớp

```bash
kubectl get nodes -o wide
kubectl -n blogapp-dev get pods,services,ingresses
kubectl -n blogapp-dev get rollouts
kubectl -n blogapp-dev get jobs
kubectl -n blogapp-dev get events --sort-by=.lastTimestamp
```

Node Ready chứng minh node agent/network ở mức cơ bản. Pod Ready chứng minh probes pass. Ingress/TG healthy chứng minh route ở các lớp tương ứng. Chỉ smoke/E2E mới kiểm chức năng đầy đủ.

Kiểm TLS và frontend từ máy ngoài VPC:

```bash
curl --fail --silent --show-error --head 'https://<dev-hostname>/'
```

Không thêm `-k`; lỗi CA/hostname phải được xử lý đúng certificate/DNS. Trình duyệt mở hostname thật, dùng DevTools kiểm request `/api` cùng origin, không có localhost/8081/8082/8083 trong URL public. Test signup/login bằng browser để phát hiện CORS/forwarded header/same-origin issue mà curl có thể không tái hiện.

### 2.2 Dùng script smoke đã có trong source

Chạy từ **source repo**, không phải infra repo:

```bash
BLOG_URL='https://<dev-hostname>' sh scripts/smoke-test.sh
```

Script thực tế đã đọc: kiểm frontend, tạo hai user giả, login, tạo/đọc post/comment, malformed JWT phải 401, user khác xóa phải 403, cuối cùng xóa post/comment test. **Script không xóa hai tài khoản đăng ký**, nên dùng synthetic dev data và có quy trình dọn user riêng. Không chạy lên dữ liệu thật khi chưa có policy test phù hợp.

Kết quả bắt buộc: HTTP responses đúng, DB mỗi service chỉ có dữ liệu của nó, request đi qua gateway, không route nhầm. Trong lần này chưa chạy script; không ghi “pass dev” theo lịch sử Compose cũ.

### 2.3 Đối chiếu image đang chạy

```bash
kubectl -n blogapp-dev get pods \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.containers[*].image}{"\t"}{.status.containerStatuses[*].imageID}{"\n"}{end}'
```

Đối chiếu pod spec digest với deployment release và runtime imageID. Runtime có thể biểu diễn manifest/index/config identity khác nhau theo CRI/registry; không so mù quáng Docker config `image_id` với registry digest. CI hiện là linux/amd64, node architecture phải tương ứng. Lưu image refs/release metadata, không lộ secret env.

## 3. D10 — Bài thử release R1 → R2 → rollback

1. Chọn R1 đã qua CI và chạy ổn dev, chụp state/evidence active.
2. Chọn R2 đúng pipeline, tạo GitOps PR giữ digest bất biến, validate/render.
3. Config Application ở đúng revision/Healthy; migration thành công và schema còn tương thích R1.
4. Argo sync R2; Rollouts giữ active R1 và tạo preview R2. Kiểm pod preview, đủ capacity, gọi chức năng có JWT qua preview.
5. Pre-promotion analysis pass mới promote; theo dõi traffic active và post-promotion analysis theo revision.
6. Trong bài thử lỗi có kiểm soát, abort khi còn cửa sổ giữ R1; revert commit GitOps chọn R2 bằng PR.
7. Sau revert, xác minh Git desired, Argo revision, active Service selector và runtime digest cùng về bản tốt; chạy smoke lần nữa.

Trong GitOps checkout, tạo revert để review:

```bash
git switch -c rollback/dev-release
git revert '<commit-cap-nhat-release-bi-loi>'
git diff HEAD~1 -- environments/dev releases
```

`revert` tạo commit đảo thay đổi đã chọn; nó không tự merge/push/khôi phục DB. Nếu release PR gồm nhiều commit hoặc config/migration thay đổi, chọn phạm vi theo diff đã review, không mặc định một commit là đủ. Không dùng `git reset --hard` để sửa lịch sử release đã chia sẻ.

- [ ] First install R1 và update R2 đã được phân biệt.
- [ ] Pre-check fail giữ active R1; no-data/query-error không pass.
- [ ] Migration fail ngăn rollout; không selective sync bỏ hook.
- [ ] Rollback app không phá DB; schema compatibility có bằng chứng.
- [ ] Argo không kéo selector hash/replicas khỏi controller hợp lệ.

## 4. D11 — HPA, Autoscaler và ASG

### 4.1 Test scale-out

Tạo tải synthetic dev có giới hạn, requests CPU/memory hợp lý; bắt đầu thấp và theo dõi RDS connection budget. Mục tiêu là thấy chuỗi:

```text
Tải/preview tăng → HPA/Rollouts tăng pod → scheduler thiếu capacity
→ CA chọn ASG → desired tăng → EC2 Pending:Wait
→ SSM Automation bootstrap/join → Node Ready → hook CONTINUE
→ pod Ready → ALB target healthy theo ingress
```

Các lệnh quan sát:

```bash
kubectl -n blogapp-dev get hpa
kubectl -n blogapp-dev get pods -o wide --watch
kubectl get nodes --watch
kubectl -n kube-system logs deployment/cluster-autoscaler --since=10m
```

Tên deployment/namespace CA phải khớp release thật; nếu chart đặt tên khác, ghi đúng vào runbook. Pod Pending do constraint/volume AZ/max size khác với pod đang pull image lỗi. CA không sửa được Secret thiếu, DNS sai hay digest không tồn tại.

Test thêm: max 4 worker, quota/capacity AWS thiếu, SSM offline, join token hết hạn, CCM lỗi, duplicate event. Kết quả đúng là timeout/alert có giới hạn và release không chuyển traffic, không phải làm mọi pod xanh bằng cách bỏ gate.

### 4.2 Test scale-in và node refresh

Giảm tải, chờ HPA stabilization và CA scale-down window. Xác nhận pod được eviction/drain theo PDB, còn đủ replica, AWS termination handler phối hợp, không giảm dưới min. Đo lỗi người dùng từ ngoài cluster trong suốt quá trình.

Chạy Terraform plan sau CA thay desired để xác nhận không có action kéo số node về giá trị bootstrap. Đổi LT version là một bài thử hạ tầng khác: chuẩn bị capacity tạm, chờ node mới Kubernetes Ready, drain từng máy và dừng orchestration khi lỗi. Không dùng EC2 status check làm điều kiện duy nhất.

Dev một replica/PDB quá chặt có thể chặn drain; chọn maxUnavailable/minAvailable theo mục tiêu bài thử và số replicas thực, không force-delete mặc định. Với PVC EBS, giữ AZ affinity và kiểm volume detach trước reschedule; không force-detach khi node cũ còn có thể ghi.

## 5. D10 — Kiểm observability bằng hành động có kết quả

- [ ] Metrics: mọi target kỳ vọng UP, không 401/403, metric HTTP/JVM/Hikari có đúng labels.
- [ ] Logs: một lỗi synthetic xuất hiện ở Loki, không có JWT/password; tìm được service/release.
- [ ] Trace: cùng request có gateway → backend → JDBC, trace_id nối được log.
- [ ] Preview metric tách active, query ít traffic/no-data không báo pass giả.
- [ ] Alert có firing và resolved thực tế tới kênh được cấu hình.
- [ ] External probe phát hiện được khi app/cluster dev mất; monitoring trong cluster không là nguồn duy nhất.
- [ ] Retention và storage không tăng vô hạn; telemetry IAM role đúng ServiceAccount.

Ngưỡng p95/error/SLO trong thiết kế gốc là mục tiêu khởi đầu, chưa phải số đo hệ thống. Đo baseline trước đặt ngưỡng demo; báo cáo thời gian quan sát, request count và traffic floor. Không suy luận SLO 99.9% chỉ từ một smoke test thành công.

## 6. D12 — Backup và restore

### 6.1 Ba loại dữ liệu cần phục hồi

| Lớp | Backup | Restore cần chứng minh |
|---|---|---|
| AWS IaC state | S3 versioning và quyền/key backend | Lấy lại state đúng, plan không mất ownership |
| Kubernetes | etcd snapshot, PKI/SA signing/encryption config bảo vệ | API hoạt động và đọc được encrypted Secrets |
| App data | RDS automated backups/PITR/snapshots | DB mới đọc đúng dữ liệu, migration history và smoke |
| GitOps/secrets config | Git revisions, age key/repo credentials backup bảo vệ | Rebuild Argo/CMP giải mã và sync đúng release |

EBS PVC/telemetry nếu cần giữ cũng phải có snapshot/object-store policy và restore bài riêng. Git không chứa dữ liệu DB/etcd private keys. RDS Multi-AZ, khi triển khai staging/prod, là availability chứ không thay backup.

### 6.2 etcd backup

Trên control plane dùng etcdctl version tương thích, endpoint và client TLS đúng theo static pod config. Không copy certificate paths từ tutorial nếu máy thực tế khác. Ví dụ cấu trúc lệnh, khi đã xác nhận paths:

```bash
sudo etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
  --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
  snapshot save '<snapshot-file-trong-thu-muc-bao-ve>'
```

Snapshot chứa Secrets/state cluster, dù Secret values đã encrypt-at-rest vẫn cần bảo vệ. Kiểm integrity theo công cụ version pin, mã hóa thêm trước upload bucket backup, lưu checksum/time/key reference; không upload private key cùng snapshot theo cách ai đọc snapshot cũng đọc key. Lập lịch backup theo RPO của thiết kế ở infrastructure workflow, kiểm stale/failure từ ngoài cluster.

Restore etcd dùng `etcdutl`/quy trình đúng version và hướng dẫn Kubernetes, thử trong môi trường cô lập. Khôi phục encryption config/PKI/signing keys liên quan, data-dir/member identity/static pod mounts và revision semantics phù hợp. Đây là thao tác nhạy cảm, **không đưa một lệnh restore ghi đè cluster đang chạy vào luồng cài đặt thường**. Khi viết runbook thực tế, có checklist input snapshot, backup hiện tại và bài thử restore trên cluster dùng riêng trước.

### 6.3 RDS restore

Thử snapshot/PITR tạo **instance mới** ở subnet/SG cô lập, giữ bản gốc. Kiểm `LatestRestorableTime`, mã hóa, grants, row count, Flyway history và transaction nghiệp vụ mẫu. Cập nhật DB endpoint trong config release có kiểm soát, xác nhận TLS/CA, rồi smoke bằng dữ liệu phục hồi.

PITR không ghi đè trực tiếp RDS hiện tại. Snapshot export ra S3 không phải backup có thể dùng nguyên để restore RDS instance. Giữ bằng chứng thời gian restore và độ mất dữ liệu thực tế, không tự ghi đạt RPO/RTO mục tiêu khi chưa đo. Xem [AWS PITR](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_PIT.html).

### 6.4 Khôi phục cluster từ máy mới

Thử theo thứ tự: đăng nhập dev SSO → đọc backend/inventory → kiểm AWS/private API → phục hồi/rebuild node theo tình huống → Calico/CCM/identity → restore encryption/age key và repo credentials → cài Argo/CMP version pin → sync platform/config/app đúng revision → restore/cutover RDS nếu cần → smoke/telemetry.

Chọn rõ **rebuild cluster từ Git** hay **restore etcd** theo loại sự cố, không tùy tiện trộn hai desired states. Rebuild có thể tạo cluster UID/token/cert mới và cần cập nhật issuer/JWKS/trust; old PVC/volume ownership/topology cũng phải xử lý. Có runbook trên giấy chưa chứng minh restore được.

## 7. Chẩn đoán lỗi thường gặp

| Triệu chứng | Kiểm tra theo thứ tự | Tránh xử lý bằng |
|---|---|---|
| EC2 Running, SSM offline | Agent → instance profile → DNS → egress/endpoints → clock | Mở SSH toàn Internet |
| Ansible SSM ping fail | Controller session plugin → collection/Python → S3 prefix/KMS → node curl/network | Cấp S3 admin cho mọi node |
| kubeadm init/health fail | CRI/cgroup/swap → advertiseIP/SAN → SG/NLB target → cert/time | Reset cluster ngay |
| Node uninitialized | CCM pod/toleration → role/STS → tags/providerID/AZ | Xóa cloud taint tay |
| Node NotReady | Kubelet journal → containerd/CRI → CNI/IP pool/MTU → DNS/routes | Xóa node trước khi biết nguyên nhân |
| PVC Pending | StorageClass WFFC → CSI controller IAM → node topology/AZ → KMS | Đặt volume AZ tùy ý |
| Metrics-server lỗi x509 | Serving CSR/cert SAN → signer/CA → kubelet address → network 10250 | Tắt TLS verification |
| ALB 503/unhealthy | TG/ASG attachment → NodePort → ping entrypoint/Host → SG/route → Traefik pods | Đổi health check thành endpoint luôn 200 không liên quan |
| UI lên, API 404 | Ingress prefix → gateway env/DNS → controller `/api` path → không StripPrefix | Thêm URL localhost frontend |
| JDBC TLS/access fail | Endpoint DNS/CA → TLS → DB tồn tại → user/grants → secret version | `useSSL=false` hoặc master user runtime |
| App CrashLoop validate | Migration Job/log/schema/history → runtime FLYWAY_ENABLED → DB grants | Hibernate ddl-auto=update |
| Prometheus 401/403 | Management security filter/credentials → ServiceMonitor → labels/ports → policy | Public toàn bộ Actuator |
| Argo ComparisonError | Repo/path → CMP sidecar/socket/config → age key permission → Helm/schema | Đổi plugin lỗi thành output rỗng |
| Rollout không tiến | Preview probes → analysis auth/data → capacity → PDB/approval | Promote cưỡng bức để xanh UI |
| CA không thêm node | Unschedulable reason → requests/constraints → ASG tags/max → IAM → lifecycle | Tăng ASG max vô hạn |
| ASG tạo/xóa liên tục | Hook event/heartbeat → SSM execution → join/CCM → timeout defaults | Gia hạn token vĩnh viễn trong AMI |

Khi cần log container, dùng `kubectl logs <pod> --previous` cho crash vừa xảy ra và chỉ chia sẻ output đã redact. Tránh `kubectl get secret -o yaml` hoặc dump toàn bộ env vào evidence.

## 8. Chi phí, tạm dừng và teardown

Lập BOM gồm control plane, 2–4 worker, automation host, RDS/storage/backups, NAT/data processing, ALB/NLB/LCU, EBS/snapshots, S3/requests/KMS, interface endpoints, transfer và registry/CI. Tính giờ bật thực tế với [AWS Pricing Calculator](https://calculator.aws/) trước apply; chưa có báo giá live trong bộ tài liệu này.

Stop EC2 không dừng phí NAT/LB/EBS/RDS/S3. **ASG có thể thay máy bạn stop/terminate**, nên không coi stop từng worker là cách tạm dừng fleet. Muốn nghỉ lab: lưu backup/evidence, chặn release/CA theo runbook, review kế hoạch scale/teardown, bảo vệ control plane/DB và backend state. Không bật `force_destroy=true` cho bucket state để dễ dọn.

Với teardown dev có chủ đích, tạo destroy plan **sau khi** có snapshot/restore evidence và đã kiểm tài nguyên nào cần giữ:

```bash
terraform -chdir=terraform/environments/dev/cluster plan -destroy -var-file=dev.tfvars -out=destroy.tfplan
terraform -chdir=terraform/environments/dev/cluster show destroy.tfplan
```

Đây mới là review plan, chưa phải lệnh xóa. Destroy cluster trước foundation; foundation chứa DB/buckets/network cần quyết định riêng và RDS deletion protection. Giữ backend bootstrap tới cuối vòng đời. Kiểm volumes/snapshots/IPs còn lại và chi phí sau dọn. Không chạy destroy vào prod bằng profile dev hoặc bằng script tự chọn workspace.

## 9. CI của infra và GitOps ở cuối chặng dev

| Repo / loại run | Checks | Credential |
|---|---|---|
| Infra untrusted PR | fmt, validate không backend, lint/scan, Ansible syntax/lint | Không AWS/app secrets |
| Infra trusted plan | Plan đúng account/root/commit, policy | OIDC plan role, backend quyền hẹp |
| Infra apply | Saved plan đã review, environment gate, concurrency theo root | OIDC apply role; job private cho Ansible/API |
| GitOps PR | Helm/schema/CRD validation, digest/release evidence, secret plaintext detection | Synthetic values, không age private key dev |
| GitOps trusted config/sync gate | Verify candidate và signature, config revision/health trước app, smoke sau sync | Quyền dev tối thiểu; không source cluster-admin |

OIDC cho GitHub-hosted runner không tạo route vào VPC. Terraform AWS API job và Ansible/private API job có thể chạy ở những môi trường mạng khác nhau, nhưng gắn cùng reviewed commit/evidence. Untrusted PR không được chạy trên privileged automation host.

Pin Actions/tools, giữ required check names ổn định và aggregate gate fail khi dependency unexpectedly skip. Khi plan stale do drift, replan/review thay vì apply một plan khác với cái đã duyệt. Không tự apply mọi drift nếu đang có incident change.

## 10. Checklist dev hoàn chỉnh

- [ ] Hai repo infra/GitOps tồn tại, branch protection và quyền đúng.
- [ ] Terraform state/key/lock/recovery có bằng chứng; plan không diff ngoài dự kiến.
- [ ] Private API/DB/nodes, public HTTPS ingress và SSM hoạt động.
- [ ] Cluster Ready, CNI/DNS/CCM/topology/CSI/metrics-server đạt.
- [ ] Workload identity pass cả allow và deny, không dùng broad node role thay thế.
- [ ] Argo/CMP/config/app có owner riêng và restore được key/repo access.
- [ ] Năm app bằng digest đúng CI release; migration tách startup, runtime quyền DB hẹp.
- [ ] Smoke browser/curl qua hostname thật, JWT/ownership đúng.
- [ ] R1→R2 preview/analysis/promote/abort/revert có evidence.
- [ ] Metrics/logs/traces nối được, alert firing/resolved và external check đạt.
- [ ] HPA→CA→ASG tự join, drain/refresh/failure limits kiểm thật.
- [ ] etcd/RDS/secret/state restore thử đạt; RPO/RTO ghi số đo thực.
- [ ] Budget, retention, teardown và incident runbooks dùng được.

Kết thúc chặng dev rồi mới nhân pattern sang staging/prod: account/state/VPC/cluster riêng, ba control plane/ba AZ theo thiết kế gốc, Multi-AZ RDS, capacity/policies/promotion gates. Không chỉ copy dev tfvars đổi `environment=prod` rồi coi HA đã có.
