#!/bin/bash

# Enforce a bounded syslog retention policy via /etc/logrotate.d/rsyslog.
# Goal: keep syslog archives bounded to roughly 1GB total (10 x 100MB).
enforce_syslog_logrotate_cap() {
    local rsyslog_rotate_file="/etc/logrotate.d/rsyslog"
    local tmp_file

    if [ ! -f "$rsyslog_rotate_file" ]; then
        echo -e "${YELLOW}⚠️ Syslog logrotate config not found at $rsyslog_rotate_file; skipping syslog cap setup.${NC}"
        return 0
    fi

    tmp_file="$(mktemp "${TMPDIR:-/tmp}/runai-rsyslog-logrotate.XXXXXX")" || {
        echo -e "${YELLOW}⚠️ Could not create temp file for syslog cap setup; skipping.${NC}"
        return 0
    }

    if ! awk '
        BEGIN {
            in_block = 0
            pending_syslog = 0
            target_block = 0
            has_size = 0
            has_rotate = 0
            patched = 0
        }
        {
            line = $0

            if (!in_block && line ~ /\/var\/log\/syslog/) {
                pending_syslog = 1
            }

            if (line ~ /\{/) {
                in_block = 1
                if (pending_syslog == 1) {
                    target_block = 1
                    pending_syslog = 0
                }
            }

            if (target_block == 1) {
                if (line ~ /^[[:space:]]*size[[:space:]]+/) {
                    line = "    size 100M"
                    has_size = 1
                    patched = 1
                } else if (line ~ /^[[:space:]]*rotate[[:space:]]+/) {
                    line = "    rotate 10"
                    has_rotate = 1
                    patched = 1
                }
            }

            if (line ~ /^[[:space:]]*}[[:space:]]*$/) {
                if (target_block == 1) {
                    if (has_size == 0) {
                        print "    size 100M"
                        patched = 1
                    }
                    if (has_rotate == 0) {
                        print "    rotate 10"
                        patched = 1
                    }
                    target_block = 0
                    has_size = 0
                    has_rotate = 0
                }
                in_block = 0
            }

            print line
        }
        END {
            if (patched == 0) {
                exit 2
            }
        }
    ' "$rsyslog_rotate_file" > "$tmp_file"; then
        local awk_rc=$?
        rm -f "$tmp_file"
        if [ "$awk_rc" -eq 2 ]; then
            echo -e "${BLUE}ℹ️ Syslog cap policy already present; no changes needed.${NC}"
            return 0
        fi
        echo -e "${YELLOW}⚠️ Failed to parse $rsyslog_rotate_file; skipping syslog cap setup.${NC}"
        return 0
    fi

    if [ -w "$rsyslog_rotate_file" ]; then
        if mv "$tmp_file" "$rsyslog_rotate_file"; then
            echo -e "${GREEN}✅ Applied syslog logrotate cap: size 100M, rotate 10 (~1GB total).${NC}"
        else
            rm -f "$tmp_file"
            echo -e "${YELLOW}⚠️ Could not update $rsyslog_rotate_file; skipping syslog cap setup.${NC}"
            return 0
        fi
    elif command -v sudo >/dev/null 2>&1; then
        if sudo mv "$tmp_file" "$rsyslog_rotate_file"; then
            echo -e "${GREEN}✅ Applied syslog logrotate cap: size 100M, rotate 10 (~1GB total).${NC}"
        else
            rm -f "$tmp_file"
            echo -e "${YELLOW}⚠️ sudo failed updating $rsyslog_rotate_file; skipping syslog cap setup.${NC}"
            return 0
        fi
    else
        rm -f "$tmp_file"
        echo -e "${YELLOW}⚠️ Need root permissions to update $rsyslog_rotate_file; skipping syslog cap setup.${NC}"
        return 0
    fi

    # Apply rotation rules immediately if possible (non-fatal if this fails).
    if command -v logrotate >/dev/null 2>&1; then
        if [ -r "/etc/logrotate.conf" ]; then
            if [ "$(id -u)" -eq 0 ]; then
                logrotate /etc/logrotate.conf >/dev/null 2>&1 || true
            elif command -v sudo >/dev/null 2>&1; then
                sudo logrotate /etc/logrotate.conf >/dev/null 2>&1 || true
            fi
        fi
    fi
}
