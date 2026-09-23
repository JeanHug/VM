#!/usr/bin/env bash
set -e

echo "=================================================="
echo "    ANDROID GRAPHICAL SMARTPHONE (PORTRAIT 720x1280)"
echo "   Amorçage Direct ISO + Attente Synchrone Boot    "
echo "=================================================="

DATA_DIR="/home/runner/android_oreo_data"
sudo mkdir -p "$DATA_DIR"
sudo chown -R runner:docker "$DATA_DIR" 2>/dev/null || sudo chown -R $(id -u):$(id -g) "$DATA_DIR" 2>/dev/null || true
sudo chmod -R 777 "$DATA_DIR"
cd "$DATA_DIR"

# 1. Nettoyage préventif
pkill -9 -f qemu-system 2>/dev/null || true
pkill -9 -f websockify 2>/dev/null || true
pkill -9 -f nginx 2>/dev/null || true
pkill -9 -f android-bridge 2>/dev/null || true
pkill -9 -f adb 2>/dev/null || true

# 2. Installation des paquets
echo "=== 1. Installation des paquets ==="
sudo apt-get update -qq >/dev/null 2>&1 || true
sudo apt-get install -y -qq qemu-system-x86 qemu-utils novnc websockify nginx adb wget curl p7zip-full squashfs-tools e2fsprogs >/dev/null 2>&1 || true

# 3. Téléchargement d'Android-x86 8.1 r6
ISO_NAME="android-x86_64-8.1-r6.iso"
if [ ! -f "$ISO_NAME" ] || [ ! -s "$ISO_NAME" ]; then
  rm -f "$ISO_NAME"
  echo "Téléchargement d'Android-x86..."
  curl -L -s -o "$ISO_NAME" "https://mirrors.dotsrc.org/osdn/android-x86/71931/android-x86_64-8.1-r6.iso" || \
  curl -L -s -o "$ISO_NAME" "https://sourceforge.net/projects/android-x86/files/Release%208.1/android-x86_64-8.1-r6.iso/download"
fi

# 4. Extraction des composants de boot (kernel + initrd)
echo "=== 2. Extraction du noyau et initrd ==="
mkdir -p "$DATA_DIR/android_fs"
7z x -y "$ISO_NAME" -o"$DATA_DIR/android_fs" kernel initrd.img >/dev/null 2>&1 || true

# Partition de données ext4 pour Android
if [ ! -f "data.img" ]; then
  echo "Création de la partition de données ext4 (data.img)..."
  qemu-img create -f raw data.img 3G
  mkfs.ext4 -F -L "data" data.img >/dev/null 2>&1 || true
fi

# 5. Détection KVM
KVM_FLAG=""
if [ -e /dev/kvm ]; then
  sudo chmod 666 /dev/kvm 2>/dev/null || true
  KVM_FLAG="-enable-kvm -cpu host"
else
  KVM_FLAG="-cpu max"
fi

# 6. Démarrage QEMU avec CDROM ISO + disque de données (Mode VESA Portrait 720x1280)
echo "=== 3. Démarrage QEMU Android (Portrait 720x1280) ==="
qemu-system-x86_64 \
  $KVM_FLAG \
  -m 3072 \
  -smp 2 \
  -vga std \
  -global VGA.vgamem_mb=64 \
  -vnc 127.0.0.1:0 \
  -cdrom "$DATA_DIR/$ISO_NAME" \
  -drive file="$DATA_DIR/data.img",format=raw,if=virtio \
  -kernel "$DATA_DIR/android_fs/kernel" \
  -initrd "$DATA_DIR/android_fs/initrd.img" \
  -append "root=/dev/ram0 androidboot.hardware=android_x86 androidboot.selinux=permissive buildvariant=userdebug DATA=/dev/vda UVESA_MODE=720x1280 DPI=280 nomodeset xforcevesa quiet" \
  -net nic,model=virtio \
  -net user,hostfwd=tcp::5555-:5555 \
  -usb -device usb-tablet \
  -daemonize

