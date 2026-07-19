# B1 — Linux & CLI Refresher

These notes were prepared on our own training server (a RedHat 9 EC2 machine,
16 CPU / 123 GB RAM). Every output you see below is real output from that box —
nothing is made up. Log in and run the same commands yourself; you should see
very similar results.

```
ssh ec2-user@<server-ip>
```

Why this module first: in every incident you will ever handle, the first ten
minutes are spent on a Linux shell. Dashboards come later. If you can read
logs, check CPU/memory/disk, and follow a process tree quickly, you are
already ahead.

---

## 1. Logs on Linux

### 1.1 Two worlds: log files and the journal

Older services write plain text files under `/var/log`. Newer systems also
have the **systemd journal**, a binary database of everything systemd-managed.
Both exist on the same box, so you should know both.

```
$ ls -lh /var/log
-rw-r-----. 1 root   adm             7.2K Jul 19 02:30 cloud-init-output.log
-rw-r-----. 1 root   root            239K Jul 19 02:30 cloud-init.log
-rw-------  1 root   root             784 Jul 19 02:30 cron
-rw-r--r--. 1 root   root             82K Jul 19 02:31 dnf.librepo.log
-rw-r--r--. 1 root   root            235K Jul 19 02:32 dnf.log
drwx------. 2 root   root              23 Apr 11  2025 audit
```

Plain files you read with `less`, `tail`, `grep`. The journal you read with
`journalctl`.

### 1.2 journalctl — the six flags you will actually use

**By unit (`-u`)** — logs of one service only:

```
$ sudo journalctl -u sshd -n 6
Jul 19 02:34:26 ip-172-31-24-168 sshd[7177]: Accepted publickey for ec2-user from 49.205.249.13 port 24762 ssh2
Jul 19 02:34:26 ip-172-31-24-168 sshd[7177]: pam_unix(sshd:session): session opened for user ec2-user(uid=1001)
Jul 19 02:35:18 ip-172-31-24-168 sshd[24484]: Accepted publickey for ec2-user from 49.205.249.13 port 23981 ssh2
```

Note the `sudo`. As a normal user you only see your own messages — journalctl
even prints a hint about it. Get into the habit of `sudo journalctl`.

**Follow (`-f`)** — like `tail -f` but for the journal. Leave it running in a
second terminal while you reproduce a problem:

```
$ sudo journalctl -u sshd -f
```

**Time window (`--since`)** — the flag that saves you during an incident.
"When did it start?" is always the first question:

```
$ sudo journalctl --since "10 minutes ago"
$ sudo journalctl --since "2026-07-19 02:30" --until "2026-07-19 02:40"
Jul 19 02:30:49 ip-172-31-24-168 cloud-init[1563]: Cloud-init v. 24.4-7.el9 finished ... Up 25.74 seconds
Jul 19 02:30:49 ip-172-31-24-168 systemd[1]: Startup finished in 1.040s (kernel) + 7.182s (initrd) + 17.567s (userspace)
```

**Priority filter (`-p err`)** — only errors and worse. On a healthy box this
is short, which is exactly the point:

```
$ sudo journalctl -p err -n 6
Jul 19 02:32:10 ip-172-31-24-168 kernel: Warning: Deprecated Driver is detected: nft_compat ...
Jul 19 02:34:05 ip-172-31-24-168 kernel: Warning: Deprecated Driver is detected: ip_tables ...
```

(Kernel driver warnings — noisy but harmless. Real trouble looks like OOM
kills, segfaults, service failures.)

**JSON output (`-o json`)** — every journal line is actually a structured
record. Useful when you want to filter with `jq` (we do that in section 3):

```
$ sudo journalctl -u sshd -n 1 -o json | jq .
{
  "SYSLOG_IDENTIFIER": "sshd",
  "_SYSTEMD_UNIT": "sshd.service",
  "_PID": "24484",
  "MESSAGE": "pam_unix(sshd:session): session opened for user ec2-user(uid=1001)",
  "_HOSTNAME": "ip-172-31-24-168.ec2.internal",
  ...
}
```

**Kernel only (`-k`)** — same as `dmesg`, but with timestamps you can trust:

