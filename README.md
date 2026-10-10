# Flash Sale B2C - Deployment Guide

> Hướng dẫn triển khai **backend (Spring Boot)** + **frontend (Next.js)** + **Redis** lên VPS Ubuntu 25.04, truy cập qua IP (`http://<VPS_IP>`). Database là **Supabase Cloud** (không chạy Postgres trong Docker).
>
> ⚠️ **Tài liệu này giả định bạn đăng nhập VPS bằng user `root`** → tất cả lệnh đều **KHÔNG cần `sudo`**.

---

## Trạng thái tài liệu

> 📅 **Cập nhật: 10/10/2026** — Đổi repo frontend sang `trangkimdat2005/flash-sale-b2c-fe` (owner mới). Đồng bộ Dockerfile dùng đúng tên biến môi trường mà FE mới đang đọc (`NEXT_PUBLIC_API_URL` + `NEXT_PUBLIC_WS_URL`).
>
> **Đã xử lý các lỗi từng gây deploy fail:**
> - ✅ Actuator đã có trong `build.gradle` + `application-prod.yaml` đã có mục `management:` → `/actuator/health` hoạt động
> - ✅ `SecurityConfig.java` đã `permitAll()` cho `/actuator/health` và `/actuator/info`
> - ✅ `?sslmode=require` đã có trong `application-prod.yaml` (profile `prod`)
> - ✅ `cors.allowed-origins` đã map từ biến môi trường `CORS_ALLOWED_ORIGINS`
> - ✅ `docker/backend.Dockerfile` xử lý thiếu `gradle.properties` bằng `COPY . ./` + `RUN rm -f` → build thành công dù repo BE chưa có file này
>
> **Chưa có code BE đọc** (biến `.env` bị bỏ qua): `WS_ENDPOINT`, `PAYMENT_GATEWAY_*`, `CLOUDINARY_*`
>
> **Còn tồn tại:** repo BE chưa có file `gradle.properties` — không ảnh hưởng build (Dockerfile đã xử lý).
>
> ⚠️ Khi có thay đổi mới ở repo BE, cập nhật lại mục này.

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
├── flash-sale-b2c-UTC2/   # Repo backend  (NgocHiep-Nguyen/...)       — Spring Boot / Java 25
├── flash-sale-b2c-fe/     # Repo frontend (trangkimdat2005/...)      — Next.js
└── deploy-b2c-utc2/       # Repo deploy    (ngominhkhoi05/...)       — compose + nginx + scripts
```

**Lưu ý đặt tên:** thư mục trên VPS trùng **đúng tên repo** để tránh nhầm khi debug. Tên repo local trên Windows cũng vậy — chỉ khác ở chữ hoa/thường và dấu gạch chéo.

| Thư mục trên VPS | Repo local (Windows) | GitHub |
|---|---|---|
| `/opt/flash-sale/flash-sale-b2c-UTC2/` | `D:\flash-sale-b2c-UTC2` | `NgocHiep-Nguyen/flash-sale-b2c-UTC2` |
| `/opt/flash-sale/flash-sale-b2c-fe/`   | `D:\flash-sale-b2c-fe`   | `trangkimdat2005/flash-sale-b2c-fe` |
| `/opt/flash-sale/deploy-b2c-utc2/`    | `D:\deploy-b2c-utc2`     | `ngominhkhoi05/deploy-b2c-utc2` |

> **Repo frontend cũ `flash-sale-b2c/` (owner `ngominhkhoi05`)** đã ngừng dùng từ 2026-10-10. Sau khi chuyển sang repo mới, chạy `scripts/remove-old-frontend.sh` để dọn folder + Docker image cũ.

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
mkdir -p /opt/flash-sale/{flash-sale-b2c-UTC2,flash-sale-b2c,deploy-b2c-utc2}
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
scp -r D:\flash-sale-b2c-UTC2 root@<VPS_IP>:/opt/flash-sale/flash-sale-b2c-UTC2_tmp
scp -r D:\flash-sale-b2c-fe   root@<VPS_IP>:/opt/flash-sale/flash-sale-b2c-fe_tmp
scp -r D:\deploy-b2c-utc2    root@<VPS_IP>:/opt/flash-sale/deploy-b2c-utc2_tmp
```

