# SSL / HTTPS - Cloudflare Tunnel (Full Tunnel)

> **Owner**: `ngominhkhoi05/deploy-b2c-utc2`
> **Updated**: 2026-10-13
> **Phương án**: Cloudflare Tunnel (Cách 2 - bảo mật cao nhất)

---

## 1. Tổng quan

```
+--------+    HTTPS     +-------------+   Tunnel (outbound)   +---------------------+
|  User  | -----------> |  Cloudflare | ---------------------> |  VPS (localhost)    |
+--------+              |  edge + CDN |    (cloudflared)       |  nginx :80          |
                        +-------------+                        |   |-> backend :8080 |
                                                              |   |-> frontend:3000|
                                                              +---------------------+
```

**Đặc điểm**:

- VPS **KHÔNG cần mở port 80/443** ra internet
- IP VPS **hoàn toàn ẩn** (DNS không trỏ về IP thật)
- Cloudflare tự cấp HTTPS + CDN miễn phí
- Khi deploy code mới → **không cần sửa gì** ở tunnel, tunnel chỉ là lớp proxy

**Domain dự kiến**: `vibe-mart.canluaz.io.vn` (subdomain của `canluaz.io.vn`)

**Domain gốc `canluaz.io.vn`** có thể dùng cho việc khác (blog, landing, ...) hoặc redirect về subdomain.

---

## 2. Chuẩn bị

### 2.1. Tài khoản Cloudflare

Bạn đã có tài khoản (bạn bè mời vào quản lý `canluaz.io.vn`).

### 2.2. Thông tin cần biết

| Thông tin | Giá trị | Lấy ở đâu |
|---|---|---|
| Tên miền chính | `canluaz.io.vn` | Đã có |
| Subdomain dùng cho app | `vibe-mart.canluaz.io.vn` | Tự chọn |
| IP VPS | `180.93.137.28` | (xem `docs/ci-cd.md` mục 6) |

### 2.3. Kiểm tra domain đang ở đâu

Trước khi làm, kiểm tra domain `canluaz.io.vn` đã trỏ nameserver về Cloudflare chưa:

