variable "project_id" {
  type        = string
  description = "Your GCP Project ID"
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "network_name" {
  type    = string
  default = "cs-vpc"
}

variable "subnet_name" {
  type    = string
  default = "cs-subnet"
}

variable "apis_to_enable" {
  type = set(string)
  description = "A comprehensive list of APIs required for the entire Creative Studio project"
  default = [
    "serviceusage.googleapis.com",
    "iam.googleapis.com",
    "compute.googleapis.com",
    "servicenetworking.googleapis.com",
    "networkconnectivity.googleapis.com",
    "sqladmin.googleapis.com",
    "cloudbuild.googleapis.com",
    "artifactregistry.googleapis.com",
    "run.googleapis.com",
    "secretmanager.googleapis.com",
    "firebase.googleapis.com",
    "iap.googleapis.com",
    "identitytoolkit.googleapis.com",
    "texttospeech.googleapis.com",
    "workflows.googleapis.com"
  ]
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# 0. Enable APIs
resource "google_project_service" "prereq_apis" {
  for_each           = var.apis_to_enable
  project            = var.project_id
  service            = each.key
  disable_on_destroy = false
}

# 1. VPC Network
resource "google_compute_network" "main" {
  name                    = var.network_name
  auto_create_subnetworks = false
  depends_on              = [google_project_service.prereq_apis]
}

# 2. Subnet (with Private Google Access enabled for GCP APIs)
resource "google_compute_subnetwork" "main" {
  name                     = var.subnet_name
  ip_cidr_range            = "10.0.0.0/24"
  region                   = var.region
  network                  = google_compute_network.main.id
  private_ip_google_access = true
}

# 3. Private Services Access (PSA) for Cloud SQL
resource "google_compute_global_address" "private_ip_address" {
  name          = "cs-sql-private-ip-alloc"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 16
  network       = google_compute_network.main.id
}

resource "google_service_networking_connection" "private_vpc_connection" {
  network                 = google_compute_network.main.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_ip_address.name]
}

# 4. Cloud Router & Cloud NAT (allows Bastion to download external packages without a Public IP)
resource "google_compute_router" "router" {
  name    = "cs-router"
  region  = var.region
  network = google_compute_network.main.id
}

resource "google_compute_router_nat" "nat" {
  name                               = "cs-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# 5. IAP Firewall Rule
resource "google_compute_firewall" "allow_iap_ssh" {
  name    = "cs-allow-iap-ssh"
  network = google_compute_network.main.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"]
  description   = "Allow SSH from Identity-Aware Proxy (IAP)"
}

# 6. Bastion VM
resource "google_compute_instance" "bastion" {
  name         = "cs-bastion-vm"
  machine_type = "e2-medium"
  zone         = "${var.region}-a"

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2204-lts"
    }
  }

  network_interface {
    network    = google_compute_network.main.id
    subnetwork = google_compute_subnetwork.main.id
    # Notice: NO access_config block, meaning it has NO public IP!
  }

  # Satisfy the organizational policy for Shielded VMs
  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  # Allow full access to Cloud APIs to run the script
  service_account {
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }
}
