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

  customization {
    force      = false
    enabled    = true
  }
}

data "vcd_vapp_vm" "vm_ip" {
  depends_on = [
    vcd_vapp_vm.vm
  ]

  vapp_name  = var.vapp
  name       = var.name
}

module "DNAT" {
  source = "github.com/brusnika-ru/terraform-vcd-vnat.git?ref=v1.0.6"
  
  for_each = {
    for rule in var.dnat_rules : "${rule.dnat_ext_port}.${rule.dnat_in_port}" => rule
  }

  vcd_edge_name  = var.edge.vcd_edge_name

  type        = "dnat"
  description = "DNAT ${each.value.dnat_in_port} / ${var.name}"
  src_port    = each.value.dnat_ext_port
  dst_net     = data.vcd_vapp_vm.vm_ip.network[0].ip
  dst_port    = each.value.dnat_in_port
  net_name    = var.edge.external_net
  ext_ip      = var.edge.external_ip
}

# Пауза после создания машины
resource "time_sleep" "wait_after_vm" {
  depends_on = [
    vcd_vapp_vm.vm
  ]

  create_duration = "30s"
}

# Создание виртуального диска и присоединение к ВМ
resource "vcd_vm_internal_disk" "vmStorage" {
  depends_on = [
    time_sleep.wait_after_vm
  ]


#for_each = {
#  for disk in local.storages_processed : 
#    "bus${disk.bus}-unit${disk.unit}-${replace(disk.name, "/", "_")}" => disk
#}

  for_each = {
    for disk in local.storages_w_iops : "${disk.type}.${disk.name}.${disk.unit}" => disk
  }

  vapp_name       = var.vapp
  vm_name         = var.name
  bus_type        = "paravirtual"
  size_in_mb      = (each.value.size * 1024) + 1
  bus_number      = each.value.bus
  unit_number     = each.value.unit
  iops            = each.value.iops
  storage_profile = each.value.type
#  storage_profile = ""

  lifecycle {
    ignore_changes = [storage_profile]
  }

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

data "vcd_vapp_vm" "vm_disks" {
  depends_on = [
    vcd_vapp_vm.vm,
    vcd_vm_internal_disk.vmStorage
  ]

  vapp_name  = var.vapp
  name       = var.name
}

# Запись точек монтирования в /tmp/mounts.txt
resource "null_resource" "mounts_writer" {
  depends_on = [vcd_vm_internal_disk.vmStorage]

  for_each = local.mounts

  triggers = {
    vm_disk_ids = join(",", data.vcd_vapp_vm.vm_disks.internal_disk[*].size_in_mb)
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

resource "time_sleep" "wait_after_disk" {
  depends_on      = [null_resource.mounts_writer]
  create_duration = "10s"
}

# Расширение раздела при изменении размера диска
resource "null_resource" "storage_extender" {
  depends_on = [vcd_vm_internal_disk.vmStorage]

  count = var.storages == {} ? 0 : 1

  triggers = {
    vm_disk_ids = join(",", data.vcd_vapp_vm.vm_disks.internal_disk[*].size_in_mb)
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
      "rm /tmp/mounts.txt"
    ]
  }
}

# Пауза после создания машины
resource "time_sleep" "wait_before_ansible" {
  depends_on = [
    vcd_vapp_vm.vm,
    null_resource.storage_extender
  ]

  create_duration = "30s"
}

resource "null_resource" "run_ansible" {
  depends_on = [
    time_sleep.wait_before_ansible,
    module.DNAT
  ]

  triggers = {
    playbook = filebase64("${var.name}.conf.yml")
  }

  provisioner "local-exec" {
    command = "ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -u ${var.common.ssh_user} -i '${local.ssh_ip},' -e 'ansible_port=${local.ssh_port} vm_name=${var.name} vapp_name=${var.vapp} vm_ip=${data.vcd_vapp_vm.vm_ip.network[0].ip}' --key-file ${var.common.ssh_key} ${var.name}.conf.yml"
  }
}
