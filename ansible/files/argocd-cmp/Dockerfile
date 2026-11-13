# syntax=docker/dockerfile:1
FROM alpine:3.24.1 AS download

ADD --checksum=sha256:0403a88ae20913d11b10a2467b50087721fea7581736da6b9d3992f5357fe54b \
    https://get.helm.sh/helm-v4.3.1-linux-amd64.tar.gz /tmp/helm.tar.gz
ADD --checksum=sha256:e5bec3346a873ae91d871550f3e698c1aad962aff462a080e40f25fde17fef6b \
    https://github.com/getsops/sops/releases/download/v3.13.3/sops-v3.13.3.linux.amd64 /tmp/sops

RUN tar -xzf /tmp/helm.tar.gz -C /tmp linux-amd64/helm

FROM alpine:3.24.1

COPY --from=download --chmod=0755 /tmp/linux-amd64/helm /usr/local/bin/helm
COPY --from=download --chmod=0755 /tmp/sops /usr/local/bin/sops
COPY --chmod=0755 render-blogapp /usr/local/bin/render-blogapp
RUN mkdir -p /home/argocd/cmp-server/config
COPY --chmod=0644 plugin.yaml /home/argocd/cmp-server/config/plugin.yaml

USER 999:999