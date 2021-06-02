data "vcd_edgegateway" "edge1" {
  name = var.vcd_edge_name
}
data "vcd_vapp" "vApp" {
  name = var.vapp_name
}
data "vcd_vapp_vm" "vm" {
  vapp_name  = data.vcd_vapp.vApp.name
  name       = var.vm_name
  depends_on = [vcd_vapp_vm.vm, vcd_vm_internal_disk.vmStorage]
}

locals {
  storage = flatten([
    for storage_key, storage in var.vm_storage : [
      for type_key, type in storage : {
        type = "vcd-type-${storage_key}"
        name = type.mount_name
        size = type.mount_size
        bus  = index(keys(var.vm_storage), storage_key) + 1
        unit = type_key
      }
    ]
  ])

  mounts_group = { for mount in local.storage : mount.name => tonumber(mount.size)... }
  mounts       = zipmap([for k, v in local.mounts_group : k], [for v in local.mounts_group : sum(v)])

  hot_add = var.vm_cpu != "8" ? true : false

  dnat_port_ssh = random_integer.dynamic_ports.result
  dnat_orig_ip  = data.vcd_edgegateway.edge1.default_external_network_ip

  ssh_ip   = local.dnat_orig_ip
  ssh_port = local.dnat_port_ssh
}

# Рандомный порт для проброса SSH
resource "random_integer" "dynamic_ports" {
  min = 49152
  max = 65535
}

# Создание проброса SSH порта во вне
resource "vcd_nsxv_dnat" "dnat_ssh" {
  edge_gateway = var.vcd_edge_name
  network_name = var.ext_net_name
  network_type = "ext"

  enabled         = true
  logging_enabled = true
  description     = "DNAT rule for SSH ${var.vm_name}"

  original_address = local.ssh_ip
  original_port    = local.ssh_port

  translated_address = var.vm_net[0].ip
  translated_port    = 22
  protocol           = "tcp"
}

# Создание виртуальной машины
resource "vcd_vapp_vm" "vm" {
  vapp_name           = data.vcd_vapp.vApp.name
  name                = var.vm_name
  catalog_name        = var.catalog_name
  template_name       = var.template_name
  vm_name_in_template = var.vm_name_template
  memory              = var.vm_memory
  cpus                = var.vm_cpu
  cpu_cores           = var.vm_cpu

  cpu_hot_add_enabled    = local.hot_add
  memory_hot_add_enabled = local.hot_add

  prevent_update_power_off = true

  dynamic "network" {
    for_each = var.vm_net

    content {
      type               = "org"
      name               = network.value["name"]
      ip                 = network.value["ip"]
      ip_allocation_mode = "MANUAL"
    }
  }

  metadata = local.mounts
}

# Создание виртуального диска и присоединение к ВМ
resource "vcd_vm_internal_disk" "vmStorage" {
  for_each = {
    for disk in local.storage : "${disk.type}.${disk.name}.${disk.unit}" => disk
  }

  vapp_name       = var.vapp_name
  vm_name         = var.vm_name
  bus_type        = "paravirtual"
  size_in_mb      = (each.value.size * 1024) + 1
  bus_number      = each.value.bus
  unit_number     = each.value.unit
  storage_profile = each.value.type
  depends_on      = [vcd_vapp_vm.vm]

  connection {
    type     = "ssh"
    host     = local.ssh_ip
    port     = local.ssh_port
    user     = var.vmuser
    password = var.vmpassword
  }

  provisioner "file" {
    source      = "files/managedisk.sh"
    destination = "/tmp/managedisk.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/managedisk.sh",
      "sudo bash /tmp/managedisk.sh ${self.bus_number} ${self.unit_number} ${each.value.name} ${self.size_in_mb}",
    ]
  }
}

# Подключение к ВМ по SSH и выполнение инструкций
resource "null_resource" "mounts_writer" {
  for_each = local.mounts

  triggers = {
    vm_disk_ids = join(",", data.vcd_vapp_vm.vm.internal_disk[*].size_in_mb)
  }

  connection {
    type        = "ssh"
    host        = local.ssh_ip
    port        = local.ssh_port
    user        = var.vmuser
    private_key = file(var.ssh_key)
  }

  provisioner "remote-exec" {
    inline = [
      "echo '${each.key}|${each.value}' >> /tmp/mounts.txt",
    ]
  }
}

resource "time_sleep" "wait_10_seconds" {
  depends_on      = [null_resource.mounts_writer]
  create_duration = "10s"
}

resource "null_resource" "storage_extender" {
  triggers = {
    vm_disk_ids = join(",", data.vcd_vapp_vm.vm.internal_disk[*].size_in_mb)
  }

  connection {
    type        = "ssh"
    host        = local.ssh_ip
    port        = local.ssh_port
    user        = var.vmuser
    private_key = file(var.ssh_key)
  }

  provisioner "file" {
    source      = "files/extenddisk.sh"
    destination = "/tmp/extenddisk.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/extenddisk.sh",
      "sudo bash /tmp/extenddisk.sh",
      "sudo rm /tmp/mounts.txt"
    ]
  }
}
