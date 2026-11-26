# DNS Role

## Linux mechanism
systemd-resolved manages DNS on Linux.

## Windows concept
DNS is managed by the DNS Manager service.

## Where it breaks
Linux resolv.conf is declarative text, not stored in active binary log files.
