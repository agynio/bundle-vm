packer {
  required_version = ">= 1.10.0"

  required_plugins {
    qemu = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

# Absolute path to the bundle-vm-base qcow2 this platform image is built on top
# of. The platform image inherits everything baked into the base (k3s, Istio,
# cert-manager, Argo CD, the argocd route) and layers the Agyn platform on top.
variable "base_image" {
  type = string
}

variable "arch" {
  type = string
  validation {
    condition     = contains(["amd64", "arm64"], var.arch)
    error_message = "Architecture must be amd64 or arm64."
  }
}

variable "disk_size" {
  type    = string
  default = "32G"
}

variable "base_domain" {
  type    = string
  default = "agyn.dev"
}

variable "ingress_host_port" {
  type    = string
  default = "2496"
}

variable "ingress_nodeport" {
  type    = string
  default = "32443"
}

variable "qemu_accelerator" {
  type    = string
  default = "kvm"
  validation {
    condition     = contains(["kvm", "hvf", "none"], var.qemu_accelerator)
    error_message = "QEMU accelerator must be kvm, hvf, or none."
  }
}

variable "efi_firmware_code" {
  type    = string
  default = ""
}

variable "efi_firmware_vars" {
  type    = string
  default = ""
}

variable "ssh_private_key_file" {
  type = string
}

variable "ssh_public_key" {
  type = string
}

variable "serial_log_path" {
  type    = string
  default = ""
}

locals {
  qemu_arch       = var.arch == "amd64" ? "x86_64" : "aarch64"
  machine         = var.arch == "amd64" ? "pc" : "virt"
  cpu             = contains(["kvm", "hvf"], var.qemu_accelerator) ? "host" : "max"
  cdrom_interface = var.arch == "amd64" ? "" : "virtio-scsi"
  arm64_qemuargs = concat([
    ["-cpu", local.cpu],
    ["-boot", "strict=off"],
    ], var.serial_log_path == "" ? [] : [
    ["-serial", "file:${var.serial_log_path}"],
  ])
  qemuargs = var.arch == "arm64" ? local.arm64_qemuargs : [
    ["-cpu", local.cpu],
  ]
}

source "qemu" "agyn_platform" {
  # Inherit the base image disk instead of a fresh cloud image. cloud-init on the
  # base disk was finalized clean, so the NoCloud seed below re-creates the
  # temporary packer build user on boot exactly like the base build did.
  iso_url      = "file://${var.base_image}"
  iso_checksum = "none"
  disk_image   = true

  accelerator = var.qemu_accelerator

  boot_wait = "2s"
  cd_label  = "cidata"
  cd_content = {
    "meta-data" = "instance-id: bundle-vm-platform-${var.arch}\nlocal-hostname: bundle-vm\n"
    "user-data" = templatefile("cloud-init.pkrtpl.hcl", {
      enable_cloud_init_diagnostics = var.arch == "arm64" && var.qemu_accelerator == "hvf"
      ssh_public_key                = var.ssh_public_key
    })
  }
  cdrom_interface        = local.cdrom_interface
  cpus                   = 4
  disk_compression       = false
  disk_size              = var.disk_size
  efi_boot               = var.arch == "arm64"
  efi_drop_efivars       = true
  efi_firmware_code      = var.efi_firmware_code
  efi_firmware_vars      = var.efi_firmware_vars
  format                 = "qcow2"
  headless               = true
  machine_type           = local.machine
  memory                 = 8192
  net_device             = "virtio-net"
  output_directory       = "output/${var.arch}"
  qemu_binary            = "qemu-system-${local.qemu_arch}"
  qemuargs               = local.qemuargs
  shutdown_command       = "sudo /usr/local/sbin/agyn-finalize-shutdown"
  shutdown_timeout       = "10m"
  ssh_handshake_attempts = 120
  ssh_private_key_file   = var.ssh_private_key_file
  ssh_timeout            = "30m"
  ssh_username           = "packer"
  vm_name                = "bundle-vm-platform-${var.arch}.qcow2"
}

build {
  name    = "bundle-vm-platform"
  sources = ["source.qemu.agyn_platform"]

  # Copy the deploy manifests + helm values into the guest for the installer.
  # (Directory source without trailing slash uploads as /tmp/deploy.)
  provisioner "file" {
    source      = "${path.root}/../deploy"
    destination = "/tmp"
  }

  # Run on first boot with values the host supplies, not at build time: a token
  # generated for this install, and the port it actually forwards.
  provisioner "file" {
    source      = "${path.root}/../scripts/set-bootstrap-token.sh"
    destination = "/tmp/set-bootstrap-token.sh"
  }

  provisioner "file" {
    source      = "${path.root}/../scripts/set-ingress-port.sh"
    destination = "/tmp/set-ingress-port.sh"
  }

  provisioner "shell" {
    environment_vars = [
      "ARCH=${var.arch}",
      "BASE_DOMAIN=${var.base_domain}",
      "INGRESS_HOST_PORT=${var.ingress_host_port}",
      "INGRESS_NODEPORT=${var.ingress_nodeport}",
    ]
    execute_command = "{{ .Vars }}sudo -E bash '{{ .Path }}'"
    scripts = [
      "${path.root}/../scripts/install-bootstrap-token-hook.sh",
      "${path.root}/../scripts/install-ingress.sh",
      "${path.root}/../scripts/install-platform.sh",
      "${path.root}/../scripts/prepull-and-wait.sh",
      "${path.root}/../scripts/cleanup-image.sh",
    ]
  }
}
