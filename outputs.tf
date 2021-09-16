output "vm_ip" {
  value = data.vcd_vapp_vm.vm_ip.network[0].ip
}
