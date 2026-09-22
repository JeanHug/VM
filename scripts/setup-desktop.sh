#!/usr/bin/env bash
set -e

echo "=================================================="
echo "    CONFIGURATION BUREAU LINUX UBUNTU MODERNE     "
echo "=================================================="

DATA_DIR="/home/runner/vm_data"
# Utilisation de sudo pour créer les dossiers afin d éviter toute erreur Permission Denied
sudo mkdir -p "$DATA_DIR/Desktop" "$DATA_DIR/Downloads" "$DATA_DIR/Applications" "$DATA_DIR/.config" "$DATA_DIR/.local/bin"
sudo chown -R 1000:1000 "$DATA_DIR"
sudo chmod -R 775 "$DATA_DIR"

# 1. Démarrage de l'image Kasm Desktop Ubuntu complète
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

sudo systemctl restart nginx

# 3. Attente que Kasm soit actif
echo "=== Attente de l'initialisation du bureau Kasm ==="
for i in {1..40}; do
  if curl -s -k https://127.0.0.1:6901/ > /dev/null 2>&1; then
    echo " Bureau moderne Ubuntu Kasm opérationnel !"
    break
  fi
  sleep 2
done

# 4. Optimisations du presse-papier & persistance dans le conteneur
echo "=== Configuration du presse-papier bidirectionnel & persistance ==="
docker exec -u 0 kasm_desktop bash -c '
  # Installation d utilitaires de presse-papier X11
  apt-get update -qq && apt-get install -y -qq xclip xsel autocutsel > /dev/null 2>&1 || true

  # Synchronisation automatique du presse-papier X11 (PRIMARY <-> CLIPBOARD)
  su - kasm-user -c "autocutsel -fork >/dev/null 2>&1 || true"
  su - kasm-user -c "autocutsel -selection PRIMARY -fork >/dev/null 2>&1 || true"

  # Snapshot des paquets initiaux pour détecter les nouveaux paquets installés
  if [ ! -f /etc/initial_manual_packages.txt ]; then
    apt-mark showmanual 2>/dev/null > /etc/initial_manual_packages.txt || true
  fi

  # Configuration de Google Chrome / Chromium pour la rétention des comptes
  mkdir -p /home/kasm-user/.config
  cat << "FLAGS_EOF" > /home/kasm-user/.config/chrome-flags.conf
--password-store=basic
--no-default-browser-check
--disable-features=Translate
FLAGS_EOF
  cp /home/kasm-user/.config/chrome-flags.conf /home/kasm-user/.config/chromium-flags.conf 2>/dev/null || true

  # Guide clair sur le Bureau avec explications copier/coller
  cat << "README_EOF" > /home/kasm-user/Desktop/INSTALLER_DES_APPLICATIONS.txt
=====================================================
 GUIDE RAPIDE VM LINUX & COPIER / COLLER
=====================================================

1. COMMENT COLLER DES COMMANDES DANS LA VM :
   - DANS LE TERMINAL LINUX : Utilisez CLIC DROIT -> COLLER
     ou faites CTRL + MAJ + V (car sous Linux, Ctrl+V dans
     un terminal est un caractère spécial).
   - VIA LE PANNEAU KASM (Très pratique) :
     Cliquez sur la petite flèche au milieu du bord gauche
     de votre écran pour ouvrir le menu Kasm, puis cliquez
     sur l icône Presse-papier (Clipboard) pour coller n importe
     quel texte immédiatement dans la VM !
   - EN PLEIN ÉCRAN : Ouvrez le lien dans un nouvel onglet
     pour autoriser l accès direct au presse-papier du navigateur.

2. INSTALLATION D APPLICATIONS (APT) :
   Ouvrez le Terminal et tapez simplement :
   sudo apt update && sudo apt install -y <nom_du_paquet>

   Exemples :
   - VLC : sudo apt install -y vlc
   - GIMP : sudo apt install -y gimp
   - Geany (Éditeur) : sudo apt install -y geany
   - Python 3 : sudo apt install -y python3-pip
   - Node.js : sudo apt install -y nodejs npm

   --> Toutes les applications sont 100% conservées entre les relais !
=====================================================
README_EOF

  # Script raccourci install-app
  cat << "INSTALLER_SCRIPT" > /usr/local/bin/install-app
#!/usr/bin/env bash
if [ -z "$1" ]; then
  echo "Usage: install-app <nom_du_paquet>"
  exit 1
fi
sudo apt-get update && sudo apt-get install -y "$@"
INSTALLER_SCRIPT
  chmod +x /usr/local/bin/install-app

  # Réinstallation automatique des paquets précédemment installés si la liste existe
  if [ -f /home/kasm-user/.installed_packages.txt ] && [ -s /home/kasm-user/.installed_packages.txt ]; then
    echo "Réinstallation automatique des paquets..."
    apt-get update -qq && xargs -r -a /home/kasm-user/.installed_packages.txt apt-get install -y --no-install-recommends || true
  fi

  chown -R 1000:1000 /home/kasm-user
'

echo " Bureau et presse-papier opérationnels sur le port 3000 !"
