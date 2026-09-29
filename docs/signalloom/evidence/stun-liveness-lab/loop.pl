# usage: perl loop.pl host port seconds -> "epoch OK|FAIL detail latency_ms" per attempt; 0.25s spacing, 1s connect+read timeout
# v2: read timeout via IO::Select (v1 used alarm+readline and misreported read timeouts as OK)
use IO::Socket::INET; use IO::Select; use Time::HiRes qw(time sleep); $|=1; my ($h,$p,$secs)=@ARGV; my $end=time+$secs;
while (time < $end) { my $t=time; my $res;
  my $c = IO::Socket::INET->new(PeerAddr=>$h, PeerPort=>$p, Timeout=>1);
  if (!$c) { $res="FAIL connect" } else { print $c "GET /healthz HTTP/1.0\r\n\r\n";
    my $sel = IO::Select->new($c); my $buf='';
    if ($sel->can_read(1) && sysread($c,$buf,64) && $buf =~ /^HTTP/) { $res="OK" } else { $res="FAIL read-timeout" } close $c }
  printf "%.3f %s %d\n", $t, $res, (time-$t)*1000; sleep 0.25 }
