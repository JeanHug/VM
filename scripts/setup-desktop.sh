#!/usr/bin/env bash
set -e

echo "=================================================="
echo "    CONFIGURATION BUREAU LINUX UBUNTU MODERNE     "
echo "=================================================="

DATA_DIR="/home/runner/vm_data"

# Utilisation de sudo pour créer les dossiers afin d'éviter toute erreur Permission Denied
sudo mkdir -p "$DATA_DIR/Desktop" "$DATA_DIR/Downloads" "$DATA_DIR/Applications" "$DATA_DIR/.config" "$DATA_DIR/.local/bin"
sudo chown -R 1000:1000 "$DATA_DIR"
sudo chmod -R 775 "$DATA_DIR"

# Nettoyage des conteneurs précédents
docker rm -f kasm_desktop 2>/dev/null || true

# 1. Démarrage de l'image Kasm Desktop Ubuntu complète et réactive
echo "=== Téléchargement et lancement de Kasm Desktop Ubuntu ==="
docker pull kasmweb/ubuntu-jammy-desktop:1.16.0
docker run -d \
  --name kasm_desktop \
  --shm-size=2048m \
  -p 6901:6901 \
  -e VNC_PW=vncpass \
  -v "$DATA_DIR":/home/kasm-user \
  kasmweb/ubuntu-jammy-desktop:1.16.0

# 2. Configuration du reverse-proxy NGINX avec Authentification transparente
echo "=== Configuration du reverse-proxy NGINX ==="
sudo apt-get update -qq && sudo apt-get install -y -qq nginx > /dev/null 2>&1

