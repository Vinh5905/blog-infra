# Ansible và kubeadm — Từ EC2 đến cluster có worker lifecycle

Phụ thuộc: foundation/cluster root đã tạo tài nguyên như [01-terraform.md](01-terraform.md). Các tên role/playbook sau là **thiết kế cần hiện thực**, chưa có file triển khai. Lệnh chỉ chạy sau khi đã viết file tương ứng và khóa version.

## 1. Ansible làm gì trong dự án này?

Terraform trả lời “có những máy và tài nguyên AWS nào?”. Ansible trả lời “bên trong máy đã có đúng OS settings, runtime và Kubernetes chưa?”. Kubernetes/Argo CD trả lời “workload nào cần chạy?”. Không dùng Ansible copy JAR ứng dụng vào mỗi worker vì ứng dụng được phát hành bằng image/GitOps.

Một **task** thay đổi hoặc kiểm tra một trạng thái. **Module** thực hiện task, ví dụ `apt`, `template`, `systemd_service`. **Role** nhóm task/defaults/templates/handlers của một trách nhiệm. **Handler** chạy khi task notify có thay đổi, ví dụ restart containerd sau đổi config. **Inventory** chọn máy; **group_vars** cấp cấu hình theo nhóm. **Playbook** sắp thứ tự role/task cho một nhóm máy.

Idempotence: chạy lại cùng đầu vào phải hội tụ, không reset cluster, không đổi token/key vô cớ. `changed_when: false` chỉ đổi cách báo cáo, không biến một lệnh thay đổi máy thành idempotent.

## 2. Chọn công cụ cài cluster và khóa compatibility

Theo lộ trình học, chọn role kubeadm nhỏ tự quản; tham khảo inventory/upgrade/recover của Kubespray. Nếu đổi sang Kubespray làm installer, chỉ dùng một bộ sở hữu OS/runtime/Kubernetes và pin release của nó.

Trước cài, điền `versions.yaml` bằng **giá trị cụ thể**:

| Thành phần | Cần khóa và đối chiếu |
|---|---|
| OS | AMI ID Ubuntu amd64, kernel và image owner |
| Kubernetes | Minor/patch còn được hỗ trợ, package version đầy đủ của kubeadm/kubelet/kubectl |
| kubeadm config API | Schema của minor đã chọn, không lấy schema từ blog cũ |
| containerd/runc/CNI plugins | CRI/cgroup tương thích; đúng layout config containerd 1.x hoặc 2.x |
| Calico | Hỗ trợ Kubernetes minor đó, VXLAN và Pod CIDR đã chốt |
| AWS CCM | Minor/version theo support matrix của cloud-provider-aws |
| EBS CSI và sidecars | Hỗ trợ Kubernetes minor và topology của node |
| Cluster Autoscaler | Bản tương thích Kubernetes minor và AWS provider |
| metrics-server | Hỗ trợ Kubernetes, kubelet TLS và network path |
| Ansible | Python/ansible-core và `amazon.aws` collection tương thích |
| Argo CD/Rollouts/charts | Pin version/chart digest/lock sau khi kiểm matrix |