```
$ sudo journalctl -k -n 5
Jul 19 02:34:05 ip-172-31-24-168 kernel: Warning: Deprecated Driver is detected: ip_tables ...
Jul 19 02:34:05 ip-172-31-24-168 systemd-journald[94]: Received client request to flush runtime journal.
```

### 1.3 Priority levels 0–7

The `-p` flag uses syslog priorities. Worth memorising the bottom half:

| Nr | Name    | Application equivalent      |
|----|---------|-----------------------------|
| 0  | emerg   | system unusable             |
| 1  | alert   | act immediately             |
| 2  | crit    | FATAL                       |
| 3  | err     | ERROR                       |
| 4  | warning | WARN                        |
| 5  | notice  | (between WARN and INFO)     |
| 6  | info    | INFO                        |
| 7  | debug   | DEBUG                       |

`journalctl -p err` means "priority 3 **and worse**", i.e. err + crit + alert
+ emerg. Same idea as setting a log level in an application.

### 1.4 tail -f vs tail -F, and rotation

Log files get **rotated**: `app.log` is renamed to `app.log.1` and a fresh
`app.log` is created. This matters for tail:

- `tail -f app.log` follows the file **descriptor**. After rotation you are
  silently following the old renamed file. Output just stops. Very confusing
  at 3 am.
- `tail -F app.log` follows the file **name**. It notices the rotation and
  re-opens the new file. **Always use `-F` on log files.**

### 1.5 less +F — the underrated one

`less +F app.log` behaves like `tail -f`, but press `Ctrl-C` and you are in
normal `less`: scroll up, search with `/error`, jump to end with `G`, then
press `F` again to resume following. One tool for both reading and following.

---

## 2. System health checks

The four resources: CPU, memory, disk, network sockets. Check them in that
order and you will find most problems.

### 2.1 CPU — top and load average

```
$ top -b -n 1 | head -12
top - 02:34:27 up 4 min,  1 user,  load average: 0.89, 0.74, 0.34
Tasks: 347 total,   1 running, 346 sleeping,   0 stopped,   0 zombie
%Cpu(s): 10.6 us,  2.6 sy,  0.0 ni, 86.0 id,  0.0 wa,  0.8 hi,  0.0 si,  0.0 st
MiB Mem : 126916.0 total, 122007.4 free,   2514.3 used,   3467.0 buff/cache

    PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
   7586 ec2-user  20   0 1388036  65272  36280 S 146.7   0.1   0:00.22 kubectl
   4698 root      20   0 3523080  72792  35208 S   6.7   0.1   0:03.75 containerd
   5789 root      20   0 2947804  88668  51800 S   6.7   0.1   0:00.67 kubelet
```

How to read the `%Cpu(s)` line:

- `us` (user) — your applications doing work
- `sy` (system) — kernel work (networking, disk I/O handling)
- `id` — idle
- `wa` (iowait) — CPU sitting idle **waiting for disk**. High `wa` with a slow
  app usually means a storage problem, not a CPU problem.

**Load average vs core count.** The three numbers are 1-, 5- and 15-minute
averages of runnable processes. They only mean something relative to core
count:

```
$ nproc
16
$ uptime
 02:35:50 up 5 min,  1 user,  load average: 6.53, 2.52, 1.00
```

Load 6.5 on 16 cores = relaxed (that spike was us pulling 60 container
images). Load 6.5 on 2 cores = users are noticing. Rule of thumb: worry when
load stays above core count.

`htop` is the friendlier interactive version (`sudo dnf install htop`) — same
data, per-core bars, tree view with F5.

### 2.2 Memory — free -h and the "available" column

```
$ free -h
               total        used        free      shared  buff/cache   available
Mem:           123Gi       2.5Gi       119Gi        17Mi       3.4Gi       121Gi
Swap:          2.0Gi          0B       2.0Gi
```

The number that matters is **available**, not free. Linux uses spare RAM for
file cache (`buff/cache`) and gives it back instantly when programs need it.
A box with low "free" but high "available" is perfectly healthy. Beginners
alarm on "free" — don't.

**OOM killer.** When memory truly runs out, the kernel kills the biggest
offender and writes the story in the kernel log:

```
$ sudo dmesg -T | grep -i "out of memory"
(no OOM events on this box — that is a good thing)
```

