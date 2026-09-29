# usage: perl client.pl host port path timeout  -> prints OK <status line> or FAIL <err>
use IO::Socket::INET; my ($h,$p,$path,$t)=@ARGV; $t||=3;
my $c = IO::Socket::INET->new(PeerAddr=>$h, PeerPort=>$p, Timeout=>$t) or do { print "FAIL connect $!\n"; exit 1 };
print $c "GET $path HTTP/1.0\r\nHost: $h\r\n\r\n"; my $r; eval { local $SIG{ALRM}=sub{die "timeout\n"}; alarm $t; $r=<$c>; alarm 0; };
if ($@ or !defined $r) { print "FAIL read ", ($@||"eof"), "\n"; exit 1 } $r =~ s/\r?\n//; print "OK $r\n";
