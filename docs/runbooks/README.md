# BlogApp dev runbooks

Các bước chạy thủ công để dựng và vận hành môi trường dev.

- [Chuẩn bị automation host](01-automation-host.md) — mở phiên SSM, cài công cụ và tạo Python virtualenv cho Ansible.
- [Publish tài liệu OIDC](02-oidc-public-documents.md) — đọc discovery/JWKS từ control plane, ghi JSON trên automation và upload S3.