When a process "randomly disappeared", check this first. On a healthy box the
grep comes back empty, like above.

### 2.3 Disk — space and inodes

```
$ df -h
Filesystem                    Size  Used Avail Use% Mounted on
/dev/mapper/RootVG-rootVol     15G  2.9G   13G  19% /
/dev/mapper/RootVG-varVol     100G  3.6G   97G   4% /var
/dev/mapper/RootVG-logVol     2.0G   92M  1.9G   5% /var/log
/dev/mapper/RootVG-homeVol    5.0G   75M  4.9G   2% /home
```

Note this box mounts `/var` separately and large — that's where Docker and
all container images live. (First lesson we learnt setting this course up:
the default image had a 2 GB `/var`, and 60 container images definitely do
not fit in 2 GB.)

A disk can also be "full" with plenty of space left — out of **inodes**
(one inode per file). Millions of tiny files will do that:

```
$ df -hi
Filesystem                   Inodes IUsed IFree IUse% Mounted on
/dev/mapper/RootVG-rootVol     7.5M   62K  7.5M    1% /
/dev/mapper/RootVG-varVol       50M   17K   50M    1% /var
```

If an app says "No space left on device" but `df -h` looks fine — run
`df -hi`.

### 2.4 Sockets — ss

Summary first:

```
$ ss -s
Total: 174
TCP:   235 (estab 9, closed 218, orphaned 1, timewait 53)
```

Then details — `-t` TCP, `-n` numeric, `-p` process (needs sudo):

```
$ sudo ss -tnp | head -5
State    Recv-Q Send-Q Local Address:Port   Peer Address:Port  Process
ESTAB    0      0      172.31.24.168:22    49.205.249.13:24948 users:(("sshd",pid=3705,fd=4))
ESTAB    0      48        172.18.0.1:55438    172.18.0.2:6443  users:(("docker-proxy",pid=4482,fd=16))
```

A one-liner you'll use constantly — count connections by state:

```
$ ss -tan | awk 'NR>1 {print $1}' | sort | uniq -c | sort -rn
     53 TIME-WAIT
      9 ESTAB
      7 LISTEN
      1 LAST-ACK
```

Two states worth understanding:

- **TIME_WAIT** — normal leftovers of connections *we* closed. The 53 above
  came from image downloads. They expire in ~60 s. Thousands of them means
  "something opens a new connection per request" (missing keep-alive), not
  "something is broken".
- **CLOSE_WAIT** — the other side hung up and **our application never called
  close()**. CLOSE_WAIT that grows and never shrinks is an application bug
  (usually a connection/file-descriptor leak). This one you escalate.

---

## 3. Text processing

You need exactly three tools to survive: `grep`, `awk`, `jq`.

### 3.1 grep with context

A matching line alone is often useless — you want what happened around it.
`-B` lines before, `-A` lines after, `-C` both:

```
$ sudo grep -B2 -A2 "session opened" /var/log/messages
Jan 13 18:37:26 ip-172-31-24-168 snoopy[55469]: ... /usr/sbin/unix_chkpwd ec2-user chkexpiry
Jan 13 18:37:26 ip-172-31-24-168 sudo[55468]: ec2-user : TTY=pts/0 ; PWD=/home/ec2-user ; USER=root ; COMMAND=/sbin/init 0
Jan 13 18:37:26 ip-172-31-24-168 sudo[55468]: pam_unix(sudo:session): session opened for user root(uid=0) by ec2-user(uid=1001)
Jan 13 18:37:26 ip-172-31-24-168 snoopy[55470]: ... init 0
```

(That is a real audit trail of someone running `sudo init 0` — the context
lines tell you who and from where.)

Other daily flags:

```
grep -v INFO app.log          # invert: everything EXCEPT INFO — quick error hunt
grep -i error app.log         # case-insensitive
zgrep "payment failed" app.log.3.gz   # search inside rotated .gz without extracting
```

### 3.2 awk — columns and counting

Think of awk as "grep for columns". `$1` is column one, `$NF` the last.

Top memory consumers, three columns only:

```
$ ps -eo pid,comm,%mem --sort=-%mem | head -5
    PID COMMAND         %MEM
   5685 kube-apiserver   0.2
   5613 kube-controller  0.0
   2944 dockerd          0.0
```

