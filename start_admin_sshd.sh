#!/bin/bash
# This file is part of Bottlerocket.
# Copyright Amazon.com, Inc., its affiliates, or other contributors. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0 OR MIT
set -e

log() {
  echo "$*" >&2
}

declare -r local_user="ec2-user"
declare -r ssh_host_key_dir="/.bottlerocket/host-containers/admin/etc/ssh"
declare -r user_data="/.bottlerocket/host-containers/admin/user-data"
declare -r user_ssh_dir="/home/${local_user}/.ssh"
available_auth_methods=0

mkdir -p "${user_ssh_dir}"
chmod 700 "${user_ssh_dir}"

get_user_data_keys() {
    # Extract the keys from user-data json
    local raw_keys
    local key_type="${1:?}"
    if ! raw_keys=$(jq --arg key_type "${key_type}" -e -r '.["ssh"][$key_type][]' "${user_data}" 2>/dev/null); then
      log "Failed to parse ${key_type} from ${user_data}"
      return 1
    fi

    # Map the keys to avoid improper splitting
    local mapped_keys
    mapfile -t mapped_keys <<< "${raw_keys}"

    # Verify the keys are valid
    local key
    local -a valid_keys
    for key in "${mapped_keys[@]}"; do
      if ! echo "${key}" | ssh-keygen -lf - &>/dev/null; then
        log "Failed to validate ${key}"
        continue
      fi
      valid_keys+=( "${key}" )
    done

    ( IFS=$'\n'; echo "${valid_keys[*]}" )
}

# Populate authorized_keys with all the authorized keys found in user-data
if authorized_keys=$(get_user_data_keys "authorized_keys"); then
  ssh_authorized_keys="${user_ssh_dir}/authorized_keys"
  touch "${ssh_authorized_keys}"
  chmod 600 "${ssh_authorized_keys}"
  echo "${authorized_keys}" > "${ssh_authorized_keys}"
  ((++available_auth_methods))
fi

chown "${local_user}" -R "${user_ssh_dir}"

# If there were no successful auth methods, then users cannot authenticate
if [[ "${available_auth_methods}" -eq 0 ]]; then
  log "Failed to configure ssh authentication"
fi

# Generate the server keys
mkdir -p "${ssh_host_key_dir}"
for key in rsa ecdsa ed25519; do
  # If both of the keys exist, don't overwrite them
  if [ -s "${ssh_host_key_dir}/ssh_host_${key}_key" ] &&
  [ -s "${ssh_host_key_dir}/ssh_host_${key}_key.pub" ]; then
    log "${key} key already exists, will use existing key."
    continue
  fi

  rm -rf \
    "${ssh_host_key_dir}/ssh_host_${key}_key" \
    "${ssh_host_key_dir}/ssh_host_${key}_key.pub"
  if ssh-keygen -t "${key}" -f "${ssh_host_key_dir}/ssh_host_${key}_key" -q -N ""; then
    chmod 600 "${ssh_host_key_dir}/ssh_host_${key}_key"
    chmod 644 "${ssh_host_key_dir}/ssh_host_${key}_key.pub"
  else
    log "Failure to generate host ${key} ssh keys"
  fi
done

# Start a single sshd process in the foreground
exec /usr/sbin/sshd -e -D
