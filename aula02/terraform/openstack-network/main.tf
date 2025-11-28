terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.10"
    }
  }
}

locals {
  var = yamldecode(file("${path.module}/variables.yml"))

  # Todos os CIDRs internos (para firewalls "allow-internal")
  all_cidrs = [
    local.var.mgmt_cidr_infra,
    local.var.mgmt_cidr_openstack,
    local.var.ext_cidr_openstack,
  ]
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

# =================== VPCs ===================

# --- INFRA ---
# Rede de Gestão (Infra)
resource "google_compute_network" "infra_mgmt" {
  provider                = google.infra
  name                    = "openstack-vpc-infra-mgmt"
  auto_create_subnetworks = false
}

# --- OPENSTACK ---
# Rede de Gestão (Controller/Computes)
resource "google_compute_network" "openstack_mgmt" {
  provider                = google.openstack
  name                    = "openstack-vpc-openstack-mgmt"
  auto_create_subnetworks = false
}

# Rede Externa/Provider (Controller/Computes)
resource "google_compute_network" "openstack_ext" {
  provider                = google.openstack
  name                    = "openstack-vpc-openstack-ext"
  auto_create_subnetworks = false
}

# =================== Subnets ===================

# --- INFRA ---
resource "google_compute_subnetwork" "infra_mgmt_subnet" {
  provider                 = google.infra
  name                     = "mgmt-net"
  region                   = local.var.region
  network                  = google_compute_network.infra_mgmt.id
  ip_cidr_range            = local.var.mgmt_cidr_infra
  private_ip_google_access = true
}

# --- OPENSTACK ---
resource "google_compute_subnetwork" "openstack_mgmt_subnet" {
  provider                 = google.openstack
  name                     = "mgmt-net"
  region                   = local.var.region
  network                  = google_compute_network.openstack_mgmt.id
  ip_cidr_range            = local.var.mgmt_cidr_openstack
  private_ip_google_access = true
}

resource "google_compute_subnetwork" "openstack_ext_subnet" {
  provider                 = google.openstack
  name                     = "ext-net"
  region                   = local.var.region
  network                  = google_compute_network.openstack_ext.id
  ip_cidr_range            = local.var.ext_cidr_openstack
  private_ip_google_access = true
}

# =================== Firewalls ===================

# 1. Regras Internas (Permite tudo entre os nós nas redes conhecidas)
resource "google_compute_firewall" "fw_infra_mgmt" {
  provider      = google.infra
  name          = "allow-internal-mgmt"
  network       = google_compute_network.infra_mgmt.name
  direction     = "INGRESS"
  source_ranges = local.all_cidrs
  allow {
    protocol = "all"
  }
}

resource "google_compute_firewall" "fw_openstack_mgmt" {
  provider      = google.openstack
  name          = "allow-internal-mgmt"
  network       = google_compute_network.openstack_mgmt.name
  direction     = "INGRESS"
  source_ranges = local.all_cidrs
  allow {
    protocol = "all"
  }
}

resource "google_compute_firewall" "fw_openstack_ext" {
  provider      = google.openstack
  name          = "allow-internal-ext"
  network       = google_compute_network.openstack_ext.name
  direction     = "INGRESS"
  source_ranges = local.all_cidrs
  allow {
    protocol = "all"
  }
}

# 2. SSH via IAP (Identity-Aware Proxy) - Apenas redes de gestão
resource "google_compute_firewall" "infra_mgmt_ssh_iap" {
  provider      = google.infra
  name          = "allow-ssh-iap-mgmt"
  network       = google_compute_network.infra_mgmt.name
  direction     = "INGRESS"
  source_ranges = ["35.235.240.0/20"]
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_firewall" "openstack_mgmt_ssh_iap" {
  provider      = google.openstack
  name          = "allow-ssh-iap-mgmt"
  network       = google_compute_network.openstack_mgmt.name
  direction     = "INGRESS"
  source_ranges = ["35.235.240.0/20"]
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# 3. Horizon Dashboard (Controller em projeto openstack)
resource "google_compute_firewall" "openstack_mgmt_horizon" {
  provider      = google.openstack
  name          = "allow-horizon-https"
  network       = google_compute_network.openstack_mgmt.name
  direction     = "INGRESS"
  target_tags   = ["horizon"]
  source_ranges = ["0.0.0.0/0"]
  allow {
    protocol = "tcp"
    ports    = ["80", "443", "6080"]
  }
}

# 4. Tráfego Externo (Permite entrada na rede "Provider" simulada)
resource "google_compute_firewall" "fw_openstack_ext_ingress" {
  provider      = google.openstack
  name          = "allow-return-traffic-ext"
  network       = google_compute_network.openstack_ext.name
  direction     = "INGRESS"
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["openstack"]
  priority      = 900

  allow {
    protocol = "icmp"
  }

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }

  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }
}