The counting pattern (print a column → sort → uniq -c) is the single most
useful shell idiom in operations. You saw it with `ss` above; the same shape
answers "which service logs the most", "which status code is most common",
"which IP hits us hardest". Learn the shape once, reuse forever:

```
<something> | awk '{print $<column>}' | sort | uniq -c | sort -rn | head
```

### 3.3 jq — the same idea for JSON

Modern services (including all 75 in our banking app) log JSON. `jq` filters
and aggregates it. Example on the journal: "which programs logged the most
info-level messages?"

```
$ sudo journalctl -n 200 -o json | jq -r 'select(.PRIORITY=="6") | .SYSLOG_IDENTIFIER' | sort | uniq -c | sort -rn
    168 snoopy
     13 sudo
      8 systemd
```

The three jq moves that cover 90% of use:

```
jq .                      # pretty-print
jq -r .MESSAGE            # extract one field (raw, no quotes)
jq 'select(.level=="ERROR")'   # filter records
```

You will use jq daily in this course against the banking services' logs.

---

## 4. Process investigation

### 4.1 Who started what — ps --forest and pstree

```
$ pstree -p 1 | head -10
systemd(1)-+-NetworkManager(1419)
           |-auditd(1148)
           |-chronyd(1192)
           |-containerd(2919)-+-{containerd}(2921)
           |-dockerd(2944)
           |-sshd(1496)
```

`ps -ef --forest` shows the same as a full listing. The parent-child view
answers "where did this process come from" instantly — e.g. every container
on this box hangs under `containerd`.

### 4.2 lsof — what is this process touching?

Two directions. **By port** — who owns port 22?

```
$ sudo lsof -i :22
COMMAND   PID     USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
sshd     1496     root    3u  IPv4  19431      0t0  TCP *:ssh (LISTEN)
sshd     3633 ec2-user    4u  IPv4  44338      0t0  TCP ip-172-31-24-168:ssh->49.205.249.13:25326 (ESTABLISHED)
```

**By process** — what files does dockerd have open?

```
$ sudo lsof -p $(pgrep -o dockerd) | head -6
COMMAND  PID USER   FD      TYPE  DEVICE  SIZE/OFF NAME
dockerd 2944 root  txt       REG   253,0 105396824 /usr/bin/dockerd
dockerd 2944 root  mem-W     REG   253,3     32768 /var/lib/docker/buildkit/cache.db
dockerd 2944 root  mem-W     REG   253,3     65536 /var/lib/docker/network/files/local-kv.db
```

Classic uses: "port already in use" (find the squatter), "file deleted but
disk not freed" (a process still holds it open — `lsof | grep deleted`).

### 4.3 strace — powerful, and dangerous in production

`strace -p <pid>` shows every system call a process makes. Superb for "the
process is stuck but logs nothing" — you can literally watch it hang on a
`connect()` or `read()`.

The warning that must come with it: strace **stops the process at every
syscall**. A busy service can slow down 10–100×. On production:

- never strace a healthy busy process casually
- prefer `-p <pid> -e trace=network -f` for a few seconds max, then detach
- if the service is behind a load balancer, take the instance out first

Mostly you will use it in test environments, which is where we'll use it too.

### 4.4 watch — observing change

Any diagnostic command becomes a live dashboard with `watch`. `-d` highlights
what changed between refreshes:

```
$ watch -d 'ss -s'
$ watch -d 'df -h /var'
```

"Is this number growing?" is half of troubleshooting. `watch -d` answers it.

---

## 5. Hands-on: timed triage drill

Ten minutes, on the training server. Write your answers down, then compare
with a neighbour. Everything needed is in this document.

1. How many CPU cores does the box have, and what is the current 5-minute
   load? Is that busy or idle?
2. How much memory is *available* (not free)?
3. Which filesystem has the least free space? Any inode problem anywhere?
4. How many TCP connections are in TIME-WAIT right now? Should you worry?
5. When did the last SSH login happen and from which IP? (journal, one command)
6. Any kernel errors since boot? (one command)
7. Which process owns port 22?
8. Using the counting idiom, which program wrote the most journal lines in
   the last 200 entries?

Target: all eight in under ten minutes. During the course we will repeat this
drill on a box where something is actually broken.
