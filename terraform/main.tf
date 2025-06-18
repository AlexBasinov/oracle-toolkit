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
  fs_disks = [
    {
      auto_delete  = true
      boot         = false
      device_name  = "oracle_home"
      disk_size_gb = var.oracle_home_disk.size_gb
      disk_type    = var.oracle_home_disk.type
      disk_labels  = { purpose = "software" } # Do not modify this label
    }
  ]
  asm_disks = [
    {
      auto_delete  = true
      boot         = false
      device_name  = "data"
      disk_size_gb = var.data_disk.size_gb
      disk_type    = var.data_disk.type
      disk_labels  = { diskgroup = "data", purpose = "asm" }
    },
    {
      auto_delete  = true
      boot         = false
      device_name  = "reco"
      disk_size_gb = var.reco_disk.size_gb
      disk_type    = var.reco_disk.type
      disk_labels  = { diskgroup = "reco", purpose = "asm" }
    },
    {
      auto_delete  = true
      boot         = false
      device_name  = "swap"
      disk_size_gb = var.swap_disk_size_gb
      disk_type    = var.swap_disk_type
      disk_labels  = { purpose = "swap" }
    }
  ]

  # Takes the list of filesystem disks and converts them into a list of objects with the required fields by ansible
  data_mounts_config = [
    for i, d in local.fs_disks : {
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
    for g in distinct([for d in local.asm_disks : d.disk_labels.diskgroup if lookup(d.disk_labels, "diskgroup", null) != null]) : {
      diskgroup = upper(g)
      disks = [
        for d in local.asm_disks : {
          blk_device = "/dev/disk/by-id/google-${d.device_name}"
          name       = d.device_name
        } if lookup(d.disk_labels, "diskgroup", null) == g
      ]
    }
  ]

  # Concatenetes both lists to be passed down to the instance module
  additional_disks = concat(local.fs_disks, local.asm_disks)

  project_id = var.project_id
}

locals {
  multi_instance = (
    var.region1 != null && var.region2 != null &&
    var.subnetwork1 != null && var.subnetwork2 != null &&
    var.zone1 != null && var.zone2 != null
  )
}

data "google_compute_image" "os_image" {
  family  = var.source_image_family
  project = var.source_image_project
}

resource "google_compute_instance_template" "database_vm" {
  project      = var.project_id
  name_prefix  = var.instance_name
  region       = var.region
  machine_type = var.machine_type

  network_interface {
    network            = coalesce(var.network, var.subnetwork) # This is overridden in the instance resource via network
    subnetwork         = coalesce(var.subnetwork, var.network) # This is overridden in the instance resource via subnetwork
    subnetwork_project = local.project_id
  }

  disk {
    boot = true
    auto_delete = true
    source_image = data.google_compute_image.os_image.self_link
    disk_type = var.boot_disk_type
    disk_size_gb  = var.boot_disk_size_gb
  }

  dynamic "disk" {
    for_each = local.additional_disks
    content {
      auto_delete       = lookup(disk.value, "auto_delete", null)
      boot              = lookup(disk.value, "boot", null)
      device_name       = lookup(disk.value, "device_name", null)
      disk_size_gb      = lookup(disk.value, "disk_size_gb", null)
      disk_type         = lookup(disk.value, "disk_type", null)
      labels            = lookup(disk.value, "disk_labels", null)
    }
  }

  service_account {
    email  = var.vm_service_account
    scopes = ["cloud-platform"]
  }

  metadata = {
    metadata_startup_script = var.metadata_startup_script
    enable-oslogin          = "TRUE"
  }

  tags = var.network_tags
}

resource "google_compute_instance_from_template" "vm" {
  project      = var.project_id
  count        = local.multi_instance ? 2 : 1
  # name         = var.deployment_type == "single-instance" ? var.instance_name : "${var.instance_name}-${count.index + 1}"
  # zone         = var.deployment_type == "single-instance" ? var.zone : var.zones[count.index]
  name         = local.multi_instance ? "${var.instance_name}-${count.index + 1}" : var.instance_name
  zone         = local.multi_instance ? (count.index == 0 ? var.zone1 : var.zone2) : var.zone
  source_instance_template = google_compute_instance_template.database_vm.self_link

  network_interface {
    # network    = var.deployment_type == "single-instance" ? coalesce(var.network, var.subnetwork) : var.networks[count.index]
    # subnetwork = var.deployment_type == "single-instance" ? coalesce(var.subnetwork, var.network) : var.subnetworks[count.index]
    network = var.network
    subnetwork = local.multi_instance ? (count.index == 0 ? var.subnetwork1 : var.subnetwork2) : var.subnetwork
    subnetwork_project = local.project_id

    dynamic "access_config" {
      for_each = var.assign_public_ip ? [1] : []
      content {}
    }
  }
}

