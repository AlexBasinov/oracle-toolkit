#!/bin/bash
# Copyright 2023 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -e

if [ ! -f "gcp_oracle.yml" ]; then
    echo "Configuration file gcp_oracle.yml not found."
    echo "Please create one from the gcp_oracle.yml.example template."
    exit 1
fi

if ! command -v yq &> /dev/null
then
    echo "yq could not be found. Please install yq to use this script."
    exit 1
fi

# Create a temporary copy of gcp_oracle.yml to apply command-line overrides without modifying the original file.
TEMP_CONFIG_FILE=$(mktemp gcp_oracle.yml.XXXXXX)
trap 'rm -f ${TEMP_CONFIG_FILE}' EXIT
cp gcp_oracle.yml "${TEMP_CONFIG_FILE}"

# Map command-line flags to their corresponding keys in gcp_oracle.yml.
# This allows overriding of YAML configuration values with command-line arguments.
declare -A FLAG_MAP
FLAG_MAP["--ora-version"]="ora_version"
FLAG_MAP["--ora-release"]="ora_release"
FLAG_MAP["--ora-edition"]="ora_edition"
FLAG_MAP["--cluster-type"]="cluster_type"
FLAG_MAP["--ora-swlib-bucket"]="ora_swlib_bucket"
FLAG_MAP["--ora-swlib-type"]="ora_swlib_type"
FLAG_MAP["--ora-swlib-path"]="ora_swlib_path"
FLAG_MAP["--ora-staging"]="ora_staging"
FLAG_MAP["--ora-disk-mgmt"]="ora_disk_mgmt"
FLAG_MAP["--ora-role-separation"]="ora_role_separation"
FLAG_MAP["--ora-data-destination"]="ora_data_destination"
FLAG_MAP["--ora-reco-destination"]="ora_reco_destination"
FLAG_MAP["--ora-asm-disks"]="ora_asm_disks"
FLAG_MAP["--ora-asm-disks-json"]="ora_asm_disks_json"
FLAG_MAP["--ora-data-mounts-json"]="ora_data_mounts_json"
FLAG_MAP["--swap-blk-device"]="swap_blk_device"
FLAG_MAP["--ora-db-name"]="ora_db_name"
FLAG_MAP["--ora-db-domain"]="ora_db_domain"
FLAG_MAP["--ora-db-charset"]="ora_db_charset"
FLAG_MAP["--ora-db-ncharset"]="ora_db_ncharset"
FLAG_MAP["--ora-db-container"]="ora_db_container"
FLAG_MAP["--ora-db-type"]="ora_db_type"
FLAG_MAP["--ora-pdb-name-prefix"]="ora_pdb_name_prefix"
FLAG_MAP["--ora-pdb-count"]="ora_pdb_count"
FLAG_MAP["--ora-redo-log-size"]="ora_redo_log_size"
FLAG_MAP["--ora-pga-target-mb"]="ora_pga_target_mb"
FLAG_MAP["--ora-sga-target-mb"]="ora_sga_target_mb"
FLAG_MAP["--db-password-secret"]="db_password_secret"
FLAG_MAP["--ora-listener-name"]="ora_listener_name"
FLAG_MAP["--ora-listener-port"]="ora_listener_port"
FLAG_MAP["--instance-ip-addr"]="instance_ip_addr"
FLAG_MAP["--instance-hostname"]="instance_hostname"
FLAG_MAP["--instance-ssh-user"]="instance_ssh_user"
FLAG_MAP["--instance-ssh-key"]="instance_ssh_key"
FLAG_MAP["--instance-ssh-extra-args"]="instance_ssh_extra_args"
FLAG_MAP["--ntp-pref"]="ntp_pref"
FLAG_MAP["--backup-dest"]="backup_dest"
FLAG_MAP["--backup-redundancy"]="backup_redundancy"
FLAG_MAP["--archive-redundancy"]="archive_redundancy"
FLAG_MAP["--archive-online-days"]="archive_online_days"
FLAG_MAP["--backup-level0-days"]="backup_level0_days"
FLAG_MAP["--backup-level1-days"]="backup_level1_days"
FLAG_MAP["--backup-start-hour"]="backup_start_hour"
FLAG_MAP["--backup-start-min"]="backup_start_min"
FLAG_MAP["--archive-backup-min"]="archive_backup_min"
FLAG_MAP["--backup-script-location"]="backup_script_location"
FLAG_MAP["--backup-log-location"]="backup_log_location"
FLAG_MAP["--gcs-backup-config"]="gcs_backup_config"
FLAG_MAP["--gcs-backup-bucket"]="gcs_backup_bucket"
FLAG_MAP["--gcs-backup-temp-path"]="gcs_backup_temp_path"
FLAG_MAP["--nfs-backup-config"]="nfs_backup_config"
FLAG_MAP["--nfs-backup-mount"]="nfs_backup_mount"
FLAG_MAP["--install-workload-agent"]="install_workload_agent"
FLAG_MAP["--oracle-metrics-secret"]="oracle_metrics_secret"
FLAG_MAP["--skip-platform-compatibility"]="skip_platform_compatibility"
FLAG_MAP["--compatible-rdbms"]="compatible_rdbms"
FLAG_MAP["--instance-hostgroup-name"]="instance_hostgroup_name"

ANSIBLE_ARGS=()
# Process command-line arguments.
# Flags recognized in FLAG_MAP will override values in the temporary gcp_oracle.yml.
# Unrecognized flags are collected into ANSIBLE_ARGS to be passed directly to ansible-playbook.
while [[ $# -gt 0 ]]; do
  FLAG="$1"
  if [[ -n "${FLAG_MAP[${FLAG}]}" ]]; then
    VALUE="$2"
    yq e ".${FLAG_MAP[${FLAG}]} = \"${VALUE}\"" -i "${TEMP_CONFIG_FILE}"
    shift 2
  else
    ANSIBLE_ARGS+=("$1")
    shift
  fi
done

# Playbooks to run
PB_VALIDATE="validate-config.yml"
PB_CHECK_INSTANCE="check-instance.yml"
PB_PREP_HOST="prep-host.yml"
PB_INSTALL_SW="install-sw.yml"
PB_CONFIG_DB="config-db.yml"
PB_CONFIG_RAC_DB="config-rac-db.yml"
PB_COMPATIBLE="compatibility-tests.yml"

PB_LIST="${PB_VALIDATE} ${PB_CHECK_INSTANCE} ${PB_PREP_HOST} ${PB_INSTALL_SW} ${PB_CONFIG_DB} ${PB_COMPATIBLE}"

CLUSTER_TYPE=$(yq e '.cluster_type' "${TEMP_CONFIG_FILE}")

if [[ "${CLUSTER_TYPE}" = "RAC" ]]; then
  PB_LIST=${PB_LIST/$PB_CONFIG_DB/$PB_CONFIG_RAC_DB}
fi

# Run playbooks
for PLAYBOOK in ${PB_LIST}; do
  ansible-playbook -i "${TEMP_CONFIG_FILE}" "${PLAYBOOK}" "${ANSIBLE_ARGS[@]}"
done
