#!/usr/bin/env bash
set -euo pipefail

SB_PATH="${SB_PATH:-/usr/bin/sb}"
SBOX_DIR="${SBOX_DIR:-/etc/s-box}"
SING_BOX_BIN="${SING_BOX_BIN:-${SBOX_DIR}/sing-box}"
CLIENT_JSON="${SBOX_DIR}/sing_box_client.json"
CLASH_YAML="${SBOX_DIR}/clash_meta_client.yaml"
CLIENT_JSON_ALT="${SBOX_DIR}/sbox.json"
CLASH_YAML_ALT="${SBOX_DIR}/clmi.yaml"
DNS_LOG="${SBOX_DIR}/sbdnsip.log"
MERGED_SUB="${SBOX_DIR}/jh_sub.txt"
RAW_LINKS="${SBOX_DIR}/jhdy.txt"
MERGED_SUB_ALT="${SBOX_DIR}/jhsub.txt"

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Run as root." >&2
    exit 1
  fi
}

require_file() {
  local path="$1"
  if [[ ! -f "${path}" ]]; then
    echo "Missing file: ${path}" >&2
    exit 1
  fi
}

version_ge() {
  local current="$1"
  local minimum="$2"
  [[ "$(printf '%s\n%s\n' "${minimum}" "${current}" | sort -V | head -n1)" == "${minimum}" ]]
}

normalize_dns_server() {
  local raw="${1:-}"
  raw="${raw#tls://}"
  raw="${raw#https://}"
  raw="${raw#h3://}"
  raw="${raw%/dns-query}"
  raw="${raw#\[}"
  raw="${raw%\]}"
  printf '%s' "${raw}"
}

refresh_generated_configs() {
  local sub_log_file
  local client_log_file
  local merged_sub_path=""
  local client_json_path=""
  local clash_yaml_path=""
  sub_log_file="$(mktemp)"
  if ! printf '9\n1\n' | bash "${SB_PATH}" >"${sub_log_file}" 2>&1; then
    echo "Subscription refresh failed. See ${sub_log_file}" >&2
    tail -n 20 "${sub_log_file}" >&2 || true
    return 1
  fi

  if [[ -s "${MERGED_SUB}" ]]; then
    merged_sub_path="${MERGED_SUB}"
  elif [[ -s "${MERGED_SUB_ALT}" ]]; then
    merged_sub_path="${MERGED_SUB_ALT}"
  fi

  if [[ -z "${merged_sub_path}" || ! -s "${RAW_LINKS}" ]]; then
    echo "Subscription refresh finished, but subscription files were not generated. See ${sub_log_file}" >&2
    tail -n 20 "${sub_log_file}" >&2 || true
    return 1
  fi

  if [[ -s "${CLIENT_JSON}" ]]; then
    client_json_path="${CLIENT_JSON}"
  elif [[ -s "${CLIENT_JSON_ALT}" ]]; then
    client_json_path="${CLIENT_JSON_ALT}"
  fi

  if [[ -s "${CLASH_YAML}" ]]; then
    clash_yaml_path="${CLASH_YAML}"
  elif [[ -s "${CLASH_YAML_ALT}" ]]; then
    clash_yaml_path="${CLASH_YAML_ALT}"
  fi

  if [[ -z "${client_json_path}" || -z "${clash_yaml_path}" ]]; then
    client_log_file="$(mktemp)"
    if ! printf '9\n2\n' | bash "${SB_PATH}" >"${client_log_file}" 2>&1; then
      echo "Client config refresh failed. See ${client_log_file}" >&2
      tail -n 20 "${client_log_file}" >&2 || true
      return 1
    fi

    if [[ -s "${CLIENT_JSON}" ]]; then
      client_json_path="${CLIENT_JSON}"
    elif [[ -s "${CLIENT_JSON_ALT}" ]]; then
      client_json_path="${CLIENT_JSON_ALT}"
    fi

    if [[ -s "${CLASH_YAML}" ]]; then
      clash_yaml_path="${CLASH_YAML}"
    elif [[ -s "${CLASH_YAML_ALT}" ]]; then
      clash_yaml_path="${CLASH_YAML_ALT}"
    fi

    if [[ -z "${client_json_path}" || -z "${clash_yaml_path}" ]]; then
      echo "Client config refresh finished, but config files were not generated. See ${client_log_file}" >&2
      tail -n 20 "${client_log_file}" >&2 || true
      return 1
    fi
    rm -f "${client_log_file}"
  fi

  rm -f "${sub_log_file}"
  return 0
}

