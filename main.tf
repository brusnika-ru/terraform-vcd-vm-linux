# Рандомный порт для проброса SSH
resource "random_integer" "dynamic_ports" {
  min = 49152
  max = 65535
}

# Создание правила Firewall для проброса SSH
resource "vcd_nsxv_firewall_rule" "dnat_ssh_firewall" {
  edge_gateway = var.common.vcd_edge_name

  name = "SSH to ${var.name}"
  
  source {
    ip_addresses = ["any"]
  }

  destination {
    ip_addresses = [local.ssh_ip]
  }

  service {
    protocol = "tcp"
    port     = local.ssh_port
  }
}

# Создание виртуальной машины
resource "vcd_vapp_vm" "vm" {
  vapp_name           = var.vapp
  name                = var.name
  catalog_name        = var.common.catalog
  template_name       = var.common.template_name
  vm_name_in_template = var.template != "" ? var.template : var.common.vm_name_template
  memory              = var.ram
  cpus                = var.cpu
  cpu_cores           = var.cpu >= 10 ? var.cpu / 2 : var.cpu
  
  cpu_hot_add_enabled    = local.hot_add
  memory_hot_add_enabled = local.hot_add

  prevent_update_power_off = true

  dynamic "network" {
    for_each = var.networks
    
    content {
      type               = "org"
      name               = network.value["name"]
      adapter_type       = "VMXNET3"
      ip_allocation_mode = network.value["ip"] != "" ? "MANUAL" : "POOL"
      ip                 = network.value["ip"] != "" ? network.value["ip"] : ""
    }
  }

  # guest_properties = {
  #   "guest.hostname" = "vm1.host.ru"
  # }

  customization {
    force      = false
    enabled    = true
    change_sid = true

    # initscript = <<EOF
    # @echo off
    # if "%1%" == "precustomization" (
    # echo Do precustomization tasks
    # ) else if "%1%" == "postcustomization" (
    # echo %DATE% %TIME% > C:\vm-is-ready
    # timeout /t 300
    # powershell -command "Set-NetConnectionProfile -InterfaceAlias 'Ethernet0 2' -NetworkCategory Private"
    # )
    # EOF
  }

  metadata = local.mounts
}

data "vcd_vapp_vm" "vm_ip" {
  depends_on = [
    vcd_vapp_vm.vm
  ]

  vapp_name  = var.vapp
  name       = var.name
}

# Создание проброса SSH порта во вне
resource "vcd_nsxv_dnat" "dnat_ssh" {
  edge_gateway = var.common.vcd_edge_name
  network_name = var.common.ext_net_name
  network_type = "ext"

  enabled         = true
  logging_enabled = true
  description     = "DNAT rule for SSH ${var.name}"

  original_address   = local.ssh_ip
  original_port      = local.ssh_port

  translated_address = var.networks[0].ip != "" ? var.networks[0].ip : data.vcd_vapp_vm.vm_ip.network[0].ip
  translated_port    = 22
  protocol           = "tcp"

}

# Пауза после создания машины, 3 минут
resource "time_sleep" "wait_3_minutes" {
  depends_on = [
    vcd_vapp_vm.vm
  ]

  create_duration = "3m"
}

# Создание виртуального диска и присоединение к ВМ
resource "vcd_vm_internal_disk" "vmStorage" {
  depends_on = [
    time_sleep.wait_3_minutes, 
    vcd_nsxv_dnat.dnat_ssh, 
    vcd_nsxv_firewall_rule.dnat_ssh_firewall
  ]

  for_each = {
    for disk in local.storages_w_iops : "${disk.type}.${disk.name}.${disk.unit}" => disk
  }

  vapp_name       = var.vapp_name
  vm_name         = var.vm_name
  bus_type        = "paravirtual"
  size_in_mb      = (each.value.size * 1024) + 1
  bus_number      = each.value.bus
  unit_number     = each.value.unit
  iops            = each.value.iops
  storage_profile = each.value.type

  connection {
    type        = "ssh"
    host        = local.ssh_ip
    port        = local.ssh_port
    user        = var.common.ssh_user
    private_key = file(var.common.ssh_key)
  }

  provisioner "file" {
    source      = "${path.module}/files/managedisk.sh"
    destination = "/tmp/managedisk.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/managedisk.sh",
      "sudo bash /tmp/managedisk.sh ${self.bus_number} ${self.unit_number} ${each.value.name} ${self.size_in_mb}",
    ]
  }
}

# Запись точек монтирования в /tmp/mounts.txt
resource "null_resource" "mounts_writer" {
  for_each = local.mounts

  triggers = {
    vm_disk_ids = join(",", data.vcd_vapp_vm.vm.internal_disk[*].size_in_mb)
  }

  connection {
    type        = "ssh"
    host        = local.ssh_ip
    port        = local.ssh_port
    user        = var.common.ssh_user
    private_key = file(var.common.ssh_key)
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

# Расширение раздела при изменении размера диска
resource "null_resource" "storage_extender" {
  triggers = {
    vm_disk_ids = join(",", data.vcd_vapp_vm.vm.internal_disk[*].size_in_mb)
  }

  connection {
    type        = "ssh"
    host        = local.ssh_ip
    port        = local.ssh_port
    user        = var.common.ssh_user
    private_key = file(var.common.ssh_key)
  }

  provisioner "file" {
    source      = "${path.module}/files/extenddisk.sh"
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
