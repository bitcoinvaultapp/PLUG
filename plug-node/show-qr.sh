#!/bin/bash
# Display your node's .onion address as a QR code in the terminal
# Requires: qrencode (apt install qrencode)

ONION=$(docker logs plug-tor 2>&1 | grep -oP '[a-z0-9]{56}\.onion:[0-9]+' | tail -1)

if [ -z "$ONION" ]; then
    echo "Error: Could not find .onion address. Is plug-tor running?"
    echo "Try: docker logs plug-tor"
    exit 1
fi

echo ""
echo "Your node address:"
echo "$ONION"
echo ""

if command -v qrencode &> /dev/null; then
    qrencode -t ANSIUTF8 "$ONION"
else
    echo "Install qrencode to display QR code:"
    echo "  sudo apt install qrencode"
    echo ""
    echo "Or copy the address above and paste it in PLUG app."
fi
