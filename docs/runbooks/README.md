# BlogApp dev runbooks

Các bước chạy thủ công để dựng và vận hành môi trường dev. Đọc [tiến độ dev](../tien-do-dev.md) trước khi mở lại môi trường; trang này ghi rõ code đã có, kết quả đã nhận và phần còn chờ.

- [Chuẩn bị automation host](01-automation-host.md) — mở phiên SSM, cài công cụ và tạo Python virtualenv cho Ansible.
- [Publish tài liệu OIDC](02-oidc-public-documents.md) — đọc discovery/JWKS từ control plane, ghi JSON trên automation và upload S3.
