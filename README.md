# Flash Sale B2C - Deployment Guide

> Hướng dẫn triển khai **backend (Spring Boot)** + **frontend (Next.js)** + **Redis** lên VPS Ubuntu 25.04, truy cập qua IP (`http://<VPS_IP>`). Database là **Supabase Cloud** (không chạy Postgres trong Docker).
>
> ⚠️ **Tài liệu này giả định bạn đăng nhập VPS bằng user `root`** → tất cả lệnh đều **KHÔNG cần `sudo`**.

---

## Mục lục

1. [Tổng quan kiến trúc](#1-tổng-quan-kiến-trúc)
2. [Cấu trúc thư mục trên VPS](#2-cấu-trúc-thư-mục-trên-vps)
3. [Cài đặt VPS lần đầu (Ubuntu 25.04)](#3-cài-đặt-vps-lần-đầu-ubuntu-2504)
4. [Sao chép code lên VPS](#4-sao-chép-code-lên-vps)
5. [Build Docker images](#5-build-docker-images)
6. [Cấu hình biến môi trường](#6-cấu-hình-biến-môi-trường)
7. [Khởi động stack](#7-khởi-động-stack)
8. [Verify](#8-verify)
9. [Cập nhật code sau này](#9-cập-nhật-code-sau-này)
10. [Troubleshooting](#10-troubleshooting)

---

## 1. Tổng quan kiến trúc

```
+----------------------------------------------------------------+
|  VPS Ubuntu 25.04 (IP: <VPS_IP>, đăng nhập bằng root)          |
|                                                                |
|  +-----------------+                                           |
|  |   Nginx (:80)   | <-- User truy cập http://<VPS_IP>         |
|  |  reverse proxy  |                                           |
|  +--------+--------+                                           |
|           |                                                     |
|     +-----+------+---------------+----------------+            |
|     | /          | /api/* /ws/*  | /actuator      |            |
|     v            v               v                v            |
|  +---------+  +---------+    +---------+                       |
|  | Next.js |  | Backend |    | Redis   |                       |
|  |   :3000 |  | :8080   |    |  :6379  |                       |
|  | (FE)    |  | Spring  |    |         |                       |
|  +---------+  +----+----+    +---------+                       |
+----------------------------------------------------------------+
                   |                          |
                   v                          v
         +--------------------+    +--------------------+
         |  Supabase Postgres |    |     Cloudinary     |
         |  (Cloud DB)        |    |  (file storage)    |
         +--------------------+    +--------------------+
```

**Đặc điểm:**
- Truy cập qua **IP** (không cần domain, không HTTPS)
- **Redis** chạy trong container, volume persistent
- **Database** là Supabase Cloud — không tự host Postgres
- **Nginx** reverse proxy: serve frontend + proxy `/api`, `/ws` → backend
- Healthcheck qua `actuator/health` + container restart policy

---

## 2. Cấu trúc thư mục trên VPS

Vì server sẽ deploy **nhiều dự án**, tất cả dùng chung tiền tố `/opt/flash-sale/`:

```
/opt/flash-sale/
├── be/         # Repo backend  (flash-sale-b2c-UTC2)  — Spring Boot / Java 25
├── fe/         # Repo frontend (flash-sale-b2c)      — Next.js
└── deploy/     # Repo deploy    (deploy-b2c-utc2)    — compose + nginx + scripts
```

**Lưu ý đặt tên:** thư mục trên VPS là `be/`, `fe/`, `deploy/` cho gọn, nhưng tên repo local vẫn là:

| Thư mục trên VPS | Repo local (Windows) |
|---|---|
| `/opt/flash-sale/be/` | `D:\flash-sale-b2c-UTC2` |
| `/opt/flash-sale/fe/` | `D:\flash-sale-b2c` |
| `/opt/flash-sale/deploy/` | `D:\deploy-b2c-utc2` |

---

## 3. Cài đặt VPS lần đầu (Ubuntu 25.04)

**Yêu cầu:** VPS Ubuntu 25.04 LTS, đã đăng nhập bằng **root**.

### 3.1 Cài `git`

```bash
apt update && apt upgrade -y
apt install -y git curl ca-certificates
```

### 3.2 Cài Docker Engine + Compose plugin

```bash
# Cách chính thức của Docker (tự cài repo, nhận được update)
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
> /etc/apt/sources.list.d/docker.list

apt update
apt install -y docker-ce docker-ce-cli containerd.io \
                docker-buildx-plugin docker-compose-plugin

systemctl enable --now docker
```

**Verify:**
```bash
docker --version
docker compose version
systemctl is-active docker     # → active
```

### 3.3 Cài `redis` trên HOST

> **Vì sao vẫn cài Redis ở host dù Docker Compose đã có Redis container?**
>
> 1. **Debug nhanh** khi chưa bật stack: chạy `redis-server` host để test Lua script (`reserve_stock.lua`) mà không cần dựng cả compose.
> 2. **Fallback** khi container Redis gặp sự cố.
> 3. Dev local chạy backend với profile `local` (Redis host = `localhost`).
>
> ⚠️ **Không xung đột port:** trong `docker-compose.yml`, Redis **không** publish port ra host (chỉ dùng internal Docker network), nên cài host Redis ở `6379` là an toàn.

```bash
apt install -y redis-server
systemctl enable --now redis-server
systemctl is-active redis-server    # → active
redis-cli ping                     # → PONG
```

> Nếu sau này không dùng host Redis: `systemctl disable --now redis-server`

### 3.4 Tạo thư mục chứa 3 repo

```bash
mkdir -p /opt/flash-sale/{be,fe,deploy}
ls -la /opt/flash-sale
```

> **Tùy chọn — tạo user riêng (khuyến nghị an toàn hơn root trực tiếp):**
> ```bash
> adduser deployer
> usermod -aG docker deployer        # quyền docker không cần sudo
> chown -R deployer:deployer /opt/flash-sale
> ```
> Nhưng nếu bạn đã quyết định dùng `root` thì bỏ qua, root đã có toàn quyền.

### 3.5 Firewall

```bash
apt install -y ufw
ufw allow 22/tcp      # SSH
ufw allow 80/tcp      # HTTP
ufw allow 443/tcp     # HTTPS (nếu sau này gắn domain)
ufw enable
```

> Port 8080 (backend) và 6379 (Redis) **không cần mở ra ngoài** — chỉ Nginx port 80 là public.

---

## 4. Sao chép code lên VPS

### 4.1 Cách 1: `scp` từ Windows

```bash
# Trên Windows PowerShell
scp -r D:\flash-sale-b2c-UTC2 root@<VPS_IP>:/opt/flash-sale/be_tmp
scp -r D:\flash-sale-b2c     root@<VPS_IP>:/opt/flash-sale/fe_tmp
scp -r D:\deploy-b2c-utc2    root@<VPS_IP>:/opt/flash-sale/deploy_tmp
```

**Trên VPS (đổi tên về tên chuẩn):**
```bash
cd /opt/flash-sale
rm -rf be fe deploy
mv be_tmp be
mv fe_tmp fe
mv deploy_tmp deploy
```

> ⚠️ `scp -r` chuyển cả `node_modules/` (FE) và `build/` + `.gradle/` (BE) → **rất chậm** (hàng trăm MB). Có thể loại trước:
> ```powershell
> # Windows PowerShell — tạo bản sạch trước khi scp
> robocopy D:\flash-sale-b2c D:\tmp\fe /E /XD node_modules .next .git
> robocopy D:\flash-sale-b2c-UTC2 D:\tmp\be /E /XD build .gradle bin .git
> robocopy D:\deploy-b2c-utc2 D:\tmp\deploy /E /XD .git
> ```

### 4.2 Cách 2 (khuyến nghị): `git clone` trên VPS

```bash
# Trên VPS
cd /opt/flash-sale
rm -rf be fe deploy

git clone <BE_REPO_URL>     be
git clone <FE_REPO_URL>     fe
git clone <DEPLOY_REPO_URL> deploy
```

**Trên Windows (để có repo local để sửa code):**
```bash
cd D:\flash-sale-b2c-UTC2 && git add -A && git commit -m "..." && git push
cd D:\flash-sale-b2c     && git add -A && git commit -m "..." && git push
cd D:\deploy-b2c-utc2    && git add -A && git commit -m "..." && git push
```

---

## 5. Build Docker images

### 5.1 Build Backend

```bash
cd /opt/flash-sale/be

docker build -t flash-sale-b2c-backend:latest \
    -f /opt/flash-sale/deploy/docker/backend.Dockerfile \
    /opt/flash-sale/be/
```

> Lần đầu: ~5 phút (download Gradle dependencies ~300MB).

### 5.2 Build Frontend

```bash
cd /opt/flash-sale/fe

# BẮT BUỘC truyền build-arg NEXT_PUBLIC_API_BASE
docker build -t flash-sale-b2c-frontend:latest \
    --build-arg NEXT_PUBLIC_API_BASE=/api/v1 \
    -f /opt/flash-sale/deploy/docker/frontend.Dockerfile \
    /opt/flash-sale/fe/
```

> ⚠️ **Bắt buộc phải truyền `--build-arg NEXT_PUBLIC_API_BASE=/api/v1`.**
> Code FE đọc `process.env.NEXT_PUBLIC_API_BASE` (`lib/api/client.ts`) — **không phải** `NEXT_PUBLIC_API_BASE_URL` như trong `.env.example`.
> Nếu không truyền, FE fallback về `http://localhost:8080/api/v1` → trình duyệt của người dùng gọi vào localhost của họ → trang trắng.

### 5.3 Verify

```bash
docker images | grep flash-sale-b2c
# flash-sale-b2c-backend    latest    abc123...    ~500MB
# flash-sale-b2c-frontend   latest    def456...    ~300MB
```

---

## 6. Cấu hình biến môi trường

```bash
cd /opt/flash-sale/deploy
cp .env.example .env
cp redis.env.example redis.env

nano .env        # điền giá trị thật
nano redis.env   # đặt REDIS_PASSWORD (nếu muốn bảo vệ Redis)
```

**Biến BẮT BUỘC phải điền trong `.env`:**

| Biến | Ví dụ / Ghi chú |
|---|---|
| `VPS_IP` | `172.20.10.5` |
| `DB_HOST` | `aws-0-ap-southeast-1.pooler.supabase.com` |
| `DB_PORT` | `6543` (pooler) hoặc `5432` (direct) |
| `DB_NAME` | `postgres` |
| `DB_USERNAME` | `postgres.abc123` |
| `DB_PASSWORD` | `<db_password>` |
| `JWT_SECRET` | `openssl rand -base64 64` (tối thiểu 32 ký tự) |
| `CORS_ALLOWED_ORIGINS` | `http://<VPS_IP>` |

> ⚠️ **KHÔNG viết comment inline sau dấu `=`** trong `.env`. Ví dụ `JWT_EXPIRATION_MS=3600000  # 1 giờ` sẽ khiến giá trị bị đọc thành chuỗi có khoảng trắng. Comment phải nằm trên **dòng riêng**.

**Các biến sau KHÔNG có code đọc → có thể xoá hoặc bỏ trống:**
- `CLOUDINARY_*` — repo BE chưa có code Cloudinary
- `PAYMENT_GATEWAY_*` — repo BE chưa có code payment gateway
- `WS_ENDPOINT` — không có chỗ nào đọc biến này

> ⚠️ **Lưu ý về CORS:** `CORS_ALLOWED_ORIGINS` hiện **CHƯA** được backend đọc — code đọc property `cors.allowed-origins` (`CorsConfig.java`) mà `application-prod.yaml` chưa map biến môi trường này vào. Vì FE và BE cùng origin qua Nginx nên vẫn chạy bình thường. Xem [§10 Troubleshooting](#10-troubleshooting) nếu cần bật CORS.

---

## 7. Khởi động stack

```bash
cd /opt/flash-sale/deploy
chmod +x scripts/*.sh
./scripts/deploy.sh
```

Script sẽ:
1. Kiểm tra `.env` và `redis.env` tồn tại
2. Tạo Docker network `flash-sale-net`
3. Khởi động 4 containers: `redis`, `backend`, `frontend`, `nginx`

**Kiểm tra trạng thái:**
```bash
cd /opt/flash-sale/deploy
docker compose ps

# NAME                    STATUS              PORTS
# flash-sale-b2c-redis    Up (healthy)        6379/tcp
# flash-sale-b2c-backend  Up (healthy)        127.0.0.1:8080->8080
# flash-sale-b2c-frontend Up (healthy)        3000/tcp
# flash-sale-b2c-nginx    Up                  0.0.0.0:80->80
```

> **Lưu ý:** nếu `nginx` không lên, nguyên nhân gần như luôn là **backend không healthy** (compose dùng `depends_on: condition: service_healthy`). Xem [§10.4](#104-nginx-không-start).

---

## 8. Verify

### 8.1 Truy cập từ trình duyệt

```
http://<VPS_IP>
```
→ Trang chủ Next.js phải load được.

### 8.2 Health check tổng thể

```bash
cd /opt/flash-sale/deploy
./scripts/check-health.sh
```

### 8.3 Test API

```bash
curl http://<VPS_IP>/actuator/health     # → {"status":"UP"}
curl http://<VPS_IP>/api/v1/products     # → JSON
```

### 8.4 Swagger UI

```
http://<VPS_IP>/swagger-ui.html
```

---

## 9. Cập nhật code sau này

### 9.1 Khi sửa backend

```bash
# Local (Windows)
cd D:\flash-sale-b2c-UTC2 && git add -A && git commit -m "..." && git push
```

**Trên VPS:**
```bash
cd /opt/flash-sale/be && git pull

docker build -t flash-sale-b2c-backend:latest \
    -f /opt/flash-sale/deploy/docker/backend.Dockerfile \
    /opt/flash-sale/be/

cd /opt/flash-sale/deploy
docker compose up -d --no-deps backend
```

### 9.2 Khi sửa frontend

```bash
# Local (Windows)
cd D:\flash-sale-b2c && git add -A && git commit -m "..." && git push
```

**Trên VPS:**
```bash
cd /opt/flash-sale/fe && git pull

docker build -t flash-sale-b2c-frontend:latest \
    --build-arg NEXT_PUBLIC_API_BASE=/api/v1 \
    -f /opt/flash-sale/deploy/docker/frontend.Dockerfile \
    /opt/flash-sale/fe/

cd /opt/flash-sale/deploy
docker compose up -d --no-deps frontend
```

### 9.3 Khi sửa Nginx config

```bash
cd /opt/flash-sale/deploy
docker compose restart nginx
```

### 9.4 Khi đổi secret trong `.env` (DB, JWT...)

```bash
cd /opt/flash-sale/deploy
docker compose up -d --force-recreate backend
```

### 9.5 Deploy dự án khác trên cùng server

Mỗi dự án dùng **tiền tố thư mục riêng** + **tên network/container riêng** để không đụng nhau:

```
/opt/flash-sale/        → network: flash-sale-net,     container: flash-sale-b2c-*
/opt/<project-khác>/    → network: <project>-net,      container: <project>-*
```

Đổi 3 chỗ trong `docker-compose.yml` của dự án mới:
```yaml
container_name: <project>-redis
networks:
  <project>-net:
    name: <project>-net
```

---

## 10. Troubleshooting

### 10.1 Backend build fail: `gradle.properties: not found`

```bash
# Nguyên nhân: backend.Dockerfile có dòng COPY gradle.properties
# nhưng repo BE hiện KHÔNG có file này → build fail ngay.
cd /opt/flash-sale/be
touch gradle.properties
# hoặc sửa Dockerfile: bỏ gradle.properties khỏi dòng COPY
```

### 10.2 Frontend trang trắng / gọi `localhost:8080`

```bash
# Nguyên nhân: build thiếu --build-arg NEXT_PUBLIC_API_BASE
cd /opt/flash-sale/deploy
docker compose logs frontend
```

**Cách sửa:**
```bash
cd /opt/flash-sale/fe
docker build -t flash-sale-b2c-frontend:latest \
    --build-arg NEXT_PUBLIC_API_BASE=/api/v1 \
    -f /opt/flash-sale/deploy/docker/frontend.Dockerfile \
    /opt/flash-sale/fe/

cd /opt/flash-sale/deploy && docker compose up -d --no-deps frontend
```

### 10.3 Backend không healthy → `/actuator/health` trả 404

```bash
cd /opt/flash-sale/deploy
docker compose logs backend | tail -50
```

**Kiểm tra trực tiếp:**
```bash
docker exec flash-sale-b2c-backend wget -qO- http://localhost:8080/actuator/health
```

> ⚠️ **Hiện tại repo BE CHƯA có `spring-boot-starter-actuator`** trong `build.gradle` và `application-prod.yaml` chưa có mục `management:`.
> Nếu đúng vậy, `/actuator/health` sẽ trả **404** → Docker healthcheck fail → backend bị đánh dấu unhealthy → `nginx` không start.
>
> **Cách sửa (cần thêm vào repo BE, commit lại):**
> ```groovy
> // build.gradle
> implementation 'org.springframework.boot:spring-boot-starter-actuator'
> ```
> ```yaml
> # application-prod.yaml
> management:
>   endpoints:
>     web:
>       exposure:
>         include: health,info
>   endpoint:
>     health:
>       show-details: never
> ```
> Hoặc **tạm thời bỏ qua** bằng cách đổi healthcheck trong `docker-compose.yml`:
> ```yaml
> backend:
>   healthcheck:
>     test: ["CMD-SHELL", "wget -q --spider http://localhost:8080/swagger-ui.html || exit 1"]
> ```

### 10.4 `nginx` không start (Restarting / Exit)

**Nguyên nhân gần như luôn là backend unhealthy**, vì compose có:
```yaml
nginx:
  depends_on:
    backend:
      condition: service_healthy
```

```bash
cd /opt/flash-sale/deploy
docker compose logs backend | tail -50      # ← xem lỗi thật ở đây
```

**Các nguyên nhân phổ biến:**
1. `/actuator/health` 404 (thiếu actuator) → xem [§10.3](#103-backend-không-healthy--actuatorhealth-trả-404)
2. DB connect fail (Supabase cần `sslmode=require`)
3. `JWT_SECRET` rỗng hoặc < 32 ký tự → `JwtProperties.validate()` throw → app không start
4. Redis không kết nối được

**Bypass để xem log backend:**
```bash
cd /opt/flash-sale/deploy
docker compose up -d backend
docker compose logs -f backend
```

### 10.5 Backend không kết nối được DB

```bash
cd /opt/flash-sale/deploy
docker compose logs backend | grep -i "connection\|ssl\|error"
```

**Lỗi thường gặp:**
- `"connection refused"` → sai `DB_HOST`, hoặc Supabase project đang pause
- `"password authentication failed"` → sai `DB_USERNAME` / `DB_PASSWORD`
- `"SSL error"` → thiếu `sslmode=require`

> ⚠️ **Cần xác nhận:** `application-prod.yaml` hiện khai báo
> `url: jdbc:postgresql://${DB_HOST}:${DB_PORT}/${DB_NAME}` — **không có `?sslmode=require`**.
> Nếu Supabase bắt buộc SSL, cần thêm vào repo BE:
> ```yaml
> url: jdbc:postgresql://${DB_HOST}:${DB_PORT}/${DB_NAME}?sslmode=require
> ```
> (profile `local` đã có `?sslmode=require` — xem `application-local.yaml`.)

### 10.6 Redis không hoạt động

```bash
cd /opt/flash-sale/deploy

# Redis trong container
docker exec flash-sale-b2c-redis redis-cli ping     # → PONG

# Nếu có password (đọc từ redis.env)
docker exec flash-sale-b2c-redis redis-cli -a <REDIS_PASSWORD> ping

# Redis trên HOST (nếu bạn cài ở §3.3)
redis-cli ping
```

> ⚠️ **Lưu ý:** `scripts/check-health.sh` hiện đọc `REDIS_PASSWORD` từ `.env`, nhưng password giờ nằm trong `redis.env` (tách riêng để không lộ secret vào container Redis). Nếu script báo sai, sửa dòng đọc trong script thành:
> ```bash
> REDIS_PASSWORD=$(grep '^REDIS_PASSWORD=' redis.env | cut -d= -f2-)
> ```

### 10.7 CORS bị chặn khi FE gọi API

```bash
cd /opt/flash-sale/deploy
grep CORS_ALLOWED_ORIGINS .env
```

> ⚠️ Backend hiện đọc property `cors.allowed-origins` (`CorsConfig.java`), nhưng `application-prod.yaml` chưa map biến môi trường này. Nếu cần bật CORS, thêm vào `application-prod.yaml`:
> ```yaml
> cors:
>   allowed-origins: ${CORS_ALLOWED_ORIGINS:http://localhost:3000}
> ```

### 10.8 WebSocket realtime không hoạt động

- Nginx đã có `location /ws` với `Upgrade` headers ✓
- FE connect: `ws://<VPS_IP>/ws?token=<JWT>` ✓
- Verify:
```bash
curl -i http://<VPS_IP>/ws/info
```

> ⚠️ Lưu ý: FE dùng **SockJS** (`sockjs-client`), nên URL thực tế qua SockJS là `http://<VPS_IP>/ws/info` (HTTP polling handshake), không phải raw WebSocket thuần.

### 10.9 Out of memory khi build

```bash
free -h

# Tạo swap 4G
fallocate -l 4G /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile

# Giữ swap sau reboot
echo '/swapfile none swap sw 0 0' >> /etc/fstab
```

### 10.10 Đổi tên/move thư mục trong `docker-compose.yml`

`nginx/default.conf` được mount bằng **đường dẫn tương đối** (`./nginx/default.conf`). Vì vậy **luôn `cd /opt/flash-sale/deploy` trước khi chạy `docker compose`**, nếu không sẽ báo lỗi mount file không tồn tại.

---

## Hỗ trợ

```bash
cd /opt/flash-sale/deploy
./scripts/check-health.sh > health-report.txt
docker compose logs --no-color > all-logs.txt
```

Gửi 2 file trên khi báo lỗi.
