#!/bin/sh

# Shared helpers for the subscription and manual-node managers.

write_managed_config() {
    managed_config_target=$1
    cat > "$managed_config_target" <<'MANAGED_CONFIG'
# Managed by the Xiaomi Smart Storage Mihomo plugin.
# The previous configuration is preserved as config.before-subscription.yaml.
mixed-port: 7890
allow-lan: false
bind-address: 127.0.0.1
mode: rule
log-level: info
ipv6: false

proxy-providers:
  APP-SUBSCRIPTION:
    type: file
    path: ./providers/app-subscription.yaml
    health-check:
      enable: true
      url: https://www.gstatic.com/generate_204
      interval: 300
  APP-MANUAL:
    type: file
    path: ./providers/app-manual.yaml
    health-check:
      enable: true
      url: https://www.gstatic.com/generate_204
      interval: 300

proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - DIRECT
    use:
      - APP-SUBSCRIPTION
      - APP-MANUAL

rules:
  - MATCH,PROXY
MANAGED_CONFIG
}

ensure_empty_provider() {
    empty_provider_target=$1
    if [ ! -s "$empty_provider_target" ]; then
        printf '%s\n' '{"proxies":[]}' > "$empty_provider_target"
        chmod 0600 "$empty_provider_target"
    fi
}

