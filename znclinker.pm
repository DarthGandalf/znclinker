use strict;
use warnings;
use diagnostics;

use Data::Munge;
use HTTP::Response;
use JSON;

package znclinker;
use base 'ZNC::Module';

sub description {
	"ZNC-Linker bot"
}

sub module_types {
	$ZNC::CModInfo::UserModule
}

sub put_chan {
	my ($self, $chan, $msg) = @_;
	$self->PutIRC("PRIVMSG $chan :$msg");
}

sub OnChanMsg {
	my ($self, $nick, $chan, $what) = @_;

	$nick = $nick->GetNick;
	$chan = $chan->GetName;

	return $ZNC::CONTINUE if $nick eq 'travis-ci';

	my $now = time;
	while (my ($key, $value) = each %{$self->{last}}) {
		delete $self->{last}{$key} if $value->{t} + 3600 < $now; # 1 hour
	}
	my $thiskey = "$nick $chan ".$self->GetNetwork->GetName;
	my $regexError;
	if (my ($sep, $old, $new, $flags) = $what =~ /^
			s
			([\/`~!#%&]) # separator
			((?:(?!\1).|\\\1)+)
			\1
			((?:(?!\1).|\\\1)*)
			(?:
				\1
				(\w*) # flags
			)?
			$/x) {
		if (exists $self->{last}{$thiskey}) {
			my ($g, $i);
			$g = 'g' if $flags =~ /g/; $flags =~ s/g//g;
			$i = 'i' if $flags =~ /i/; $flags =~ s/i//g;
			if ($flags) {
				$self->put_chan($chan, "Supported regex flags: g, i. Flags “$flags” are unknown.");
				$regexError = 1;
			} else {
				my $str = $self->{last}{$thiskey}{msg};
				eval {
					my $re;
					if ($i) {
						$re = qr/$old/i;
					} else {
						$re = qr/$old/;
					}
					$what = Data::Munge::replace($str, $re, $new, $g);
					$self->put_chan($chan, "$nick meant: “$what”") if $what ne $str;
				};
				if ($@) {
					print $@;
					my $error = "$@";
					$error =~ s# at [/.\w]+ line \d+\.$##;
					$self->put_chan($chan, $error);
					$regexError = 1;
				}
			}
		}
	}
	$self->{last}{$thiskey} = {
		msg => $what,
		t => $now,
	} unless $regexError;

	if (my ($to) = $what=~/^!q\s+(\S+)/) {
		$self->put_chan($chan=>"$to, we are not telepaths, please ask a concrete question and wait for an answer. Be sure that you checked http://wiki.znc.in/FAQ before. You may want to read http://catb.org/~esr/faqs/smart-questions.html");
	}
	if (my ($to) = $what=~/^!d\s+(\S+)/) {
		$self->put_chan($chan=>"$to, when asking for help, be sure to provide as much details as possible. What did you try to do, how exactly did you try it (step by step), all error messages, znc version, etc. Without it, the only possible answer is '$to, you're doing something wrong.'");
	}
	if (my ($to) = $what=~/^!request(?:\s+(\S+))?/) {
		$to = $to // $nick;
		$self->put_chan($chan=>"$to, ZNC is free software. Just install and use it. If you wanted free BNC account instead, go somewhere else. http://wiki.znc.in/Providers may be a good start.");
	}
	if ($what=~/^!win/) {
		$self->put_chan($chan=>'ZNC for Windows: http://code.google.com/p/znc-msvc/wiki/WikiStart?tm=6');
	}
	if ($what eq '!help') {
		$self->put_chan($chan=>'Need any help?');
	}
	my $count = 0;
	for(my ($w,$q,$foo)=($what,'','');($q,$foo,$w)=$w=~/.*?\[\[([^\]\|]*)(\|[^\]]*)?\]\](.*)/ and $count++<4;){
		$q=~s/ /_/g;
		$q=~s/\003\d{0,2}(,\d{0,2})?//g;#color
		$q=~s/[\x{2}\x{f}\x{16}\x{1f}]//g;
		$q=~s/[\r\n]//g;
		$self->put_chan($chan=>"http://wiki.znc.in/$q");
	}
	if ($what=~/any(?:one|body)\s+(?:around|here)\s*(?:\?|$)/i) {
		$self->put_chan($chan=>"Pointless question detected! $nick, we are not telepaths, please ask a concrete question and wait for an answer. Be sure that you checked http://wiki.znc.in/FAQ before. You may want to read http://catb.org/~esr/faqs/smart-questions.html Sorry if this is false alarm.");
	}
	if (my ($issue) = $what=~m@(?:#|https://github.com/znc/znc/(?:issues|pull)/)(\d+)@) {
		$self->CreateSocket('znclinker::github', $issue, $self->GetNetwork, $chan);
	}

	return $ZNC::CONTINUE;
}

sub OnUserMsg {
	my ($self, $tgt, $msg) = @_;
	my @targets = (
		{
			network => 'freenode',
			chan => '#znc',
		},
		{
			network => 'efnet',
			chan => '#znc',
		}
	);
	for my $target (@targets) {
		$self->GetUser->FindNetwork($target->{network})->PutIRC("PRIVMSG $target->{chan} :$msg");
	}
	return $ZNC::HALT;
}

package znclinker::github;
use base 'ZNC::Socket';

sub Init {
	my $self = shift;
	$self->{issue} = shift;
	$self->{network} = shift;
	$self->{chan} = shift;
	$self->{response} = '';
	$self->DisableReadLine;
	$self->Connect('api.github.com', 443, ssl=>1);
	$self->Write("GET https://api.github.com/repos/znc/znc/issues/$self->{issue} HTTP/1.0\r\n");
	$self->Write("User-Agent: https://github.com/DarthGandalf/znclinker\r\n");
	$self->Write("Host: api.github.com\r\n");
	$self->Write("\r\n");
}

sub OnReadData {
	my $self = shift;
	my $data = shift;
	print "new data |$data|\n";
	$self->{response} .= $data;
}

sub OnDisconnected {
	my $self = shift;
	my $response = HTTP::Response->parse($self->{response});
	if ($response->is_success) {
		my $data = JSON->new->utf8->decode($response->decoded_content);
		$self->{network}->PutIRC("PRIVMSG $self->{chan} :$data->{html_url} “$data->{title}” ($data->{state})");
	} else {
		my $error = $response->status_line;
		$self->{network}->PutIRC("PRIVMSG $self->{chan} :https://github.com/znc/znc/issues/$self->{issue} – $error");
	}
}

sub OnTimeout {
	my $self = shift;
	$self->{network}->PutIRC("PRIVMSG $self->{chan} :github timeout");
}

sub OnConnectionRefused {
	my $self = shift;
	$self->{network}->PutIRC("PRIVMSG $self->{chan} :github connection refused");
}

1;
