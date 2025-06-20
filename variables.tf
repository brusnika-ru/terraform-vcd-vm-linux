variable "vcd_edge_name" {
  type        = string
  description = ""
  default     = ""
}

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
  description = "Map of polcies with size disks in GigaBytes and name of mount points"
  default     =  {}
}

#variable "storages" {
#  description = "Disks configuration (mount points and sizes)"
#  type = map(list(object({
#    mount_name = string
#    mount_size = number
#  })))
#  default = {}
#}

variable "types" {
  description = "List of disk polcies"
}

variable "networks" {
  description = "Name networks for attach to VM. Manual IP (optional)"
}

variable "template" {
  description = "Name of VM in vApp template to deploy (optional)"
  default     = "" 
}

variable "common" {
  description = "Common variables"
}

variable "edge" {
  description = "EDGE variables"
  default     = {}
}

variable "dnat_ip" {
  description = "External IP if DNAT used"
  default     = ""
}

variable "dnat_ext_port" {
  description = "External port if DNAT used"
  default     = ""
}

variable "dnat_in_port" {
  description = "Internal port if DNAT used"
  default     = "22"
}

variable "external_net" {
  description = "External net for DNAT"
  default     = ""
}

variable "external_ip" {
  description = "External IP for DNAT"
  default     = ""
}

variable "dnat_rules" {
  description = "List DNAT rules (optional)"
  type        = list(object({
    dnat_ext_port = string
    dnat_in_port  = string
  }))
  default     = []
}

locals {
  storages = flatten([
    for storage_key, storage in var.storages : [
      for type_key, type in storage : {
        bus  = index(keys(var.storages), storage_key) + 1
        name = contains(keys(type), "mount_name") ? type.mount_name : "block"
        size = type.mount_size
        type = storage_key
        unit = type_key
      }
    ]
  ])

  storages_w_iops = flatten([
    for s in local.storages : [
      for t in var.types : merge(s, {
        iops = t.iops >= 0 ? t.iops : min(s.size * t.iops_per_gb, t.iops_limit)
      }) if t.type == s.type
    ]
  ])

  mounts_group = { for mount in local.storages : mount.name => tonumber(mount.size)... }
  mounts       = zipmap([for k, v in local.mounts_group : k], [for v in local.mounts_group : sum(v)])

  hot_add = var.cpu != 8 ? true : false

  dnat_ip       = length(var.dnat_rules) > 0 ? var.edge.external_ip : ""
  dnat_ext_port = length(var.dnat_rules) > 0 ? var.dnat_rules[0].dnat_ext_port : "" 

  ssh_ip   = local.dnat_ip != "" ? local.dnat_ip : data.vcd_vapp_vm.vm_ip.network[0].ip
  ssh_port = local.dnat_ext_port != "" ? local.dnat_ext_port : 22
}
