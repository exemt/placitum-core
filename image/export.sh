#!/bin/sh
# Disk formats of a built image for other hypervisors, next to the qcow2 for KVM: VHDX for Hyper-V
# and an OVA for VirtualBox and VMware.
#
#     sh image/export.sh image/work/placitum-<revision>.qcow2 [vhdx|ova|all]
#
# Needs qemu-img, tar and sha256sum. The OVA describes a machine with 2 processors, 4 GB of memory,
# the disk on an IDE controller and an Intel E1000 network adapter: what every version of VirtualBox
# and VMware imports without questions, with the drivers of the generic Debian kernel in the image
# (image/build.sh without --base genericcloud). After the import the disk can move to a SATA or
# SCSI controller of the hypervisor: the kernel has those drivers too. The files land next to the
# qcow2 under the same name.

set -eu

src=${1:?usage: export.sh <image.qcow2> [vhdx|ova|all]}
what=${2:-all}

case "$what" in
    vhdx|ova|all) ;;
    *) printf 'usage: export.sh <image.qcow2> [vhdx|ova|all]\n' >&2; exit 2 ;;
esac

[ -f "$src" ] || { printf 'no image: %s\n' "$src" >&2; exit 1; }

for tool in qemu-img tar sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || { printf '%s not found\n' "$tool" >&2; exit 1; }
done

dir=$(CDPATH= cd -- "$(dirname -- "$src")" && pwd)
name=$(basename "$src" .qcow2)
say() { printf '\n== %s\n' "$*"; }

vhdx() {
    say "VHDX for Hyper-V"
    out="$dir/$name.vhdx"
    qemu-img convert -p -O vhdx -o subformat=dynamic "$src" "$out.part"
    mv "$out.part" "$out"
    printf 'vhdx: %s, %s\n' "$out" "$(du -h "$out" | cut -f1)"
}