**Trên VPS (đổi tên về tên chuẩn):**
```bash
cd /opt/flash-sale
rm -rf flash-sale-b2c-UTC2 flash-sale-b2c-fe deploy-b2c-utc2
mv flash-sale-b2c-UTC2_tmp flash-sale-b2c-UTC2
mv flash-sale-b2c-fe_tmp   flash-sale-b2c-fe
mv deploy-b2c-utc2_tmp    deploy-b2c-utc2
```

> ⚠️ `scp -r` chuyển cả `node_modules/` (FE) và `build/` + `.gradle/` (BE) → **rất chậm** (hàng trăm MB). Có thể loại trước:
> ```powershell
> # Windows PowerShell — tạo bản sạch trước khi scp
> robocopy D:\flash-sale-b2c-fe   D:\tmp\flash-sale-b2c-fe   /E /XD node_modules .next .git
> robocopy D:\flash-sale-b2c-UTC2 D:\tmp\flash-sale-b2c-UTC2 /E /XD build .gradle bin .git
> robocopy D:\deploy-b2c-utc2     D:\tmp\deploy-b2c-utc2     /E /XD .git
> ```

### 4.2 Cách 2 (khuyến nghị): `git clone` trên VPS

```bash
# Trên VPS
cd /opt/flash-sale
rm -rf flash-sale-b2c-UTC2 flash-sale-b2c-fe deploy-b2c-utc2

git clone https://github.com/NgocHiep-Nguyen/flash-sale-b2c-UTC2.git flash-sale-b2c-UTC2
git clone https://github.com/trangkimdat2005/flash-sale-b2c-fe.git         flash-sale-b2c-fe
git clone https://github.com/ngominhkhoi05/deploy-b2c-utc2.git             deploy-b2c-utc2
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
cd /opt/flash-sale/flash-sale-b2c-UTC2

docker build -t flash-sale-b2c-backend:latest \
    -f /opt/flash-sale/deploy-b2c-utc2/docker/backend.Dockerfile \
    /opt/flash-sale/flash-sale-b2c-UTC2/
```

> Lần đầu: ~5 phút (download Gradle dependencies ~300MB).

> ⚠️ **Phải rebuild mỗi khi `docker/backend.Dockerfile` thay đổi.** `git pull` trong `deploy-b2c-utc2` **không** cập nhật image đã build. Nếu Dockerfile thêm `apt-get install curl` mà bạn không rebuild, container vẫn chạy image cũ không có `curl` → healthcheck fail với `curl: not found`.
>
> ```bash
> # Xem image đang dùng có curl không (nên trả về đường dẫn):
> docker exec flash-sale-b2c-backend sh -c 'command -v curl || echo "THIEU CURL - can rebuild image"'
> ```

### 5.2 Build Frontend

```bash
cd /opt/flash-sale/flash-sale-b2c-fe

# BẮT BUỘC truyền build-arg NEXT_PUBLIC_API_URL.
# Code FE (repo flash-sale-b2c-fe) đọc:
#   - process.env.NEXT_PUBLIC_API_URL  trong src/lib/api/client.ts
#   - process.env.NEXT_PUBLIC_WS_URL   trong src/lib/stomp.ts
# Phải khớp tên biến trong Dockerfile (xem docker/frontend.Dockerfile).
docker build -t flash-sale-b2c-frontend:latest \
    --build-arg NEXT_PUBLIC_API_URL=/api/v1 \
    --build-arg NEXT_PUBLIC_WS_URL= \
    -f /opt/flash-sale/deploy-b2c-utc2/docker/frontend.Dockerfile \
    /opt/flash-sale/flash-sale-b2c-fe/
```

> ⚠️ **Bắt buộc phải truyền `--build-arg NEXT_PUBLIC_API_URL=/api/v1`.**
> Nếu không truyền, FE fallback về `http://localhost:8080` → trình duyệt của người dùng gọi vào localhost của họ → trang trắng.
>
> 💡 **Để trống `--build-arg NEXT_PUBLIC_WS_URL=`** — SockJS sẽ tự dùng `window.location.host` (cùng host với trang web) → ws://<VPS_IP>/ws tự động, không cần hard-code IP/domain.

