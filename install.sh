#!/bin/bash
# VpsE Proxmox Lite — Bootstrap
# Installer Python, controleert of python3 beschikbaar is, en runt de echte installer.
set -e

# Minimal bootstrap: ensure python3 is available and run the installer
if ! command -v python3 &>/dev/null; then
    echo "Python3 not found — installing..."
    apt-get update -qq 2>/dev/null
    apt-get install -y -qq python3 2>&1 | tail -3
fi

PYTHON_SCRIPT_URL="https://raw.githubusercontent.com/VpsE-Scripts/Proxmox-Lite/master/install.py"

# Download and run
curl -sL "$PYTHON_SCRIPT_URL" | python3