patch_sb_script() {
  local proxy_dns_server="$1"
  local backup_path
  backup_path="${SB_PATH}.bak.$(date -u +%Y%m%d%H%M%S)"
  cp -a "${SB_PATH}" "${backup_path}"
  export SB_PATH proxy_dns_server

  python3 <<'PY'
from pathlib import Path
import os
import sys

sb_path = Path(os.environ["SB_PATH"])
proxy_dns_server = os.environ["proxy_dns_server"]
script = sb_path.read_text(encoding="utf-8")
original = script

simple_replacements = [
    ("sbdnsip='tls://8.8.8.8/dns-query'", "sbdnsip='8.8.8.8'"),
    ("sbdnsip='tls://[2001:4860:4860::8888]/dns-query'", "sbdnsip='2001:4860:4860::8888'"),
]

for old, new in simple_replacements:
    script = script.replace(old, new)

old_dns_block = """        \"servers\": [
            {
                \"tag\": \"proxydns\",
                \"address\": \"$sbdnsip\",
                \"detour\": \"select\"
            },
            {
                \"tag\": \"localdns\",
                \"address\": \"h3://223.5.5.5/dns-query\",
                \"detour\": \"direct\"
            },
            {
                \"tag\": \"dns_fakeip\",
                \"address\": \"fakeip\"
            }
        ],
        \"rules\": [
            {
                \"outbound\": \"any\",
                \"server\": \"localdns\",
                \"disable_cache\": true
            },
            {
                \"clash_mode\": \"Global\",
                \"server\": \"proxydns\"
            },
            {
                \"clash_mode\": \"Direct\",
                \"server\": \"localdns\"
            },
            {
                \"rule_set\": \"geosite-cn\",
                \"server\": \"localdns\"
            },
            {
                 \"rule_set\": \"geosite-geolocation-!cn\",
                 \"server\": \"proxydns\"
            },
             {
                \"rule_set\": \"geosite-geolocation-!cn\",         
                \"query_type\": [
                    \"A\",
                    \"AAAA\"
                ],
                \"server\": \"dns_fakeip\"
            }
          ],
           \"fakeip\": {
           \"enabled\": true,
           \"inet4_range\": \"198.18.0.0/15\",
           \"inet6_range\": \"fc00::/18\"
         },
          \"independent_cache\": true,
          \"final\": \"proxydns\""""

new_dns_block = """        \"servers\": [
            {
                \"tag\": \"proxydns\",
                \"type\": \"tls\",
                \"server\": \"$sbdnsip\",
                \"server_port\": 853,
                \"tls\": {
                    \"enabled\": true,
                    \"server_name\": \"dns.google\"
                },
                \"detour\": \"select\"
            },
            {
                \"tag\": \"localdns\",
                \"type\": \"https\",
                \"server\": \"223.5.5.5\",
                \"server_port\": 443,
                \"path\": \"/dns-query\",
                \"tls\": {
                    \"enabled\": true,
                    \"server_name\": \"dns.alidns.com\"
                },
                \"detour\": \"direct\"
            },
            {
                \"tag\": \"dns_fakeip\",
                \"type\": \"fakeip\",
                \"inet4_range\": \"198.18.0.0/15\",
                \"inet6_range\": \"fc00::/18\"
            }
        ],
        \"rules\": [
            {
                \"clash_mode\": \"Global\",
                \"action\": \"route\",
                \"server\": \"proxydns\"
            },
            {
                \"clash_mode\": \"Direct\",
                \"action\": \"route\",
                \"server\": \"localdns\"
            },
            {
                \"rule_set\": \"geosite-cn\",
                \"action\": \"route\",
                \"server\": \"localdns\"
            },
            {
                \"rule_set\": \"geosite-geolocation-!cn\",         
                \"query_type\": [
                    \"A\",
                    \"AAAA\"
                ],
                \"action\": \"route\",
                \"server\": \"dns_fakeip\"
            },
            {
                 \"rule_set\": \"geosite-geolocation-!cn\",
                 \"action\": \"route\",
                 \"server\": \"proxydns\"
            }
          ],
          \"final\": \"proxydns\""""

legacy_found = old_dns_block in script
modern_markers = [
    '"tag": "proxyDns"',
    '"server": "dns.google"',
    '"type": "fakeip"',
]

if legacy_found:
    script = script.replace(old_dns_block, new_dns_block)
elif new_dns_block not in script:
    if all(marker in script for marker in modern_markers):
        print(f"Detected an already modern DNS template in {sb_path}, skipping /usr/bin/sb patch.")
        sys.exit(0)
    print("Failed to locate a supported DNS template block in /usr/bin/sb.", file=sys.stderr)
    sys.exit(1)

sb_path.write_text(script, encoding="utf-8", newline="\n")

if script == original:
    print(f"No changes were needed in {sb_path}.")
else:
    print(f"Patched {sb_path} for DNS compatibility.")
PY

  perl -0pi -e 's/\r\n/\n/g' "${SB_PATH}"
  bash -n "${SB_PATH}"
  echo "Backup saved to ${backup_path}"
}

