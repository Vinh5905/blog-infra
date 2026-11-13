# GitOps — Từ cluster dev đến BlogApp được phát hành và quan sát được

Phụ thuộc [Terraform](01-terraform.md) và [Ansible/kubeadm](02-ansible-kubeadm.md). Argo CD cơ bản đã cài bằng playbook `50`, chart `10.17.1`, app `v3.6.1`; người vận hành xác nhận kết nối repo `https://github.com/Vinh5905/blog-gitops.git` thành công qua UI. Repo GitOps hiện chỉ có README trong lần rà 13/11/2026. CMP, platform, migration và các Application ở dưới vẫn là thiết kế cần thực hiện. CI candidate đủ năm image là đầu vào trước khi triển khai app. Xem [tiến độ dev](tien-do-dev.md).

## 1. Phải làm thêm gì ngoài infrastructure repo?

Infrastructure chỉ đủ tạo cluster và tài nguyên. Để dev đúng kiến trúc, cần GitOps repo, Argo CD, Rollouts, Helm chart của app, platform charts, secret rendering, migration và monitoring. Dựng chúng theo chặng, kiểm từng lớp trước khi cài toàn bộ.

| Việc | Repo sở hữu |
|---|---|
| Thêm gateway Prometheus, quyền scrape, trace agent, migration images | `blog_app_microservices` bằng PR riêng |
| AWS resources, node OS, identity, lifecycle, Argo/CMP bootstrap | `blog-infra` |
| Helm app, platform values, release digest, SOPS encrypted values, dashboards/rules | `blog-gitops` |
| Bot tạo GitOps PR từ verified candidate | CI source + quyền GitHub App hạn chế |

Không nhét sửa Java vào infrastructure repo. Nếu chưa thực hiện source PR cần thiết, ghi rõ gate tương ứng chưa đạt, không dùng ConfigMap để giả vờ dependency/agent đã tồn tại.

## 2. D7 — Bootstrap Argo CD

### 2.1 Cài từ version pin bằng đường private

Implementation hiện tại thuộc `blog-infra/ansible/playbooks/50-argocd.yml` và `ansible/files/argocd-values.yml`. Chạy mặc định để kiểm tra/render trên automation host; truyền `-e argocd_install=true` để kiểm tra worker và cài/nâng cấp release từ control plane bằng `admin.conf`. Helm được copy từ automation host, còn các Pod Argo CD do scheduler đặt trên worker. Phần CMP bên dưới còn cần bổ sung vào bootstrap này. Khối lệnh Helm tiếp theo mô tả thiết kế ban đầu; dùng playbook hiện tại cho release đang triển khai.

Thực hiện trên automation host hoặc Mac đã có private API tunnel và kubeconfig đúng dev. Đọc version từ lock đã review, không dùng `stable` manifest trôi nổi:

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update argo
kubectl create namespace argocd
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --version "$ARGOCD_CHART_VERSION" \
  -f bootstrap/argocd-values.yaml \
  --wait --timeout 10m
kubectl -n argocd get pods
```

`ARGOCD_CHART_VERSION` phải được gán version cụ thể từ lock trước lệnh. Chart version khác appVersion/controller image version; ghi cả hai. Nếu namespace đã có, không chạy `create` lại hoặc dùng task Ansible idempotent. `--wait` chỉ chờ điều kiện resource theo Helm, chưa chứng minh repo access/CMP/app hoạt động.

Bootstrap values cần: ClusterIP cho UI, resources, repo-server CMP sidecar, volumes/key mounts, RBAC và cấu hình truy cập phù hợp. Baseline dùng bootstrap Ansible/Helm sở hữu Argo CD/CMP release; không đồng thời tạo một Argo Application tự quản cùng release này. Nếu muốn self-management về sau, có thủ tục bàn giao owner riêng.

Trên Mac qua private API tunnel:

```bash
kubectl -n argocd port-forward --address=127.0.0.1 svc/argocd-server 8080:443
```

Sau đó truy cập UI local bằng phương án TLS tin cậy đã cấu hình; không hướng dẫn bỏ qua cảnh báo certificate làm mặc định. Tốt hơn cấp certificate cho endpoint quản trị và cấu hình local name/certificate đúng hoặc dùng CLI qua đường quản trị đã xác thực. Không expose dashboard công khai chỉ để đăng nhập dễ hơn. Bootstrap admin credential lấy một lần qua kênh operator bảo vệ, đổi/cất phù hợp và tắt tài khoản bootstrap khi đã có SSO/RBAC.

### 2.2 Ba credential khác nhau

1. **Argo đọc GitOps repo:** deploy key read-only hoặc GitHub App permission chỉ đọc contents của repo. Tạo Secret repository trong namespace argocd qua kênh bootstrap; không commit private key plaintext.
2. **Kubelet pull GHCR private:** registry credential read-only trong namespace workload; ServiceAccount/imagePullSecrets tham chiếu đúng Secret. Node không dùng Git deploy key để pull container.
3. **Bot mở PR GitOps:** GitHub App installation token ngắn hạn với quyền đúng repo, không bypass branch protection. `GITHUB_TOKEN` source repo không mặc nhiên ghi được repo GitOps khác.

Đừng coi `argocd repo list` thành công là đã chứng minh pod pull GHCR thành công. Kiểm từng quyền riêng.

### 2.3 Projects tách quyền platform và ứng dụng

AppProject app chỉ đọc GitOps repo đã chọn, chỉ deploy namespace `blogapp-dev`, whitelist những resource namespaced cần dùng. AppProject platform có quyền cần thiết để tạo CRD/ClusterRole/StorageClass và namespaces, nhưng chỉ cho platform repo/path tin cậy và operator có quyền quản.

Ví dụ trích đoạn project ứng dụng:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: blogapp-dev
  namespace: argocd
spec:
  sourceRepos:
    - https://github.com/Vinh5905/blog-gitops.git
  destinations:
    - server: https://kubernetes.default.svc
      namespace: blogapp-dev
  clusterResourceWhitelist: []
  namespaceResourceWhitelist:
    - group: ''
      kind: Service
    - group: ''
      kind: ConfigMap
    - group: ''
      kind: Secret
    - group: ''
      kind: ServiceAccount
    - group: argoproj.io
      kind: Rollout
    - group: argoproj.io
      kind: AnalysisTemplate
    - group: batch
      kind: Job
    - group: networking.k8s.io
      kind: Ingress
    - group: networking.k8s.io
      kind: NetworkPolicy
```

