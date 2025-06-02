#!/bin/bash
# Copyright 2025 Google LLC
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

set -Eeuo pipefail

# Matches the most recent Terraform version supported by Infra Manager
# https://cloud.google.com/infrastructure-manager/docs/terraform
VERSION="1.5.7"

apk add --update --virtual .deps --no-cache gnupg && \
cd /tmp && \
wget https://releases.hashicorp.com/terraform/"${VERSION}"/terraform_"${VERSION}"_linux_amd64.zip && \
wget https://releases.hashicorp.com/terraform/"${VERSION}"/terraform_"${VERSION}"_SHA256SUMS && \
wget https://releases.hashicorp.com/terraform/"${VERSION}"/terraform_"${VERSION}"_SHA256SUMS.sig && \
wget -qO- https://www.hashicorp.com/.well-known/pgp-key.txt | gpg --import && \
gpg --verify terraform_"${VERSION}"_SHA256SUMS.sig terraform_"${VERSION}"_SHA256SUMS && \
grep terraform_"${VERSION}"_linux_amd64.zip terraform_"${VERSION}"_SHA256SUMS | sha256sum -c && \
unzip /tmp/terraform_"${VERSION}"_linux_amd64.zip -d /tmp && \
mv /tmp/terraform /usr/local/bin/terraform && \
rm -f /tmp/terraform_"${VERSION}"_linux_amd64.zip terraform_"${VERSION}"_SHA256SUMS "${VERSION}"/terraform_${VERSION}_SHA256SUMS.sig && \
apk del .deps

cd terraform/

TIMESTAMP=$(date +%s)
VM_NAME="github-presubmit-${TIMESTAMP}"

cat  <<EOF > main.tf
module "oracle_toolkit" {
  source = "./modules/oracle_toolkit_module"

  region                       = "us-central1"
  zone                         = "us-central1-a"
  project_id                   = "gcp-oracle-benchmarks"
  subnetwork                   = "default"
  vm_service_account           = "oracle-vm-runner@gcp-oracle-benchmarks.iam.gserviceaccount.com"
  control_node_service_account = "control-node-sa@gcp-oracle-benchmarks.iam.gserviceaccount.com"
  gcs_source                   = "gs://oracle-toolkit-presubmit-test-staging-artifacts/oracle-toolkit.zip"

  instance_name        = "${VM_NAME}"
  source_image_family  = "oracle-linux-8"
  source_image_project = "oracle-linux-cloud"
  machine_type         = "n4-standard-4"
  os_disk_size         = "100"
  os_disk_type         = "hyperdisk-balanced"

  fs_disks = [
    {
      auto_delete  = true
      boot         = false
      device_name  = "oracle-u01"
      disk_size_gb = 50
      disk_type    = "hyperdisk-balanced"
      disk_labels  = { purpose = "software" } # Do not modify this label
    }
  ]

  asm_disks = [
    {
      auto_delete  = true
      boot         = false
      device_name  = "oracle-data-1"
      disk_size_gb = 50
      disk_type    = "hyperdisk-balanced"
      disk_labels  = { diskgroup = "data", purpose = "asm" }
    },
    {
      auto_delete  = true
      boot         = false
      device_name  = "oracle-reco-2"
      disk_size_gb = 50
      disk_type    = "hyperdisk-balanced"
      disk_labels  = { diskgroup = "reco", purpose = "asm" }
    },
    {
      auto_delete  = true
      boot         = false
      device_name  = "swap"
      disk_size_gb = 50
      disk_type    = "hyperdisk-balanced"
      disk_labels  = { purpose = "swap" }
    }
  ]

  ora_swlib_bucket = "gs://bmaas-testing-oracle-software"
  ora_version      = "19"
  ora_backup_dest  = "+RECO"
  ora_db_name       = "test"
  ora_db_container  = false
  ntp_pref          = "169.254.169.254"
  oracle_release    = ""
  ora_edition       = ""
  ora_listener_port = ""
  ora_redo_log_size = ""
}
EOF

cat << EOF > backend.tf 
terraform {
  required_version = ">= $VERSION"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.20.0"
    }
  }

  backend "gcs" {
    bucket = "oracle-toolkit-presubmit-tf-state"
  }
}
EOF

terraform apply --auto-approve