patch_current_client_json() {
  local proxy_dns_server="$1"
  local target_json="${CLIENT_JSON}"
  if [[ ! -f "${target_json}" && -f "${CLIENT_JSON_ALT}" ]]; then
    target_json="${CLIENT_JSON_ALT}"
  fi
  if [[ ! -f "${target_json}" ]]; then
    return 0
  fi

  export CLIENT_JSON="${target_json}" proxy_dns_server
  python3 <<'PY'
from pathlib import Path
import json
import os

client_json = Path(os.environ["CLIENT_JSON"])
proxy_dns_server = os.environ["proxy_dns_server"]

data = json.loads(client_json.read_text(encoding="utf-8"))
detour_tag = "select"
for outbound in data.get("outbounds", []):
    tag = outbound.get("tag")
    if tag == "select":
        detour_tag = "select"
        break
    if tag == "proxy":
        detour_tag = "proxy"

data["dns"] = {
    "servers": [
        {
            "tag": "proxydns",
            "type": "tls",
            "server": proxy_dns_server,
            "server_port": 853,
            "tls": {
                "enabled": True,
                "server_name": "dns.google",
            },
            "detour": detour_tag,
        },
        {
            "tag": "localdns",
            "type": "https",
            "server": "223.5.5.5",
            "server_port": 443,
            "path": "/dns-query",
            "tls": {
                "enabled": True,
                "server_name": "dns.alidns.com",
            },
            "detour": "direct",
        },
        {
            "tag": "dns_fakeip",
            "type": "fakeip",
            "inet4_range": "198.18.0.0/15",
            "inet6_range": "fc00::/18",
        },
    ],
    "rules": [
        {
            "clash_mode": "Global",
            "action": "route",
            "server": "proxydns",
        },
        {
            "clash_mode": "Direct",
            "action": "route",
            "server": "localdns",
        },
        {
            "rule_set": "geosite-cn",
            "action": "route",
            "server": "localdns",
        },
        {
            "rule_set": "geosite-geolocation-!cn",
            "query_type": ["A", "AAAA"],
            "action": "route",
            "server": "dns_fakeip",
        },
        {
            "rule_set": "geosite-geolocation-!cn",
            "action": "route",
            "server": "proxydns",
        },
    ],
    "final": "proxydns",
}

client_json.write_text(
    json.dumps(data, ensure_ascii=False, indent=2) + "\n",
    encoding="utf-8",
)
print(f"Patched {client_json}.")
PY
}

main() {
  require_root
  require_file "${SB_PATH}"
  require_file "${SING_BOX_BIN}"

  local current_version
  current_version="$("${SING_BOX_BIN}" version 2>/dev/null | awk '/version/{print $NF; exit}')"
  if [[ -z "${current_version}" ]]; then
    echo "Failed to detect sing-box version from ${SING_BOX_BIN}." >&2
    exit 1
  fi

  if ! version_ge "${current_version}" "1.12.0"; then
    echo "sing-box ${current_version} is too old for this DNS patch." >&2
    echo "Install or switch to sing-box 1.12.0+ before applying it." >&2
    exit 1
  fi

  local proxy_dns_server="8.8.8.8"
  if [[ -f "${DNS_LOG}" ]]; then
    proxy_dns_server="$(normalize_dns_server "$(cat "${DNS_LOG}")")"
    if [[ -z "${proxy_dns_server}" ]]; then
      proxy_dns_server="8.8.8.8"
    fi
    printf '%s\n' "${proxy_dns_server}" > "${DNS_LOG}"
  fi

  patch_sb_script "${proxy_dns_server}"
  refresh_generated_configs
  patch_current_client_json "${proxy_dns_server}"

  echo "Patch applied successfully."
  echo "Current proxydns server: ${proxy_dns_server}"
  if [[ -f "${RAW_LINKS}" ]]; then
    echo "Raw node links: ${RAW_LINKS}"
  fi
  if [[ -f "${MERGED_SUB}" ]]; then
    echo "Merged subscription: ${MERGED_SUB}"
  elif [[ -f "${MERGED_SUB_ALT}" ]]; then
    echo "Merged subscription: ${MERGED_SUB_ALT}"
  fi
  if [[ -f "${CLIENT_JSON}" ]]; then
    echo "Updated client config: ${CLIENT_JSON}"
  elif [[ -f "${CLIENT_JSON_ALT}" ]]; then
    echo "Updated client config: ${CLIENT_JSON_ALT}"
  fi
  if [[ -f "${CLASH_YAML}" ]]; then
    echo "Clash config is available at: ${CLASH_YAML}"
  elif [[ -f "${CLASH_YAML_ALT}" ]]; then
    echo "Clash config is available at: ${CLASH_YAML_ALT}"
  fi
}

main "$@"
