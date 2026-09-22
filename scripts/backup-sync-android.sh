#!/usr/bin/env bash
set -e

ACTION="${1:-backup}"
SESSION_ID="${2:-session-android}"
DATA_DIR="/home/runner/android_vm_data/data"
BRANCH="vm-data-android"
ARCHIVE_NAME="android-data.tar.zst"

if [ -z "$GH_TOKEN" ] || [ -z "$GITHUB_REPOSITORY" ]; then
  echo "⚠️ Identifiants GitHub manquants, synchronisation ignorée."
  exit 0
fi

sudo mkdir -p "$DATA_DIR"
sudo chmod -R 777 "$DATA_DIR" 2>/dev/null || true

TMP_REPO=$(mktemp -d)

case "$ACTION" in
  restore)
    echo "=================================================="
    echo "   RESTAURATION DES DONNÉES ANDROID 13 (PERSISTANCE) "
    echo "=================================================="
    cd "$TMP_REPO"
    git init -q
    git config user.name "VM-Android-Sync"
    git config user.email "bot@vm.android.local"
    git remote add origin "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"

    if git fetch origin "$BRANCH" --depth=1 2>/dev/null; then
      git checkout -B "$BRANCH" origin/"$BRANCH"
      if [ -f "$ARCHIVE_NAME" ]; then
        echo " Archive persistante trouvée. Décompression..."
        sudo apt-get update -qq >/dev/null 2>&1 && sudo apt-get install -y -qq zstd tar >/dev/null 2>&1 || true
        sudo tar -I zstd -xf "$ARCHIVE_NAME" -C "$DATA_DIR" 2>/dev/null || true
        sudo chmod -R 777 "$DATA_DIR" 2>/dev/null || true
        echo " Données Android 13 restaurées avec succès !"
      else
        echo "ℹ️ Aucune archive $ARCHIVE_NAME sur la branche $BRANCH (première session)."
      fi
    else
      echo "ℹ️ Branche $BRANCH inexistante. Initialisation d'une nouvelle session Android."
    fi
    cd /
    rm -rf "$TMP_REPO"
    ;;

  backup)
    echo "=================================================="
    echo "   SAUVEGARDE DES DONNÉES ANDROID 13 (PERSISTANCE)   "
    echo "=================================================="
    if [ ! -d "$DATA_DIR" ] || [ -z "$(ls -A "$DATA_DIR" 2>/dev/null)" ]; then
      echo "ℹ️ Aucun fichier à sauvegarder pour Android."
      exit 0
    fi

    sudo apt-get update -qq >/dev/null 2>&1 && sudo apt-get install -y -qq zstd tar >/dev/null 2>&1 || true

    ARCHIVE_PATH="/tmp/$ARCHIVE_NAME"
    echo "Création de l'archive compressée zstd..."
    # Exclure les caches et sockets temporaires
    sudo tar -I "zstd -3 -T0" -cf "$ARCHIVE_PATH" -C "$DATA_DIR" \
      --exclude="cache" \
      --exclude="dalvik-cache" \
      --exclude="*.sock" \
      . 2>/dev/null || true

    cd "$TMP_REPO"
    git init -q
    git config user.name "VM-Android-Sync"
    git config user.email "bot@vm.android.local"
    git remote add origin "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git"
    git checkout -B "$BRANCH"

    git pull origin "$BRANCH" --rebase 2>/dev/null || true

    mv -f "$ARCHIVE_PATH" "$ARCHIVE_NAME"
    echo "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" > last_sync_android.txt

    git add "$ARCHIVE_NAME" last_sync_android.txt
    if ! git diff --staged --quiet; then
      git commit -m "chore(android-data): backup [$(date -u +'%Y-%m-%d %H:%M:%S UTC')]"
      git push --force origin "$BRANCH" 2>&1 | sed 's/'"$GH_TOKEN"'/REDACTED/g'
      echo " Données Android 13 synchronisées et sécurisées !"
    else
      echo "ℹ️ Aucun changement dans les données Android."
    fi
    cd /
    rm -rf "$TMP_REPO"
    ;;

  *)
    echo "Usage: $0 {restore|backup} [session_id]"
    exit 1
    ;;
esac