ova() {
    say "OVA for VirtualBox and VMware"
    stage=$(mktemp -d "$dir/ova.XXXXXX")
    disk="$name-disk1.vmdk"

    qemu-img convert -p -O vmdk -o subformat=streamOptimized "$src" "$stage/$disk"

    capacity=$(qemu-img info "$src" | sed -n 's/^virtual size: .*(\([0-9]*\) bytes)$/\1/p')
    [ -n "$capacity" ] || { printf 'cannot read the virtual size of %s\n' "$src" >&2; exit 1; }
    size=$(stat -c %s "$stage/$disk")

    cat > "$stage/$name.ovf" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<Envelope ovf:version="1.0" xml:lang="en-US"
    xmlns="http://schemas.dmtf.org/ovf/envelope/1"
    xmlns:ovf="http://schemas.dmtf.org/ovf/envelope/1"
    xmlns:rasd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_ResourceAllocationSettingData"
    xmlns:vssd="http://schemas.dmtf.org/wbem/wscim/1/cim-schema/2/CIM_VirtualSystemSettingData"
    xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <References>
    <File ovf:id="file1" ovf:href="$disk" ovf:size="$size"/>
  </References>
  <DiskSection>
    <Info>Virtual disk information</Info>
    <Disk ovf:capacity="$capacity" ovf:diskId="vmdisk1" ovf:fileRef="file1"
        ovf:format="http://www.vmware.com/interfaces/specifications/vmdk.html#streamOptimized"
        ovf:populatedSize="$size"/>
  </DiskSection>
  <NetworkSection>
    <Info>Logical networks</Info>
    <Network ovf:name="LAN">
      <Description>The network the machine serves traffic and the panel on</Description>
    </Network>
  </NetworkSection>
  <VirtualSystem ovf:id="$name">
    <Info>Placitum: a ready machine, the installation runs on the first boot</Info>
    <Name>$name</Name>
    <OperatingSystemSection ovf:id="96">
      <Info>The kind of installed guest operating system</Info>
      <Description>Debian GNU/Linux 13 (64-bit)</Description>
    </OperatingSystemSection>
    <VirtualHardwareSection>
      <Info>Virtual hardware requirements</Info>
      <System>
        <vssd:ElementName>Virtual Hardware Family</vssd:ElementName>
        <vssd:InstanceID>0</vssd:InstanceID>
        <vssd:VirtualSystemIdentifier>$name</vssd:VirtualSystemIdentifier>
        <vssd:VirtualSystemType>vmx-13</vssd:VirtualSystemType>
      </System>
      <Item>
        <rasd:AllocationUnits>hertz * 10^6</rasd:AllocationUnits>
        <rasd:Description>Number of Virtual CPUs</rasd:Description>
        <rasd:ElementName>2 virtual CPUs</rasd:ElementName>
        <rasd:InstanceID>1</rasd:InstanceID>
        <rasd:ResourceType>3</rasd:ResourceType>
        <rasd:VirtualQuantity>2</rasd:VirtualQuantity>
      </Item>
      <Item>
        <rasd:AllocationUnits>byte * 2^20</rasd:AllocationUnits>
        <rasd:Description>Memory Size</rasd:Description>
        <rasd:ElementName>4096 MB of memory</rasd:ElementName>
        <rasd:InstanceID>2</rasd:InstanceID>
        <rasd:ResourceType>4</rasd:ResourceType>
        <rasd:VirtualQuantity>4096</rasd:VirtualQuantity>
      </Item>
      <Item>
        <rasd:Address>0</rasd:Address>
        <rasd:Description>IDE Controller</rasd:Description>
        <rasd:ElementName>IDE Controller 0</rasd:ElementName>
        <rasd:InstanceID>3</rasd:InstanceID>
        <rasd:ResourceSubType>PIIX4</rasd:ResourceSubType>
        <rasd:ResourceType>5</rasd:ResourceType>
      </Item>
      <Item>
        <rasd:AddressOnParent>0</rasd:AddressOnParent>
        <rasd:ElementName>Hard Disk 1</rasd:ElementName>
        <rasd:HostResource>ovf:/disk/vmdisk1</rasd:HostResource>
        <rasd:InstanceID>4</rasd:InstanceID>
        <rasd:Parent>3</rasd:Parent>
        <rasd:ResourceType>17</rasd:ResourceType>
      </Item>
      <Item>
        <rasd:AddressOnParent>7</rasd:AddressOnParent>
        <rasd:AutomaticAllocation>true</rasd:AutomaticAllocation>
        <rasd:Connection>LAN</rasd:Connection>
        <rasd:Description>E1000 ethernet adapter</rasd:Description>
        <rasd:ElementName>Network Adapter 1</rasd:ElementName>
        <rasd:InstanceID>5</rasd:InstanceID>
        <rasd:ResourceSubType>E1000</rasd:ResourceSubType>
        <rasd:ResourceType>10</rasd:ResourceType>
      </Item>
    </VirtualHardwareSection>
  </VirtualSystem>
</Envelope>
EOF

    (
        cd "$stage"
        {
            printf 'SHA256(%s)= %s\n' "$name.ovf" "$(sha256sum "$name.ovf" | cut -d' ' -f1)"
            printf 'SHA256(%s)= %s\n' "$disk" "$(sha256sum "$disk" | cut -d' ' -f1)"
        } > "$name.mf"
        # The descriptor goes first in the archive: importers read it before the disk.
        tar --format=ustar -cf "$dir/$name.ova.part" "$name.ovf" "$name.mf" "$disk"
    )

    mv "$dir/$name.ova.part" "$dir/$name.ova"
    rm -rf "$stage"
    printf 'ova: %s, %s\n' "$dir/$name.ova" "$(du -h "$dir/$name.ova" | cut -f1)"
}

case "$what" in
    vhdx) vhdx ;;
    ova)  ova ;;
    all)  vhdx; ova ;;
esac
