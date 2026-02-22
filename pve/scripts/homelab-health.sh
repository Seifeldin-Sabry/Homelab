#!/bin/bash
# Homelab health check - runs via cron every minute
# Sends alerts via Telegram bot
# Includes escalating memory response: alert → restart container → reboot VM

BOT_TOKEN="8269357613:AAEEFZ7Mf3Juyz-pM8jxqlECatcNQ_lykEU"
CHAT_ID="6488806652"
ALERT_COOLDOWN=300  # Don't re-alert for same issue within 5 minutes

VM100_USER="admin"
VM100_IP="192.168.129.10"
SSH_OPTS="-o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=no"

# State files for escalating memory response
MEM_WARN_FILE="/tmp/health-mem-warning"
MEM_RESTART_FILE="/tmp/health-mem-restart"

send_alert() {
    local subject="$1"
    local body="$2"

    # Cooldown: don't spam for the same issue
    local hash=$(echo "$subject" | md5sum | cut -d' ' -f1)
    local last_alert="/tmp/health-alert-${hash}"

    if [ -f "$last_alert" ]; then
        local age=$(( $(date +%s) - $(stat -c %Y "$last_alert") ))
        if [ "$age" -lt "$ALERT_COOLDOWN" ]; then
            return
        fi
    fi

    local message="⚠️ *PVE ALERT*: ${subject}

${body}

_$(date '+%Y-%m-%d %H:%M:%S')_"

    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d chat_id="$CHAT_ID" \
        -d text="$message" \
        -d parse_mode="Markdown" > /dev/null 2>&1

    touch "$last_alert"
    logger -t homelab-health "ALERT: $subject"
}

# Check 1: AdGuard primary DNS
if ! dig +short +timeout=2 @10.10.10.2 cloudflare.com > /dev/null 2>&1; then
    send_alert "AdGuard Primary DNS DOWN" "CT 101 (10.10.10.2) not responding to DNS queries."
fi

# Check 2: AdGuard replica DNS
if ! dig +short +timeout=2 @10.10.10.3 cloudflare.com > /dev/null 2>&1; then
    send_alert "AdGuard Replica DNS DOWN" "CT 103 (10.10.10.3) not responding to DNS queries."
fi

# Check 3: Container status
for ct in 101 102 103 104; do
    status=$(pct status "$ct" 2>/dev/null | awk '{print $2}')
    if [ "$status" != "running" ]; then
        send_alert "Container $ct is $status" "CT $ct is not running (status: ${status:-unknown})."
    fi
done

# Check 4: VM 100 status
vm_status=$(qm status 100 2>/dev/null | awk '{print $2}')
if [ "$vm_status" != "running" ]; then
    send_alert "VM 100 (docker-host) is $vm_status" "VM 100 is not running (status: ${vm_status:-unknown})."
fi

# Check 5: Escalating memory response
mem_available_kb=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
mem_total_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
mem_pct_used=$(( (mem_total_kb - mem_available_kb) * 100 / mem_total_kb ))
avail_mb=$(( mem_available_kb / 1024 ))
total_mb=$(( mem_total_kb / 1024 ))

if [ "$mem_pct_used" -gt 90 ]; then
    # STAGE 3: Critical — check if we already restarted a container 5+ min ago
    if [ -f "$MEM_RESTART_FILE" ]; then
        restart_age=$(( $(date +%s) - $(stat -c %Y "$MEM_RESTART_FILE") ))
        if [ "$restart_age" -ge 300 ]; then
            # 5 minutes passed since container restart, RAM still critical — reboot VM 100
            send_alert "REBOOTING VM 100" "Memory still critical (${mem_pct_used}%, ${avail_mb}MB free) after container restart ${restart_age}s ago. Rebooting VM 100."
            logger -t homelab-health "ACTION: Rebooting VM 100 due to sustained memory pressure"
            qm reboot 100
            rm -f "$MEM_RESTART_FILE" "$MEM_WARN_FILE"
        fi
    else
        # STAGE 2: Try restarting the heaviest Docker container
        heaviest=$(ssh $SSH_OPTS ${VM100_USER}@${VM100_IP} \
            "docker stats --no-stream --format '{{.MemPerc}} {{.Name}}' 2>/dev/null | sort -rn | head -1 | awk '{print \$2}'" 2>/dev/null)

        if [ -n "$heaviest" ]; then
            send_alert "Restarting container: $heaviest" "Memory critical (${mem_pct_used}%, ${avail_mb}MB/${total_mb}MB free). Restarting heaviest container: $heaviest"
            logger -t homelab-health "ACTION: Restarting Docker container $heaviest"
            ssh $SSH_OPTS ${VM100_USER}@${VM100_IP} "docker restart $heaviest" 2>/dev/null
            touch "$MEM_RESTART_FILE"
        else
            send_alert "High memory: ${mem_pct_used}%" "Available: ${avail_mb}MB / ${total_mb}MB. Could not identify heaviest container to restart."
        fi
    fi
elif [ "$mem_pct_used" -gt 85 ]; then
    # STAGE 1: Warning only
    send_alert "Memory warning: ${mem_pct_used}%" "Available: ${avail_mb}MB / ${total_mb}MB. Will escalate if usage exceeds 90%."
    touch "$MEM_WARN_FILE"
else
    # Memory OK — clear escalation state
    rm -f "$MEM_WARN_FILE" "$MEM_RESTART_FILE"
fi

# Check 6: USB HDD (media storage)
if ! mountpoint -q /mnt/media 2>/dev/null; then
    send_alert "USB HDD NOT MOUNTED" "/mnt/media is not mounted. NFS clients will fail. Try: mount /dev/sda1 /mnt/media"
elif ! ls /dev/sda1 > /dev/null 2>&1; then
    send_alert "USB HDD DISCONNECTED" "/dev/sda1 not found. Drive may have disconnected. Check USB cable and dmesg."
fi

# Check 7: NFS server
if ! systemctl is-active --quiet nfs-server; then
    send_alert "NFS server DOWN" "NFS server is not running. VM 100 cannot access media storage."
fi

# Check 8: Kernel errors (bad pages, lockups)
recent_errors=$(dmesg --since "2 minutes ago" 2>/dev/null | grep -ic "bad page\|lockup\|corrupt\|bug:")
if [ "$recent_errors" -gt 0 ]; then
    errors=$(dmesg --since '5 minutes ago' | grep -i 'bad page\|lockup\|corrupt\|bug:' | head -3)
    send_alert "Kernel errors detected (${recent_errors})" "$errors"
fi