1. Vào [dash.cloudflare.com](https://dash.cloudflare.com) → chọn `canluaz.io.vn`
2. Nếu thấy màn hình dashboard với menu **DNS**, **SSL/TLS**, ... → OK, đang ở Cloudflare
3. Nếu báo "Add a site" → domain chưa ở Cloudflare, **hỏi bạn bè trước khi làm tiếp**

---

## 3. Tạo Tunnel (Cloudflare Dashboard)

### Bước 3.1. Tạo tunnel

1. Đăng nhập Cloudflare → chọn account của bạn
2. Vào **Zero Trust** (hoặc **Networks** → **Tunnels**)
   - URL: `https://one.dash.cloudflare.com/.../networks/tunnels`
3. Bấm **Create a tunnel**
4. Chọn **Cloudflared** → **Next**
5. Đặt tên tunnel: `vibe-mart-vps` (tên bất kỳ, dễ nhớ)
6. Bấm **Save tunnel**

### Bước 3.2. Lưu tunnel token

Sau khi tạo, Cloudflare hiện ra màn hình "Install and run a connector". Có 1 dòng lệnh dạng:

```bash
cloudflared service install <LONG_TOKEN_STRING>
```

**Copy token này** (rất dài, dạng `eyJhIjoi...`). Đây là thứ ta sẽ paste vào VPS.

> **QUAN TRỌNG**: KHÔNG share token này công khai (GitHub, screenshot, chat public). Nó cho phép ai có nó kết nối tunnel của bạn.

### Bước 3.3. Cấu hình Public Hostname (route domain → service)

Trong cùng trang cấu hình tunnel, thêm **Public Hostnames**:

| Subdomain | Domain | Service | Type |
|---|---|---|---|
| `vibe-mart` | `canluaz.io.vn` | `http://nginx:80` | HTTP |

Nghĩa là: ai truy cập `https://vibe-mart.canluaz.io.vn` → Cloudflare tunnel sẽ gửi request về VPS, gọi `http://nginx:80` (nginx container trong Docker).

Bấm **Save tunnel**.

---

## 4. Cài đặt Cloudflared trên VPS

### Bước 4.1. SSH vào VPS

```bash
ssh root@180.93.137.28
```

### Bước 4.2. Cài cloudflared

**Ubuntu/Debian**:

```bash
# Thêm Cloudflare GPG key
mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
  | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null

# Thêm repo
echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(lsb_release -cs) main" \
  | tee /etc/apt/sources.list.d/cloudflared.list

# Cài
apt-get update && apt-get install -y cloudflared
```

Kiểm tra:

```bash
cloudflared --version
# Kỳ vọng: cloudflared version 2024.x.x
```

### Bước 4.3. Cài tunnel như systemd service

Thay `<TOKEN>` bằng token đã copy ở Bước 3.2:

```bash
cloudflared service install <TOKEN>
```

Lệnh này sẽ:

- Tạo file `/etc/systemd/system/cloudflared.service`
- Enable + start service tự động
- Tự restart khi VPS reboot

### Bước 4.4. Kiểm tra service

```bash
systemctl status cloudflared
# Kỳ vọng: active (running)

journalctl -u cloudflared -f
# Xem log real-time
```

---

## 5. Cấu hình Nginx (chỉ listen localhost)

Vì giờ tunnel đã nhận HTTPS từ Cloudflare và forward về VPS dưới dạng HTTP, nginx chỉ cần listen port 80 cho localhost (không cần SSL).

### Bước 5.1. Sửa `docker-compose.yml`

Trong repo `deploy-b2c-utc2`, sửa phần ports của service `nginx`:

```yaml
nginx:
  # ... (giữ nguyên phần khác)
  ports:
    # Bỏ public port 80, chỉ bind localhost.
    # Cloudflared (host) sẽ gọi vào localhost:80 → nginx container.
    - "127.0.0.1:80:80"
  # ...
```

**Lưu ý**: Nếu trước đó nginx bind `80:80` (public), đổi thành `127.0.0.1:80:80` để chỉ localhost gọi được.

### Bước 5.2. (Tuỳ chọn) Thêm server_name cho nginx

Trong `nginx/default.conf`, sửa dòng `server_name _;` thành:

```nginx
server {
    listen 80;
    server_name vibe-mart.canluaz.io.vn;
    # ... (giữ nguyên phần còn lại)
}
```

> **Lưu ý**: Sửa này không bắt buộc nếu bạn không có site khác dùng chung VPS. Nginx mặc định `server_name _;` vẫn hoạt động.

### Bước 5.3. Rebuild + restart

```bash
cd /opt/flash-sale/deploy-b2c-utc2
docker compose up -d --no-deps nginx
```

Hoặc nếu muốn restart toàn bộ stack:

```bash
docker compose down && docker compose up -d
```

### Bước 5.4. Mở firewall cho cloudflared (nếu dùng UFW)

```bash
# Cloudflared KHÔNG cần inbound port nào (vì nó kết nối outbound).
# Nhưng nếu bạn dùng UFW, cần cho phép outbound HTTPS:
ufw allow out 443/tcp
ufw reload
```

---

## 6. Kiểm tra

### Bước 6.1. Test tunnel status

```bash
# Trên VPS
systemctl status cloudflared
# Phải thấy: active (running)

# Test tunnel hoạt động
curl -H "Host: vibe-mart.canluaz.io.vn" http://127.0.0.1/
# Phải trả HTML của Next.js (status 200)
```

### Bước 6.2. Test từ browser

1. Đợi 1-2 phút cho Cloudflare propagate
2. Mở browser, vào `https://vibe-mart.canluaz.io.vn`
3. Kỳ vọng:
   - Có ổ khoá (HTTPS hợp lệ)
   - Trang chủ Next.js hiển thị
   - Không có cảnh báo SSL

### Bước 6.3. Test các path quan trọng

| URL test | Kỳ vọng |
|---|---|
| `https://vibe-mart.canluaz.io.vn/` | Next.js trang chủ |
| `https://vibe-mart.canluaz.io.vn/api/v1/products` | JSON từ backend (có thể trả 401/403 - OK) |
| `https://vibe-mart.canluaz.io.vn/actuator/health` | `{"status":"UP"}` |
| `https://vibe-mart.canluaz.io.vn/ws/info` | SockJS info response |

### Bước 6.4. Verify IP VPS đã ẩn

```bash
# Từ máy local, check DNS
nslookup vibe-mart.canluaz.io.vn
# Kỳ vọng: trả IP của Cloudflare (172.67.x.x hoặc 104.x.x.x)
# KHÔNG phải 180.93.137.28
```

---

## 7. Cập nhật Frontend env (nếu cần)

Frontend cần biết domain mới để build đúng URL.

### Bước 7.1. Sửa `NEXT_PUBLIC_SITE_URL`

Trong repo `flash-sale-b2c-fe`, sửa env:

```bash
NEXT_PUBLIC_SITE_URL=https://vibe-mart.canluaz.io.vn
```

### Bước 7.2. Cập nhật GitHub Secrets

Vào repo `ngominhkhoi05/flash-sale-b2c-fe` → **Settings** → **Secrets** → **Actions**:

- Sửa secret `NEXT_PUBLIC_SITE_URL` (nếu có) thành `https://vibe-mart.canluaz.io.vn`

### Bước 7.3. Trigger rebuild FE

```bash
cd /path/to/flash-sale-b2c-fe
git commit --trailer "Co-authored-by: Cursor <cursoragent@cursor.com>" --allow-empty -m "ci: trigger rebuild with new SITE_URL"
git push origin dev
```

CI sẽ tự build & deploy lại FE với URL mới.

---

## 8. Bảo trì

### 8.1. Cập nhật cloudflared

```bash
# Ubuntu/Debian
apt-get update && apt-get upgrade cloudflared
systemctl restart cloudflared
```

### 8.2. Rotate tunnel token (bảo mật)

Nếu token bị lộ:

1. Vào Cloudflare → **Zero Trust** → **Networks** → **Tunnels**
2. Chọn tunnel `vibe-mart-vps`
3. Bấm **Rotate token** → copy token mới
4. Trên VPS: `cloudflared service install <TOKEN_MỚI>`
5. Service tự restart với token mới

### 8.3. Tạm tắt tunnel

```bash
# Trên VPS
systemctl stop cloudflared
# User sẽ không truy cập được site cho đến khi start lại
systemctl start cloudflared
```

---

## 9. Troubleshooting

### 9.1. Tunnel không connect được

**Triệu chứng**: `systemctl status cloudflared` báo `activating` hoặc restart liên tục.

**Cách xử lý**:

```bash
# Xem log chi tiết
journalctl -u cloudflared -n 100 --no-pager

# Kiểm tra token
cat /etc/systemd/system/cloudflared.service
# Tìm dòng ExecStart có token không? Format đúng không?

# Nếu token sai, reinstall
cloudflared service uninstall
cloudflared service install <TOKEN_ĐÚNG>
systemctl daemon-reload
systemctl start cloudflared
```

### 9.2. 502 Bad Gateway từ Cloudflare

**Triệu chứng**: User vào `https://vibe-mart.canluaz.io.vn` thấy 502.

**Cách xử lý**:

```bash
# 1. Kiểm tra nginx container có chạy không
docker ps | grep nginx
# Kỳ vọng: có "Up X minutes"

# 2. Kiểm tra backend + frontend
docker ps | grep -E "backend|frontend"

# 3. Test trực tiếp trên VPS
curl -H "Host: vibe-mart.canluaz.io.vn" http://127.0.0.1/
# Nếu OK ở đây mà user thấy 502 → tunnel/nginx bị sai

# 4. Nếu curl fail → check nginx log
docker logs flash-sale-b2c-nginx --tail 50
```

### 9.3. 521 Web Server Is Down (từ Cloudflare)

**Triệu chứng**: Cloudflare báo "Error 521 - Web server is down".

**Nguyên nhân**: Tunnel không reach được service backend.

**Cách xử lý**:

```bash
# 1. Kiểm tra tunnel status
systemctl status cloudflared
# Nếu không active → xem 9.1

# 2. Kiểm tra service URL trong tunnel config
# Vào Cloudflare dashboard → Tunnels → vibe-mart-vps → Public Hostname
# Đảm bảo: Service = http://nginx:80 (KHÔNG phải localhost hay IP VPS)

# 3. Nếu service URL sai → sửa trong dashboard
# Cloudflare KHÔNG cần reconnect tunnel, chỉ cần save
```

### 9.4. SSL handshake failed / ERR_TOO_MANY_REDIRECTS

**Triệu chứng**: User vào site thấy redirect loop hoặc SSL error.

**Cách xử lý**:

Vào Cloudflare → **SSL/TLS** → **Overview**:

- Chọn **Flexible** (khuyến nghị khi dùng tunnel vì nginx không có cert)
  - Cloudflare ↔ User: HTTPS
  - Cloudflare ↔ VPS (qua tunnel): HTTP
- **KHÔNG chọn Full / Full (Strict)** vì nginx chưa có cert → sẽ fail

### 9.5. WebSocket không hoạt động (Flash Sale realtime)

**Triệu chứng**: `/ws` endpoint không connect được, Flash Sale realtime bị lỗi.

**Cách xử lý**:

1. Vào Cloudflare → **SSL/TLS** → **Edge Certificates** → **Minimum TLS Version**: đặt về **TLS 1.2** (không phải 1.3-only)
2. Vào **Network** → **WebSockets**: bật **ON**
3. Restart tunnel: `systemctl restart cloudflared`

### 9.6. Domain chưa trỏ về Cloudflare

**Triệu chứng**: Vào `https://vibe-mart.canluaz.io.vn` thấy lỗi DNS hoặc không load.

**Cách xử lý**:

```bash
# Check nameserver
nslookup -type=ns canluaz.io.vn
# Kỳ vọng: trả về ns1.cloudflare.com, ns2.cloudflare.com
# Nếu trả nameserver khác → domain chưa ở Cloudflare
```

→ Hỏi bạn bè (chủ domain) vào nhà cung cấp domain đổi nameserver.

### 9.7. IP VPS vẫn bị lộ

**Triệu chứng**: `nslookup vibe-mart.canluaz.io.vn` trả về IP VPS thật.

**Nguyên nhân**: DNS record chưa bật proxy (đám mây xám thay vì cam).

**Cách xử lý**:

Vào Cloudflare → **DNS** → **Records**:
- Tìm record cho `vibe-mart`
- Bấm vào **đám mây** để chuyển từ **DNS only** (xám) → **Proxied** (cam)

---

## 10. Tóm tắt các thông tin user cần cung cấp

Sau khi đọc file này, bạn cần cung cấp cho tôi:

| # | Thông tin | Cách lấy | Bắt buộc? |
|---|---|---|---|
| 1 | **Tunnel token** (string dài ~200 ký tự) | Cloudflare dashboard sau khi tạo tunnel (Bước 3.2) | Có |
| 2 | **Xác nhận domain `canluaz.io.vn` đang ở Cloudflare** | Bước 2.3 | Có |
| 3 | **IP VPS** (nếu khác `180.93.137.28`) | `curl ifconfig.me` trên VPS | Nếu đổi |
| 4 | **OS của VPS** (Ubuntu/Debian version) | `cat /etc/os-release` | Nếu khác Ubuntu/Debian |

Tôi sẽ dùng những thông tin này để:
- Viết script `install-tunnel.sh` tự động cài + cấu hình cloudflared trên VPS
- Sửa `docker-compose.yml` + `nginx/default.conf` cho phù hợp
- Verify mọi thứ chạy đúng

---

## 11. Liên quan

- `docs/ci-cd.md` - CI/CD workflow + IP VPS hiện tại
- `docker-compose.yml` - Stack hiện tại (sẽ sửa port nginx)
- `nginx/default.conf` - Nginx config hiện tại
- `flash-sale-b2c-fe/.env` - Frontend env (sẽ sửa `NEXT_PUBLIC_SITE_URL`)