Đây là whitelist khởi đầu; thêm HPA/PDB/ResourceQuota/Deployment khi chart thực sự render chúng. Namespace tạo bởi platform trước, app project không có quyền tạo Namespace cluster-scoped. AppProject giới hạn repo/destination/kinds nhưng không tự cô lập mọi đường dẫn trong cùng repo hoặc ngăn người có quyền commit sửa plugin input. CODEOWNERS, branch protection, Argo RBAC và CMP trust boundary vẫn cần thiết.

## 3. D7 — SOPS + age + Config Management Plugin

### 3.1 Chọn định dạng secret duy nhất cho app

`environments/dev/secrets.enc.yaml` chứa **Helm values đã SOPS mã hóa**, được giải mã trước `helm template`. Application `blogapp-dev-config` dùng CMP render chart ở `chartMode=config`, chỉ sở hữu Secret/ConfigMap. Application `blogapp-dev` dùng native Helm ở `chartMode=app`, chỉ sở hữu workloads/Jobs/Services và tham chiếu tên Secret/ConfigMap đã có. Không trộn file raw Secret YAML với Helm values rồi truyền cả hai bằng `-f`.

Shape plaintext minh họa, chỉ tên trường/dữ liệu giả:

```yaml
secrets:
  jwtSecret: <gia-tri-random-dai-rieng-dev>
  userDbPassword: <password-runtime-userdb>
  postDbPassword: <password-runtime-postdb>
  commentDbPassword: <password-runtime-commentdb>
  userMigrationPassword: <password-ddl-userdb>
  postMigrationPassword: <password-ddl-postdb>
  commentMigrationPassword: <password-ddl-commentdb>
```

JWT HS256 phải đồng nhất giữa auth/post/comment trong cùng môi trường; khác môi trường dùng key khác. Không để JWT, mật khẩu hay registry credential trong `values.yaml`, PR text hoặc Terraform outputs. Usernames/DB URL không phải mật khẩu nhưng vẫn review thông tin nội bộ khi chia sẻ.

Tạo age key bằng máy operator bảo vệ, backup offline/password manager theo chính sách; `age-keygen -o <path>` tạo private key, public recipient được phép đưa vào `.sops.yaml`. Không tạo age private key bằng Terraform `random_*` rồi lưu trong state.

Ví dụ `.sops.yaml`:

```yaml
creation_rules:
  - path_regex: environments/dev/.*\.enc\.yaml$
    age: age1<public-recipient-dev>
```

Khi có file plaintext ở vùng tạm bảo vệ:

```bash
umask 077
sops --encrypt --input-type yaml --output-type yaml \
  --filename-override environments/dev/secrets.enc.yaml \
  '<duong-dan-plaintext-tam>' > environments/dev/secrets.enc.yaml
sops --decrypt environments/dev/secrets.enc.yaml > /dev/null
```

Lệnh đầu mã hóa theo creation rule của đường dẫn output; lệnh hai kiểm giải mã mà không in plaintext. Kiểm output có SOPS metadata và field ciphertext trước commit. Xóa file tạm theo chính sách storage, bảo vệ cả backup/editor swap files. `no_log` và mã hóa Git không ngăn secret đã vào RAM, disk tạm, rendered manifest hoặc etcd; kiểm RBAC và encryption-at-rest của API server.

### 3.2 CMP thực sự làm gì?

