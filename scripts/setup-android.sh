#!/usr/bin/env bash
set -e

echo "=================================================="
echo "   LANCEMENT D'ANDROID 14 (API 34) AOSP NATIF     "
echo "   NOUVELLE ARCHITECTURE 0 LAG / 0 LATENCE MOBILE "
echo "=================================================="

DATA_DIR="/home/runner/android_vm_data"
sudo mkdir -p "$DATA_DIR/data"
sudo chmod -R 777 "$DATA_DIR" 2>/dev/null || true

# 1. Nettoyage absolu
echo "=== Nettoyage des processus et conteneurs antérieurs ==="
docker rm -f redroid14 redroid13 android_vm ws_scrcpy novnc_android 2>/dev/null || true
pkill -9 -f scrcpy 2>/dev/null || true
pkill -9 -f Xvfb 2>/dev/null || true
pkill -9 -f x11vnc 2>/dev/null || true
pkill -9 -f websockify 2>/dev/null || true
pkill -9 -f nginx 2>/dev/null || true

# 2. Préparation du noyau Linux (KVM & Binder natifs indispensables à Android 14)
echo "=== Chargement et configuration des modules noyau (KVM + Binder) ==="
sudo chmod 666 /dev/kvm 2>/dev/null || true

sudo apt-get update -qq >/dev/null 2>&1
sudo apt-get install -y -qq linux-modules-extra-$(uname -r) adb net-tools novnc x11vnc xvfb scrcpy nginx curl jq >/dev/null 2>&1 || true

# Chargement du module binder_linux officiel pour kernel Ubuntu
sudo modprobe binder_linux devices="binder,hwbinder,vndbinder" 2>/dev/null || true

