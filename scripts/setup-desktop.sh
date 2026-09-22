#!/usr/bin/env bash
set -e

echo "=================================================="
echo "    DÉMARRAGE DU BUREAU VIRTUEL LINUX (KASM)      "
echo "=================================================="

# 1. Vérification / Installation de Docker et NGINX
if ! command -v docker &> /dev/null; then
  echo "Installation de Docker..."
  sudo apt-get update -qq && sudo apt-get install -y -qq docker.io > /dev/null 2>&1
  sudo systemctl start docker
fi

if ! command -v nginx &> /dev/null; then
  echo "Installation de Nginx..."
  sudo apt-get update -qq && sudo apt-get install -y -qq nginx > /dev/null 2>&1
fi

# Nettoyage des conteneurs précédents
docker rm -f kasm_desktop 2>/dev/null || true

# 2. Lancement du conteneur Kasm Desktop Ubuntu Jammy
# Port 6901 exposé localement pour noVNC WebRTC haute performance
echo "Lancement du conteneur Kasm Desktop..."
docker run -d \
  --name kasm_desktop \
  --restart unless-stopped \
  --shm-size=2g \
  -p 127.0.0.1:6901:6901 \
  -e VNC_PW=vncpass \
  -e KASM_USER=kasm_user \
  -e KASM_PW=vncpass \
  kasmweb/ubuntu-jammy-desktop:1.16.0

# Attente que le bureau soit opérationnel
echo "Attente de l'initialisation du bureau Kasm..."
for i in {1..40}; do
  if docker exec kasm_desktop bash -c "test -d /home/kasm-user" 2>/dev/null; then
    echo " Conteneur Kasm prêt !"
    break
  fi
  sleep 2
done

# 3. Configuration du reverse-proxy NGINX sur le port 3000 avec Basic Auth intégrée
echo "Configuration du reverse proxy Nginx (port 3000)..."
cat << 'NGINX_EOF' | sudo tee /etc/nginx/sites-available/default > /dev/null
map $http_upgrade $connection_upgrade {
    default upgrade;
    '' close;
}

