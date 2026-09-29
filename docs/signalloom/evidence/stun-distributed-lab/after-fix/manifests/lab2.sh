# sourceable helpers for the W6 distributed stun lab (kind cluster osramp-dist only)
K="kubectl --context kind-osramp-dist -n fe-signalloom-agents"
R=/tmp/w6-lab/raw2
ts() { date +%T.%N; }
podjson() { $K get pod -l app=kusari-agent -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.uid} {.spec.nodeName} {.status.phase} {.metadata.deletionTimestamp}{"\n"}{end}'; }
# slice <node> <uid> -> absolute pod slice path inside the node container
slice() { docker exec "$1" sh -c "find /sys/fs/cgroup/kubelet.slice -maxdepth 3 -type d -name '*pod$(echo "$2" | tr - _).slice' | head -1"; }
# poll <node> <uid> <outfile> : background in-node loop, logs each change of the pod slice's frozen flag (or 'absent')
poll() { docker exec -d "$1" sh -c "u=$(echo "$2" | tr - _); last=x; while true; do p=\$(find /sys/fs/cgroup/kubelet.slice -maxdepth 3 -type d -name \"*pod\${u}.slice\" 2>/dev/null | head -1); if [ -n \"\$p\" ]; then v=\$(grep frozen \$p/cgroup.events 2>/dev/null | cut -d' ' -f2); else v=absent; fi; if [ \"\$v\" != \"\$last\" ]; then echo \"\$(date +%T.%N) $1 frozen=\$v\" >> /tmp/$3; last=\$v; fi; sleep 0.05; done"; }
# vethof <node> <uid> -> host veth name, via the pod's eth0 peer index read with `ip` (rtnetlink) in the pod netns
vethof() { docker exec "$1" sh -c "u=$(echo "$2" | tr - _); p=\$(find /sys/fs/cgroup/kubelet.slice -maxdepth 3 -type d -name \"*pod\${u}.slice\" | head -1); pid=\$(cat \$p/*/cgroup.procs | head -1); idx=\$(nsenter -t \$pid -n ip -o link show eth0 | sed -E 's/.*eth0@if([0-9]+).*/\1/'); ip -o link | awk -F': ' -v i=\$idx '\$1==i{split(\$2,a,\"@\"); print a[1]}'"; }
# tcshow <node> <veth> -> sentinel filters on ingress and egress
tcshow() { docker exec "$1" sh -c "echo \"[ingress]\"; tc filter show dev $2 ingress; echo \"[egress]\"; tc filter show dev $2 egress"; }
