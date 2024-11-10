## Server Admin

### Crontab thingy
# 30 23 *   *   *     /usr/sbin/rtcwake -m mem -u -t $(date +\%s -d "tomorrow 06:30am")
