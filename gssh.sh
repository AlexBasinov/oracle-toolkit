#!/bin/bash

host="${@: -2: 1}"
cmd="${@: -1: 1}"

# gcloud_ssh_args="
#            -C \
#            -o ControlPath=/tmp/ansible-ssh-${host} \
#            -o ControlMaster=auto \
#            -o ControlPersist=20 \
#            -o PreferredAuthentications=publickey \
#            -o KbdInteractiveAuthentication=no \
#            -o PasswordAuthentication=no \
#            -o ConnectTimeout=20 \
#            -o ServerAliveInterval=60 \
#            -o ServerAliveCountMax=3 \
#            -o StrictHostKeyChecking=no \
#            -o UserKnownHostsFile=/dev/null \
#            -o IdentityAgent=no
# "

ssh_args="
           -o PreferredAuthentications=publickey \
           -o KbdInteractiveAuthentication=no \
           -o PasswordAuthentication=no \
           -o ConnectTimeout=20 \
           -o ServerAliveInterval=60 \
           -o ServerAliveCountMax=3 \
           -o StrictHostKeyChecking=no \
           -o UserKnownHostsFile=/dev/null \
"

echo "cmd_line=$@" > /tmp/gssh-ot.log
echo "host=$host" >> /tmp/gssh-ot.log
echo "cmd=$cmd" >> /tmp/gssh-ot.log

is_gce() {
    curl -s -H "Metadata-Flavor: Google" http://metadata.google.internal > /dev/null 2>&1
}


if is_gce; then
    zone=$(gcloud compute instances list --filter="name=($host)" --format="value(zone)" --limit=1)


    if [[ -z "$zone" ]]; then
        echo "Error: Could not determine zone for host $host"
        exit 1
    fi

    gcloud_args="
    --internal-ip
    --zone=$zone
    --quiet
    --no-user-output-enabled
    "

    exec gcloud compute ssh "$host" $gcloud_args -C "$cmd" -- $ssh_args 
else
    # Not on GCE - fallback to standard SSH using arguments provided by Ansible (from inventory or ansible.cfg)
    exec /usr/bin/ssh "$@"
fi