cat << 'NGINX_EOF' | sudo tee /etc/nginx/sites-available/default > /dev/null
server {
    listen 3000 default_server;
    listen [::]:3000 default_server;

    location / {
        proxy_pass https://127.0.0.1:6901;
        proxy_ssl_verify off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        
        # Autologin direct sans pop-up de mot de passe (kasm_user:vncpass)
        proxy_set_header Authorization "Basic a2FzbV91c2VyOnZuY3Bhc3M=";
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
NGINX_EOF

sudo systemctl restart nginx || sudo service nginx restart

# 3. Attente que Kasm soit actif
echo "=== Attente de l'initialisation du bureau Kasm ==="
for i in {1..40}; do
  if curl -s -k https://127.0.0.1:6901/ > /dev/null 2>&1; then
    echo " Bureau moderne Ubuntu Kasm opérationnel !"
    break
  fi
  sleep 2
done

# 4. Optimisations du presse-papier & applications
echo "=== Configuration des applications et du presse-papier ==="
docker exec -u 0 kasm_desktop bash -c '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y -qq xclip xsel autocutsel wget curl gnupg > /dev/null 2>&1 || true

  # Synchronisation automatique du presse-papier X11
  su - kasm-user -c "autocutsel -fork >/dev/null 2>&1 || true"
  su - kasm-user -c "autocutsel -selection PRIMARY -fork >/dev/null 2>&1 || true"

  # Installation officielle de Google Chrome Stable
  if ! command -v google-chrome-stable &>/dev/null; then
    wget -q -O - https://dl-ssl.google.com/linux/linux_signing_key.pub | gpg --dearmor --yes -o /usr/share/keyrings/google-chrome.gpg 2>/dev/null || true
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y -qq google-chrome-stable >/dev/null 2>&1 || true
  fi

  # Wrappers directs simples (sans boucle de recherche)
  cat << "CHROME_EOF" > /usr/local/bin/google-chrome
#!/usr/bin/env bash
exec /usr/bin/google-chrome-stable --no-sandbox --disable-dev-shm-usage --disable-gpu --password-store=basic --no-default-browser-check "$@"
CHROME_EOF
  chmod 755 /usr/local/bin/google-chrome
  cp -f /usr/local/bin/google-chrome /usr/local/bin/chrome 2>/dev/null || true

  cat << "DOCS_EOF" > /usr/local/bin/google-docs
#!/usr/bin/env bash
exec /usr/bin/google-chrome-stable --no-sandbox --disable-dev-shm-usage --disable-gpu --password-store=basic --app="https://docs.google.com" "$@"
DOCS_EOF
  chmod 755 /usr/local/bin/google-docs

  cat << "ANTIGRAV_EOF" > /usr/local/bin/google-antigravity
#!/usr/bin/env bash
exec /usr/bin/google-chrome-stable --no-sandbox --disable-dev-shm-usage --disable-gpu --password-store=basic --app="https://antigravity.google" "$@"
ANTIGRAV_EOF
  chmod 755 /usr/local/bin/google-antigravity
  cp -f /usr/local/bin/google-antigravity /usr/local/bin/antigravity 2>/dev/null || true

  # Icône SVG officielle Google Antigravity (Prisme / Étoile Google)
  mkdir -p /usr/share/icons/hicolor/scalable/apps /usr/share/pixmaps
  cat << "SVG_ANTIGRAV" > /usr/share/icons/hicolor/scalable/apps/google-antigravity.svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="128" height="128">
  <defs>
    <linearGradient id="bgGrad" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" stop-color="#1B1C20"/>
      <stop offset="100%" stop-color="#0E0F12"/>
    </linearGradient>
    <linearGradient id="sparkGrad" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" stop-color="#4285F4"/>
      <stop offset="30%" stop-color="#9B72CB"/>
      <stop offset="70%" stop-color="#D96570"/>
      <stop offset="100%" stop-color="#F4B400"/>
    </linearGradient>
    <linearGradient id="orbitGrad" x1="0%" y1="0%" x2="100%" y2="100%">
      <stop offset="0%" stop-color="#4285F4"/>
      <stop offset="50%" stop-color="#34A853"/>
      <stop offset="100%" stop-color="#FBBC04"/>
    </linearGradient>
  </defs>
  <rect width="64" height="64" rx="14" fill="url(#bgGrad)" stroke="#2D3035" stroke-width="1.5"/>
  <ellipse cx="32" cy="32" rx="25" ry="11" fill="none" stroke="url(#orbitGrad)" stroke-width="2.2" transform="rotate(-28 32 32)" stroke-dasharray="5 3"/>
  <path d="M32 10 C32 22 22 32 10 32 C22 32 32 42 32 54 C32 42 42 32 54 32 C42 32 32 22 32 10 Z" fill="url(#sparkGrad)"/>
  <circle cx="32" cy="32" r="3.5" fill="#FFFFFF"/>
</svg>
SVG_ANTIGRAV
  cp -f /usr/share/icons/hicolor/scalable/apps/google-antigravity.svg /usr/share/pixmaps/google-antigravity.svg 2>/dev/null || true

  # Icône SVG officielle Google Docs
  cat << "SVG_DOCS" > /usr/share/icons/hicolor/scalable/apps/google-docs.svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48" width="128" height="128">
  <path fill="#4285F4" d="M30 4H12C9.79 4 8 5.79 8 8v32c0 2.21 1.79 4 4 4h24c2.21 0 4-1.79 4-4V16L30 4z"/>
  <path fill="#A1C2FA" d="M30 4v12h12L30 4z"/>
  <path fill="#FFFFFF" d="M16 22h16v2.5H16zm0 6h16v2.5H16zm0 6h10v2.5H16z"/>
</svg>
SVG_DOCS
  cp -f /usr/share/icons/hicolor/scalable/apps/google-docs.svg /usr/share/pixmaps/google-docs.svg 2>/dev/null || true

  # Raccourcis Bureau XFCE
  mkdir -p /home/kasm-user/Desktop

  cat << "DESKTOP_CHROME" > /home/kasm-user/Desktop/google-chrome.desktop
[Desktop Entry]
Version=1.0
Type=Application
Name=Google Chrome
GenericName=Navigateur Web
Exec=/usr/local/bin/google-chrome %U
Icon=google-chrome
Terminal=false
Categories=Network;WebBrowser;
DESKTOP_CHROME

  cat << "DESKTOP_ANTIGRAV" > /home/kasm-user/Desktop/google-antigravity.desktop
[Desktop Entry]
Version=1.0
Type=Application
Name=Google Antigravity
GenericName=Plateforme IA Agentique
Exec=/usr/local/bin/google-antigravity %U
Icon=/usr/share/icons/hicolor/scalable/apps/google-antigravity.svg
Terminal=false
Categories=Development;
DESKTOP_ANTIGRAV

  cat << "DESKTOP_DOCS" > /home/kasm-user/Desktop/google-docs.desktop
[Desktop Entry]
Version=1.0
Type=Application
Name=Google Docs
GenericName=Traitement de texte
Exec=/usr/local/bin/google-docs %U
Icon=/usr/share/icons/hicolor/scalable/apps/google-docs.svg
Terminal=false
Categories=Office;
DESKTOP_DOCS

  chmod 755 /home/kasm-user/Desktop/*.desktop
  chown -R 1000:1000 /home/kasm-user
  su - kasm-user -c "gio set /home/kasm-user/Desktop/*.desktop metadata::trusted true 2>/dev/null || true"
'

echo " Bureau opérationnel, rapide et fluide !"
