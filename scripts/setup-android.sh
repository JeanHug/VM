#!/usr/bin/env bash
set -e

echo "=================================================="
echo "    ANDROID GRAPHICAL SMARTPHONE (PORTRAIT 720x1280)"
echo "   Amorçage Direct Ultra-Optimisé VESA / Software  "
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

# 2. Installation des dépendances
echo "=== 1. Installation des dépendances système ==="
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

# 4. Extraction et préparation de la partition système bootable
echo "=== 2. Préparation du système de fichiers Android ==="
mkdir -p "$DATA_DIR/android_fs"
7z x -y "$ISO_NAME" -o"$DATA_DIR/android_fs" >/dev/null 2>&1 || true

# Création du disque système amorçable avec les données
if [ ! -f "android_disk.img" ]; then
  echo "Création de la partition système ext4..."
  qemu-img create -f raw android_disk.img 5G
  mkfs.ext4 -F -L "AndroidOS" android_disk.img >/dev/null 2>&1 || true
  
  MOUNT_DIR="/tmp/mnt_android"
  sudo mkdir -p "$MOUNT_DIR"
  sudo mount -o loop android_disk.img "$MOUNT_DIR"
  sudo cp -r "$DATA_DIR/android_fs/"* "$MOUNT_DIR/" 2>/dev/null || true
  sudo mkdir -p "$MOUNT_DIR/data"
  sudo chmod 777 "$MOUNT_DIR/data"
  sudo umount "$MOUNT_DIR" || true
  sudo rm -rf "$MOUNT_DIR"
fi

# 5. Détection KVM matériel
KVM_FLAG=""
if [ -e /dev/kvm ]; then
  sudo chmod 666 /dev/kvm 2>/dev/null || true
  KVM_FLAG="-enable-kvm -cpu host"
else
  KVM_FLAG="-cpu max"
fi

# 6. Démarrage de QEMU Android (Mode Portrait 720x1280 + Rendu Graphique VESA / Software)
echo "=== 3. Démarrage QEMU Android (720x1280 Portrait VESA) ==="
qemu-system-x86_64 \
  $KVM_FLAG \
  -m 2048 \
  -smp 2 \
  -vga std \
  -global VGA.vgamem_mb=32 \
  -vnc 127.0.0.1:0 \
  -kernel "$DATA_DIR/android_fs/kernel" \
  -initrd "$DATA_DIR/android_fs/initrd.img" \
  -drive file="$DATA_DIR/android_disk.img",format=raw,if=virtio \
  -append "root=/dev/ram0 androidboot.hardware=android_x86 androidboot.selinux=permissive buildvariant=userdebug SRC=/ DATA=/data UVESA_MODE=720x1280 DPI=280 nomodeset xforcevesa quiet" \
  -net nic,model=virtio \
  -net user,hostfwd=tcp::5555-:5555 \
  -usb -device usb-tablet \
  -daemonize

# 7. Relais Websockify vers QEMU VNC (:0 -> 6080)
echo "=== 4. Démarrage Websockify (127.0.0.1:5900 -> 6080) ==="
sleep 2
websockify --web /usr/share/novnc 6080 127.0.0.1:5900 >/dev/null 2>&1 &
sleep 2

# 8. Démarrage du bridge ADB
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

# 10. Validation HTTP locale
echo "=== 6. Validation du serveur Web Android ==="
for i in {1..20}; do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3000/ || echo "000")
  if [ "$HTTP_CODE" = "200" ]; then
    echo " Serveur Web Android QEMU opérationnel (HTTP 200) !"
    break
  fi
  sleep 2
done

# Attente initiale du démon ADB
(
  for attempt in {1..30}; do
    sleep 3
    adb connect 127.0.0.1:5555 >/dev/null 2>&1 || true
    BOOT_OK=$(adb -s 127.0.0.1:5555 shell getprop sys.boot_completed 2>/dev/null || echo "0")
    if [ "$BOOT_OK" = "1" ]; then
      echo "=== ANDROID BOOT TERMINE AVEC SUCCES ==="
      # Configuration du format vertical et désactivation de l'écran de veille
      adb -s 127.0.0.1:5555 shell settings put system user_rotation 0 >/dev/null 2>&1 || true
      adb -s 127.0.0.1:5555 shell settings put system screen_off_timeout 2147483647 >/dev/null 2>&1 || true
      adb -s 127.0.0.1:5555 shell wm size 720x1280 >/dev/null 2>&1 || true
      adb -s 127.0.0.1:5555 shell wm density 280 >/dev/null 2>&1 || true
      break
    fi
  done
) >/dev/null 2>&1 &

echo "=================================================="
echo " Android Graphique Prêt (Port 3000 Ouvert) !"
echo "=================================================="