Không điền số Kubernetes “mới nhất” tùy ý từ README fork. Bộ version platform chưa được test trong account này, vì vậy đây là cổng cần đóng trước D4. Có thể đọc [kubeadm install](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/) và [version skew](https://kubernetes.io/releases/version-skew-policy/). Bản implementation phải biến bảng này thành pin trong package/tasks/chart, không chỉ ghi một file metadata mà lệnh vẫn cài latest.

## 3. D3 — Automation host và kết nối SSM

Baseline chạy Ansible trên một EC2 automation private, độc lập cluster. Mac mở SSM session vào đó; host có đường đến API NLB/RDS và SSM/S3. Đây là đường quản trị còn dùng được khi Argo hoặc cluster hỏng.

Host cần Python virtualenv, AWS CLI, Session Manager plugin, Git, Terraform outputs cần thiết, kubectl và Ansible. Source/requirements pin đúng commit. Không chạy job PR không tin cậy trên máy có quyền bootstrap này. Có thể chuyển sang ephemeral runner ở chặng CI sau.

Trên máy đang dùng AWS profile dev:

```bash
aws ssm describe-instance-information --region ap-southeast-1
aws ssm start-session --target '<automation-instance-id>' --region ap-southeast-1
```

Lệnh đầu kiểm danh sách managed instances và `PingStatus`; lệnh sau mở phiên quản trị host. Có EC2 Running không đồng nghĩa SSM Online. SSM cần agent, instance profile và network tới endpoint service; private DNS phải hoạt động. S3 cần đường truyền cho plugin Ansible, còn GitHub/GHCR/package repositories cần egress riêng.

### 3.1 Chuẩn bị dependency Python/collection

Các lệnh cài công cụ và kích hoạt lại virtualenv nằm trong [runbook chuẩn bị automation host](runbooks/01-automation-host.md).

Sau khi có `ansible/requirements-controller.txt` và `ansible/requirements.yml` đã pin/review:

```bash
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -r ansible/requirements-controller.txt
ansible-galaxy collection install -r ansible/requirements.yml
ansible --version
ansible-galaxy collection list
```

Virtualenv tránh trộn Python hệ thống. File requirements cần chứa ansible-core/boto3/botocore và các dependency đúng version plugin; không cài `pip install ansible` không pin rồi kỳ vọng tái tạo được. Collection tối thiểu là `amazon.aws`; thêm collection khác chỉ khi role dùng module của nó. Module systemd/apt/template thuộc `ansible.builtin`, không cần cài một Galaxy role chỉ để restart service.

### 3.2 Dynamic inventory theo tag EC2

Ví dụ dự kiến `ansible/inventories/dev/aws_ec2.yml`:

```yaml
plugin: amazon.aws.aws_ec2
regions:
  - ap-southeast-1
filters:
  instance-state-name: running
  tag:Project: blogapp
  tag:Environment: dev
  tag:Cluster: blogapp-dev
hostnames:
  - instance-id
keyed_groups:
  - key: tags.Role
    prefix: role
compose:
  ansible_host: instance_id
strict: true
```

`plugin` lấy inventory từ EC2 API. Ba tag giới hạn đúng project/env/cluster. `instance-id` phù hợp SSM thay private IP dễ thay đổi. `keyed_groups` tạo nhóm `role_worker`; tag `control-plane` thường được sanitize thành `role_control_plane`, phải xem `--graph` để xác nhận. `strict` không phải kiểm “chỉ có đúng một control plane”; thêm assert riêng về số lượng và account.

Ví dụ `group_vars/all.yml`:

```yaml
ansible_connection: amazon.aws.aws_ssm
ansible_aws_ssm_region: ap-southeast-1
ansible_aws_ssm_bucket_name: <bucket-transfer-rieng>
ansible_aws_ssm_bucket_sse_mode: aws:kms
ansible_aws_ssm_bucket_sse_kms_key_id: <arn-kms-transfer>
ansible_become: true
ansible_become_user: root
```

SSM plugin không dùng `ansible_user` như SSH thông thường. Quyền chạy root phải phù hợp cấu hình SSM/sudo. Controller cần quyền thao tác prefix bucket; node tải/đẩy qua presigned URL, không tự cần được cấp toàn bộ S3 quyền của controller. Bucket transfer tắt versioning, dọn object tồn đọng khi run bị ngắt. Theo [Ansible SSM plugin](https://docs.ansible.com/projects/ansible/latest/collections/amazon/aws/aws_ssm_connection.html), ngay cả task command cũng truyền module qua S3.

Kiểm inventory và kết nối trước cấu hình:

```bash
ansible-inventory -i ansible/inventories/dev/aws_ec2.yml --graph
ansible -i ansible/inventories/dev/aws_ec2.yml role_control_plane -m ansible.builtin.ping
ansible -i ansible/inventories/dev/aws_ec2.yml role_control_plane -m ansible.builtin.setup -a 'filter=ansible_distribution*'
```

`--graph` xem đúng nhóm; `ping` của Ansible chạy Python qua SSM, không phải ICMP; `setup` đọc OS facts. Nếu chưa thấy Python trên node, dùng raw bootstrap tối thiểu có điều kiện, sau đó quay về module khai báo. Không lẫn automation host vào nhóm cần kubeadm.

## 4. D4 — Cấu trúc role và thứ tự cấu hình

```text
roles/
  os_base/                  # Kernel, sysctl, swap, time, packages
  containerd/               # CRI runtime và cgroup
  kubernetes_packages/      # Repo/key và pin packages
  control_plane/            # Kubeadm init + API security config
  worker_join/              # Join có token TTL, guard kiểm cluster
  cluster_network/          # Calico bootstrap pin
  aws_ccm/                  # Cloud identity/topology của node
  workload_identity/        # Discovery/JWKS và xác minh STS
playbooks/
  10-os-runtime.yml
  20-control-plane.yml
  30-network-ccm.yml
  40-worker-join.yml
  50-platform-bootstrap.yml
  90-upgrade-node.yml
```

Đây là tên dự kiến cho code tương lai. Thứ tự chạy có thể làm thành một orchestrating playbook nhưng vẫn cần checkpoints rõ ràng. Playbook reset/rebuild/restore tách riêng, không nằm trong đường chạy mặc định.

### 4.1 OS base

Thực hiện theo thứ tự: assert OS/CPU/account/tag; kiểm DNS và clock; quản package theo pin; tắt swap cả hiện tại lẫn fstab; nạp kernel modules; cấu hình forwarding/bridge theo CNI/runtime; chuẩn bị thư mục có quyền hạn chế; reboot nếu kernel cần đổi và chờ SSM quay lại.

Ví dụ task **đơn lẻ** trong role:

```yaml
- name: Persist kernel modules needed by the selected runtime and network
  ansible.builtin.copy:
    dest: /etc/modules-load.d/blogapp-kubernetes.conf
    content: |
      overlay
      br_netfilter
    owner: root
    group: root
    mode: '0644'
  notify: Load Kubernetes kernel modules
```

`copy` so nội dung và chỉ báo changed khi khác. File modules-load giúp nạp lại khi reboot; handler phải thực sự nạp module ở run hiện tại. Nếu sysctl task chạy ngay sau đó phụ thuộc module đã có, dùng task nạp module trước hoặc `meta: flush_handlers` tại cổng phù hợp; không chờ handler cuối play rồi chạy sysctl quá sớm.

Không tắt firewall toàn máy chỉ vì một repo ví dụ khuyên vậy. Khai báo ports cần giữa SG/host firewall phù hợp. Không cài Java/Maven/Docker Engine trên worker chỉ để chạy container Java; worker cần containerd/CRI, image đã chứa runtime ứng dụng.

### 4.2 containerd

Role cài containerd/runc đúng version, kiểm CRI plugin không bị disable, cấu hình systemd cgroup, render config bằng template theo major version. Không dùng sed thay chuỗi config 1.x cho containerd 2.x. Restart chỉ khi config đổi; nếu worker đang phục vụ, nâng runtime đi qua drain/serial.

Ví dụ task/handler minh họa:

```yaml
- name: Render reviewed containerd configuration
  ansible.builtin.template:
    src: config.toml.j2
    dest: /etc/containerd/config.toml
    owner: root
    group: root
    mode: '0644'
  notify: Restart containerd
```

Handler `Restart containerd` dùng `ansible.builtin.systemd_service` với name containerd, state restarted; task riêng bảo đảm enabled/started. Sau thay đổi, kiểm CRI socket hoạt động trước kubeadm. Kubelet và runtime phải cùng dùng systemd cgroup theo baseline.

### 4.3 Packages Kubernetes

Dùng repository `pkgs.k8s.io` của minor đã chọn, keyring signed-by và version cụ thể; giữ hold khi cần tránh apt nâng ngoài quy trình. Cài kubeadm/kubelet trên node, kubectl chỉ nơi cần; không copy nguyên lệnh apt cũ dùng `apt-key` và repository đã ngừng dùng.

Các kiểm tra trên node qua SSM:

```bash
containerd --version
kubeadm version -o short
kubelet --version
swapon --show
sysctl net.ipv4.ip_forward
sudo systemctl is-active containerd
sudo systemctl status kubelet --no-pager
```

Trước kubeadm init, kubelet có thể chưa healthy vì chưa có cấu hình cluster; không che lỗi sau init bằng giả định này. Swap phải không có entry đang bật, forwarding đúng giá trị thiết kế. Không gọi `systemctl status` thành công là đủ xác nhận CRI hoạt động; role cần health check CRI tương ứng.

## 5. D4 — kubeadm init trên control plane

### 5.1 Chuẩn bị config trước init

Kubeadm config phải bao gồm:

- Cluster name, version pin, private `controlPlaneEndpoint` qua NLB `:6443`.
- `advertiseAddress` là private IP của control plane, không phải public IP/NLB IP.
- Pod CIDR `172.20.0.0/16`, Service CIDR `172.30.0.0/16` sau kiểm overlap.
- CRI socket containerd và kubelet systemd cgroup.
- Certificate SAN chứa private API DNS; bảo đảm đường truy cập operator xác thực tên này.
- External cloud-provider flag cho kubelet theo minor, providerID theo EC2 identity hoặc CCM.
- Service-account issuer HTTPS đã định trước, signing/public key được bảo vệ.
- EncryptionConfiguration cho Secrets và audit policy/log path nội bộ; mounts/args API server đúng schema kubeadm version pin.

Không đưa một file kubeadm “dùng mọi phiên bản” vào đây. Khi viết implementation, render đúng API schema của minor pin rồi validate bằng chính kubeadm version đó. Theo [AWS CCM getting started](https://cloud-provider-aws.sigs.k8s.io/getting_started/), external cloud provider có yêu cầu node flags/tags/permissions, cần đồng bộ từ bootstrap.

### 5.2 Ví dụ guard cho init

```yaml
- name: Initialize the first control plane once
  ansible.builtin.command:
    argv:
      - kubeadm
      - init
      - --config
      - /etc/kubernetes/kubeadm-init.yaml
    creates: /etc/kubernetes/admin.conf
  no_log: true
```

`argv` tránh shell phân tích chuỗi. `creates` bỏ qua khi file đã tồn tại. `no_log` tránh stdout chứa token/cert data. Guard này chưa đủ: role còn phải kiểm cluster ID/endpoint và `/readyz`; nếu có state nhưng API hỏng, dừng để chẩn đoán, không chạy `kubeadm reset` tự động.

`admin.conf` có quyền rất cao. Giữ mode 0600, chỉ đưa tới operator/bootstrap host qua kênh bảo vệ, không log nội dung, không Git/Terraform output. Sau bootstrap tạo quyền operator phù hợp; automation worker join nên dùng quyền đọc Node và đường cấp token có kiểm soát, không phân phối admin.conf cho mọi node.

Sau init trên host có kubeconfig private hợp lệ:

```bash
kubectl --kubeconfig='<duong-dan-kubeconfig-bao-ve>' get --raw='/readyz?verbose'
kubectl --kubeconfig='<duong-dan-kubeconfig-bao-ve>' get nodes -o wide
```

API ready và NLB TCP healthy là cổng đầu tiên. Node có thể chưa Ready khi CNI/CCM chưa được cài; phải hoàn tất bước tiếp theo để kết luận cluster hoạt động.

## 6. D4 — Calico, CCM, CoreDNS và vòng bootstrap

### 6.1 Calico

Bootstrap manifest/operator đã pin; Pod CIDR khớp kubeadm; chọn VXLAN, kiểm MTU theo VPC/encapsulation và yêu cầu phiên bản. Kiểm DaemonSet/node agent, IP pools và kết nối chéo node. Không dùng AWS VPC CNI theo mặc định của EKS vì network đã chọn là Calico overlay.

### 6.2 CCM và identity

External CCM điền/kiểm providerID `aws:///<az>/<instance-id>`, labels region/AZ và xử lý node initialization. Khi external provider bật, node có thể mang taint `node.cloudprovider.kubernetes.io/uninitialized`; không xóa taint tay để che CCM hỏng.

CCM cần chạy trước khi mọi node đều untainted. Baseline dùng manifest bootstrap có tolerations cần thiết và `hostNetwork` khi cần; cung cấp role riêng bằng projected token, biến AWS region và cấu hình SDK để không phụ thuộc node role rộng. Trường hợp hostNetwork dùng token/STS trước CNI cần được kiểm riêng. Một số DaemonSet Calico cũng cần chạy qua taints bootstrap; đối chiếu manifest version đã chọn.

Để tránh vòng identity → CCM → node scheduling → identity, làm rõ thứ tự:

1. Terraform đã cấp DNS/HTTPS issuer và bucket/key infrastructure.
2. Ansible tạo signing key trước init, cấu hình issuer và xuất **chỉ public key/JWKS**.
3. Public discovery/JWKS được publish đúng URL, TLS hợp lệ và STS đọc được.
4. Terraform apply IAM OIDC provider/role trust cho CCM; manifest projected token được bootstrap trực tiếp.
5. CCM chạy với toleration/network phù hợp, node hết uninitialized, có topology/providerID.
6. Sau đó nghiệm thu identity cho CSI/CA/NTH/telemetry theo ServiceAccount riêng.

Giữ Calico/CCM do bootstrap Ansible sở hữu ở bản đầu, ghi version pin và lệnh nâng cấp. Argo CD không nhận đồng quản các resource này. Các platform còn lại sau đó do GitOps quản.

### 6.3 CoreDNS và kiểm DNS

Kubeadm cài CoreDNS/kube-proxy theo cấu hình. CoreDNS cần schedule được sau CNI/taints. Worker chưa có thì control-plane taint có thể giữ CoreDNS pending tạm thời; bootstrap network/CCM không được phụ thuộc CoreDNS đã chạy nếu nó chưa có nơi schedule. Sau hai worker join, CoreDNS phải Ready và pod phân giải được Service DNS.

## 7. D5 — Worker join và chạy lại an toàn

Role worker join thực hiện preflight OS/CRI/version, kiểm cluster endpoint/certificate, rồi nhận token ngắn hạn do control-plane automation tạo. CA hash phải xác minh; không dùng `--discovery-token-unsafe-skip-ca-verification`. Không ghi token vào AMI, user_data, Git hoặc output log.

Lệnh kubeadm để hiểu chức năng, chạy **trên control plane qua automation bảo vệ**:

```bash
sudo kubeadm token create --ttl 15m --print-join-command
```

Nó in join command chứa secret; automation phải thu vào biến có `no_log`, chuyển qua kênh được kiểm soát và hạn chế lưu lâu. Token join không phải quyền workload gọi AWS. TTL 15m là giả định vận hành cần điều chỉnh nếu bootstrap lâu, không phải credential sống mãi cho ASG.

Trên worker, role dùng JoinConfiguration đã render, `creates: /etc/kubernetes/kubelet.conf`; trước skip phải xác minh file thuộc đúng cluster. Sau join chờ Node Ready qua API và kiểm privateIP/providerID/AZ/labels. Guard file không đủ chứng minh worker healthy. Có state sai thì dừng; reset là runbook riêng.

Lệnh kiểm trên automation host:

```bash
kubectl get nodes -o wide
kubectl get nodes -L topology.kubernetes.io/zone,node.kubernetes.io/instance-type
kubectl get pods -A -o wide
kubectl get daemonsets -A
```

Chờ đúng 1 control plane và 2 workers; CNI, CCM, CoreDNS/kube-proxy hoạt động. Node names cần mapping rõ với EC2 instance ID để lifecycle workflow không drain nhầm máy.

### 7.1 Lệnh chạy playbook sau khi implementation có đủ file

```bash
ansible-playbook -i ansible/inventories/dev/aws_ec2.yml ansible/playbooks/10-os-runtime.yml --syntax-check
ansible-playbook -i ansible/inventories/dev/aws_ec2.yml ansible/playbooks/10-os-runtime.yml --limit role_control_plane --check --diff
ansible-playbook -i ansible/inventories/dev/aws_ec2.yml ansible/playbooks/10-os-runtime.yml --limit role_control_plane
ansible-playbook -i ansible/inventories/dev/aws_ec2.yml ansible/playbooks/20-control-plane.yml
ansible-playbook -i ansible/inventories/dev/aws_ec2.yml ansible/playbooks/30-network-ccm.yml
```

`--syntax-check` kiểm parse, không thử kết nối; `--check` là mô phỏng có giới hạn, task command/join không tự mô phỏng đúng; `--diff` không dùng cho secrets. `--limit` giới hạn host, không thay preflight account/env. Chạy runtime cho worker trong launch workflow rồi gọi join role; ban đầu ASG đang 0 nên không mong inventory có worker.

Sau khi bootstrap, chạy lại roles OS/runtime/control-plane ở chế độ phù hợp để chứng minh không re-init, không xoay key hay reset. Thay đổi OS/runtime trên worker đã phục vụ phải qua playbook rolling drain `serial: 1`, không chạy lại toàn bộ fleet như lúc mới dựng.

## 8. D6 — Workload identity trên self-hosted Kubernetes

### 8.1 Hai loại OIDC khác nhau

GitHub OIDC là token của workflow để Terraform gọi AWS. Kubernetes OIDC là projected ServiceAccount JWT để pod gọi STS. Cùng có OIDC nhưng issuer, subject và quyền khác nhau. Kubeadm không tự có IRSA/EKS Pod Identity.

Theo [AWS self-hosted identity setup](https://github.com/aws/amazon-eks-pod-identity-webhook/blob/master/SELF_HOSTED_SETUP.md), cần issuer discovery, JWKS, API signing config, IAM OIDC provider và role trust. Trang này có ví dụ Kubernetes rất cũ; lấy mô hình, không copy nguyên public ACL/lệnh key historical vào bản hiện hành.

Ví dụ phần pod để hiểu cơ chế, **role/trust/discovery phải có trước**:

```yaml
spec:
  serviceAccountName: ebs-csi-controller
  containers:
    - name: controller
      env:
        - name: AWS_ROLE_ARN
          value: <role-arn-cua-ebs-csi>
        - name: AWS_WEB_IDENTITY_TOKEN_FILE
          value: /var/run/blogapp-aws/token
        - name: AWS_REGION
          value: ap-southeast-1
        - name: AWS_EC2_METADATA_DISABLED
          value: 'true'
      volumeMounts:
        - name: aws-token
          mountPath: /var/run/blogapp-aws
          readOnly: true
  volumes:
    - name: aws-token
      projected:
        sources:
          - serviceAccountToken:
              path: token
              audience: sts.amazonaws.com
              expirationSeconds: 3600
```

Token được kubelet xoay; AWS SDK đổi token lấy credential ngắn hạn. Trust phải khớp `system:serviceaccount:<namespace>:ebs-csi-controller`, issuer và audience. Cấp token này cho container AWS API cần dùng, không mặc định mọi sidecar/app có token. Annotation role ARN một mình không inject token/env khi chưa có webhook; baseline có thể render token/env trực tiếp cho ít controllers, webhook là lựa chọn tự động hóa sau.

Nghiệm thu bằng pod kiểm tra AWS CLI image đã pin: role đúng gọi `sts get-caller-identity` trả đúng ARN; ServiceAccount khác không assume được role. `AWS_EC2_METADATA_DISABLED=true` tránh test vô tình pass bằng node role. Không cấp broad node role làm phương án bỏ qua identity gate.

### 8.2 CSI và metrics-server

Sau identity, cài EBS CSI qua GitOps hoặc bootstrap một lần có ownership rõ; baseline giao cho Argo ở D8. StorageClass gp3 dùng `WaitForFirstConsumer`, reclaim policy theo dữ liệu, encryption/KMS phù hợp. Test PVC bằng một workload ghi file rồi reschedule trong cùng AZ; volume EBS không tự di chuyển sang AZ khác. Cần labels AZ/providerID đúng trước cài CSI.

metrics-server cần kubelet serving cert được ký bởi CA được tin cậy với IP/DNS SAN đúng. Nếu bật kubelet `serverTLSBootstrap`, kubeadm không tự approve mọi serving CSR; thiết kế bước kiểm danh tính node rồi approve có kiểm soát hoặc approver có policy phù hợp. Không dùng `--kubelet-insecure-tls` như cách làm baseline. Nghiệm thu `kubectl top nodes` và `kubectl top pods -A` trước HPA.

## 9. D5/D11 — Hoàn thiện ASG tự join và drain

### 9.1 Vì sao cần automation ngoài cluster

ASG chỉ tạo EC2. Ansible chạy tay một lần không xử lý worker mới lúc CA scale. Dùng EventBridge → **SSM Automation runbook** → SSM Run Command trên automation host để chạy role pin cho đúng instance. Máy automation và workflow không sống trong chính cluster, nên vẫn sửa được khi Kubernetes lỗi.

Đây là thành phần cần viết, không phải tính năng module Registry tự có. Terraform quản EventBridge/runbook/IAM/hooks; Ansible repo chứa role/script entrypoint; SSM lưu execution history. Runbook pin commit của bộ bootstrap, không chạy branch bất kỳ do event cung cấp.

### 9.2 Launch workflow chi tiết

1. ASG launch hook giữ instance ở `Pending:Wait`, EventBridge chuyển instance ID/hook/ASG tới SSM Automation.
2. Workflow xác thực account, region, ASG, LT version và tag. Không cho payload chỉ định tùy ý shell command/target.
3. Đặt execution lock/dedup theo instance ID + lifecycle action token; trùng event không join hai lần.
4. Gửi lifecycle heartbeat trong lúc chờ SSM Online và trong lúc cấu hình. Retry có backoff và deadline, không chờ vô hạn.
5. Run Command tới automation host chạy playbook `--limit` chính instance ID, tải đúng source commit. Refresh inventory trước run; không dùng danh sách host cũ.
6. OS/runtime preflight → token TTL ngắn → kubeadm join → kiểm Node Ready, providerID, labels và đúng cluster.
7. Thành công gọi `CompleteLifecycleAction CONTINUE`. Lỗi đánh dấu execution failed, gửi alert và `ABANDON` cho launch để máy sai không InService.

Giới hạn lỗi liên tiếp và tạm đưa ASG về chế độ can thiệp khi bootstrap bị lỗi chung; tránh vòng tạo-xóa vô hạn tốn tiền. Thời gian join phải nhỏ hơn timeout CA đang chờ node xuất hiện; đo trước hiệu chỉnh cả hai.

Tham khảo [AWS lifecycle hooks](https://docs.aws.amazon.com/autoscaling/ec2/userguide/lifecycle-hooks.html). `heartbeat_timeout=900` không có nghĩa ASG chờ mãi nếu workflow chết. Runbook phải biết hook nào đang active và gửi heartbeat hợp lệ.

### 9.3 Termination workflow

Lắp termination hook trước bật scale-in: EventBridge → SQS + DLQ → AWS Node Termination Handler ở Queue Processor mode, role/RBAC đúng cluster. Handler map instance ID sang Node, cordon, eviction/drain theo PDB, heartbeat và complete hook khi đạt điều kiện. Xem [Node Termination Handler](https://github.com/aws/aws-node-termination-handler).

PDB không chặn một máy chết đột ngột. Trong baseline **chưa cấu hình instance lifecycle retention policy**, termination hook timeout/ABANDON vẫn dẫn đến terminate, không giữ máy sống vô hạn. Muốn dừng một instance refresh hàng loạt, phải pause/cancel orchestration trước khi đẩy thêm máy vào termination, không kỳ vọng “drain fail thì default ABANDON giữ máy sống”. AWS hiện có [instance lifecycle policies để retain khi termination action bị abandon](https://docs.aws.amazon.com/autoscaling/ec2/userguide/gracefully-handle-instance-termination.html); nếu chọn bổ sung, cần thiết kế riêng retained-instance cleanup, chi phí và tương tác CA/NTH, rồi kiểm version module/provider hỗ trợ. Không mặc nhiên policy đó đã được bật.

CA tự drain trước khi giảm ASG; handler cần phối hợp an toàn khi node đã cordon/empty. Thử riêng CA scale-in và refresh/termination ngoài CA, không chỉ một đường happy path. Khi cluster/API chết, in-cluster NTH có thể không chạy; workflow timeout/failure phải hiện trên AWS monitoring ngoài cluster.

### 9.4 Cluster Autoscaler

CA dùng workload role có quyền trên đúng ASG, autodiscovery theo cluster tags. Requests, taints, labels và AZ phải khớp template worker. Không thêm CPU target tracking hay scheduled scaling cùng sửa desired ở baseline. Không cần HPA tăng trước mọi lần scale-out: Rollouts tạo preview cũng có thể làm pod unschedulable và CA tăng node.

Test pod pending do thiếu CPU/RAM; không dùng `ImagePullBackOff` làm bài test CA. Giảm tải, kiểm PDB cho phép drain, chờ CA scale-in rồi chứng minh Terraform plan không kéo desired về 2.

## 10. Quản trị từ Mac qua private endpoint

Ban đầu chạy kubectl trên automation host có kubeconfig được bảo vệ. Nếu cần dùng Mac, chuẩn bị kubeconfig có CA và credential được cấp đúng quyền, rồi mở SSM remote-host port forwarding qua automation host:

```bash
aws ssm start-session \
  --target '<automation-instance-id>' \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters '{"host":["api.dev.<domain>"],"portNumber":["6443"],"localPortNumber":["16443"]}'
```

Host được resolve từ automation host trong VPC. Giữ terminal mở; ở terminal khác:

```bash
kubectl --kubeconfig='<kubeconfig-dev>' \
  --server=https://127.0.0.1:16443 \
  --tls-server-name='api.dev.<domain>' get nodes
```

`--tls-server-name` xác thực certificate bằng DNS nằm trong SAN dù TCP kết nối localhost. Không dùng `--insecure-skip-tls-verify`. SSM permission chỉ là quyền mở tunnel; kubeconfig vẫn phải có Kubernetes RBAC. Với UI Argo/Grafana có thể chạy `kubectl port-forward --address=127.0.0.1` trên Mac qua API tunnel; không bind UI vào `0.0.0.0` trên automation host.

## 11. Tiêu chí hoàn thành chặng cluster

- Một control plane và hai worker Ready, đúng EC2/providerID/AZ; API chỉ private.
- Re-run role không init/reset/rotate key ngoài dự kiến; runtime upgrade có drain/serial.
- Pod chéo node kết nối được; DNS, NetworkPolicy và CoreDNS đạt bài thử.
- Pod role đúng/role sai đã kiểm; không fallback node IAM để pass test.
- CSI PVC hoạt động với topology AZ; kubelet TLS và resource metrics hoạt động.
- Worker thứ ba từ ASG tự join không cần SSH/playbook tay; lỗi join không được báo thành công.
- Scale-in/refresh thử drain và hook timeout, có evidence cả failure path.
- Có đường SSM/API operator độc lập Argo và bản phục hồi signing/encryption config ở nơi bảo vệ.

Các resource platform cài sau Argo được nghiệm thu ở chương tiếp theo; chưa coi D6 là dev hoàn chỉnh.