Argo CD không tự giải mã chỉ vì đuôi `.enc.yaml`. Dùng repo-server sidecar chạy `argocd-cmp-server`, có Helm/SOPS và một renderer đã pin trong image nội bộ. Bootstrap mount age key Secret vào sidecar, cấu hình `SOPS_AGE_KEY_FILE`; không mount sang mọi container nếu không cần.

| Cấu phần CMP | Việc phải hiện thực |
|---|---|
| Image | Helm/SOPS/renderer theo version và checksum, chạy non-root user phù hợp Argo; image pin digest |
| Command | `/var/run/argocd/argocd-cmp-server` theo chart version |
| Config | `plugin.yaml` mount đúng `/home/argocd/cmp-server/config/plugin.yaml` |
| Runtime volumes | Mount var-files/plugins/socket theo hướng dẫn Argo version pin |
| Temp | `emptyDir` riêng của sidecar, không dùng chung `/tmp` repo-server |
| Age key | Secret chỉ đọc, file mode/user đọc được; có bản restore ngoài cluster |
| Network/creds | Không cấp AWS admin; không truyền Git credential cho renderer nếu không cần |

Theo [Argo CMP](https://argo-cd.readthedocs.io/en/stable/operator-manual/config-management-plugins/), đây là executable render nằm trong ranh giới tin cậy. Người có thể sửa lệnh/render code hay exec vào sidecar có thể đọc secrets. Baseline đặt renderer cố định trong image, không lấy tên lệnh từ values của repo.

Ví dụ `plugin.yaml` tối thiểu về hợp đồng:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ConfigManagementPlugin
metadata:
  name: blogapp-helm-sops
spec:
  version: v1
  generate:
    command: [/usr/local/bin/render-blogapp]
```

ConfigManagementPlugin ở đây là config file sidecar, **không phải CRD để kubectl apply**. Khi có spec.version, Application chọn tên `blogapp-helm-sops-v1`. Renderer dự kiến chạy trong source.path `environments/dev`:

```sh
#!/bin/sh
set -eu
umask 077
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT HUP INT TERM
sops --decrypt --input-type yaml --output-type yaml \
  secrets.enc.yaml > "$work_dir/secrets.values.yaml"
helm template blogapp ../../charts/blogapp \
  --namespace blogapp-dev \
  -f values.yaml \
  -f "$work_dir/secrets.values.yaml" \
  --set chartMode=config
```

Đây là **renderer minh họa cần đóng gói và kiểm thử**, không phải plugin image đã có. `set -e` dừng khi decrypt/render lỗi; `umask` hạn chế file; trap cleanup temp; stdout chỉ là YAML render để Argo nhận. Không bật `set -x`, không `cat` file secret, không `helm --debug` vào log. Dependency chart phải vendored/được tải ở quy trình có kiểm soát trước, không kéo dependency trôi nổi mỗi lần render. Plugin cần toàn repo chứa `charts/` ngoài `source.path`; không cấu hình tar exclusions/manifest-generate-paths làm mất chart đó.

Chỉ dùng renderer này cho config-mode của chart BlogApp. Secrets platform có renderer riêng theo chart/path hoặc bootstrap quản; chưa để script cố định này render mọi chart platform. `values.schema.json` phải hiểu hai mode: config yêu cầu secrets, app chỉ yêu cầu secret names. Tối thiểu phải có negative test: thiếu age key, ciphertext hỏng, chart lỗi và path không hợp lệ đều làm Argo báo lỗi, không render ra danh sách resource rỗng rồi prune.

## 4. D8 — Platform Applications theo thứ tự có kiểm chứng

Không cài mọi chart cùng lúc và chờ root Application xanh. Chọn thứ tự:

1. Namespace/RBAC nền và policies không làm chết bootstrap.
2. Rollouts CRDs/controller; health customization đúng controller version.
3. CSI/StorageClass và metrics-server sau identity/TLS gate.
4. Traefik NodePort, public health route và ingress class.
5. Prometheus Operator/CRDs qua kube-prometheus-stack, rồi monitors/rules.
6. Loki/Alloy, Tempo/OTel Collector, sau đó app instrumentation/rules.
7. App namespace, config/secrets, migration Job và app release.

Calico/CCM/Argo CD đã do infra bootstrap sở hữu; không thêm chart thứ hai để quản lại. Với EBS CSI/metrics-server nếu đã bootstrap tạm, bàn giao manifest ownership rõ trước tạo Argo app tương ứng.

Dùng root app tạo child Applications được, nhưng sync waves trên cha **không tự chứng minh child đã Healthy**. Baseline dùng bootstrap workflow chờ từng child bằng API/CLI rồi mới cho bước phụ thuộc:

```bash
argocd app wait platform-rollouts-dev --sync --health --timeout 600
argocd app wait platform-storage-dev --sync --health --timeout 600
argocd app wait platform-ingress-dev --sync --health --timeout 600
argocd app wait platform-monitoring-dev --sync --health --timeout 900
```

Tên này là conventions sẽ tạo. CLI phải đăng nhập server theo đường quản trị tin cậy trước; `app wait` timeout không đồng nghĩa cứ bỏ qua. Kiểm CRD tồn tại trước render resources dùng kind mới. Cài chart bằng Argo: chọn Helm source hoặc wrapper chart dependency pin; repo chart mới không được tự upgrade khi chỉ refresh repo.

### 4.1 Traefik health và request routing

Service Traefik: NodePort cố định 30080 cho HTTP/web, `externalTrafficPolicy: Cluster`, replicas ít nhất 2 ở dev nếu budget cho phép. Terraform ALB target group trỏ 30080; ASG tự đăng ký node.

Expose `/ping` của Traefik trên entrypoint web bằng cấu hình phù hợp chart version, chấp nhận health check Host IP của ALB. Không expose dashboard/API quản trị Traefik. Một target healthy chỉ chứng minh ingress trả ping, không chứng minh DB/application healthy. Tham khảo [Traefik health check](https://doc.traefik.io/traefik/reference/install-configuration/observability/healthcheck/).

Ingress app có hostname dev, ingress class Traefik, hai path:

| Path | Backend | Quy tắc |
|---|---|---|
| `/api` Prefix | `api-gateway-server:8080` | Không strip `/api` |
| `/` Prefix | `blog-client:8080` | SPA fallback nằm ở Nginx |

ALB terminate TLS; chỉ tin forwarded headers từ ALB/proxy CIDR đúng. Kiểm `X-Forwarded-Proto/Host`, origin và URL redirect. Nginx hiện có `$scheme` là HTTP sau TLS termination; nếu request `/api` đi qua Nginx, cần kiểm việc ghi lại X-Forwarded-Proto. Test bằng browser hostname thật, không chỉ curl localhost, để phát hiện CORS/forwarded-header lỗi.

## 5. D8 — Database bootstrap và migration

### 5.1 Hợp đồng DB

| Service | DB | Runtime user | Migration user |
|---|---|---|---|
| userauthservice | userdb | user_service | user_migrator |
| postservice | postdb | post_service | post_migrator |
| commentservice | commentdb | comment_service | comment_migrator |

Bootstrap chạy qua private DB path, lấy master credential từ Secrets Manager trong tiến trình được bảo vệ. Tạo DB/users/grants có kiểm tra tồn tại, không log password/SQL có credential. Runtime chỉ DML cần thiết trong DB sở hữu; migration có DDL cần thiết trong cùng DB, không quyền account/global. Không dùng nguyên `GRANT ALL PRIVILEGES` trong script Compose cho runtime RDS.

Flyway history và Hibernate validate có thể cần đọc metadata; kiểm bằng cả migration và app startup để không vô tình loại quyền cần thiết. Account bootstrap không được đưa vào app Secret. Tính connection budget theo số pod tối đa + blue/green + migration/admin; Hikari pool mặc định của mỗi pod không tự thích nghi tổng budget RDS.

### 5.2 Phần source phải bổ sung

Hiện SQL nằm trong JAR và app tự chạy Flyway khi startup. Cần CI tạo migration image bất biến riêng cho từng DB, chứa SQL của đúng revision và Flyway/MySQL driver đã kiểm. Lựa chọn đề xuất: image runner Flyway CLI đã pin, copy SQL đúng service vào image, chạy migrate rồi exit.

Không dùng nguyên Java app image làm Job rồi mong Spring Boot tự exit sau migrate. Không mount SQL lấy từ mutable main ở lúc CD, không build migration image trên dev trước deploy vì sẽ phá nguyên tắc artifact kiểm chứng trước.

Các image migration được build/scan/publish từ source pipeline; thêm release schema/evidence cho chúng. Validator candidate hiện tại yêu cầu đúng năm app image: giữ contract đó hoặc nâng schema có test tương thích; không lén thêm ba entry làm consumer hiện tại hỏng. Deployment release sẽ tham chiếu original CI candidate và migration artifact contract riêng, chart version, config commit và environment evidence.

### 5.3 Migration Job trước rollout

Trong một Application sync đầy đủ, chart render ba Job migration theo thứ tự/độc lập DB phù hợp. Dùng `PreSync` hook, timeout và retry hữu hạn. Secret DB do platform bootstrap/Application secrets chuẩn bị và kiểm tồn tại **trước** app sync có PreSync; Secret normal Sync của chính lần sync chưa chắc tồn tại khi PreSync chạy.

Các cấu hình cần có cho Job:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/hook: PreSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
spec:
  backoffLimit: 1
  activeDeadlineSeconds: 600
```

Đây chỉ là phần policy của Job, còn image/command/env/SA/resources/securityContext. `BeforeHookCreation` xóa Job cũ cùng tên trước run mới; lưu log/evidence đã redact ra nơi phù hợp trước bị xóa. Backoff 1 giới hạn retry, deadline 600s là giá trị khởi đầu cần đo. Flyway lịch sử/checksum quyết định migration có cần áp dụng lại, không `clean` DB khi fail.

**Vòng secrets cụ thể:** tạo Application `blogapp-dev-config` với source.path `environments/dev`, plugin `blogapp-helm-sops-v1`, target namespace `blogapp-dev`; renderer mục 3 chỉ xuất Secret/ConfigMap. Chờ config app Synced/Healthy rồi mới tạo/sync app Application ở mục 7.2. Native Helm app-mode không render lại các object config. Khi đổi credential, workflow phải sync và xác nhận config revision trước sync app revision, rồi restart workload có kiểm soát; environment variables từ Secret không tự cập nhật pod đang chạy. Tên Secret/version/checksum cần nằm trong rollout template để thay config tạo revision mới; không đặt plaintext secret vào annotation checksum.

Runtime đặt `FLYWAY_ENABLED=false`, Hibernate `validate`. Migration fail → không tiếp tục rollout. Chỉ dùng full Application sync; selective sync có thể bỏ qua hooks. Release chứa breaking schema phải chia expand/migrate/contract, giữ bản cũ chạy được trong cửa sổ rollback. Xem thiết kế gốc mục 11.

## 6. D9 — Chart ứng dụng và cấu hình khớp source

### 6.1 Cấu trúc chart dự kiến

```text
charts/blogapp/
  Chart.yaml
  values.yaml
  values.schema.json
  templates/
    configmap.yaml
    secrets.yaml                 # Chỉ config-mode sở hữu
    serviceaccount.yaml
    service-active.yaml
    service-preview.yaml
    rollout.yaml
    migration-job.yaml
    ingress.yaml
    networkpolicy.yaml
    pdb.yaml
    servicemonitor.yaml
```

Dùng một map `services` và template lặp năm service, tránh copy ba bộ YAML chỉ đổi môi trường. Chart defaults chung; values dev chọn replica/resources/DB endpoints, release values chọn digest. `values.schema.json` bắt buộc trường và format digest, ngăn typo vô tình fallback localhost/latest. Tên active Service phải đúng `userauthservice`, `postservice`, `commentservice`, `api-gateway-server`, `blog-client` theo contract source; nếu helper Helm thêm prefix release thì phải chủ động override hoặc cập nhật toàn bộ DNS contract và test, không để mặc định âm thầm thành `blogapp-postservice`.

### 6.2 Bảng environment chính xác

| Workload | Biến / cấu hình |
|---|---|
| Gateway | `AUTH_SERVICE_URL=http://userauthservice:8080`, `POST_SERVICE_URL=http://postservice:8080`, `COMMENT_SERVICE_URL=http://commentservice:8080` |
| Java chung | `SERVER_PORT=8080`, `MANAGEMENT_PORT=9090`; graceful timeout source 20s |
| Ba business service | `DB_URL`, `DB_USERNAME`, `DB_PASSWORD`, `JWT_SECRET`, `JWT_EXPIRATION_SECONDS=3600`, `FLYWAY_ENABLED=false` |
| Frontend | Nginx 8080, health `/health`, SPA fallback; browser giữ `/api` |
| Tracing sau instrumentation | OTEL service/resource name và collector endpoint; không coi env tự thêm Java agent |

`DB_URL` dùng RDS endpoint và TLS xác thực hostname, ví dụ phần URL `jdbc:mysql://<rds-endpoint>:3306/postdb?sslMode=VERIFY_IDENTITY`. CA truststore phải được mount/bake theo release và cấu hình Connector/J/JVM cho đúng file; mặc định Java truststore có thể chưa tin CA RDS. Không dùng IP RDS hay tắt SSL để làm startup pass.

### 6.3 Probes, resources và security context

Ví dụ container business service, bổ sung vào template Rollout:

```yaml
ports:
  - name: http
    containerPort: 8080
  - name: management
    containerPort: 9090
startupProbe:
  httpGet:
    path: /actuator/health/liveness
    port: management
  periodSeconds: 5
  failureThreshold: 36
readinessProbe:
  httpGet:
    path: /actuator/health/readiness
    port: management
  periodSeconds: 5
livenessProbe:
  httpGet:
    path: /actuator/health/liveness
    port: management
  periodSeconds: 10
resources:
  requests:
    cpu: 250m
    memory: 512Mi
  limits:
    cpu: '1'
    memory: 1Gi
securityContext:
  runAsNonRoot: true
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: [ALL]
```

Startup budget ở ví dụ là khoảng 180s, cần đo cold start thực tế. Readiness bỏ pod khỏi endpoint, liveness restart pod; không đưa DB dependency gây restart hàng loạt vào liveness. Management-port probe pass chưa chắc app port 8080 phục vụ được; thêm synthetic test đường request và cân nhắc app-port health group theo cấu hình Boot đã kiểm.

Resources là giả thuyết ban đầu, không sizing đã chứng minh. Tính JVM heap + non-heap + thread/native dưới limit, không chỉ đặt heap bằng toàn bộ RAM. Khi read-only filesystem, mount `emptyDir` cho `/tmp` Java và Nginx temp/cache/pid thực sự cần ghi. Seccomp RuntimeDefault ở pod/container level theo chart; `automountServiceAccountToken=false` cho app không gọi K8s API. Frontend/gateway có sizing/probe riêng, không copy cấu hình JVM/DB sang frontend.

NetworkPolicy: default deny app namespace; allow DNS TCP/UDP53, Traefik→frontend/gateway 8080, gateway→business 8080, Prometheus→9090, business→RDS 3306, traces→collector. Migration Jobs cũng cần RDS/DNS; bootstrap config phải có nhãn phù hợp. Node kubelet probes/hostNetwork traffic có semantics riêng của CNI; kiểm thật, không coi deny policy bảo vệ mọi node-origin request.

## 7. D9 — Deployment release từ CI candidate thật

### 7.1 Nguồn artifact

Code hiện tại xuất `kind=ci-release-candidate`, `schema_version=1`, `source_sha`, repository/run_url/identity/issuer và map năm image. Mỗi image có registry digest khác với Docker config `image_id`; deploy dùng **`images.<module>.image`**, không dùng `image_id` làm `image:`.

Ví dụ release-values sẽ được tạo từ evidence thật:

```yaml
releaseId: <release-id>
services:
  postservice:
    image: ghcr.io/vinh5905/blog_app_microservices/postservice@sha256:<64-hex>
```

File thực tế phải có đủ năm service và migration refs, không chỉ trích đoạn postservice. Source pipeline hiện vẫn publish full năm app image cùng SHA cho release ứng dụng; chưa thiết kế consumer chọn digest lẫn nhiều source SHA tùy ý. Branch local đang ahead chưa phải main release.

Trình tự chọn candidate:

1. Chọn successful trusted main push có verified-release artifact còn hạn; không chọn run chỉ docs/no-release.
2. Kiểm source SHA/repository/schema, đủ năm image và full evidence, giữ bản evidence lâu hơn retention tạm của Actions.
3. Verify Cosign với identity workflow và issuer đúng, đối chiếu digest còn pull được bằng `linux/amd64`.
4. Tạo deployment release tham chiếu candidate + chart/config/migrations; validate schema và render chart.
5. PR GitOps chỉ cập nhật release-values/metadata dev và các config thay đổi đã review. Merge xong Argo mới đồng bộ.

Ví dụ verify **một** image sau khi điền values từ candidate:

```bash
cosign verify \
  --certificate-identity 'https://github.com/Vinh5905/blog_app_microservices/.github/workflows/backend-ci.yml@refs/heads/main' \
  --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
  --certificate-github-workflow-sha "$SOURCE_SHA" \
  "$IMAGE_REF"
```

Không chỉ nhìn trường JSON `signature_verified=true`; verify độc lập và kiểm artifact đúng source. Identity đối chiếu source `publish_images.py`, thay owner/workflow nếu repo thay. Thiết kế có admission verify ở giai đoạn enforce; CI verify trước sync chưa tương đương cluster từ chối mọi image không ký.

### 7.2 Application app dùng native Helm, config dùng CMP

Ví dụ sau khi config app đã Healthy:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: blogapp-dev
  namespace: argocd
spec:
  project: blogapp-dev
  source:
    repoURL: https://github.com/Vinh5905/blog-gitops.git
    targetRevision: main
    path: charts/blogapp
    helm:
      releaseName: blogapp
      valueFiles:
        - ../../environments/dev/values.yaml
        - ../../environments/dev/release-values.yaml
      valuesObject:
        chartMode: app
  destination:
    server: https://kubernetes.default.svc
    namespace: blogapp-dev
  syncPolicy:
    automated:
      prune: false
      selfHeal: true
    syncOptions:
      - RespectIgnoreDifferences=true
  ignoreDifferences:
    - group: ''
      kind: Service
      jsonPointers:
        - /spec/selector/rollouts-pod-template-hash
```

`targetRevision=main` nghĩa là PR protection tại GitOps repo là release gate. `path` là chart; valueFiles được tính tương đối từ chart path. `valuesObject.chartMode=app` buộc chart bỏ Secret/ConfigMap. `prune=false` giai đoạn đầu giúp không xóa resource do nhầm chart path; sau kiểm thử mới bật prune cho stateless phù hợp, tách namespace/CRD/PVC/data khỏi auto-delete. `RespectIgnoreDifferences` tránh apply ghi lại field selector hash do Rollouts quản; chỉ ignore đúng field, không ignore toàn bộ Service.

Application config và app không được render cùng object. Lần đầu chỉ tạo app Application sau khi config app đã Healthy. Sau đó có thể giữ dev auto-sync như ví dụ nếu quy trình enforce **hai PR khi đổi config/credential**: PR config trước, chờ đúng revision Healthy và xác minh credential/DB; PR app sau mới đổi digest/configRevision để rollout. PR chỉ đổi app digest không cần sync lại secret. CI phải chặn PR đổi đồng thời config nhạy cảm và release app khi chưa có orchestrator chờ dependency. Hai Applications auto-sync độc lập không tự bảo đảm thứ tự; nếu chưa hiện thực gate này thì chưa bật automated của app ở lần bootstrap.

## 8. D10 — Blue-green với Argo Rollouts

Mỗi service có active Service theo tên DNS hiện tại, preview Service hậu tố `-preview`, và Rollout. Gateway bình thường luôn gọi active Service. Rollouts controller đổi selector hash để chuyển traffic; Argo CD giữ desired spec/digest.

Trích đoạn Rollout của postservice:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: postservice
  namespace: blogapp-dev
spec:
  replicas: 1
  revisionHistoryLimit: 3
  selector:
    matchLabels:
      app: postservice
  strategy:
    blueGreen:
      activeService: postservice
      previewService: postservice-preview
      autoPromotionEnabled: false
      scaleDownDelaySeconds: 300
  template:
    metadata:
      labels:
        app: postservice
    spec:
      containers:
        - name: app
          image: ghcr.io/vinh5905/blog_app_microservices/postservice@sha256:<64-hex>
```

Đây chưa đủ apply: thiếu env/probes/resources/SA/Secret/mounts và hai Service. Preview tạo thêm pod, nên tính cả 2× resources và DB connections. 300s là cửa sổ giữ bản cũ khởi đầu; đo drain/HTTP keep-alive trước chốt. Lần cài R1 đầu tiên không chứng minh blue-green; phải tạo R2 sau khi R1 đang phục vụ.

Theo [Rollouts BlueGreen](https://argo-rollouts.readthedocs.io/en/stable/features/bluegreen/), pre/post promotion analysis cần AnalysisTemplate thật và provider đúng. Làm theo ba bước học:

1. R1 chạy, R2 preview và pause; gọi preview Service bằng smoke có JWT hợp lệ.
2. Thêm prePromotionAnalysis chạy Job synthetic; success mới được promote, fail giữ active R1.
3. Thêm postPromotionAnalysis Prometheus theo revision; thử bản lỗi có kiểm soát, abort và revert Git.

CLI trên đường quản trị, plugin version đã pin:

```bash
kubectl argo rollouts get rollout postservice -n blogapp-dev --watch
kubectl argo rollouts promote postservice -n blogapp-dev
kubectl argo rollouts abort postservice -n blogapp-dev
```

`promote` chuyển bước đang pause theo policy, không bỏ qua PR gate; `abort` dùng trong bài thử/phát hiện lỗi phù hợp trạng thái rollout. Không chạy promote và abort nối tiếp như một script cài đặt. Nếu abort, cập nhật/revert GitOps về digest tốt để tự đồng bộ không tái áp bản lỗi.

Test preview backend phải có token/seed; gọi `/health` không thay nghiệm thu chức năng post/comment. Release nhiều service có thể cần preview gateway riêng để kiểm contract liên service, không mặc nhiên toàn bộ route active cùng chuyển một lúc.

Khi bật HPA cho Rollout, `scaleTargetRef` trỏ đúng group/kind/name Rollout và Argo/Helm không giành replicas. D0–D9 có thể giữ replicas tĩnh để debug; D11 mới bật HPA/CA sau resource metrics gate.

## 9. D10 — Observability theo ba đường độc lập

### 9.1 Metrics trước

Cài kube-prometheus-stack chart pin, một bộ Prometheus Operator. Đầu tiên xác nhận node-exporter/kube-state-metrics và Prometheus targets; sau đó thêm ServiceMonitor cho từng Java service. Business service cần source PR xử lý security của `/actuator/prometheus`; gateway cần dependency/exposure tương ứng. Management port 9090 chỉ nội bộ, không Ingress public.

ServiceMonitor trích đoạn:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: postservice
  namespace: monitoring
  labels:
    release: observability
spec:
  namespaceSelector:
    matchNames: [blogapp-dev]
  selector:
    matchLabels:
      app: postservice
      traffic: active
  endpoints:
    - port: management
      path: /actuator/prometheus
      interval: 30s
```

`selector` khớp **Service labels**, `endpoints.port` khớp Service port name, không phải trực tiếp containerPort. Prometheus selectors phải chọn monitor có label thực tế `release=observability`; release chart tên khác thì đổi cho khớp. NetworkPolicy và scrape authentication phải cho phép, không chỉ có YAML này là target UP.

Theo dõi preview bằng một monitor/PodMonitor riêng có label revision; không tính cả active và preview vào SLO người dùng rồi che lỗi. Ingest metric cùng pod từ hai targets có thể gây double-count; selector cho mục đích SLO/analysis phải rõ.

Dashboard khởi đầu: requests/error/p95, JVM RSS/heap/GC/threads, Hikari active/pending, pod restarts/OOM, node allocatable/requests/pending, RDS/ALB signals, Argo sync/rollout và telemetry health. Kiểm metric name/labels thực từ endpoint trước viết PromQL. No-data/NaN/query-error không được coi analysis pass.

### 9.2 Logs

Loki dev có thể single-binary retention ngắn với storage/identity đúng chart version. Alloy DaemonSet đọc logs node và đẩy Loki, quyền đọc hostPath chỉ cho collector. App cần log JSON chứa timestamp/service/env/release/trace_id; nếu source hiện chưa xuất JSON/correlation field thì thêm source PR. Không hứa có log-trace correlation chỉ vì cài Alloy.

Nhãn index Loki giữ cardinality thấp; request/user/post/trace ID để field/structured metadata. Không gửi JWT/Authorization/password/request body nhạy cảm. Secret trong env không tự xuất log, nhưng debug logging có thể làm lộ, cần kiểm output thật.

### 9.3 Traces

Tempo nhận traces qua OTel Collector. Java agent phải thực sự được bake vào image hoặc tải bằng init container đã pin/checksum rồi mount. Image hiện tại chưa có agent; nếu chọn init container cần supply-chain policy và quyền filesystem tương thích.

Ví dụ env sau khi đã có agent tại `/otel/opentelemetry-javaagent.jar`:

```text
JAVA_TOOL_OPTIONS=-javaagent:/otel/opentelemetry-javaagent.jar
OTEL_SERVICE_NAME=postservice
OTEL_RESOURCE_ATTRIBUTES=deployment.environment.name=dev,service.version=<release-id>
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.monitoring.svc.cluster.local:4318
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_METRICS_EXPORTER=none
OTEL_LOGS_EXPORTER=none
```

Gộp Java memory flags vào JAVA_TOOL_OPTIONS, không ghi đè làm mất agent hoặc memory tuning. Port/protocol phải khớp Collector receiver; ví dụ này dùng OTLP HTTP 4318, không gửi gRPC vào endpoint đó. Metrics đi Micrometer, logs stdout/Alloy; agent gửi traces để tránh duplicate signal. Collector có memory limiter/batch/queue/retry và resource limits.

Nghiệm thu: request qua gateway tạo trace gateway→postservice→JDBC; mở log theo trace_id; metrics cùng service/release hiện đúng. Auth/comment dùng DB riêng, không vẽ span liên service chưa có trong source.

### 9.4 Alerts và kiểm tra bên ngoài

Alert khởi đầu: public journey failed, node not ready, crash/OOM, DB connections/storage, telemetry unavailable, cert/backup stale và release analysis failed. Thử cả firing/resolved. Alertmanager gửi tới kênh owner chọn và cấu hình secret sau; chưa tự gửi tin nhắn cho người khác khi soạn tài liệu.

External check phải chạy ngoài dev cluster để thấy cluster chết toàn bộ; có thể dùng một endpoint checker độc lập hoặc dịch vụ phù hợp budget. CloudWatch ALB/EC2/RDS/lifecycle errors bổ sung tín hiệu ngoài cluster. Alert không tự rollback nếu chưa có automation cụ thể; postPromotionAnalysis chỉ điều khiển trong cửa sổ rollout được cấu hình.

## 10. Validate GitOps trước merge

Các check khi chart đã có:

```bash
helm dependency build charts/blogapp
helm lint charts/blogapp -f environments/dev/values.yaml -f environments/dev/release-values.yaml --set chartMode=app
```

Dependency build sử dụng Chart.lock; chart không có dependency thì bước này không tải thêm gì. Lint thêm config-mode bằng synthetic secret values khi schema bắt buộc fields, không dùng secret dev thật trong untrusted PR. Chạy renderer với synthetic values, validate output bằng kubeconform có schemas CRD đúng version; sau CRD có thể dùng server-side dry-run trên dev qua trusted workflow. `kubectl --dry-run=client` một mình không chứng minh CRD/schema hợp lệ.

Policy bắt buộc: đủ năm app image/digests, không latest, không privileged/public management, probes/resources/SA hợp lệ, selectors/ports/path đúng, default deny có allow cần thiết, migration image/evidence đúng release. Gitleaks quét cả infra/GitOps. Plaintext secrets không đi vào artifact rendered manifest công khai.

Dev auto-sync chỉ sau PR merge và checks; source CI tạo PR, không chạy kubectl apply app trực tiếp. Một PR fail decrypt/render phải fail check, không biến thành manifest trống.

## 11. Điểm chốt nghiệm thu GitOps

- Repo access, registry access, CMP/key restore là ba bài kiểm riêng đã pass.
- Config/secret sẵn trước migration; migration fail chặn deploy; runtime không có DDL/master credentials.
- R1 chạy đủ năm workload bằng digest; smoke qua HTTPS hostname thật; R2 preview/promote/abort đã thử.
- Sau revert, Git/Argo/active selector/image runtime cùng hội tụ bản tốt.
- Prometheus scrape đúng quyền, logs và traces có dữ liệu thật; gateway metrics/agent gaps trong source đã được xử lý.
- Các dashboards, rules và values đều có version và nằm trong GitOps repo; bootstrap owners không trùng.
- Chưa tick dev hoàn chỉnh cho đến khi scale lifecycle và restore trong [chương vận hành](04-nghiem-thu-va-van-hanh.md) có evidence.
