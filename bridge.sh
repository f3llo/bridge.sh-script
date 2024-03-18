#!/usr/bin/env bash

set -e

[ $EUID -ne 0 ] && echo "run as root" >&2 && exit 1

# https://serverfault.com/a/926773/373603
ethernet_interface="$(ls /sys/class/net | grep -E 'end|eth')"

# Install required software.
apt update && apt install -y parprouted dhcpcd dhcp-helper

# Stop dhcp-helper. It will run after the Pi reboots.
systemctl stop dhcp-helper

# NetworkManager will invoke dhcpcd itself. Disable the standard service unit.
systemctl stop dhcpcd
systemctl disable dhcpcd

# Enable ipv4 forwarding.
sed -i'' s/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/ /etc/sysctl.conf

# Use dhcpcd as the DHCP backend for NetworkManager
cat << EOF > /etc/NetworkManager/conf.d/dhcpcd.conf
[main]
dhcp=dhcpcd
EOF

# Enable IP forwarding for wlan0 if it's not already enabled.
grep '^option ip-forwarding 1$' /etc/dhcpcd.conf || printf "option ip-forwarding 1\n" >> /etc/dhcpcd.conf

# Disable dhcpcd control of the wired interface.
grep '^denyinterfaces ${ethernet_interface}$' /etc/dhcpcd.conf || printf "denyinterfaces ${ethernet_interface}\n" >> /etc/dhcpcd.conf

# Configure dhcp-helper.
cat > /etc/default/dhcp-helper <<EOF
DHCPHELPER_OPTS="-b wlan0"
EOF

# Enable avahi reflector if it's not already enabled.
sed -i'' 's/#enable-reflector=no/enable-reflector=yes/' /etc/avahi/avahi-daemon.conf
grep '^enable-reflector=yes$' /etc/avahi/avahi-daemon.conf || {
  printf "something went wrong...\n\n"
  printf "Manually set 'enable-reflector=yes in /etc/avahi/avahi-daemon.conf'\n"
}

cat << 'EOF' > /usr/local/bin/bridge.py
#!/usr/bin/env python3

from subprocess import check_call, check_output, Popen, PIPE, run
from sys import argv, exit
from threading import Thread
from time import sleep

def get_ip(interface_name):
    return check_output(['ip', '-4', '-br', 'addr', 'show', interface_name]).decode('utf-8').strip().split()[-1]

def pre_start(ip, ethernet_interface, wireless_interface):
    try:
        check_call(['ip', 'addr', 'add', ip, 'dev', ethernet_interface])
        check_call(['ip', 'link', 'set', 'dev', ethernet_interface, 'up'])
        check_call(['ip', 'link', 'set', wireless_interface, 'promisc', 'on'])
    except:
        print('pre_start error')
        # In case of error, try to clean up
        pre_stop(ip, ethernet_interface, wireless_interface)
        exit(1)

def pre_stop(ip, ethernet_interface, wireless_interface):
    run(['ip', 'link', 'set', wireless_interface, 'promisc', 'off'], check=False)
    run(['ip', 'link', 'set', 'dev', ethernet_interface, 'down'], check=False)
    run(['ip', 'addr', 'del', ip, 'dev', ethernet_interface], check=False)

def start(ethernet_interface, wireless_interface):
    with Popen(['parprouted', '-d', ethernet_interface, wireless_interface], stdout=PIPE, stderr=PIPE, bufsize=1, universal_newlines=True) as process:
        for line in iter(process.stdout.readline, ''):
            print(line, end='')
        for line in iter(process.stderr.readline, ''):
            print(line, end='')

if __name__ == '__main__':
    is_up = False
    ip = None
    ethernet_interface = argv[1]
    wireless_interface = argv[2]
    task = None

    try:
        while True:
            new_ip = get_ip(wireless_interface)

            if is_up:
                if task and not task.is_alive():
                    pre_stop(ip, ethernet_interface, wireless_interface)
                    print('process stopped unexpectedly', task)
                    exit(1)
                if ip and not new_ip:
                    pre_stop(ip, ethernet_interface, wireless_interface)
                    print('ip disappeared')
                    exit(1)

            ip = new_ip

            if ip and not is_up:
                print('starting...')
                pre_start(ip, ethernet_interface, wireless_interface)
                task = Thread(target=start, args=(ethernet_interface, wireless_interface,))
                task.start()
                is_up = True

            if not ip and is_up:
                print('stopping...')
                pre_stop(ip, ethernet_interface, wireless_interface)
                task.join()
                exit(0)

            sleep(1)

    except KeyboardInterrupt:
        pre_stop(ip, ethernet_interface, wireless_interface)
        exit(0)
EOF

chmod +x /usr/local/bin/bridge.py

cat <<EOF >/usr/lib/systemd/system/parprouted.service
[Unit]
Description=proxy arp routing service
Documentation=https://raspberrypi.stackexchange.com/q/88954/79866
Requires=sys-subsystem-net-devices-wlan0.device dhcpcd.service
After=sys-subsystem-net-devices-wlan0.device dhcpcd.service

[Service]
Type=forking
Restart=on-failure
RestartSec=5
TimeoutStartSec=30
ExecStart=/usr/local/bin/bridge.py ${ethernet_interface} wlan0

[Install]
WantedBy=wpa_supplicant.service
EOF

systemctl daemon-reload
systemctl enable dhcp-helper parprouted