### 5.3 Verify

```bash
docker images | grep flash-sale-b2c
# flash-sale-b2c-backend    latest    abc123...    ~500MB
# flash-sale-b2c-frontend   latest    def456...    ~300MB
```

---

## 6. Cấu hình biến môi trường

```bash
cd /opt/flash-sale/deploy-b2c-utc2
cp .env.example .env
cp redis.env.example redis.env

vi .env        # điền giá trị thật
vi redis.env   # đặt REDIS_PASSWORD (nếu muốn bảo vệ Redis)
```

> 💡 **Dùng `vi` không `nano`** — Ubuntu 25.04 minimal **không có `nano` mặc định** (`nano: command not found`). `vi` luôn có sẵn.
>
> Nếu quen `nano` hơn, cài 1 lần rồi xài vĩnh viễn:
> ```bash
> apt update && apt install -y nano
> ```
>
> **Cách nhanh nhất không cần editor** — sửa trực tiếp bằng `sed`:
> ```bash
> # Ví dụ đặt VPS_IP
> sed -i "s|^VPS_IP=.*|VPS_IP=172.20.10.5|" .env
> ```
> | Phím tắt trong `vi` | Tác dụng |
> |---|---|
> | `i` | Vào chế độ nhập (insert) |
> | `Esc` | Thoát chế độ nhập |
> | `:wq` | Lưu và thoát |
> | `:q!` | Thoát **không** lưu |

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

**Biến có giá trị mặc định hợp lý — chỉ cần đổi nếu muốn tuỳ biến:**

| Biến | Mặc định trong `.env.example` | Ghi chú |
|---|---|---|
| `SPRING_PROFILES_ACTIVE` | `prod` | Bắt buộc — nạp `application-prod.yaml` |
| `REDIS_HOST` | `redis` | Tên service trong Docker network, **không đổi** |
| `REDIS_PORT` | `6379` | |
| `DB_POOL_MAX_SIZE` | `20` | `application-prod.yaml` default là `30` |
| `DB_POOL_MIN_IDLE` | `5` | `application-prod.yaml` default là `10` |
| `JWT_EXPIRATION_MS` | `3600000` | 1 giờ |
| `JWT_REFRESH_EXPIRATION_MS` | `604800000` | 7 ngày |
| `JAVA_OPTS` | `-Xmx1024m -Xms512m -XX:+UseG1GC` | Nhớ chỉnh `-Xmx` nếu VPS RAM nhỏ |
| `TZ` | `Asia/Ho_Chi_Minh` | |

> ⚠️ **KHÔNG viết comment inline sau dấu `=`** trong `.env`. Ví dụ `JWT_EXPIRATION_MS=3600000  # 1 giờ` sẽ khiến giá trị bị đọc thành chuỗi có khoảng trắng. Comment phải nằm trên **dòng riêng**. (Lưu ý: `.env.example` hiện đang đặt comment "1 giờ" / "7 ngày" ở dòng kế tiếp — đúng quy tắc.)

**Các biến sau KHÔNG có code BE đọc → backend sẽ BỎ QUA, có thể để trống:**
- `WS_ENDPOINT` — endpoint hard-code `/ws` trong `WebSocketConfig.java`, không đọc biến môi trường
- `PAYMENT_GATEWAY_API_KEY` / `PAYMENT_GATEWAY_SECRET` — repo BE chưa có code payment gateway
- `CLOUDINARY_*` — `application-prod.yaml` **có** khai báo property `cloudinary.*` (mặc định rỗng) nhưng repo BE chưa có class Java nào đọc chúng

> ✅ **CORS đã được map đầy đủ.** `application-prod.yaml` khai báo:
> ```yaml
> cors:
>   allowed-origins: ${CORS_ALLOWED_ORIGINS:http://localhost:3000}
> ```
> → `CORS_ALLOWED_ORIGINS` **có tác dụng**. Vì FE và BE cùng origin qua Nginx nên bình thường không cần CORS, nhưng nếu test FE ở `localhost:3000` gọi thẳng backend thì phải khai báo origin đó.
>
> ⚠️ Nhớ **restart backend** sau khi đổi biến này: `docker compose up -d --force-recreate backend`

