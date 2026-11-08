#!/usr/bin/env bash
# A throwaway GPU box for fine-tuning polish models, so training stays off the laptop.
#
#     cloud/train-box.sh up      # launch (or reuse) the box and print its address
#     cloud/train-box.sh ssh ... # run a command on it
#     cloud/train-box.sh down    # terminate it
#
# On-demand g6.xlarge (NVIDIA L4, 24 GB) in us-east-1 at $0.80/h. The account has
# no spot quota for G instances (0 vCPUs in every region checked on 2026-11-07)
# but 8 vCPUs of on-demand G in us-east-1. The box shuts itself down, and so
# terminates, after HOURS hours whatever happens to this script.
set -euo pipefail
export AWS_PROFILE="${AWS_PROFILE:-jclegg}"
REGION=us-east-1
TYPE="${TYPE:-g6.xlarge}"
HOURS="${HOURS:-6}"
NAME=whisper-polish-train
KEY_FILE="$HOME/.ssh/$NAME"
ssh_to=(ssh -i "$KEY_FILE" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
        -o ConnectTimeout=10 -o ServerAliveInterval=30)
log() { echo "== $* ($(date -u +%H:%M:%S))" >&2; }

running_instance() {
  aws ec2 describe-instances --region $REGION \
    --filters "Name=tag:Name,Values=$NAME" "Name=instance-state-name,Values=pending,running" \
    --query 'Reservations[0].Instances[0].[InstanceId,PublicIpAddress]' --output text
}

up() {
  read -r instance ip <<<"$(running_instance)"
  if [ "$instance" = "None" ]; then
    if [ ! -f "$KEY_FILE" ]; then
      aws ec2 create-key-pair --region $REGION --key-name $NAME --query KeyMaterial --output text > "$KEY_FILE"
      chmod 600 "$KEY_FILE"
    fi
    group="$(aws ec2 describe-security-groups --region $REGION --filters "Name=group-name,Values=$NAME" \
      --query 'SecurityGroups[0].GroupId' --output text)"
    if [ "$group" = "None" ]; then
      group="$(aws ec2 create-security-group --region $REGION --group-name $NAME \
        --description "SSH to the polish training box" --query GroupId --output text)"
    fi
    my_ip="$(curl -s https://checkip.amazonaws.com)"
    aws ec2 authorize-security-group-ingress --region $REGION --group-id "$group" \
      --protocol tcp --port 22 --cidr "$my_ip/32" >/dev/null 2>&1 || true
    ami="$(aws ssm get-parameter --region $REGION \
      --name /aws/service/deeplearning/ami/x86_64/oss-nvidia-driver-gpu-pytorch-2.12-ubuntu-24.04/latest/ami-id \
      --query Parameter.Value --output text)"
    instance="$(aws ec2 run-instances --region $REGION --image-id "$ami" --instance-type "$TYPE" \
      --key-name $NAME --security-group-ids "$group" \
      --instance-initiated-shutdown-behavior terminate \
      --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=150,VolumeType=gp3,DeleteOnTermination=true}' \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$NAME}]" \
      --query 'Instances[0].InstanceId' --output text)"
    log "launched $instance ($TYPE, $ami)"
    aws ec2 wait instance-running --region $REGION --instance-ids "$instance"
    read -r instance ip <<<"$(running_instance)"
    until "${ssh_to[@]}" "ubuntu@$ip" true 2>/dev/null; do sleep 5; done
    "${ssh_to[@]}" "ubuntu@$ip" "sudo shutdown -h +$((HOURS * 60)) >/dev/null 2>&1"
    log "ready; terminates itself in $HOURS h"
  fi
  echo "$ip"
}

case "${1:-}" in
  up) up ;;
  ssh) shift; read -r _ ip <<<"$(running_instance)"; "${ssh_to[@]}" "ubuntu@$ip" "$@" ;;
  ip) read -r _ ip <<<"$(running_instance)"; echo "$ip" ;;
  down)
    read -r instance _ <<<"$(running_instance)"
    [ "$instance" != "None" ] && aws ec2 terminate-instances --region $REGION --instance-ids "$instance" >/dev/null
    log "terminated $instance" ;;
  *) echo "usage: $0 up|ssh|ip|down" >&2; exit 2 ;;
esac
