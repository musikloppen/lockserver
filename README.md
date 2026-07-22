# 🔒 Smart Lock Control Server

A lightweight, secure, mod_perl and Apache-based web interface and REST API for controlling physical door lock hardware via SMS authentication, temporary guest access passes, and Redis pub/sub messaging.

Optimized to run inside Docker on resource-constrained hardware such as a **Raspberry Pi** (512 MB RAM).

---

## 🏗 System Architecture

```
                                  [ USER INPUTS ]

   Web Browser              Physical Exit Button             RFID Badge Reader
        |                            |                              |
        | HTTP / REST                | GPIO / Hardware Event        | Serial / RFID Event
        v                            v                              v
+---------------+            +---------------+              +---------------+
|   lock_web    |            | lock_button   |              |   lock_rfid   |
| (mod_perl)    |            |   _server     |              |    _server    |
+---+-------+---+            +-------+-------+              +-------+-------+
    |       |                        |                              |
    |       | Requests Unlock        | Publishes Event              | Publishes Event
    |       +------------------------+------------------------------+
    |                                |
    | Authenticate                   v
    v                         +--------------+
+-------+                     |  lock_redis  |
|lock_db|                     | (Pub/Sub)    |
+-------+                     +------+-------+
                                     |
                                     | Event Notification
                                     v
                              +--------------+
                              | lock_unlock  |
                              |   _server    |
                              +------+-------+
                                     |
                                     | Drives Relay
                                     v
                            [ PHYSICAL DOOR LOCK ]
```

### Docker Services Breakdown

| Service Name | Dockerfile | Description |
| :--- | :--- | :--- |
| **`lock_web`** | `Dockerfile.web` | Apache + mod_perl server handling the REST API, web UI, and SMS authentication. |
| **`lock_button_server`** | `Dockerfile.button_server` | Daemon listening for physical exit button presses and dispatching unlock events. |
| **`lock_rfid_server`** | `Dockerfile.rfid_server` | Daemon reading RFID card/badge scans and validating access. |
| **`lock_unlock_server`** | `Dockerfile.unlock_server` | Hardware controller daemon listening to Redis channels and driving physical door lock relays. |
| **`lock_redis`** | `Dockerfile.redis` | In-memory message broker managing event pub/sub and millisecond hardware mutex locks. |
| **`lock_db`** | `Dockerfile.db` | MariaDB/MySQL database for user accounts, logs, lock hardware metadata, and temporary passes. |

---

## Key Features
* **Multi-Input Unlock Triggers**: Open door via Web API (`lock_web`), physical exit button (`lock_button_server`), or RFID badge scanner (`lock_rfid_server`).
* **SMS-Based Authentication**: Secure phone number verification without persistent password management.
* **Temporary Guest Access**: Logarithmic duration slider allowing user creation for 1 hour up to 1 week with automated expiration.
* **Strict Hardware Mutex Locking**: Prevents race conditions and duplicate physical relay activations using millisecond-precision Redis locks (`PX` TTL based on `open_time + 200ms`).
* **Dry-Run Mode**: Supports full local/testing development via `DEBUG` flags without dispatching real SMS notifications.
* **Low Memory Footprint**: Configured for single-process `mpm_prefork` execution (~30 MB RAM total footprint).

---

## 🚀 Quick Start

### Prerequisites
* Docker & Docker Compose
* An SMTP gateway configured for sending outbound SMS notifications (unless running in `DEBUG` dry-run mode).

### 1. Environment Setup

Copy `.env.example` to `.env` (or set environment variables in your Compose file):

```env
# Database Settings
DB_HOST=lock-db
DB_NAME=lock_db
DB_USER=lock_user
DB_PASS=secret

# Redis Settings
REDIS_HOST=lock-redis
REDIS_PORT=6379

# SMTP / SMS Settings
SMTP_HOST=smtp.example.com
SMTP_PORT=587
SMTP_USER=meterlogger
SMTP_PASSWORD=secret

# Debug / Development
DEBUG=0
```

### 2. Launch with Docker Compose

```bash
docker compose up -d --build
```

The web interface will be available at `http://localhost`.

---

## 🔌 API Endpoints

### 1. Trigger Door Unlock
**Endpoint:** `POST /api/unlock`  
**Authentication:** Required (`auth_token` cookie)

