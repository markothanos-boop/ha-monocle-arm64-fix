#!/usr/bin/with-contenv bashio
set -e

MONOCLE_CONFIG="/etc/monocle/monocle.json"
PROPERTIES="/etc/monocle/monocle.properties"
RESTART_MARKER="/run/monocle-certificate-restart"
MONOCLE_TOKEN=$(bashio::config 'monocle_token')
AUTO_DISCOVER=$(bashio::config 'auto_discover')
REFRESH_INTERVAL=$(bashio::config 'refresh_interval')
GATEWAY_HOST=$(bashio::config 'gateway_host')
GATEWAY_FQDN=$(bashio::config 'gateway_fqdn')
CERT_FILE=$(bashio::config 'cert_file')
KEY_FILE=$(bashio::config 'key_file')

if [ -z "$MONOCLE_TOKEN" ] || [ "$MONOCLE_TOKEN" = "null" ]; then
    bashio::log.error "Monocle token not configured"
    exit 1
fi

bashio::log.info "Running camera discovery..."
python3 /opt/monocle/discover_cameras.py
if [ ! -f /etc/monocle/monocle.token ]; then
    bashio::log.error "Monocle token file not created"
    exit 1
fi
if [ "$AUTO_DISCOVER" = "true" ] && [ ! -f "$MONOCLE_CONFIG" ]; then
    bashio::log.error "Monocle configuration not generated"
    exit 1
fi

: > "$PROPERTIES"
if [ -n "$GATEWAY_HOST" ] && [ "$GATEWAY_HOST" != "null" ]; then
    if ! [[ "$GATEWAY_HOST" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        bashio::log.error "gateway_host must be an IPv4 address"
        exit 1
    fi
    printf 'rtsp.register.host=%s\n' "$GATEWAY_HOST" >> "$PROPERTIES"
fi

check_certificate() {
    local cert_public key_public
    [ -r "$CERT_PATH" ] && [ -r "$KEY_PATH" ] || return 1
    openssl x509 -in "$CERT_PATH" -noout -checkend 86400 >/dev/null 2>&1 || return 1
    openssl x509 -in "$CERT_PATH" -noout -checkhost "$GATEWAY_FQDN" >/dev/null 2>&1 || return 1
    cert_public=$(openssl x509 -in "$CERT_PATH" -pubkey -noout 2>/dev/null) || return 1
    key_public=$(openssl pkey -in "$KEY_PATH" -passin pass: -pubout 2>/dev/null) || return 1
    [ -n "$cert_public" ] && [ "$cert_public" = "$key_public" ]
}

certificate_hash() {
    sha256sum "$CERT_PATH" "$KEY_PATH" 2>/dev/null | sha256sum | cut -d' ' -f1
}

CUSTOM_CERT=false
if [ -n "$GATEWAY_FQDN" ] && [ "$GATEWAY_FQDN" != "null" ]; then
    if ! [[ "$GATEWAY_FQDN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?\.[a-zA-Z]{2,}$ ]] ||
       ! [[ "$CERT_FILE" =~ ^[a-zA-Z0-9_-][a-zA-Z0-9_.-]*\.pem$ ]] ||
       ! [[ "$KEY_FILE" =~ ^[a-zA-Z0-9_-][a-zA-Z0-9_.-]*\.pem$ ]]; then
        bashio::log.error "Use a valid gateway_fqdn and PEM filenames without directory paths"
        exit 1
    fi
    CERT_PATH="/ssl/$CERT_FILE"
    KEY_PATH="/ssl/$KEY_FILE"
    if ! check_certificate; then
        bashio::log.error "Custom certificate/key missing, mismatched, wrong hostname, or expiring within 24 hours"
        exit 1
    fi
    CUSTOM_CERT=true
    printf 'rtsp.register.fqdn=%s\nrtsp.ssl.cert=%s\nrtsp.ssl.key=%s\n' \
        "$GATEWAY_FQDN" "$CERT_PATH" "$KEY_PATH" >> "$PROPERTIES"
    bashio::log.info "Using validated custom certificate for $GATEWAY_FQDN"
fi

GATEWAY_PID=""
WATCH_PID=""
cleanup() {
    [ -z "$WATCH_PID" ] || kill "$WATCH_PID" 2>/dev/null || true
    [ -z "$GATEWAY_PID" ] || kill "$GATEWAY_PID" 2>/dev/null || true
    rm -f "$RESTART_MARKER"
}
trap cleanup EXIT
trap 'exit 0' TERM INT
cd /opt/monocle
bashio::log.info "Local TCP port 443 must be reachable from Echo; no Internet port forwarding required"

while true; do
    rm -f "$RESTART_MARKER"
    CONFIG_HASH=$(sha256sum "$MONOCLE_CONFIG" 2>/dev/null | cut -d' ' -f1)
    CERT_HASH=""
    if [ "$CUSTOM_CERT" = "true" ]; then
        check_certificate || { bashio::log.error "Custom certificate validation failed"; exit 1; }
        CERT_HASH=$(certificate_hash)
    fi
    bashio::log.info "Starting Monocle Gateway..."
    ./monocle-gateway &
    GATEWAY_PID=$!
    (
        while kill -0 "$GATEWAY_PID" 2>/dev/null; do
            sleep "$REFRESH_INTERVAL"
            RESTART=false
            if [ "$CUSTOM_CERT" = "true" ] && [ "$(certificate_hash)" != "$CERT_HASH" ]; then
                if check_certificate; then
                    bashio::log.info "Renewed certificate detected; restarting gateway"
                    RESTART=true
                else
                    bashio::log.warning "Certificate files changed but are not yet valid; keeping current gateway"
                fi
            fi
            if [ "$AUTO_DISCOVER" = "true" ]; then
                if python3 /opt/monocle/discover_cameras.py; then
                    NEW_HASH=$(sha256sum "$MONOCLE_CONFIG" 2>/dev/null | cut -d' ' -f1)
                    if [ "$NEW_HASH" != "$CONFIG_HASH" ]; then
                        bashio::log.info "Camera configuration changed; restarting gateway"
                        RESTART=true
                    fi
                fi
            fi
            if [ "$RESTART" = "true" ]; then
                touch "$RESTART_MARKER"
                kill "$GATEWAY_PID" 2>/dev/null || true
                break
            fi
        done
    ) &
    WATCH_PID=$!
    GATEWAY_STATUS=0
    wait "$GATEWAY_PID" || GATEWAY_STATUS=$?
    GATEWAY_PID=""
    kill "$WATCH_PID" 2>/dev/null || true
    wait "$WATCH_PID" 2>/dev/null || true
    WATCH_PID=""
    if [ ! -f "$RESTART_MARKER" ]; then
        exit "$GATEWAY_STATUS"
    fi
done
