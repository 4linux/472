terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

# =================== Locals / Vars ===================
locals {
  var = yamldecode(file("${path.module}/variables.yml"))

  # Filtrar apenas VMs habilitadas (enabled: true/default)
  vms_enabled = {
    for name, vm in local.var.vms :
    name => merge(vm, { name = name })
    if lookup(vm, "enabled", true)
  }

  # Grupos por projeto (infra / openstack)
  vms_infra     = { for k, v in local.vms_enabled : k => v if v.project == "infra" }
  vms_openstack = { for k, v in local.vms_enabled : k => v if v.project == "openstack" }

  # Tipo custom: N2 se nested_kvm=true, senão E2
  machine_type = {
    for name, vm in local.vms_enabled :
    name => (
      lookup(vm, "nested_kvm", false)
      ? "n2-custom-${vm.vcpu}-${vm.memory_mb}"
      : "e2-custom-${vm.vcpu}-${vm.memory_mb}"
    )
  }
}

# =================== Providers (2 projetos) ===================
provider "google" {
  alias   = "infra"
  project = local.var.project_infra
  region  = local.var.region
  zone    = local.var.zone
}

provider "google" {
  alias   = "openstack"
  project = local.var.project_openstack
  region  = local.var.region
  zone    = local.var.zone
}

# =================== Imagem AlmaLinux 9 ===================
data "google_compute_image" "almalinux9" {
  family  = "almalinux-9"
  project = "almalinux-cloud"
}

# =================== Lookups de Subnets ===================

# --- INFRA (mgmt apenas) ---
data "google_compute_subnetwork" "infra_mgmt" {
  provider = google.infra
  name     = local.var.subnet_mgmt_name
  region   = local.var.region
}

# --- OPENSTACK (mgmt + ext) ---
data "google_compute_subnetwork" "openstack_mgmt" {
  provider = google.openstack
  name     = local.var.subnet_mgmt_name
  region   = local.var.region
}

data "google_compute_subnetwork" "openstack_ext" {
  provider = google.openstack
  name     = local.var.subnet_ext_name
  region   = local.var.region
}

# =================== IP público estático (controller) ===================
# Só VMs do projeto openstack com public_ip: true (hoje apenas "controller")
resource "google_compute_address" "openstack_public_ips" {
  provider = google.openstack

  for_each = {
    for k, v in local.vms_openstack :
    k => v if lookup(v, "public_ip", false)
  }

  name   = "${each.key}-public-ip"
  region = local.var.region
}

# =================== Instâncias ===================

# --- INFRA (infra + ansible-server) ---
resource "google_compute_instance" "infra_vms" {
  provider       = google.infra
  for_each       = local.vms_infra
  name           = each.key
  machine_type   = local.machine_type[each.key]
  zone           = local.var.zone
  can_ip_forward = lookup(each.value, "can_ip_forward", false)
  labels         = lookup(each.value, "labels", null)

  boot_disk {
    initialize_params {
      image = data.google_compute_image.almalinux9.self_link
      size  = lookup(each.value, "disk_gb", 50)
      type  = "pd-balanced"
    }
  }

  # NIC 1 - mgmt (10.0.1.0/24)
  network_interface {
    subnetwork = data.google_compute_subnetwork.infra_mgmt.self_link
    network_ip = each.value.ip_mgmt

    # Se public_ip = true, cria IP externo EPHEMERAL (atualmente todos false)
    dynamic "access_config" {
      for_each = lookup(each.value, "public_ip", false) ? [1] : []
      content {}
    }
  }

  metadata = {
    enable-oslogin   = "TRUE"
    hostname         = "${each.key}.openstack.local"
    "startup-script" = lookup(each.value, "startup_script", local.var.startup_script)
  }

  # Não participa das regras de "openstack" (apenas infra)
  tags = ["infra"]

  advanced_machine_features {
    enable_nested_virtualization = lookup(each.value, "nested_kvm", false)
  }
}

# --- OPENSTACK (controller + compute01 + compute02) ---
resource "google_compute_instance" "openstack_vms" {
  provider       = google.openstack
  for_each       = local.vms_openstack
  name           = each.key
  machine_type   = local.machine_type[each.key]
  zone           = local.var.zone
  can_ip_forward = lookup(each.value, "can_ip_forward", false)
  labels         = lookup(each.value, "labels", null)

  boot_disk {
    initialize_params {
      image = data.google_compute_image.almalinux9.self_link
      size  = lookup(each.value, "disk_gb", 50)
      type  = "pd-balanced"
    }
  }

  # NIC 1 - mgmt (10.0.2.0/24)
  network_interface {
    subnetwork = data.google_compute_subnetwork.openstack_mgmt.self_link
    network_ip = each.value.ip_mgmt

    # Se public_ip = true (controller), usa IP estático
    dynamic "access_config" {
      for_each = lookup(each.value, "public_ip", false) ? [1] : []
      content {
        nat_ip = google_compute_address.openstack_public_ips[each.key].address
      }
    }
  }

  # NIC 2 - ext (192.168.200.0/24) se nic_ext: true
  dynamic "network_interface" {
    for_each = lookup(each.value, "nic_ext", false) ? [1] : []
    content {
      subnetwork = data.google_compute_subnetwork.openstack_ext.self_link
      network_ip = lookup(each.value, "ip_ext", null)
    }
  }

  metadata = {
    enable-oslogin   = "TRUE"
    hostname         = "${each.key}.openstack.local"
    "startup-script" = lookup(each.value, "startup_script", local.var.startup_script)
  }

  # Todas as VMs OpenStack recebem tag "openstack"
  # Controller ainda ganha "horizon" via extra_tags
  tags = distinct(concat(
    ["openstack"],
    lookup(each.value, "extra_tags", [])
  ))

  advanced_machine_features {
    enable_nested_virtualization = lookup(each.value, "nested_kvm", false)
  }
}

# =================== Outputs ===================
output "instances" {
  value = {
    infra     = keys(google_compute_instance.infra_vms)
    openstack = keys(google_compute_instance.openstack_vms)
  }
}

# IP público estático do controller
output "controller_public_ip" {
  value = try(
    google_compute_address.openstack_public_ips["controller"].address,
    null
  )
  description = "IP público estático do controller (Horizon)."
}
