output "incus_instance_node01_ip" {
  value = incus_instance.node01.ipv4_address
}

# HAOS has no Incus agent and br0 is unmanaged, so ipv4_address is never populated
# (see main.tf). Export status instead; the IP is pinned via a router DHCP reservation.
output "incus_instance_haos_status" {
  value = incus_instance.haos.status
}
