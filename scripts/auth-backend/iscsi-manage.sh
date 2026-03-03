#!/bin/bash
# =============================================================================
# iscsi-manage.sh – iSCSI-Target Verwaltung fuer NetBoot Auth-Backend
# =============================================================================
# Wird vom Flask-Backend via sudo aufgerufen.
# Erstellt und verwaltet per-User iSCSI-Targets (tgt).
#
# Usage:
#   iscsi-manage.sh exists <username>   – Prueft ob Image existiert
#   iscsi-manage.sh create <username>   – Erstellt Image + Target
#   iscsi-manage.sh delete <username>   – Loescht Image + Target
# =============================================================================

set -euo pipefail

# --- Konfiguration ---
ISCSI_DIR="/srv/netboot/iscsi"
ISCSI_DISK_SIZE="60G"
ISCSI_IQN_PREFIX="iqn.2024-01.local.lab.netboot"
ISCSI_NETWORK="10.10.0.0/24"
TGT_CONF_DIR="/etc/tgt/conf.d"

ACTION="${1:-}"
USERNAME="${2:-}"

# --- Validierung ---
if [[ -z "${USERNAME}" ]]; then
    echo "ERROR: Kein Benutzername angegeben" >&2
    exit 1
fi

# Nur alphanumerisch, Bindestrich und Unterstrich erlaubt
if [[ ! "${USERNAME}" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    echo "ERROR: Ungueltiger Benutzername: ${USERNAME}" >&2
    exit 1
fi

IMAGE_PATH="${ISCSI_DIR}/${USERNAME}.img"
CONF_PATH="${TGT_CONF_DIR}/${USERNAME}.conf"
TARGET_IQN="${ISCSI_IQN_PREFIX}:${USERNAME}"

# --- Aktionen ---
case "${ACTION}" in
    exists)
        if [[ -f "${IMAGE_PATH}" ]]; then
            echo "true"
        else
            echo "false"
        fi
        ;;

    create)
        if [[ -f "${IMAGE_PATH}" ]]; then
            echo "exists"
            exit 0
        fi

        # Sparse Disk-Image erstellen (belegt nur genutzten Platz)
        truncate -s "${ISCSI_DISK_SIZE}" "${IMAGE_PATH}"

        # tgt-Konfiguration erstellen
        cat > "${CONF_PATH}" <<EOF
<target ${TARGET_IQN}>
    backing-store ${IMAGE_PATH}
    initiator-address ${ISCSI_NETWORK}
</target>
EOF

        # Target aktivieren
        tgt-admin --update ALL 2>/dev/null || true

        echo "created"
        ;;

    delete)
        # Target offline nehmen
        if tgtadm --lld iscsi --op show --mode target 2>/dev/null | grep -q "${TARGET_IQN}"; then
            # Target-ID finden
            TID=$(tgtadm --lld iscsi --op show --mode target | \
                  grep -B1 "Target.*${TARGET_IQN}" | \
                  grep -oP 'Target \K[0-9]+')
            if [[ -n "${TID}" ]]; then
                tgtadm --lld iscsi --op delete --mode target --tid "${TID}" --force 2>/dev/null || true
            fi
        fi

        # Konfiguration und Image loeschen
        rm -f "${CONF_PATH}"
        rm -f "${IMAGE_PATH}"

        echo "deleted"
        ;;

    *)
        echo "Usage: $0 {exists|create|delete} <username>" >&2
        exit 1
        ;;
esac
