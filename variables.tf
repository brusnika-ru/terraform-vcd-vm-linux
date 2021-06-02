variable "vcd_edge_name" {
  default = "brusnika_EDGE"
}
variable "vapp_name" {
  type        = string
  description = "Name of vApp to deploy VM"
}
variable "ext_net_name" {
  type    = string
  default = "Inet300"
}
variable "catalog_name" {
  type    = string
  default = "vApps_hk41"
}
variable "template_name" {
  type    = string
  default = "tpl-linux"
}
variable "vm_name_template" {
  type    = string
  default = "debian10"
}
variable "vm_name" {
  type = string
}
variable "vm_memory" {
  type = number
}
variable "vm_cpu" {
  type = number
}
variable "vm_net" {
  type = list(object({
    name = string
    ip   = string
  }))
}
variable "vm_storage" {
  type = object({
    med = list(object({
      mount_name = string
      mount_size = string
    }))
    ssd = list(object({
      mount_name = string
      mount_size = string
    }))
  })
}
variable "vmuser" {
  type    = string
  default = "Administrator"
}
variable "vmpassword" {
  type    = string
  default = "Brus123!"
}
variable "ssh_key" {
  type    = string
  default = "/home/mshlmv/.ssh/id_cloud-svc"
}
variable "ssh_user" {
  type    = string
  default = "cloud-svc"
}