# data "google_compute_image" "os_image" {
#   family  = var.source_image_family
#   project = var.source_image_project
# }

# resource "google_compute_instance" "database_vms" {
#   project      = var.project_id
#   count        = var.deployment_type == "single-instance" ? 1 : 2
#   name         = var.deployment_type == "single-instance" ? var.instance_name : "${var.instance_name}-${count.index + 1}"
#   machine_type = var.machine_type
#   zone         = var.deployment_type == "single-instance" ? var.zone : var.zones[count.index]

#   boot_disk {
#     initialize_params {
#       image = data.google_compute_image.os_image.self_link
#       size = var.os_disk_size
#       type = var.os_disk_type
#     }
#   }

#   # additional_disks = local.additional_disks
#   dynamic "attached_disk" {
#     for_each = local.additional_disks
#     content {
#       source       = attached_disk.value.source
#       device_name  = attached_disk.value.device_name
#     }
#   }

#   network_interface {
#     network    = var.deployment_type == "single-instance" ? coalesce(var.network, var.subnetwork) : var.networks[count.index]
#     subnetwork = var.deployment_type == "single-instance" ? coalesce(var.subnetwork, var.network) : var.subnetworks[count.index]
#     subnetwork_project = local.project_id

#     dynamic "access_config" {
#       for_each = var.assign_public_ip ? [1] : []
#       content {}
#     }
#   }

#   service_account {
#     email  = var.vm_service_account
#     scopes = ["cloud-platform"]
#   }

#   metadata = {
#     metadata_startup_script = var.metadata_startup_script
#     enable-oslogin          = "TRUE"
#   }

#   tags = var.network_tags
# }


resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  oracle_nodes = [
    for vm in google_compute_instance_from_template.vm : {
      name = vm.name
      zone = vm.zone
      ip   = vm.network_interface[0].network_ip
    }
  ]
}

locals {
  common_flags = join(" ", compact([
    length(local.asm_disk_config) > 0 ? "--ora-asm-disks-json '${jsonencode(local.asm_disk_config)}'" : "",
    length(local.data_mounts_config) > 0 ? "--ora-data-mounts-json '${jsonencode(local.data_mounts_config)}'" : "",
    "--swap-blk-device /dev/disk/by-id/google-swap",
    var.ora_swlib_bucket != "" ? "--ora-swlib-bucket ${var.ora_swlib_bucket}" : "",
    var.ora_version != "" ? "--ora-version ${var.ora_version}" : "",
    var.ora_backup_dest != "" ? "--backup-dest ${var.ora_backup_dest}" : "",
    var.ora_db_name != "" ? "--ora-db-name ${var.ora_db_name}" : "",
    var.ora_db_container != "" ? "--ora-db-container ${var.ora_db_container}" : "",
    var.ntp_pref != "" ? "--ntp-pref ${var.ntp_pref}" : "",
    var.ora_release != "" ? "--ora-release ${var.ora_release}" : "",
    var.ora_edition != "" ? "--ora-edition ${var.ora_edition}" : "",
    var.ora_listener_port != "" ? "--ora-listener-port ${var.ora_listener_port}" : "",
    var.ora_redo_log_size != "" ? "--ora-redo-log-size ${var.ora_redo_log_size}" : "",
    var.db_password_secret != "" ? "--db-password-secret ${var.db_password_secret}" : "",
    var.oracle_metrics_secret != "" ? "--oracle-metrics-secret ${var.oracle_metrics_secret}" : "",
    var.install_workload_agent ? "--install-workload-agent" : "",
    var.skip_database_config ? "--skip-database-config" : ""
  ]))
}

resource "google_compute_instance" "control_node" {
  project      = var.project_id
  name         = "${var.control_node_name_prefix}-${random_id.suffix.hex}"
  machine_type = var.control_node_machine_type
  zone         = var.zone
  
  # comment out for debugging
  #
  # scheduling {
  #   max_run_duration {
  #     seconds = 604800
  #   }
  #   instance_termination_action = "DELETE"
  # }

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }

  network_interface {
    network            = coalesce(var.network, var.subnetwork)
    subnetwork         = coalesce(var.subnetwork, var.network)
    subnetwork_project = local.project_id

    dynamic "access_config" {
      for_each = var.assign_public_ip ? [1] : []
      content {}
    }
  }

  service_account {
    email  = var.control_node_service_account
    scopes = ["cloud-platform"]
  }

  metadata_startup_script = templatefile("${path.module}/scripts/setup.sh.tpl", {
    gcs_source = var.gcs_source
    oracle_nodes_json = jsonencode(local.oracle_nodes)
    common_flags = local.common_flags
  })

  metadata = {
    enable-oslogin = "TRUE"
    serial-port-logging-enable = true
  }

  depends_on = [google_compute_instance_from_template.vm]
}
