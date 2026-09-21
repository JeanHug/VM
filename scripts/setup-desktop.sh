#!/usr/bin/env bash
set -e

echo "=== [1/3] Configuration de l'environnement de bureau web ==="

DATA_DIR="/home/runner/vm_data"
mkdir -p "$DATA_DIR"
sudo chown -R 1000:1000 "$DATA_DIR"

echo "=== [2/3] Démarrage du conteneur Webtop Ubuntu-XFCE ==="
docker pull lscr.io/linuxserver/webtop:ubuntu-xfce

# Lancement de l'environnement graphique avec accélération et audio
docker run -d \
  --name webtop \
  --restart unless-stopped \
  --security-opt seccomp=unconfined \
  -e PUID=1000 \
  -e PGID=1000 \
  -e TZ=Europe/Paris \
  -e SUBFOLDER=/ \
  -e TITLE="Web VM Linux (Persistent Relay)" \
  -p 3000:3000 \
  -v "$DATA_DIR":/config \
  --shm-size="2gb" \
  lscr.io/linuxserver/webtop:ubuntu-xfce

echo "=== [3/3] Vérification de disponibilité (Healthcheck) ==="
for i in {1..30}; do
  if curl -s -f http://127.0.0.1:3000/ > /dev/null 2>&1; then
    echo " Bureau Web disponible sur http://127.0.0.1:3000 (essai $i)"
    break
  fi
  echo "En attente du démarrage du bureau web ($i/30)..."
  sleep 2
done

# Installation d'outils essentiels dans le conteneur
echo "Installation des outils additionnels (git, curl, python, htop, nano)..."
docker exec -u 0 webtop bash -c "apt-get update && apt-get install -y --no-install-recommends git curl python3 python3-pip htop nano wget unzip && apt-get clean" || true

echo " Bureau Web prêt et opérationnel !"
