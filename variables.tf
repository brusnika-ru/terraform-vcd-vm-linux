variable "vapp" {
  type        = string
  description = "Name of vApp to deploy VM"
}

variable "name" {
  type        = string
  description = "A unique name for VM"
}

variable "ram" {
  type        = number
  description = "Size of memory VM in MegaBytes"
}

variable "cpu" {
  type        = number
  description = "Count of CPU cores VM"
}

variable "storages" {
  description = "Size of disks in GigaBytes and name of mount points"
  default     =  [{}]
}

variable "types" {
  type = list(object({
    type = string
    iops = number
  }))
}

variable "networks" {
  description = "Name networks for attach to VM. Manual IP (optional)"
}

variable "template" {
  description = "Name of VM in vApp template to deploy (optional)"
  default     = "" 
}

variable "common" {
  # type        = map
  description = "Common variables"
}

locals {
  storages = flatten([
    for storage_key, storage in var.storages : [
      for type_key, type in storage : {
        type = "vcd-type-${storage_key}"
        name = type.mount_name
        size = type.mount_size
        bus  = index(keys(var.storages), storage_key) + 1
        unit = type_key
      }
    ]
  ])

  storages_w_iops = flatten([
    for s in local.storages : [
      for t in var.types : merge(s,t) if s.type == t.type
    ]
  ])

  mounts_group = { for mount in local.storages : mount.name => tonumber(mount.size)... }
  mounts       = zipmap([for k, v in local.mounts_group : k], [for v in local.mounts_group : sum(v)])

  hot_add = var.cpu != 8 ? true : false

  ssh_ip   = local.dnat_orig_ip
  ssh_port = local.dnat_port_ssh

  dnat_port_ssh = random_integer.dynamic_ports.result
  dnat_orig_ip  = "176.53.182.12"
  
}