---

## 7. Khởi động stack

```bash
cd /opt/flash-sale/deploy-b2c-utc2
git pull
./scripts/deploy.sh
```

> 💡 Từ commit `f1375d9` trở đi, file trong `scripts/` đã có quyền executable (mode `755`) sẵn trong Git, nên **không cần** `chmod +x` nữa. Lệnh đó chỉ có tác dụng ở các bản cũ.

Script sẽ:
1. Kiểm tra `.env` và `redis.env` tồn tại
2. Khởi động 4 containers: `redis`, `backend`, `frontend`, `nginx` (Compose tự tạo network `flash-sale-net`)
3. Kiểm tra đủ 4 container đang chạy, nếu thiếu sẽ báo lỗi và exit 1

> ⚠️ **Không tạo network thủ công.** Nếu bạn từng chạy `docker network create flash-sale-net`, network đó thiếu label `com.docker.compose.*` và Compose sẽ abort với lỗi:
> ```
> network flash-sale-net was found but has incorrect label com.docker.compose.network
> ```
> Cách sửa:
> ```bash
> docker network rm flash-sale-net
> ./scripts/deploy.sh
> ```

> ⚠️ **`git pull` bị từ chối** với lỗi `Your local changes to the following files would be overwritten by merge`? Thường do đã chạy `chmod +x scripts/*.sh` trên VPS — Git coi đó là thay đổi local, trong khi file trong repo lại ở mode khác. Bỏ thay đổi local rồi pull lại:
> ```bash
> git checkout -- scripts/
> git pull
> ```
> File trong repo đã có quyền execute sẵn nên không cần `chmod` nữa.

**Kiểm tra trạng thái:**
```bash
cd /opt/flash-sale/deploy-b2c-utc2
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
cd /opt/flash-sale/deploy-b2c-utc2
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
cd /opt/flash-sale/flash-sale-b2c-UTC2 && git pull

docker build -t flash-sale-b2c-backend:latest \
    -f /opt/flash-sale/deploy-b2c-utc2/docker/backend.Dockerfile \
    /opt/flash-sale/flash-sale-b2c-UTC2/

cd /opt/flash-sale/deploy-b2c-utc2
docker compose up -d --no-deps backend
```

### 9.2 Khi sửa frontend

```bash
# Local (Windows)
cd D:\flash-sale-b2c-fe && git add -A && git commit -m "..." && git push
```

**Trên VPS:**
```bash
cd /opt/flash-sale/flash-sale-b2c-fe && git pull

docker build -t flash-sale-b2c-frontend:latest \
    --build-arg NEXT_PUBLIC_API_URL=/api/v1 \
    --build-arg NEXT_PUBLIC_WS_URL= \
    -f /opt/flash-sale/deploy-b2c-utc2/docker/frontend.Dockerfile \
    /opt/flash-sale/flash-sale-b2c-fe/

cd /opt/flash-sale/deploy-b2c-utc2
docker compose up -d --no-deps frontend
```

### 9.3 Khi sửa Nginx config

```bash
cd /opt/flash-sale/deploy-b2c-utc2
docker compose restart nginx
```

### 9.4 Khi đổi secret trong `.env` (DB, JWT...)

