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

module "instance_template" {
  source  = "terraform-google-modules/vm/google//modules/instance_template"
  version = "~> 13.0"

  name_prefix        = format("%s-template", var.instance_name)
  region             = var.region
  project_id         = local.project_id
  subnetwork         = var.subnetwork
  subnetwork_project = local.project_id
  service_account = {
    email  = var.vm_service_account
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

module "compute_instance" {
  source  = "terraform-google-modules/vm/google//modules/compute_instance"
  version = "~> 13.0"

  num_instances       = var.num_instances
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

locals {
  oracle_nodes = [
    for inst in module.compute_instance.instances_details : {
      name = inst.name
      ip   = inst.network_interface[0].network_ip
      zone = inst.zone
    }
  ]

  oracle_nodes_json = jsonencode(local.oracle_nodes)
}

locals {
  common_flags = template(<<-EOT
    %{ if ora_edition != "" }--ora-edition "${ora_edition}" %{ endif }
    %{ if ora_listener_port != "" }--ora-listener-port "${ora_listener_port}" %{ endif }
    %{ if ora_redo_log_size != "" }--ora-redo-log-size "${ora_redo_log_size}" %{ endif }
    %{ if db_name != "" }--db-name "${db_name}" %{ endif }
    %{ if db_version != "" }--db-version "${db_version}" %{ endif }
    %{ if data_dir != "" }--data-dir "${data_dir}" %{ endif }
  EOT,
  {
    ora_edition        = var.ora_edition
    ora_listener_port  = var.ora_listener_port
    ora_redo_log_size  = var.ora_redo_log_size
    db_name            = var.db_name
    db_version         = var.db_version
    data_dir           = var.data_dir
  })
}

resource "random_id" "suffix" {
  byte_length = 4
}

resource "google_compute_instance" "control_node" {
  project      = var.project_id
  name         = "${var.control_node_name_prefix}-${random_id.suffix.hex}"
  machine_type = var.control_node_machine_type
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
    }
  }

  network_interface {
    network       = var.subnetwork

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
    oracle_nodes_json   = local.oracle_nodes_json
    gcs_source          = var.gcs_source
    asm_disk_config     = jsonencode(local.asm_disk_config)
    data_mounts_config  = jsonencode(local.data_mounts_config)
    swap_blk_device     = "/dev/disk/by-id/google-swap"
    ora_swlib_bucket    = var.ora_swlib_bucket
    ora_version         = var.ora_version
    ora_backup_dest     = var.ora_backup_dest
    ora_db_name         = var.ora_db_name
    ora_db_container    = lower(var.ora_db_container)
    ntp_pref            = var.ntp_pref
    oracle_release      = var.oracle_release
    ora_edition         = var.ora_edition
    ora_listener_port   = var.ora_listener_port
    ora_redo_log_size   = var.ora_redo_log_size
  })

  depends_on = [module.compute_instance]
}

resource "google_dns_managed_zone" "example" {
  count    = var.create_zone ? 1 : 0
  name     = var.dns_zone_name
  dns_name = var.dns_name
}

resource "google_dns_record_set" "primary" {
  name         = "primary.${google_dns_managed_zone.prod.dns_name}"
  type         = "A"
  ttl          = 300
  managed_zone = var.dns_zone_name
  rrdatas      = []
}
