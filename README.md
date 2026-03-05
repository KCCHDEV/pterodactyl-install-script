# Pterodactyl Panel Auto Installer

ชุดสคริปต์สำหรับติดตั้ง Pterodactyl Panel แบบอัตโนมัติ กรอกข้อมูลครั้งเดียว แล้วระบบจะติดตั้งจนใช้งานได้ทันที

## ความต้องการของระบบ

- **OS**: Ubuntu 22.04/24.04, Debian 11/12
- **สิทธิ์**: Root (sudo)
- **พื้นที่**: อย่างน้อย 5GB
- **เครือข่าย**: เปิด port 80, 443 (สำหรับ HTTP/HTTPS) หรือใช้ Cloudflare Tunnel ไม่ต้องเปิด port

## โครงสร้างไฟล์

```
├── install.sh       # ติดตั้งหลัก
├── uninstall.sh     # ลบการติดตั้ง
├── cleaner.sh       # ทำความสะอาด logs/cache
├── lib/
│   ├── common.sh
│   ├── dependencies.sh
│   ├── panel.sh
│   ├── wings.sh
│   ├── ssl.sh
│   └── cftunnel.sh
└── README.md
```

## การใช้งาน

### ติดตั้ง

```bash
# รันผ่าน curl จาก GitHub
curl -sSL https://raw.githubusercontent.com/naygolf/ptero-panel-installer/main/install.sh | sudo bash

# หรือ clone แล้วรัน
git clone https://github.com/naygolf/ptero-panel-installer.git
cd ptero-panel-installer
sudo ./install.sh
```

กรอกข้อมูลเมื่อถาม:
- **FQDN**: domain เช่น panel.example.com (หรือ localhost สำหรับทดสอบ)
- **Admin Email**: อีเมลผู้ดูแล
- **Admin Password**: รหัสผ่าน (ขั้นต่ำ 8 ตัว)
- **Install Mode**: 1=HTTP, 2=HTTPS, 3=Cloudflare Tunnel
- **DB Password**: Enter เพื่อสร้างอัตโนมัติ
- **Install Wings**: Y/n (ตัวเลือกเพิ่มเติม สำหรับ game server daemon)

### โหมดการติดตั้ง

| โหมด | คำอธิบาย |
|------|----------|
| 1 - HTTP | สำหรับพัฒนา ไม่มี SSL |
| 2 - HTTPS | Let's Encrypt SSL (domain ต้องชี้มาที่ server นี้) |
| 3 - CF Tunnel | Quick Tunnel (ได้ xxx.trycloudflare.com) หรือ Named Tunnel (ใช้ domain ของคุณ) |

### ลบการติดตั้ง

```bash
# หลังติดตั้งผ่าน curl - installer ถูก copy ไปที่ /opt
sudo /opt/ptero-panel-installer/uninstall.sh

# หรือถ้า clone repo มา
sudo ./uninstall.sh
```

พิมพ์ `yes` หรือ domain ของ panel เพื่อยืนยัน

### ทำความสะอาด

```bash
# หลังติดตั้งผ่าน curl
sudo /opt/ptero-panel-installer/cleaner.sh logs

# หรือถ้า clone repo มา
sudo ./cleaner.sh logs

# ล้าง cache
sudo ./cleaner.sh cache

# ลบ temp files
sudo ./cleaner.sh temp

# ทำทั้งหมด
sudo ./cleaner.sh all

# ดูว่าจะลบอะไร (ไม่ลบจริง)
sudo ./cleaner.sh logs --dry-run

# เก็บ logs 14 วัน
sudo ./cleaner.sh logs --keep-days 14
```

## หลังติดตั้ง

1. Login ที่ Panel URL ด้วย admin / (รหัสที่ตั้ง)
2. สร้าง **Location** ที่ Nodes > Locations
3. สร้าง **Node** ที่ Nodes > Create
   - FQDN: ชื่อ server หรือ IP
   - ตั้ง Memory, Disk ตามต้องการ
4. ไปที่แท็บ **Configuration** ของ Node แล้ว copy คำสั่ง deployment
5. รันคำสั่งนั้นบน server เพื่อตั้งค่า Wings
6. เริ่ม Wings: `sudo systemctl start wings`

## Settings JSON

หลังติดตั้งเสร็จ ระบบจะบันทึกการตั้งค่าไว้ที่ `/root/pterodactyl-settings.json`:

- `fqdn`, `admin_email`, `install_mode`, `db_name`, `panel_url`, `wings_installed` ฯลฯ
- ไม่เก็บรหัสผ่านในไฟล์นี้ (เก็บใน credentials file แยก)
- ใช้โดย uninstall.sh และ cleaner.sh เพื่ออ่าน config

## หมายเหตุ

- **Wings (ตัวเลือก)**: เลือก n ถ้าต้องการแค่ Panel เท่านั้น (ไม่ติดตั้ง Docker)
- **Wings**: จะยังไม่ start อัตโนมัติจนกว่าจะสร้าง Node ใน Panel และรัน deployment command
- **Cloudflare Quick Tunnel**: URL จะเปลี่ยนทุกครั้งที่ restart
- **HTTPS**: domain ต้องชี้มาที่ IP ของ server ก่อนรัน Certbot

## License

MIT
