# Intentional stub. VM provisioning is delegated to the project-level stack at
# nilgiri/terraform/libvirt/. This file exists so GOAD's provider-factory.py can
# register the libvirt provider name even though there is no per-VM HCL here.
#
# To bring up just the GOAD VMs:
#     cd nilgiri/terraform/libvirt
#     terraform apply -target='libvirt_domain.vm["dc1.charlie"]' \
#                     -target='libvirt_domain.vm["fs.charlie"]'   \
#                     -target='libvirt_domain.vm["dc1.oscar"]'
#
# To bring up everything:
#     terraform apply
#
# Then run GOAD's ansible against the inventory in this directory:
#     cd nilgiri/vendor/GOAD
#     ANSIBLE_CONFIG=ansible/ansible.cfg ../../.venv/bin/ansible-playbook \
#         -i ../../ad/NILGIRI-V1/providers/libvirt/inventory \
#         ad.yml --tags "ad-setup"
