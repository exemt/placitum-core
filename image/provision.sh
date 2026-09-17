#!/bin/sh
# Runs as root on the build machine of image/build.sh: Docker, haproxy, Placitum
# files and images, the first boot service, then cleanup and power off.

set -eu

export DEBIAN_FRONTEND=noninteractive

say() { printf '\n== %s\n' "$*"; }

say "packages"

apt-get update -q
apt-get install -y -q --no-install-recommends ca-certificates curl gnupg openssl haproxy

# haproxy of the distribution stays off: install.sh runs its own service for several nodes.
systemctl disable --now haproxy

install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# shellcheck disable=SC1091
. /etc/os-release
printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian %s stable\n' \
    "$(dpkg --print-architecture)" "$VERSION_CODENAME" > /etc/apt/sources.list.d/docker.list

apt-get update -q
apt-get install -y -q --no-install-recommends docker-ce docker-ce-cli containerd.io docker-compose-plugin
apt-get upgrade -y -q

# Container logs rotate, so a small disk does not fill up over months.
cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
systemctl restart docker

say "images"

docker load -i /tmp/images.tar
rm -f /tmp/images.tar

while read -r built name; do
    docker tag "$built" "$name"
    docker rmi "$built" >/dev/null
done < /tmp/retag.txt

docker image ls --format '{{.Repository}}:{{.Tag}} {{.Size}}'

say "files"

install -d -m 0755 /opt/placitum
tar -C /opt/placitum -xf /tmp/core.tar
install -m 0644 /tmp/MANIFEST /opt/placitum/image/MANIFEST
chown -R root:root /opt/placitum
chmod 0700 /opt/placitum/secrets

# Console and ssh user; the first boot asks its password.
useradd -m -s /bin/bash -G sudo,docker placitum
passwd -l placitum

install -m 0755 /opt/placitum/image/placitum /usr/local/sbin/placitum

# haproxy in front of several nodes and its agent; install.sh enables them when it needs them.
install -m 0755 /tmp/waf-haproxy-agent /usr/local/bin/waf-haproxy-agent
install -m 0644 /opt/placitum/image/balancer/placitum-haproxy.service \
    /opt/placitum/image/balancer/placitum-haproxy-agent.service /etc/systemd/system/
systemctl daemon-reload

install -m 0644 /opt/placitum/image/placitum-firstboot.service /etc/systemd/system/
systemctl enable placitum-firstboot.service
sh /opt/placitum/image/firstboot.sh --issue

# Host keys are created on the first boot of every machine, with or without cloud-init.
install -d /etc/systemd/system/ssh.service.d
printf '[Service]\nExecStartPre=-/usr/bin/ssh-keygen -A\n' > /etc/systemd/system/ssh.service.d/placitum-keys.conf

say "cleanup"

apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/core.tar /tmp/retag.txt /tmp/MANIFEST /tmp/waf-haproxy-agent

cat > /root/seal.sh <<'EOF'
#!/bin/sh
sleep 3
pkill -KILL -u build 2>/dev/null || true
userdel -rf build 2>/dev/null || true
rm -f /etc/sudoers.d/90-cloud-init-users /tmp/provision.sh
cloud-init clean --logs --seed 2>/dev/null || true
rm -f /etc/ssh/ssh_host_*
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
journalctl --rotate >/dev/null 2>&1 || true
journalctl --vacuum-time=1s >/dev/null 2>&1 || true
find /var/log -type f -name '*.log' -exec truncate -s 0 {} +
rm -f /root/seal.sh
fstrim -av
systemctl poweroff
EOF

systemd-run --no-block --unit=placitum-seal /bin/sh /root/seal.sh
