#!/bin/sh

PATH=/usr/bin:/usr/sbin:/usr/local/bin:/usr/bin:/usr/local/sbin
export PATH

privuid=$(sudo id -u)

if [ "$privuid" != "0" ]; then
	echo "$0 failed: sudo access required"
	exit 1
fi

privrun() { sudo "$@"; }
traceprun() { echo "# $*"; privrun "$@"; }
checkprun() {
	if traceprun "$@"; then :; else
		echo "FAILED"
		exit 1
	fi
}
rundnf() { checkprun dnf -y "$@"; }

selinux_mode=$(getenforce)
if [ "$selinux_mode" = "Enforcing" ]; then
	echo "WARNING: selinux mode is $selinux_mode"
	echo "NOTE: you may need to change this permanently; or add your own handling of selinux"
	grep '^SELINUX=' /etc/selinux/config /dev/null 2>/dev/null
	checkprun setenforce Permissive
fi

rundnf install podman

cat >> Dockerfile.with-cuda << 'EOF'
FROM docker.io/vespaengine/vespa:latest
USER root
RUN dnf -y install 'dnf-command(config-manager)'
RUN dnf -y config-manager --add-repo https://raw.githubusercontent.com/vespa-engine/vespa/master/dist/vespa-engine.repo
RUN dnf -y config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/rhel8/x86_64/cuda-rhel8.repo
RUN dnf -y install $(rpm -q --queryformat '%{NAME}-cuda-%{VERSION}' vespa-onnxruntime)
USER vespa
EOF

checkprun podman build -t vespaengine/with-cuda -f Dockerfile.with-cuda .

rundnf config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/rhel8/x86_64/cuda-rhel8.repo
rundnf config-manager --add-repo https://nvidia.github.io/libnvidia-container/rhel8.6/libnvidia-container.repo
rundnf module install nvidia-driver:580-dkms

checkprun nvidia-modprobe

rundnf install nvidia-container-toolkit-base-1.13.5

makedev() {
	devname="/dev/$1"
	major=$2
	minor=$3
	if [ -e $devname ]; then
		info=$(file $devname)
		if file $devname | grep -q ": character special ($major/$minor)\$"; then
			echo "device OK: $info"
		else
			echo "Wanted '$devname' with major/minor device number '$major/$minor'"
			echo "But got: $info"
			exit 1
		fi
		privrun chmod 666 $devname

	else
		checkprun mknod -Z -m 666 $devname c ${major} ${minor}
		file $devname
	fi
	if [ "$selinux_mode" != "Disabled" ]; then
		privrun chcon -t container_file_t $devname
	fi
}

frontend_major=$(awk '$2 == "nvidia-frontend" || $2 == "nvidia" { print $1 }' < /proc/devices)
if [ "${frontend_major}" = "" ]; then
	echo "FAILED: missing 'nvidia-frontend' in /proc/devices"
	exit 1
fi
makedev nvidiactl ${frontend_major} 255
for i in $(cat /proc/driver/nvidia/gpus/*/information | awk '$2 == "Minor:" { print $3 }'); do
	makedev nvidia${i} ${frontend_major} $i
done
makedev nvidia-modeset ${frontend_major} 254

uvm_major=$(awk '$2 == "nvidia-uvm" { print $1 }' < /proc/devices)
if [ "${uvm_major}" = "" ]; then
	echo "FAILED: missing 'nvidia-uvm' in /proc/devices"
	exit 1
fi
makedev nvidia-uvm       ${uvm_major} 0
makedev nvidia-uvm-tools ${uvm_major} 1

privrun mkdir -p /etc/cdi
checkprun nvidia-ctk cdi generate --device-name-strategy=type-index --format=json --output /etc/cdi/nvidia.json
privrun chmod 644 /etc/cdi/nvidia.json

podname=vespa-test-$$-tmp
checkprun podman run --device nvidia.com/gpu=all --detach --name ${podname} --hostname ${podname} vespaengine/with-cuda
privrun podman exec -it ${podname} sh -c 'cd /tmp && set -x && vespa clone examples/model-exporting/app s-app && vespa deploy --wait 300 s-app && vespa-logfmt -N | grep -9 -i gpu'
privrun podman stop ${podname}
checkprun podman rm ${podname}
