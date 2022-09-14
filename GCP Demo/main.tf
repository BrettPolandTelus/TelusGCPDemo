# ---------------------------------------------------------------------------------------------------------------------
# SETUP GCP AS TERRAFORM PROVIDER
# ---------------------------------------------------------------------------------------------------------------------
terraform {
  required_version = ">= 0.12.26"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 3.50.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 3.50.0"
    }
  }
}

# ------------------------------------------------------------------------------
# CONFIGURE OUR GCP CONNECTION
# ------------------------------------------------------------------------------
provider "google" {
  region  = var.region
  project = var.project
}

provider "google-beta" {
  region  = var.region
  project = var.project
}

# ------------------------------------------------------------------------------
# VPC NETWORK SETUP
# ------------------------------------------------------------------------------
resource "google_compute_subnetwork" "vpcnetwork" {
  name          = "default"
  ip_cidr_range = "10.2.0.0/16"
  region        = "northamerica-northeast2"
  network       = google_compute_network.subnet1.id
  private_ip_google_access = true
}

resource "google_compute_network" "subnet1" {
  name                    = "default"
  auto_create_subnetworks = false
}

# ------------------------------------------------------------------------------
# CREATE THE LOAD BALANCER
# ------------------------------------------------------------------------------
module "lb" {
  source                = "./modules/http-load-balancer"
  name                  = var.name
  project               = var.project
  url_map               = google_compute_url_map.urlmap.self_link
  dns_managed_zone_name = var.dns_managed_zone_name
  custom_domain_names   = [var.custom_domain_name]
  create_dns_entries    = var.create_dns_entry
  dns_record_ttl        = var.dns_record_ttl
  enable_http           = var.enable_http
  enable_ssl            = var.enable_ssl
  custom_labels = var.custom_labels
}

# ------------------------------------------------------------------------------
# CREATE THE URL MAP TO MAP PATHS TO BACKENDS
# ------------------------------------------------------------------------------
resource "google_compute_url_map" "urlmap" {
  project = var.project

  name        = "${var.name}-url-map"
  description = "URL map for ${var.name}"

  default_service = google_compute_backend_bucket.static.self_link

  host_rule {
    hosts        = ["*"]
    path_matcher = "all"
  }

  path_matcher {
    name            = "all"
    default_service = google_compute_backend_bucket.static.self_link

    path_rule {
      paths   = ["/api", "/api/*"]
      service = google_compute_backend_service.api.self_link
    }
  }
}

# ------------------------------------------------------------------------------
# CREATE THE BACKEND SERVICE CONFIGURATION FOR THE INSTANCE GROUP
# ------------------------------------------------------------------------------
resource "google_compute_backend_service" "api" {
  project = var.project

  name        = "${var.name}-api"
  description = "API Backend for ${var.name}"
  port_name   = "http"
  protocol    = "HTTP"
  timeout_sec = 10
  enable_cdn  = false

  backend {
    group = google_compute_instance_group.api.self_link
  }

  health_checks = [google_compute_health_check.default.self_link]
  depends_on = [google_compute_instance_group.api]
}

# ------------------------------------------------------------------------------
# CONFIGURE HEALTH CHECK FOR THE API BACKEND
# ------------------------------------------------------------------------------
resource "google_compute_health_check" "default" {
  project = var.project
  name    = "${var.name}-hc"

  http_health_check {
    port         = 5000
    request_path = "/api"
  }

  check_interval_sec = 5
  timeout_sec        = 5
}

# ------------------------------------------------------------------------------
# CREATE THE STORAGE BUCKET FOR THE STATIC CONTENT
# ------------------------------------------------------------------------------
resource "google_storage_bucket" "static" {
  project = var.project

  name          = "${var.name}-bucket-telushealth"
  location      = var.static_content_bucket_location
  storage_class = "MULTI_REGIONAL"

  website {
    main_page_suffix = "index.html"
    not_found_page   = "404.html"
  }

  #In production, you should set this to false to prevent accidental loss of data
  force_destroy = true
  uniform_bucket_level_access = true
  labels = var.custom_labels
}

# ------------------------------------------------------------------------------
# CREATE THE BACKEND FOR THE STORAGE BUCKET
# ------------------------------------------------------------------------------
resource "google_compute_backend_bucket" "static" {
  project = var.project
  name        = "${var.name}-backend-bucket"
  bucket_name = google_storage_bucket.static.name
}

# ------------------------------------------------------------------------------
# UPLOAD SAMPLE CONTENT WITH PUBLIC READ ACCESS
# IAM Policy for Storage Bucket
# ------------------------------------------------------------------------------
data "google_iam_policy" "admin" {
  binding {
    role = "roles/storage.admin"
    #role = "roles/storage.objectViewer"
    members = [
      "allUsers",
    ]
  }
}

# ------------------------------------------------------------------------------
# BUCKET CONTENT CREATION
# ------------------------------------------------------------------------------
resource "google_storage_bucket_iam_policy" "web_policy" {
  bucket = google_storage_bucket.static.name
  policy_data = data.google_iam_policy.admin.policy_data
}

resource "google_storage_bucket_object" "index" {
  name    = "index.html"
  content = var.telushealthascii
  bucket  = google_storage_bucket.static.name
}

resource "google_storage_bucket_object" "not_found" {
  name    = "404.html"
  content = var.error404
  bucket  = google_storage_bucket.static.name
}


# ------------------------------------------------------------------------------
# CREATE THE INSTANCE GROUP WITH A SINGLE INSTANCE AND THE BACKEND SERVICE CONFIGURATION
# ------------------------------------------------------------------------------
resource "google_compute_instance_group" "api" {
  project   = var.project
  name      = "${var.name}-instance-group"
  zone      = var.zone
  instances = [google_compute_instance.api.self_link]

  lifecycle {
    create_before_destroy = true
  }

  named_port {
    name = "http"
    port = 5000
  }
}

# ------------------------------------------------------------------------------
# SINGLE INSTANCE WITH FLASK API
# ------------------------------------------------------------------------------
resource "google_compute_instance" "api" {
  project      = var.project
  name         = "${var.name}-instance"
  machine_type = var.instance_size
  zone         = var.zone
  depends_on = [google_compute_subnetwork.vpcnetwork]

  # We're tagging the instance with the tag specified in the firewall rule
  tags = ["private-app"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-10"
    }
  }

  # Make sure we have the flask application running
  metadata_startup_script = file("${path.module}/startup_script/startup_script.sh")

  # Launch the instance in the default subnetwork
  network_interface {
    subnetwork = "default"
    # This gives the instance a public IP address for internet connectivity. 
    access_config {
    }
  }
}

# ------------------------------------------------------------------------------
# CREATE A FIREWALL TO ALLOW ACCESS FROM THE LB TO THE INSTANCE
# ------------------------------------------------------------------------------
resource "google_compute_firewall" "firewall" {
  project = var.project
  name    = "${var.name}-fw"
  network = "default"
  depends_on = [google_compute_subnetwork.vpcnetwork]

  # Allow load balancer access to the API instances
  # https://cloud.google.com/load-balancing/docs/https/#firewall_rules
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]

  target_tags = ["private-app"]
  source_tags = ["private-app"]

  allow {
    protocol = "tcp"
    ports    = ["5000"]
  }
}