```bash
cd /opt/flash-sale/deploy-b2c-utc2
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

### 10.1 Backend build fail: `unknown flag: --optional`

```
dockerfile parse error on line 26: unknown flag: --optional
```

> ⚠️ **Lỗi này đã xảy ra và đã được sửa.** Bản `deploy-b2c-utc2` cũ (trước commit sửa lỗi) dùng `COPY --optional gradle.properties ./` — nhưng **Docker KHÔNG có flag `--optional`** cho `COPY`.
>
> **Cách sửa trên VPS:**
> ```bash
> cd /opt/flash-sale/deploy-b2c-utc2 && git pull
> ```
> rồi build lại (§5.1). Docker đã được sửa thành:
> ```dockerfile
> COPY . ./
> RUN rm -f ./gradle.properties
> ```
> → copy cả build context rồi xoá file trong cùng một layer. `rm -f` không fail khi file vắng mặt.
>
> **Cách xử lý tạm thời nếu chưa `git pull` được:**
> ```bash
> cd /opt/flash-sale/flash-sale-b2c-UTC2 && touch gradle.properties
> ```
> (rỗng cũng được — chỉ cần để `COPY` không báo thiếu file)

### 10.2 Frontend trang trắng / gọi `localhost:8080`

```bash
# Nguyên nhân: build thiếu --build-arg NEXT_PUBLIC_API_URL
cd /opt/flash-sale/deploy-b2c-utc2
docker compose logs frontend
```

**Cách sửa:**
```bash
cd /opt/flash-sale/flash-sale-b2c-fe
docker build -t flash-sale-b2c-frontend:latest \
    --build-arg NEXT_PUBLIC_API_URL=/api/v1 \
    --build-arg NEXT_PUBLIC_WS_URL= \
    -f /opt/flash-sale/deploy-b2c-utc2/docker/frontend.Dockerfile \
    /opt/flash-sale/flash-sale-b2c-fe/

cd /opt/flash-sale/deploy-b2c-utc2 && docker compose up -d --no-deps frontend
```

### 10.3 Backend không healthy → `/actuator/health` trả 404 hoặc 401

```bash
cd /opt/flash-sale/deploy-b2c-utc2
docker compose logs backend | tail -80
```

> ⚠️ **`/bin/sh: 1: wget: not found` trong `docker inspect ... Health.Log`?** Healthcheck cũ dùng `wget` nhưng image `eclipse-temurin` JRE **không có sẵn wget lẫn curl** → mọi lần check đều fail → container `unhealthy` → nginx không start. **Đã sửa:** `docker/backend.Dockerfile` cài `curl`, healthcheck đổi sang `curl`.

> ⚠️ **Chỉ sửa healthcheck chưa đủ** nếu app vẫn crash. `wget: not found` chỉ là *triệu chứng*; app có thể đã chết vì lỗi khác. Luôn đọc `docker compose logs backend` tìm dòng `APPLICATION FAILED TO START` hoặc `Caused by:` — đó mới là nguyên nhân gốc.

**Kiểm tra trực tiếp:**
```bash
docker exec flash-sale-b2c-backend curl -fsS http://localhost:8080/actuator/health
```

> ✅ **Repo BE ĐÃ có actuator** (`build.gradle`: `spring-boot-starter-actuator`) và `application-prod.yaml` **đã có** mục `management:` expose `health,info`. `SecurityConfig.java` cũng đã `permitAll()` cho `/actuator/health` và `/actuator/info`.

> ⚠️ **Healthcheck đã kiểm tra status == 200, không chỉ "curl thành công".** `curl -f` trả **exit 0 với cả 401/403** (đã test) — chỉ fail từ 400 trở lên. Nếu chỉ dùng `curl -fsS`, một backend bị Security chặn sẽ bị báo healthy. Lệnh hiện tại:
> ```yaml
> test: ["CMD-SHELL", "curl -fsS -o /dev/null -w '%{http_code}' http://localhost:8080/actuator/health | grep -qx 200 || exit 1"]
> ```

**Đã test:** `200` → healthy; `401`, `404`, `503`, connection refused → unhealthy.
>
> Vì vậy nếu `/actuator/health` vẫn lỗi thì **không phải thiếu dependency** — hãy kiểm tra theo thứ tự:

| Mã trả về | Nguyên nhân | Cách xử lý |
|---|---|---|
| `404` | Đang chạy **image cũ**, chưa rebuild sau khi thêm actuator | `docker build` lại backend rồi `docker compose up -d --no-deps backend` |
| `404` | Profile không phải `prod` → không nạp `application-prod.yaml` | Kiểm tra `SPRING_PROFILES_ACTIVE=prod` trong `.env` |
| `401` | Security chặn — image build từ commit cũ (chưa có `permitAll`) | Rebuild image từ branch `dev` mới nhất |
| `503` | Actuator trả về `DOWN` — DB hoặc Redis chưa kết nối được | Xem log backend, kiểm tra `DB_*` / `REDIS_*` |

> 💡 `management.health.db.enabled: true` và `management.health.redis.enabled: true` trong `application-prod.yaml` → actuator sẽ báo `DOWN` nếu **một trong hai** kết nối lỗi. Dùng `show-details: never` nên response chỉ có `{"status":"DOWN"}`, phải xem log mới biết thành phần nào lỗi.

> **Tạm thời bỏ qua actuator** bằng cách đổi healthcheck trong `docker-compose.yml` (nhớ dùng `curl`, **không** dùng `wget` — xem cảnh báo ở đầu mục):
> ```yaml
> backend:
>   healthcheck:
>     test: ["CMD-SHELL", "curl -fsS -o /dev/null -w '%{http_code}' http://localhost:8080/swagger-ui/index.html | grep -qx 200 || exit 1"]
> ```
>
> ⚠️ Sửa `docker-compose.yml` **không** thay thế việc rebuild image. Nếu `docker/backend.Dockerfile` chưa được rebuild từ commit có `apt-get install curl` thì container vẫn không có `curl` và healthcheck vẫn fail với `curl: not found`.

### 10.4 `nginx` không start (Restarting / Exit)

**Nguyên nhân gần như luôn là backend unhealthy**, vì compose có:
```yaml
nginx:
  depends_on:
    backend:
      condition: service_healthy