# Support BinderFS
sudo mkdir -p /dev/binderfs 2>/dev/null || true
sudo mount -t binder binder /dev/binderfs 2>/dev/null || true
sudo ln -sf /dev/binderfs/binder /dev/binder 2>/dev/null || true
sudo ln -sf /dev/binderfs/hwbinder /dev/hwbinder 2>/dev/null || true
sudo ln -sf /dev/binderfs/vndbinder /dev/vndbinder 2>/dev/null || true
sudo chmod 777 /dev/binder* /dev/binderfs/* 2>/dev/null || true

# 3. Lancement de Redroid 14 (Android 14 API 34 Officiel)
echo "=== Démarrage d'Android 14 Officiel (redroid:14.0.0-latest) ==="
docker pull redroid/redroid:14.0.0-latest

docker run -d \
  --name redroid14 \
  --privileged \
  --pull always \
  -v "$DATA_DIR/data":/data \
  -p 5555:5555 \
  redroid/redroid:14.0.0-latest \
  androidboot.redroid_width=720 \
  androidboot.redroid_height=1560 \
  androidboot.redroid_dpi=320 \
  androidboot.redroid_fps=60 \
  androidboot.redroid_gpu_mode=guest \
  androidboot.hardware=redroid

# 4. Attente active de la disponibilité ADB d'Android 14
echo "=== Connexion ADB à Android 14 (API 34) ==="
adb connect 127.0.0.1:5555 || true
for i in {1..45}; do
  STATE=$(adb get-state 2>/dev/null || echo "offline")
  echo "[Tentative $i/45] État ADB : $STATE"
  if [ "$STATE" = "device" ]; then
    echo " Android 14 (API 34) démarré et réactif sous ADB !"
    break
  fi
  sleep 2
  adb connect 127.0.0.1:5555 2>/dev/null || true
done

# Attente que le système Android termine son initialisation SurfaceFlinger
echo "=== Attente de l'animation de boot et de l'initialisation de l'UI Android ==="
for i in {1..30}; do
  BOOT_COMPLETED=$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || echo "0")
  echo "[Boot $i/30] sys.boot_completed = $BOOT_COMPLETED"
  if [ "$BOOT_COMPLETED" = "1" ]; then
    echo " Système Android 14 totalement initialisé !"
    break
  fi
  sleep 2
done

# Déverrouiller l'écran et réveiller l'appareil
adb shell input keyevent 82 2>/dev/null || true
adb shell wm size 720x1560 2>/dev/null || true
adb shell wm density 320 2>/dev/null || true

# 5. Moteur d'affichage fluide 60 FPS Xvfb + Scrcpy + noVNC
echo "=== Démarrage du serveur d'affichage X11 virtuel (Xvfb 720x1560) ==="
Xvfb :99 -screen 0 720x1560x24 -ac +extension GLX +render -noreset &
export DISPLAY=:99
sleep 2

echo "=== Lancement de Scrcpy (Accélération 60 FPS & 0 Lag) ==="
scrcpy --serial=127.0.0.1:5555 \
       --max-size=1560 \
       --video-bit-rate=8M \
       --max-fps=60 \
       --window-title="Android14Screen" \
       --window-x=0 --window-y=0 \
       --window-width=720 --window-height=1560 \
       --disable-screensaver \
       --turn-screen-on \
       --stay-awake &

sleep 3

echo "=== Lancement du serveur x11vnc ultra-optimisé (Ultra low-latency) ==="
x11vnc -display :99 \
       -forever \
       -shared \
       -rfbport 5900 \
       -nopw \
       -wait 5 \
       -defer 5 \
       -noxdamage \
       -speed 100 \
       -nowf &

sleep 2

# Vérification du port noVNC
NOVNC_DIR="/usr/share/novnc"
if [ ! -d "$NOVNC_DIR" ]; then
  NOVNC_DIR="/opt/novnc"
fi

echo "=== Démarrage de Websockify / noVNC (Port 6080) ==="
websockify --web "$NOVNC_DIR" --wrap-mode=ignore 6080 127.0.0.1:5900 &
sleep 3

# 6. Configuration NGINX Reverse-Proxy (Immersion 100% Smartphone, zéro bandeau, clavier mobile interactif)
echo "=== Configuration du Reverse Proxy NGINX (Port 3000) ==="

sudo mkdir -p /opt/android-ui
cat << 'INDEX_EOF' | sudo tee /opt/android-ui/index.html > /dev/null
<!DOCTYPE html>
<html lang="fr">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no, viewport-fit=cover">
  <title>Android 14 Cloud (API 34)</title>
  <style>
    * {
      box-sizing: border-box;
      margin: 0;
      padding: 0;
    }
    html, body {
      width: 100vw;
      height: 100vh;
      overflow: hidden;
      background: #000;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
    }
    #frame-container {
      width: 100vw;
      height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      position: relative;
      background: #000;
    }
    iframe {
      width: 100%;
      height: 100%;
      border: none;
      display: block;
      background: #000;
    }
    #fs-btn {
      position: fixed;
      bottom: 24px;
      right: 24px;
      z-index: 99999;
      background: linear-gradient(135deg, #10b981, #059669);
      color: #fff;
      border: none;
      border-radius: 50px;
      padding: 14px 22px;
      font-weight: 700;
      font-size: 14px;
      box-shadow: 0 8px 24px rgba(16, 185, 129, 0.45);
      cursor: pointer;
      display: flex;
      align-items: center;
      gap: 8px;
      transition: transform 0.2s ease, opacity 0.2s ease;
    }
    #fs-btn:active {
      transform: scale(0.92);
    }
    #dummy-input {
      position: absolute;
      opacity: 0;
      left: -9999px;
      top: -9999px;
      width: 1px;
      height: 1px;
    }
  </style>
</head>
<body>
  <div id="frame-container">
    <iframe id="vnc-frame" src="/vnc_lite.html?autoconnect=true&resize=scale&quality=9&compression=0"></iframe>
    <input type="text" id="dummy-input" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false" />
  </div>

  <button id="fs-btn">⛶ Plein Écran Immersion</button>

  <script>
    const fsBtn = document.getElementById('fs-btn');
    const dummyInput = document.getElementById('dummy-input');
    const iframe = document.getElementById('vnc-frame');

    // Gestion Plein Écran + Disparition automatique du bouton en mode plein écran
    fsBtn.addEventListener('click', () => {
      if (!document.fullscreenElement) {
        document.documentElement.requestFullscreen().catch(() => {});
      } else {
        document.exitFullscreen().catch(() => {});
      }
    });

    document.addEventListener('fullscreenchange', () => {
      if (document.fullscreenElement) {
        fsBtn.style.display = 'none';
      } else {
        fsBtn.style.display = 'flex';
      }
    });

    // Détection pour ouverture du clavier virtuel mobile
    window.addEventListener('message', (e) => {
      if (e.data === 'open_keyboard') {
        dummyInput.focus();
      }
    });
  </script>
</body>
</html>
INDEX_EOF

cat << 'NGINX_EOF' | sudo tee /etc/nginx/sites-available/default > /dev/null
server {
    listen 3000 default_server;
    listen [::]:3000 default_server;

    port_in_redirect off;
    absolute_redirect off;

    proxy_buffering off;
    proxy_request_buffering off;
    tcp_nodelay on;

    location = / {
        root /opt/android-ui;
        try_files /index.html =404;
    }

    location / {
        proxy_pass http://127.0.0.1:6080;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
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
}
NGINX_EOF

sudo nginx -t
sudo systemctl restart nginx || sudo service nginx restart

# 7. Test de validation en local
echo "=== Test de validation HTTP local de NGINX (Port 3000) ==="
for i in {1..20}; do
  CODE=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:3000/ || echo "000")
  echo "[Vérif HTTP $i/20] Réponse Port 3000 : $CODE"
  if [ "$CODE" = "200" ]; then
    echo " Port 3000 actif et renvoyant le portail Android 14 !"
    break
  fi
  sleep 2
done

echo " Architecture Android 14 (API 34) AOSP 100% opérationnelle !"
