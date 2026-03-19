#!/bin/bash
# acms-portal.sh
# Starts the captive-portal HTTP server using socat.
# Each TCP connection spawns acms-http-handler.sh as a subprocess.
exec socat TCP-LISTEN:80,fork,reuseaddr \
    EXEC:"/bin/bash /usr/local/bin/acms-http-handler.sh"