```

```bash
cd /opt/flash-sale/deploy-b2c-utc2
docker compose logs backend | tail -50      # ← xem lỗi thật ở đây
```

**Các nguyên nhân phổ biến:**
1. `/actuator/health` 404 (thiếu actuator) → xem [§10.3](#103-backend-không-healthy--actuatorhealth-trả-404)
2. DB connect fail (Supabase cần `sslmode=require`)
3. `JWT_SECRET` rỗng hoặc < 32 ký tự → `JwtProperties.validate()` throw → app không start
4. Redis không kết nối được (xem [§10.6b](#106b-dependency-failed-to-start-container-flash-sale-b2c-redis-is-unhealthy))

**Bypass để xem log backend:**
```bash
cd /opt/flash-sale/deploy-b2c-utc2
docker compose up -d backend
docker compose logs -f backend
```

### 10.5 Backend không kết nối được DB

```bash
cd /opt/flash-sale/deploy-b2c-utc2
docker compose logs backend | grep -i "connection\|ssl\|error"
```

**Lỗi thường gặp:**
- `"connection refused"` → sai `DB_HOST`, hoặc Supabase project đang pause
- `"password authentication failed"` → sai `DB_USERNAME` / `DB_PASSWORD`
- `"SSL error"` → thiếu `sslmode=require`

> ✅ **`sslmode=require` đã có sẵn.** `application-prod.yaml` khai báo:
> ```yaml
> url: jdbc:postgresql://${DB_HOST:localhost}:${DB_PORT:5432}/${DB_NAME:flash_sale_db}?sslmode=require
> ```
>
> ⚠️ **Nếu gặp lỗi SSL dù Supabase Connection Pooler (port 6543)**: pooler chặn SSL ở chế độ transaction. Khi đó đổi `DB_PORT` trong `.env` sang `5432` (direct connection) — không sửa code.
>
> ⚠️ Nếu Supabase bắt buộc mã hóa mạnh hơn (ví dụ IP allowlist trong dashboard), cần thêm `&sslrootcert=...` — trường hợp này phải sửa ở repo BE.

### 10.6 Redis không hoạt động

```bash
cd /opt/flash-sale/deploy-b2c-utc2

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

### 10.6b `dependency failed to start: container flash-sale-b2c-redis is unhealthy`

**Nguyên nhân (đã xảy ra và đã được sửa):**

1. **Healthcheck không truyền password.** Healthcheck cũ là:
   ```yaml
   test: ["CMD-SHELL", "redis-cli ping | grep -q PONG"]
   ```
   Khi Redis chạy `--requirepass`, lệnh trả về `NOAUTH Authentication required.` — và **vẫn exit 0** — nên `grep -q PONG` không match → container bị đánh dấu `unhealthy`. Vì `backend` có `depends_on: redis: condition: service_healthy` nên backend không khởi động được, kéo theo nginx.