# =================== Peering (Apenas Redes MGMT) ===================
# Ordem:
# 1) infra <-> openstack
# Serializado pra evitar erro "peering operation in progress".

# ---------- INFRA <-> OPENSTACK ----------

resource "google_compute_network_peering" "mgmt_infra_to_openstack" {
  provider             = google.infra
  name                 = "peering-mgmt-infra-to-openstack"
  network              = google_compute_network.infra_mgmt.self_link
  peer_network         = google_compute_network.openstack_mgmt.self_link
  export_custom_routes = true
}

resource "time_sleep" "wait_mgmt_infra_to_openstack" {
  depends_on      = [google_compute_network_peering.mgmt_infra_to_openstack]
  create_duration = "15s"
}

resource "google_compute_network_peering" "mgmt_openstack_to_infra" {
  provider             = google.openstack
  name                 = "peering-mgmt-openstack-to-infra"
  network              = google_compute_network.openstack_mgmt.self_link
  peer_network         = google_compute_network.infra_mgmt.self_link
  depends_on           = [time_sleep.wait_mgmt_infra_to_openstack]
  import_custom_routes = true
}

# =================== Cloud NAT (Internet Access) ===================

# --- INFRA MGMT ---
resource "google_compute_router" "infra_mgmt_router" {
  provider = google.infra
  name     = "router-infra-mgmt"
  region   = local.var.region
  network  = google_compute_network.infra_mgmt.id
}
resource "google_compute_router_nat" "infra_mgmt_nat" {
  provider                           = google.infra
  name                               = "nat-infra-mgmt"
  region                             = local.var.region
  router                             = google_compute_router.infra_mgmt_router.name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"
  subnetwork {
    name                    = google_compute_subnetwork.infra_mgmt_subnet.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
}

# --- OPENSTACK MGMT ---
resource "google_compute_router" "openstack_mgmt_router" {
  provider = google.openstack
  name     = "router-openstack-mgmt"
  region   = local.var.region
  network  = google_compute_network.openstack_mgmt.id
}
resource "google_compute_router_nat" "openstack_mgmt_nat" {
  provider                           = google.openstack
  name                               = "nat-openstack-mgmt"
  region                             = local.var.region
  router                             = google_compute_router.openstack_mgmt_router.name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"
  subnetwork {
    name                    = google_compute_subnetwork.openstack_mgmt_subnet.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
}

# --- OPENSTACK EXT ---
resource "google_compute_router" "openstack_ext_router" {
  provider = google.openstack
  name     = "router-openstack-ext"
  region   = local.var.region
  network  = google_compute_network.openstack_ext.id
}
resource "google_compute_router_nat" "openstack_ext_nat" {
  provider                           = google.openstack
  name                               = "nat-openstack-ext"
  region                             = local.var.region
  router                             = google_compute_router.openstack_ext_router.name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "LIST_OF_SUBNETWORKS"
  subnetwork {
    name                    = google_compute_subnetwork.openstack_ext_subnet.id
    source_ip_ranges_to_nat = ["ALL_IP_RANGES"]
  }
}

# =================== Outputs ===================
output "vpcs" {
  value = {
    infra_mgmt     = google_compute_network.infra_mgmt.name
    openstack_mgmt = google_compute_network.openstack_mgmt.name
    openstack_ext  = google_compute_network.openstack_ext.name
  }
}
