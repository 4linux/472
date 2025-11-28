#!/bin/bash
set -e

# 1) Caminho para o arquivo rc do admin
source /root/admin-open.rc

HOSTNAME=$(hostname)
PORT_NAME="octavia-hm-port-${HOSTNAME}"

# 2) Descobrir ID da porta, MAC e IP/CIDR a partir do Neutron
PORT_ID=$(openstack port show "$PORT_NAME" -f value -c id)
PORT_MAC=$(openstack port show "$PORT_ID" -f value -c mac_address)

PORT_FIXED_IPS=$(openstack port show "$PORT_ID" -f value -c fixed_ips)
PORT_IP=$(echo "$PORT_FIXED_IPS"  | awk -F"'" '{print $8}')
SUBNET_ID=$(echo "$PORT_FIXED_IPS" | awk -F"'" '{print $4}')

SUBNET_CIDR=$(openstack subnet show "$SUBNET_ID" -f value -c cidr)
IP_CIDR="${PORT_IP}/${SUBNET_CIDR#*/}"

# 3) Garantir que a porta está associada a este host (idempotente)
HOST_SHORT=$(hostname)
openstack port set --host "$HOST_SHORT" "$PORT_ID" || true

# 4) Garantir que a interface o-hm0 existe no br-int e está ligada à porta Neutron
ovs-vsctl -- --may-exist add-port br-int o-hm0 -- \
    set Interface o-hm0 type=internal -- \
    set Interface o-hm0 external_ids:iface-status=active -- \
    set Interface o-hm0 external_ids:attached-mac=$PORT_MAC -- \
    set Interface o-hm0 external_ids:iface-id=$PORT_ID -- \
    set Interface o-hm0 external_ids:skip_cleanup=true

# 5) Reconfigurar MAC, IP e rota no SO
ip link set dev o-hm0 address "$PORT_MAC"

ip addr flush dev o-hm0
ip addr add "$IP_CIDR" dev o-hm0

ip link set dev o-hm0 up

ip route replace "$SUBNET_CIDR" dev o-hm0 src "$PORT_IP"