2. **`command` mất dấu nháy.** Dòng `exec redis-server --requirepass \"$$REDIS_PASSWORD\"` dùng escaped quotes (`\"`). Docker Compose **strip** những dấu này khi dựng command, thành `redis-server --requirepass $REDIS_PASSWORD`. Khi `REDIS_PASSWORD` rỗng thì Redis nhận `--requirepass` không có đối số → `FATAL CONFIG FILE ERROR: wrong number of arguments`, container exit code 1.

**Đã sửa trong `docker-compose.yml`:**
- Healthcheck dùng `$${REDIS_PASSWORD:+-a "$$REDIS_PASSWORD" --no-auth-warning}` — chỉ thêm `-a` khi password khác rỗng
- `command` bỏ escaped quotes, dùng `>-` với dấu nháy đơn bao ngoài

> 💡 Vì sao escape thành `$$`? Docker Compose tự interpolate `${...}` khi đọc file compose. Không escape thì `${REDIS_PASSWORD:+...}` bị Compose thay bằng chuỗi rỗng **trước khi** container khởi động, nên healthcheck mất hết tham số `-a`.

**Đã test:** cả 3 trường hợp đều `healthy` — password đơn giản, password có ký tự đặc biệt (`$`, space, `&`), và không có password.

**Nếu vẫn gặp lỗi:**
```bash
cd /opt/flash-sale/deploy-b2c-utc2
git pull
docker compose up -d --force-recreate redis
docker compose ps
```

### 10.7 CORS bị chặn khi FE gọi API

```bash
cd /opt/flash-sale/deploy-b2c-utc2
grep CORS_ALLOWED_ORIGINS .env
```

> ✅ **CORS đã được map đầy đủ** — `application-prod.yaml` có:
> ```yaml
> cors:
>   allowed-origins: ${CORS_ALLOWED_ORIGINS:http://localhost:3000}
> ```
> Nếu vẫn bị chặn, kiểm tra theo thứ tự:
>
> 1. **Biến có được truyền vào container không** — sau khi sửa `.env` phải recreate, không dùng `restart`:
>    ```bash
>    cd /opt/flash-sale/deploy-b2c-utc2
>    docker compose up -d --force-recreate backend
>    docker compose exec backend printenv CORS_ALLOWED_ORIGINS
>    ```
> 2. **Giá trị có đúng format không** — phải là danh sách origin đầy đủ, phân tách bằng dấu phẩy, **không có dấu `/` cuối**:
>    ```
>    Đúng:  CORS_ALLOWED_ORIGINS=http://172.20.10.5
>    Sai:   CORS_ALLOWED_ORIGINS=http://172.20.10.5:80/    ← có dấu /
>    Sai:   CORS_ALLOWED_ORIGINS=http://172.20.10.5:80,     ← dấu phẩy cuối
>    ```
> 3. **Nếu không đổi gì được** — kiểm tra origin thực tế FE gửi lên. Mở DevTools → Network → filter `api` → cột `Origin`. Giá trị này phải nằm trong `CORS_ALLOWED_ORIGINS`.
>
> 💡 Thông thường khi deploy qua Nginx 1 origin thì **không cần CORS** (same-origin). CORS chỉ cần khi: test FE ở `localhost:3000` gọi thẳng `:8080`, hoặc tách FE/BE qua domain khác nhau.

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

`nginx/default.conf` được mount bằng **đường dẫn tương đối** (`./nginx/default.conf`). Vì vậy **luôn `cd /opt/flash-sale/deploy-b2c-utc2` trước khi chạy `docker compose`**, nếu không sẽ báo lỗi mount file không tồn tại.

---

## Hỗ trợ

```bash
cd /opt/flash-sale/deploy-b2c-utc2
./scripts/check-health.sh > health-report.txt
docker compose logs --no-color > all-logs.txt
```

Gửi 2 file trên khi báo lỗi.
