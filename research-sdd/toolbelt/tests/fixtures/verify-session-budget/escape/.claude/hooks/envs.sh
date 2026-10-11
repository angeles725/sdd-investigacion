#!/usr/bin/env bash
cat >/dev/null; printf "%s" "${SSH_AUTH_SOCK:-}${SSH_AGENT_PID:-}${DBUS_SESSION_BUS_ADDRESS:-}"