Acquires a Redis hardware lock and publishes an `unlock_web:<username>` event to Redis channel `lock_events`.

* **Success (200 OK):**
  ```json
  {
    "status": "ok",
    "message": "Door unlocked",
    "user": "john_doe",
    "open_time": 2
  }
  ```
* **Conflict / Busy (429 Too Many Requests):**
  ```json
  {
    "error": "Door activation already in progress. Please wait."
  }
  ```

---

### 2. Grant Temporary Access
**Endpoint:** `POST /api/grant_access`  
**Authentication:** Required (`auth_token` cookie)

Creates a temporary user and dispatches an invitation SMS with access credentials. Rollbacks database creation automatically if SMS delivery fails.

* **Payload:**
  ```json
  {
    "name": "Jane Guest",
    "phone": "+4512345678",
    "duration_hours": 2
  }
  ```
* **Success (200 OK):**
  ```json
  {
    "status": "ok",
    "message": "Guest access created and SMS dispatched",
    "username": "guest-swift-panda-42",
    "phone": "004512345678",
    "expires_in": "2 hours",
    "sms_sent": 1
  }
  ```

---

## 🛠 Testing & Dry Run Mode

To test API workflows without sending real SMS messages, enable `DEBUG=1`:

```bash
DEBUG=1 docker compose up -d
```

When active, `send_notification` will validate phone numbers and format output, logging the notification to stdout instead of opening SMTP connections:

```text
[INFO] [DEBUG DRY-RUN] Skipping actual SMTP dispatch. SMS to 004512345678: "You have been granted door access for 2 hour(s)..."
```

---

## ⚙️ Raspberry Pi Low-RAM Tuning

To run reliably on 512 MB RAM devices, Apache is restricted to **1 worker process** via `mpm_prefork.conf`:

```apache
<IfModule mpm_prefork_module>
    StartServers             1
    MinSpareServers          1
    MaxSpareServers          1
    MaxRequestWorkers        1
    MaxConnectionsPerChild   1000
</IfModule>
```

Verify current running processes inside the container:

```bash
docker exec -it lock_web ps aux | grep apache2
```

---

## 📂 Directory Structure

```text
.
├── 000-default.conf             # Apache VirtualHost configuration
├── Dockerfile.base              # Shared base Docker image for Perl services
├── Dockerfile.web               # Apache + mod_perl web server container
├── Dockerfile.unlock_server     # Door unlock hardware listener service
├── Dockerfile.button_server     # Physical button input event daemon
├── Dockerfile.rfid_server       # RFID card reader daemon
├── Dockerfile.redis             # Redis message broker container
├── Dockerfile.db                # MariaDB/MySQL database container
├── docker-compose.yml           # Core Docker service definitions
├── docker-compose.override.yml  # Local development overrides
├── mpm_prefork.conf             # Low-memory Apache MPM process tuning
├── lock_server.sql              # Database schema initialization script
├── db/                          # Database persistent storage & configuration
│   └── conf.d/                  # Custom MariaDB/MySQL config options
│       └── 99-client.cnf
├── htdocs/                      # Web frontend static assets & dashboard views
│   └── private/                 # Authenticated views (SMS login & verification)
└── perl/                        # Perl codebase & background daemons
    ├── startup.pl               # mod_perl initialization script
    ├── unlock_server.pl         # Listener service: Subscribes to Redis & drives relay hardware
    ├── button_server.pl         # Trigger daemon: Detects physical button presses to request unlock
    ├── rfid_server.pl           # Trigger daemon: Reads RFID badges & dispatches unlock events
    └── LockServer/              # Core Perl application modules
        ├── APIUnlock.pm          # POST /api/unlock & Redis hardware mutex lock
        ├── APIGrantTempAccess.pm # POST /api/grant_access & temporary pass creation
        ├── SMSAuth.pm            # SMS login & verification workflow
        ├── Db.pm                 # Database connection & query helper
        ├── Utils.pm              # Logger & SMTP notification helper
        └── Number/
            └── Phone.pm          # Phone number normalization logic
```

---

## 📄 License

This project is licensed under the **MIT License**.

```text
MIT License

Copyright (c) 2026 Smart Lock Control Server

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```