# 7. Relais Websockify vers QEMU VNC (:0 -> 6080)
echo "=== 4. Démarrage Websockify ==="
sleep 2
websockify --web /usr/share/novnc 6080 127.0.0.1:5900 >/dev/null 2>&1 &
sleep 2

# 8. Bridge ADB
CURRENT_DIR=$(pwd)
WORK_DIR="/home/runner/work/VM/VM"
if [ -d "$WORK_DIR" ]; then
  CURRENT_DIR="$WORK_DIR"
fi
node "$CURRENT_DIR/scripts/android-bridge.cjs" >/dev/null 2>&1 &
sleep 1

# 9. Configuration NGINX Reverse-Proxy
echo "=== 5. Configuration NGINX ==="
sudo mkdir -p /var/www/android-web
sudo cp -r "$CURRENT_DIR/android-web/"* /var/www/android-web/
sudo chmod -R 755 /var/www/android-web

cat << 'NGINX_EOF' | sudo tee /etc/nginx/sites-available/default > /dev/null
server {
    listen 3000 default_server;
    listen [::]:3000 default_server;

    proxy_buffering off;
    proxy_request_buffering off;
    tcp_nodelay on;

    location / {
        root /var/www/android-web;
        index index.html;
        try_files $uri $uri/ @novnc_proxy;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:8080/api/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }

    location /websockify {
        proxy_pass http://127.0.0.1:6080/websockify;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }

    location @novnc_proxy {
        proxy_pass http://127.0.0.1:6080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
NGINX_EOF

sudo systemctl restart nginx || sudo service nginx restart

# 10. Attente SYNCHRONE jusqu'à ce qu'Android soit 100% DÉMARRÉ et SUR LE LAUNCHER
echo "=== 6. Attente synchrone du démarrage complet d'Android (sys.boot_completed) ==="
BOOT_SUCCESS=0
for attempt in {1..60}; do
  sleep 4
  adb connect 127.0.0.1:5555 >/dev/null 2>&1 || true
  
  # Réveil de l'écran et simulation de déverrouillage
  adb -s 127.0.0.1:5555 shell input keyevent 82 >/dev/null 2>&1 || true
  adb -s 127.0.0.1:5555 shell input keyevent 3 >/dev/null 2>&1 || true

  BOOT_OK=$(adb -s 127.0.0.1:5555 shell getprop sys.boot_completed 2>/dev/null || echo "0")
  if [ "$BOOT_OK" = "1" ]; then
    echo "✅ ANDROID BOOT TERMINE AVEC SUCCES (sys.boot_completed = 1) !"
    BOOT_SUCCESS=1
    
    # Auto-provisioning & contournement de la configuration initiale
    adb -s 127.0.0.1:5555 shell settings put global device_provisioned 1 >/dev/null 2>&1 || true
    adb -s 127.0.0.1:5555 shell settings put secure user_setup_complete 1 >/dev/null 2>&1 || true
    adb -s 127.0.0.1:5555 shell settings put system user_rotation 0 >/dev/null 2>&1 || true
    adb -s 127.0.0.1:5555 shell settings put system screen_off_timeout 2147483647 >/dev/null 2>&1 || true
    adb -s 127.0.0.1:5555 shell wm size 720x1280 >/dev/null 2>&1 || true
    adb -s 127.0.0.1:5555 shell wm density 280 >/dev/null 2>&1 || true
    
    # Lancement explicite de l'écran d'accueil (Launcher)
    adb -s 127.0.0.1:5555 shell input keyevent 82 >/dev/null 2>&1 || true
    adb -s 127.0.0.1:5555 shell input keyevent 3 >/dev/null 2>&1 || true
    sleep 3
    break
  else
    echo "Attente du boot Android... (tentative $attempt/60)"
  fi
done

if [ "$BOOT_SUCCESS" = "1" ]; then
  echo "=================================================="
  echo " Android Smartphone Prêt & Fonctionnel !"
  echo "=================================================="
else
  echo "⚠️ Android est démarré en arrière-plan, passage à l'étape suivante..."
fi