server {
    listen 3000 default_server;
    listen [::]:3000 default_server;

    location / {
        proxy_pass https://127.0.0.1:6901;
        proxy_ssl_verify off;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        
        # Autologin direct (kasm_user:vncpass)
        proxy_set_header Authorization "Basic a2FzbV91c2VyOnZuY3Bhc3M=";
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
NGINX_EOF

sudo nginx -t && sudo systemctl restart nginx || sudo service nginx restart

# 4. Installation et configuration intégrale dans le conteneur
echo "Installation des dépendances et navigateurs officiels..."
docker exec -u root kasm_desktop bash -c '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y -qq \
    curl \
    wget \
    gnupg \
    ca-certificates \
    libgbm1 \
    libnss3 \
    libasound2 \
    fonts-liberation \
    xdg-utils \
    desktop-file-utils \
    libgtk-3-0 \
    libxss1 \
    libsecret-1-0 >/dev/null 2>&1 || true

  # ----------------------------------------------------
  # 1. APPLICATION OFFICIELLE : GOOGLE CHROME STABLE
  # ----------------------------------------------------
  echo "Installation de Google Chrome officiel..."
  curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor --yes -o /usr/share/keyrings/google-chrome.gpg 2>/dev/null || true
  echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y -qq google-chrome-stable >/dev/null 2>&1 || {
    curl -sSL -o /tmp/google-chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
    dpkg -i /tmp/google-chrome.deb 2>/dev/null || apt-get install -y -f -qq >/dev/null 2>&1
    rm -f /tmp/google-chrome.deb
  }

  # Wrapper d exécution Google Chrome direct, sans récursion et sans crash sandbox
  cat << "CHROME_WRAPPER_EOF" > /usr/local/bin/google-chrome
#!/usr/bin/env bash
rm -f /home/kasm-user/.config/google-chrome/Singleton* 2>/dev/null || true
rm -f /home/kasm-user/.config/chromium/Singleton* 2>/dev/null || true

CHROME_EXEC=""
if [ -x /opt/google/chrome/chrome ]; then
  CHROME_EXEC="/opt/google/chrome/chrome"
elif [ -x /opt/google/chrome/google-chrome ]; then
  CHROME_EXEC="/opt/google/chrome/google-chrome"
elif [ -x /usr/bin/google-chrome-stable ]; then
  CHROME_EXEC="/usr/bin/google-chrome-stable"
elif [ -x /usr/bin/chromium-browser ]; then
  CHROME_EXEC="/usr/bin/chromium-browser"
elif [ -x /usr/bin/chromium ]; then
  CHROME_EXEC="/usr/bin/chromium"
fi

if [ -n "$CHROME_EXEC" ]; then
  exec "$CHROME_EXEC" \
    --no-sandbox \
    --disable-dev-shm-usage \
    --disable-gpu \
    --disable-software-rasterizer \
    --password-store=basic \
    --no-default-browser-check \
    --no-first-run \
    "$@"
else
  echo "Navigateur introuvable" >&2
  exit 1
fi
CHROME_WRAPPER_EOF
  chmod 755 /usr/local/bin/google-chrome
  cp -f /usr/local/bin/google-chrome /usr/local/bin/chrome 2>/dev/null || true

  # ----------------------------------------------------
  # 2. APPLICATION : GOOGLE DOCS (LANCEMENT DIRECT)
  # ----------------------------------------------------
  echo "Configuration de Google Docs..."
  cat << "DOCS_WRAPPER_EOF" > /usr/local/bin/google-docs
#!/usr/bin/env bash
rm -f /home/kasm-user/.config/google-chrome/Singleton* 2>/dev/null || true
exec /usr/local/bin/google-chrome --app="https://docs.google.com" "$@"
DOCS_WRAPPER_EOF
  chmod 755 /usr/local/bin/google-docs

  # Icône SVG officielle Google Docs
  cat << "DOCS_SVG_EOF" > /usr/share/icons/hicolor/scalable/apps/google-docs.svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48" width="128" height="128">
  <path fill="#4285F4" d="M30 4H12C9.79 4 8 5.79 8 8v32c0 2.21 1.79 4 4 4h24c2.21 0 4-1.79 4-4V16L30 4z"/>
  <path fill="#A1C2FA" d="M30 4v12h12L30 4z"/>
  <path fill="#FFFFFF" d="M16 22h16v2.5H16zm0 6h16v2.5H16zm0 6h10v2.5H16z"/>
</svg>
DOCS_SVG_EOF
  cp -f /usr/share/icons/hicolor/scalable/apps/google-docs.svg /usr/share/pixmaps/google-docs.svg 2>/dev/null || true

  # ----------------------------------------------------
  # 3. APPLICATION : GOOGLE ANTIGRAVITY (IDE & HUB)
  # ----------------------------------------------------
  echo "Installation de Google Antigravity..."
  mkdir -p /opt/google-antigravity /opt/antigravity-hub /home/kasm-user/Desktop
  
  if [ ! -d /opt/google-antigravity/bin ] && [ ! -f /opt/google-antigravity/antigravity ]; then
    curl -fsSL -o /tmp/antigravity-ide.tar.gz "https://edgedl.me.gvt1.com/edgedl/release2/j0qc3/antigravity/stable/2.5.5-4923483625488384/linux-x64/Antigravity%20IDE.tar.gz" 2>/dev/null || true
    if [ -f /tmp/antigravity-ide.tar.gz ]; then
      tar -xzf /tmp/antigravity-ide.tar.gz -C /opt/google-antigravity/ --strip-components=1 2>/dev/null || tar -xzf /tmp/antigravity-ide.tar.gz -C /opt/google-antigravity/ 2>/dev/null || true
      rm -f /tmp/antigravity-ide.tar.gz
    fi
  fi

  cat << "ANTIGRAVITY_WRAPPER_EOF" > /usr/local/bin/antigravity
#!/usr/bin/env bash
for bin in \
  "/opt/google-antigravity/antigravity" \
  "/opt/google-antigravity/Antigravity" \
  "/opt/google-antigravity/Antigravity IDE/antigravity" \
  "/opt/google-antigravity/bin/antigravity" \
  "/opt/antigravity-hub/antigravity" \
  "/opt/antigravity-hub/Antigravity" \
  "/home/kasm-user/.local/bin/agy"
do
  if [ -x "$bin" ]; then
    exec "$bin" --no-sandbox --disable-dev-shm-usage --disable-gpu "$@"
  fi
done
exec /usr/local/bin/google-chrome --app="https://antigravity.google" "$@"
ANTIGRAVITY_WRAPPER_EOF
  chmod 755 /usr/local/bin/antigravity
  cp -f /usr/local/bin/antigravity /usr/local/bin/google-antigravity 2>/dev/null || true

  # ----------------------------------------------------
  # RACCOURCIS BUREAU ET MENUS XFCE
  # ----------------------------------------------------
  mkdir -p /home/kasm-user/Desktop /usr/share/applications

  # Raccourci Google Chrome
  cat << "DESKTOP_CHROME_EOF" > /home/kasm-user/Desktop/google-chrome.desktop
[Desktop Entry]
Version=1.0
Type=Application
Name=Google Chrome
GenericName=Navigateur Web
Comment=Accéder à Internet et à vos applications web
Exec=/usr/local/bin/google-chrome %U
Icon=google-chrome
Terminal=false
Categories=Network;WebBrowser;StartupNotify=true
Actions=new-window;new-private-window;
DESKTOP_CHROME_EOF

  # Raccourci Google Docs
  cat << "DESKTOP_DOCS_EOF" > /home/kasm-user/Desktop/google-docs.desktop
[Desktop Entry]
Version=1.0
Type=Application
Name=Google Docs
GenericName=Traitement de texte en ligne
Comment=Créer et éditer des documents avec Google Docs
Exec=/usr/local/bin/google-docs %U
Icon=/usr/share/icons/hicolor/scalable/apps/google-docs.svg
Terminal=false
Categories=Office;WordProcessor;StartupNotify=true
DESKTOP_DOCS_EOF

  # Raccourci Google Antigravity
  cat << "DESKTOP_ANTIGRAVITY_EOF" > /home/kasm-user/Desktop/google-antigravity.desktop
[Desktop Entry]
Version=1.0
Type=Application
Name=Google Antigravity
GenericName=Plateforme IA Agentique & IDE
Comment=Plateforme de Développement Agentique & IA Autonome Google
Exec=/usr/local/bin/antigravity %U
Icon=/usr/share/icons/hicolor/scalable/apps/google-antigravity.svg
Terminal=false
Categories=Development;IDE;Utility;StartupNotify=true
DESKTOP_ANTIGRAVITY_EOF

  # Synchronisation dans le menu des applications XFCE
  cp -f /home/kasm-user/Desktop/google-chrome.desktop /usr/share/applications/
  cp -f /home/kasm-user/Desktop/google-docs.desktop /usr/share/applications/
  cp -f /home/kasm-user/Desktop/google-antigravity.desktop /usr/share/applications/

  # Permissions d exécution et approbation XFCE pour l utilisateur kasm-user
  chmod 755 /home/kasm-user/Desktop/*.desktop /usr/share/applications/*.desktop
  chown -R 1000:1000 /home/kasm-user
  su - kasm-user -c "gio set /home/kasm-user/Desktop/*.desktop metadata::trusted true 2>/dev/null || true"
'

echo " Bureau, Google Chrome, Google Docs et Antigravity configurés et prêts !"
