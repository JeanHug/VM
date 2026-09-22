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

# 1. Démarrage de l'image Kasm Desktop Ubuntu complète et interactive
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

# 4. Installation propre et sans conflit des applications officielles
echo "=== Configuration des applications & raccourcis sur le bureau ==="
docker exec -u 0 kasm_desktop bash -c '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y -qq xclip xsel autocutsel wget curl gnupg > /dev/null 2>&1 || true

  # Installation officielle de Google Chrome Stable si absent
  if ! command -v google-chrome-stable &>/dev/null && ! command -v google-chrome &>/dev/null; then
    wget -q -O - https://dl-ssl.google.com/linux/linux_signing_key.pub | gpg --dearmor --yes -o /usr/share/keyrings/google-chrome.gpg 2>/dev/null || true
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y -qq google-chrome-stable >/dev/null 2>&1 || true
  fi

  # Synchronisation du presse-papier X11
  su - kasm-user -c "autocutsel -fork >/dev/null 2>&1 || true"
  su - kasm-user -c "autocutsel -selection PRIMARY -fork >/dev/null 2>&1 || true"

  # Raccourcis directs sur le Bureau
  mkdir -p /home/kasm-user/Desktop

  # 1. Raccourci Google Chrome (avec flag sandbox docker propre)
  cat << "EOF_CHROME" > /home/kasm-user/Desktop/google-chrome.desktop
[Desktop Entry]
Version=1.0
Type=Application
Name=Google Chrome
GenericName=Navigateur Web
Comment=Naviguer sur le web
Exec=google-chrome-stable --no-sandbox --disable-dev-shm-usage %U
Icon=google-chrome
Terminal=false
Categories=Network;WebBrowser;
EOF_CHROME

  # 2. Raccourci Google Docs
  cat << "EOF_DOCS" > /home/kasm-user/Desktop/google-docs.desktop
[Desktop Entry]
Version=1.0
Type=Application
Name=Google Docs
GenericName=Traitement de texte
Comment=Accéder à Google Docs
Exec=google-chrome-stable --no-sandbox --disable-dev-shm-usage --app=https://docs.google.com %U
Icon=google-chrome
Terminal=false
Categories=Office;WordProcessor;
EOF_DOCS

  # 3. Raccourci Google Antigravity
  cat << "EOF_ANTIGRAV" > /home/kasm-user/Desktop/google-antigravity.desktop
[Desktop Entry]
Version=1.0
Type=Application
Name=Google Antigravity
GenericName=IA Autonome Google
Comment=Plateforme Agentique Google
Exec=google-chrome-stable --no-sandbox --disable-dev-shm-usage --app=https://antigravity.google %U
Icon=google-chrome
Terminal=false
Categories=Development;
EOF_ANTIGRAV

  # Permissions correctes pour que le clic fonctionne immédiatement
  chmod +x /home/kasm-user/Desktop/*.desktop 2>/dev/null || true
  chown -R 1000:1000 /home/kasm-user
'

echo " Bureau 100% interactif, Google Chrome, Docs et Antigravity configurés !"
