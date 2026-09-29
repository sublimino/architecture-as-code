use IO::Socket::INET; $|=1;
my $s = IO::Socket::INET->new(LocalPort=>($ENV{PORT}||8081), Listen=>16, ReuseAddr=>1) or die "listen: $!";
while (my $c = $s->accept) { my $l=<$c>; while (my $h=<$c>) { last if $h =~ /^\r?\n$/ } print $c "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 3\r\n\r\nok\n"; close $c; }
