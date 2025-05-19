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

locals {
  # Takes the list of filesystem disks and converts them into a list of objects with the required fields by ansible
  data_mounts_config = [
    for i, d in var.fs_disks : {
      purpose     = d.disk_labels.purpose
      blk_device  = "/dev/disk/by-id/google-${d.device_name}"
      name        = format("u%02d", i + 1)
      fstype      = "xfs"
      mount_point = format("/u%02d", i + 1)
      mount_opts  = "nofail"
    }
  ]

  # Takes the list of asm disks and converts them into a list of objects with the required fields by ansible
  asm_disk_config = [
    for g in distinct([for d in var.asm_disks : d.disk_labels.diskgroup if lookup(d.disk_labels, "diskgroup", null) != null]) : {
      diskgroup = upper(g)
      disks = [
        for d in var.asm_disks : {
          blk_device = "/dev/disk/by-id/google-${d.device_name}"
          name       = d.device_name
        } if lookup(d.disk_labels, "diskgroup", null) == g
      ]
    }
  ]

  # Concatenetes both lists to be passed down to the instance module
  additional_disks = concat(var.fs_disks, var.asm_disks)

  project_id = var.project_id
}

# Instance template module
module "instance_template" {
  source  = "terraform-google-modules/vm/google//modules/instance_template"
  version = "~> 13.0"

  name_prefix        = format("%s-template", var.instance_name)
  region             = var.region
  project_id         = local.project_id
  subnetwork         = var.subnetwork
  subnetwork_project = local.project_id
  service_account = {
    email  = var.service_account_email
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  machine_type         = var.machine_type
  source_image_family  = var.source_image_family
  source_image_project = var.source_image_project
  disk_size_gb         = var.os_disk_size
  disk_type            = var.os_disk_type
  auto_delete          = true


  metadata = {
    metadata_startup_script = var.metadata_startup_script
  }

  additional_disks = local.additional_disks

  tags = var.network_tags
}

# Compute instance module
module "compute_instance" {
  source  = "terraform-google-modules/vm/google//modules/compute_instance"
  version = "~> 13.0"

  region              = var.region
  zone                = var.zone
  subnetwork          = var.subnetwork
  subnetwork_project  = local.project_id
  hostname            = var.instance_name
  instance_template   = module.instance_template.self_link
  deletion_protection = false

  access_config = [
    {
      nat_ip       = null
      network_tier = "PREMIUM"
    }
  ]
}

# Local provisioner to run the Oracle Toolkit
resource "null_resource" "oracle_toolkit" {
  for_each = { for i, instance in module.compute_instance.instances_details : i => instance }

  provisioner "local-exec" {
    working_dir = "../"
    command     = <<-EOT
      until gcloud compute ssh ${each.value.name} --zone=${var.zone} --internal-ip --command="echo ready" --quiet; do
        echo "Waiting for SSH to become available on ${each.value.name}..."
        sleep 10
      done

      bash install-oracle.sh \
      --instance-hostname ${each.value.name} \
      --ora-asm-disks-json '${jsonencode(local.asm_disk_config)}' \
      --ora-data-mounts-json '${jsonencode(local.data_mounts_config)}' \
      --swap-blk-device "/dev/disk/by-id/google-swap" \
      --ora-swlib-bucket "${var.ora_swlib_bucket}" \
      --ora-version "${var.ora_version}" \
      --backup-dest "${var.ora_backup_dest}" \
      ${var.ora_db_name != "" ? "--ora-db-name ${var.ora_db_name}" : ""} \
      ${var.ora_db_container != "" ? "--ora-db-container ${lower(var.ora_db_container)}" : ""} \
      ${var.ntp_pref != "" ? "--ntp-pref ${var.ntp_pref}" : ""} \
      ${var.oracle_release != "" ? "--oracle-release ${var.oracle_release}" : ""} \
      ${var.ora_edition != "" ? "--ora-edition ${var.ora_edition}" : ""} \
      ${var.ora_listener_port != "" ? "--ora-listener-port ${var.ora_listener_port}" : ""} \
      ${var.ora_redo_log_size != "" ? "--ora-redo-log-size ${var.ora_redo_log_size}" : ""} &
    EOT
  }

  depends_on = [module.compute_instance]
}
