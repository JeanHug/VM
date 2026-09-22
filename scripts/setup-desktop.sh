#!/usr/bin/env bash
set -e

echo "=================================================="
echo "    CONFIGURATION BUREAU LINUX UBUNTU MODERNE     "
echo "=================================================="

DATA_DIR="/home/runner/vm_data"
mkdir -p "$DATA_DIR/Desktop" "$DATA_DIR/Downloads" "$DATA_DIR/Applications" "$DATA_DIR/.config" "$DATA_DIR/.local/bin"
sudo chown -R 1000:1000 "$DATA_DIR"

# 1. Démarrage de l'image Kasm Desktop Ubuntu complète (KasmVNC 60fps, WebAssembly, Google Chrome, audio, clipboard)
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
echo "=== Configuration du reverse-proxy NGINX (HTTP 3000 -> Kasm 6901 HTTPS + Autologin) ==="
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

# 4. Initialisation des optimisations de persistance dans le conteneur
echo "=== Application des règles de persistance 100% & comptes connectés ==="
docker exec -u 0 kasm_desktop bash -c '
  # Snapshot des paquets initiaux pour détecter les nouveaux paquets installés par l utilisateur
  if [ ! -f /etc/initial_manual_packages.txt ]; then
    apt-mark showmanual 2>/dev/null > /etc/initial_manual_packages.txt || true
  fi

  # Configuration de Google Chrome / Chromium pour que les comptes et mots de passe restent 100% connectés
  # --password-store=basic stocke les sessions dans le profil ~/.config plutôt que dans le trousseau volatile
  mkdir -p /home/kasm-user/.config
  cat << "FLAGS_EOF" > /home/kasm-user/.config/chrome-flags.conf
--password-store=basic
--no-default-browser-check
--disable-features=Translate
FLAGS_EOF
  cp /home/kasm-user/.config/chrome-flags.conf /home/kasm-user/.config/chromium-flags.conf 2>/dev/null || true

  # Raccourci d explications sur le bureau de l utilisateur
  cat << "README_EOF" > /home/kasm-user/Desktop/INSTALLER_DES_APPLICATIONS.txt
=====================================================
 COMMENT INSTALLER DES APPLICATIONS SUR CETTE VM ?
=====================================================

1. VIA LE TERMINAL (APT - Recommandé) :
   Ouvrez le Terminal (dans le menu des applications en bas à gauche) et tapez :
   sudo apt update && sudo apt install -y <nom-de-l-application>
   
   Exemples :
   - VLC Media Player : sudo apt install -y vlc
   - GIMP (Retouche photo) : sudo apt install -y gimp
   - Python & Pip : sudo apt install -y python3-pip
   - NodeJS / NPM : sudo apt install -y nodejs npm
   - Htop (Moniteur) : sudo apt install -y htop

   --> NOTRE SYSTÈME ENREGISTRE AUTOMATIQUEMENT LA LISTE DE VOS PAQUETS
       ET LES RÉINSTALLE AUTOMATIQUEMENT À CHAQUE RELAIS !

2. VIA DES APPLICATIONS PORTABLES (AppImage) :
   Téléchargez n importe quelle AppImage Linux (VS Code, Discord, Obsidian, etc.),
   placez-la dans votre dossier "Applications" ou sur le Bureau,
   clic droit -> Propriétés -> Rendre exécutable, et lancez-la !
   Elle sera conservée à 100% entre les sauvegardes.

3. VIA GOOGLE CHROME (Applications Web & PWA) :
   Ouvrez Chrome, allez sur WhatsApp Web, Discord, ChatGPT, Spotify, etc.,
   cliquez sur les 3 points en haut à droite -> "Enregistrer et partager" -> "Installer cette application".
   Elle apparaîtra dans votre menu et restera connectée 100% du temps !

4. VOS COMPTES & MOTS DE PASSE :
   Le navigateur est spécialement configuré pour stocker vos sessions de manière
   persistante. Vous restez connecté à vos comptes (Google, GitHub, etc.)
   même après le passage au cycle suivant !
=====================================================
README_EOF

  # Création d un script raccourci "install-app" dans le PATH
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
    echo "Réinstallation automatique des paquets utilisateurs : $(cat /home/kasm-user/.installed_packages.txt | tr "\n" " ")"
    apt-get update -qq && xargs -r -a /home/kasm-user/.installed_packages.txt apt-get install -y --no-install-recommends || true
  fi

  chown -R 1000:1000 /home/kasm-user
'

echo " Configuration 100% persistante terminée avec succès !"
