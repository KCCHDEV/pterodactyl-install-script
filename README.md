<div align="center">

# 🦖 Pterodactyl Panel Auto Installer

**One-Click Setup | กรอกครั้งเดียว แล้วปล่อยให้ระบบจัดการให้**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Platform-Ubuntu%2022.04%20%7C%20Debian%2011+-blue)](https://ubuntu.com)
[![Shell](https://img.shields.io/badge/Shell-Bash-green)](https://www.gnu.org/software/bash/)

*ติดตั้ง Pterodactyl Panel แบบอัตโนมัติ — HTTP, HTTPS, Cloudflare Proxy หรือ Cloudflare Tunnel เลือกได้ตามใจ*

</div>

---

## ✨ Features

| Feature | Description |
|--------|-------------|
| 🚀 **One-Time Input** | กรอกข้อมูลครั้งเดียว — ที่เหลือให้สคริปต์จัดการ |
| 🔐 **4 Modes** | HTTP / HTTPS (Let's Encrypt) / Cloudflare Proxy / Cloudflare Tunnel |
| 🎮 **Wings Optional** | เลือกได้ว่าจะติดตั้ง game server daemon หรือไม่ |
| 📦 **Curated** | ตั้งค่าทุกอย่างให้ — พร้อมใช้ทันที |
| 🧹 **Maintenance** | มี uninstall + cleaner ในชุด |
| 📄 **JSON Config** | บันทึก settings อัตโนมัติ ไว้ใช้ต่อได้ง่าย |

---

## 🚀 Quick Start

```bash
curl -sSL https://raw.githubusercontent.com/KCCHDEV/pterodactyl-install-script/refs/heads/main/install.sh | sudo bash
```

**หรือ**

```bash
git clone https://github.com/KCCHDEV/pterodactyl-install-script.git
cd pterodactyl-install-script
sudo ./install.sh
```

> **หมายเหตุ:** Raw URL แบบสั้น: `https://raw.githubusercontent.com/KCCHDEV/pterodactyl-install-script/main/install.sh` ใช้ได้เหมือนกัน

---

## 📋 Requirements

| Item | Specification |
|------|---------------|
| **OS** | Ubuntu 22.04/24.04, Debian 11/12 |
| **Privilege** | Root (sudo) |
| **Disk** | ≥ 5GB |
| **Network** | Port 80, 443 (หรือใช้ CF Tunnel ไม่ต้องเปิด port) |

---

## 📖 Installation Modes

| Mode | Use Case | SSL |
|------|----------|-----|
| **1 - HTTP** | Development / ทดสอบ | ❌ |
| **2 - HTTPS** | Production (Let's Encrypt) | ✅ Auto |
| **3 - CF Tunnel** | Quick (`xxx.trycloudflare.com`) หรือ Named (domain ของคุณ) | ✅ |
| **4 - CF Proxy** | Orange cloud + Origin SSL (cert path แบบกำหนดเองได้) | ✅ Custom |

---

## 🎯 Input Prompts

ตอนติดตั้งจะถาม:

- **FQDN** — domain เช่น `panel.example.com` หรือ `localhost`
- **Admin Email** — สำหรับ admin + SSL
- **Admin Password** — ขั้นต่ำ 8 ตัว
- **Install Mode** — 1, 2, 3 หรือ 4
- **DB Password** — กด Enter เพื่อ auto-generate
- **Install Wings?** — Y/n (ตัวเลือก game server daemon)

---

## 🗂 Project Structure

```
pterodactyl-install-script/
├── install.sh        # Single-file installer (run curl|bash or ./install.sh)
├── build.sh          # Build install.sh from lib/* (run: ./build.sh)
├── install-multi.sh  # Backup/source for build
├── uninstall.sh      # Standalone uninstall (or use install.sh menu [5])
├── cleaner.sh        # Logs/cache cleanup
├── lib/              # Source modules (for build)
│   ├── common.sh
│   ├── dependencies.sh
│   ├── panel.sh
│   ├── wings.sh
│   ├── ssl.sh
│   ├── cftunnel.sh
│   └── switch.sh
└── README.md
```

**Single-file:** `install.sh` เป็นไฟล์เดียว — ไม่ต้องดาวน์โหลด archive อีก รัน `curl ... | bash` ได้ทันที

---

## 🧹 Uninstall & Cleaner

### Uninstall

```bash
# รัน installer อีกครั้ง เลือก [5] Remove
sudo ./install.sh

# หรือ standalone (ถ้ามี)
sudo /opt/pterodactyl-install-script/install.sh
```

พิมพ์ `yes` หรือ domain เพื่อยืนยัน

### Cleaner

```bash
# หลังติดตั้งผ่าน curl
sudo /opt/pterodactyl-install-script/cleaner.sh logs

# หรือ clone repo มา
sudo ./cleaner.sh logs           # ลบ logs เก่า
sudo ./cleaner.sh cache          # ล้าง cache
sudo ./cleaner.sh temp           # ลบ temp
sudo ./cleaner.sh all            # ทำทั้งหมด
sudo ./cleaner.sh logs --dry-run # ดูว่าจะลบอะไร (ไม่ลบจริง)
sudo ./cleaner.sh logs --keep-days 14
```

---

## 📄 Settings JSON

หลังติดตั้งเสร็จ:

- **Path:** `/root/pterodactyl-settings.json`
- **ใช้เก็บ:** fqdn, admin_email, install_mode, db_name, panel_url, wings_installed ฯลฯ
- **ปลอดภัย:** ไม่เก็บรหัสผ่าน — ใช้ credentials file แยก
- **ใช้โดย:** uninstall.sh, cleaner.sh

---

## 📌 Post-Install

1. เข้า Panel ด้วย admin / (รหัสที่ตั้ง)
2. สร้าง **Location** (Nodes → Locations)
3. สร้าง **Node** (Nodes → Create) — ตั้ง FQDN, Memory, Disk
4. Tab **Configuration** → copy คำสั่ง deployment
5. รันบน server เพื่อตั้งค่า Wings
6. `sudo systemctl start wings`

---

## ⚠️ Notes

- **Wings Optional** — เลือก `n` ถ้าต้องการแค่ Panel (ไม่ติดตั้ง Docker)
- **Wings** — ไม่ start อัตโนมัติจนกว่าจะสร้าง Node และรัน deployment
- **CF Quick Tunnel** — URL เปลี่ยนทุกครั้งที่ restart
- **HTTPS** — domain ต้องชี้มาที่ server ก่อนรัน Certbot
- **CF Proxy (4)** — ใช้กับ Cloudflare orange cloud, ระบุ path cert/key ได้ (เช่น Cloudflare Origin SSL, Let's Encrypt)
- **Self-Signed SSL** — ถ้า cert ไม่มี สคริปต์จะถามสร้างให้อัตโนมัติ (ใช้ OpenSSL)

---

<div align="center">

**License:** MIT

Made with ❤️ for Pterodactyl Community

</div>
