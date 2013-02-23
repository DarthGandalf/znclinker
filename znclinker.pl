#!/usr/bin/perl

use strict;
use warnings;
use POE qw(Component::IRC::State Component::IRC::Plugin::Connector);
use IO::File;
use Data::Munge;
use POE::Component::Server::HTTP;
use HTTP::Status;
use HTTP::Request::Params;
use JSON;

my $githubpass = `cat githubpass`;
chomp $githubpass;

my $freenode = POE::Component::IRC::State->spawn(
		nick => 'ZNC-Linker',
		server => 'irc.freenode.net',
		port => 7070,
		ircname => 'Bot',
		usessl => 1,
) or die "Can't load freenode IRC Component! $!";

my $efnet = POE::Component::IRC::State->spawn(
		nick => 'ZNCLinker',
		server => 'ssl.efnet.org',
		port => 9999,
		ircname => 'Bot',
		usessl => 1,
) or die "Can't load efnet IRC Component! $!";

POE::Session->create(
	package_states => [
		'main' => {
			_default => '_default',
			_start => 'fn_start',
			irc_001 => 'common_001',
			irc_public => 'common_public',
			irc_msg => 'msg',
		},
	],
);
POE::Session->create(
	package_states => [
		'main' => {
			_default => '_default',
			_start => 'ef_start',
			irc_001 => 'ef_001',
			irc_public => 'common_public',
			irc_msg => 'msg',
		},
	],
);

my @github_targets = (
	{
		network => $freenode,
		channel => '#znc',
	},
);

POE::Component::Server::HTTP->new(
	Port => 8000,
	ContentHandler => {
		'/' => sub {
			my ($request, $response) = @_;
			$response->code(404);
			return RC_OK;
		},
		$githubpass => sub {
			my ($request, $response) = @_;
			my $parser = HTTP::Request::Params->new({req => $request});
			my $payload = $parser->params->{payload};
			my $obj = decode_json $payload;

			my $branch = $obj->{ref};
			$branch =~ s#^refs/heads/##;
			
			for my $target (@github_targets) {
				my $network = $target->{network};
				my $channel = $target->{channel};

				$network->yield(privmsg=>$channel=>"[$branch] $obj->{compare}");
				my $i = 0;
				for my $commit (@{$obj->{commits}}) {
					if ($i++ > 5) {
						$network->yield(privmsg=>$channel=>"and more...");
						last;
					}
					my $id = $commit->{id};
					$id =~ s/^.{10}\K.*//;
					my $msg = $commit->{message};
					$msg =~ s/\n.*//;
					$msg =~ s/^.{100}\K.+/.../;
					$network->yield(privmsg=>$channel=>"$id: $commit->{author}{name} - $msg");
				}
			}

			$response->code(RC_OK);
			$response->content("Thanks");
			return RC_OK;
		},
	},
	Headers => { Server => 'Server' },
);



$poe_kernel->run();
exit 0;

sub fn_start {
	my $heap=$_[HEAP];
	$freenode->yield(register=>'all');
	$heap->{irc} = $freenode;
	$heap->{connector} = POE::Component::IRC::Plugin::Connector->new();
	$heap->{last} = {};
	$freenode->plugin_add('Connector'=>$heap->{connector});
	$freenode->yield(connect=>{});
}

sub ef_start {
	my $heap=$_[HEAP];
	$efnet->yield(register=>'all');
	$heap->{irc} = $efnet;
	$heap->{connector} = POE::Component::IRC::Plugin::Connector->new();
	$heap->{last} = {};
	$efnet->plugin_add('Connector'=>$heap->{connector});
	$efnet->yield(connect=>{});
}

sub common_001 {
	my $heap = $_[HEAP];
	print "Connected to ", $heap->{irc}->server_name(), "\n";
	$heap->{irc}->yield(join=>'#znc');
}

sub ef_001 {
	&common_001;
	my $heap = $_[HEAP];
	$heap->{irc}->yield(join=>'#znc-dev');
	$heap->{irc}->yield(join=>'#znc.de');
}

sub _default {
	my ($event, $args) = @_[ARG0 .. $#_];
	my @output = ("$event: ");
	for my $arg (@$args) {
		if (ref $arg eq 'ARRAY') {
			push(@output, '['.join(', ',@$arg).']');
		} else {
			push(@output, "'$arg'");
		}
	}
	print join ' ', @output, "\n";
	return 0;
}

sub common_public {
	my ($heap, $mask, $where, $what) = @_[HEAP, ARG0 .. ARG2];
	my ($nick) = $mask=~/^(.*)!/;
	my $chan = $where->[0];

	my $now = time;
	while (my ($key, $value) = each %{$heap->{last}}) {
		delete $heap->{last}{$key} if $value->{t} + 3600 < $now; # 1 hour
	}
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
		if (exists $heap->{last}{"$nick$chan"}) {
			my ($g, $i);
			$g = 'g' if $flags =~ /g/; $flags =~ s/g//g;
			$i = 'i' if $flags =~ /i/; $flags =~ s/i//g;
			if ($flags) {
				$heap->{irc}->yield(privmsg=>$chan=>"Supported regex flags: g, i. Flags “$flags” are unknown.");
				$regexError = 1;
			} else {
				my $str = $heap->{last}{"$nick$chan"}{msg};
				eval {
					my $re;
					if ($i) {
						$re = qr/$old/i;
					} else {
						$re = qr/$old/;
					}
					$what = Data::Munge::replace($str, $re, $new, $g);
					$heap->{irc}->yield(privmsg=>$chan=>"$nick meant: “$what”") if $what ne $str;
				};
				if ($@) {
					print $@;
					my $error = "$@";
					$error =~ s# at [/.\w]+ line \d+\.$##;
					$heap->{irc}->yield(privmsg=>$chan=>$error);
					$regexError = 1;
				}
			}
		}
	}
	$heap->{last}{"$nick$chan"} = {
		msg => $what,
		t => $now,
	} unless $regexError;

	if (my ($to) = $what=~/^!q\s+(\S+)/) {
		$heap->{irc}->yield(privmsg=>$chan=>"$to, we are not telepaths, please ask a concrete question and wait for an answer. Be sure that you checked http://wiki.znc.in/FAQ before. You may want to read http://catb.org/~esr/faqs/smart-questions.html");
	}
	if (my ($to) = $what=~/^!d\s+(\S+)/) {
		$heap->{irc}->yield(privmsg=>$chan=>"$to, when asking for help, be sure to provide as much details as possible. What did you try to do, how exactly did you try it (step by step), all error messages, znc version, etc. Without it, the only possible answer is '$to, you're doing something wrong.'");
	}
	if (my ($to) = $what=~/^!request(?:\s+(\S+))?/) {
		$to = $to // $nick;
		$heap->{irc}->yield(privmsg=>$chan=>"$to, ZNC is free software. Just install and use it. If you wanted free BNC account instead, go somewhere else. http://wiki.znc.in/Providers may be a good start.");
	}
	if ($what=~/^!win/) {
		$heap->{irc}->yield(privmsg=>$chan=>'ZNC for Windows: http://code.google.com/p/znc-msvc/wiki/WikiStart?tm=6');
	}
	if ($what eq '!help') {
		$heap->{irc}->yield(privmsg=>$chan=>'Need any help?');
	}
	my $count = 0;
	for(my ($w,$q,$foo)=($what,'','');($q,$foo,$w)=$w=~/.*?\[\[([^\]\|]*)(\|[^\]]*)?\]\](.*)/ and $count++<4;){
		$q=~s/ /_/g;
		$q=~s/\003\d{0,2}(,\d{0,2})?//g;#color
		$q=~s/[\x{2}\x{f}\x{16}\x{1f}]//g;
		$q=~s/[\r\n]//g;
		$heap->{irc}->yield(privmsg=>$chan=>"http://wiki.znc.in/$q");
	}
	if ($what=~/any(?:one|body)\s+(?:around|here)\s*(?:\?|$)/i) {
		$heap->{irc}->yield(privmsg=>$chan=>"Pointless question detected! $nick, we are not telepaths, please ask a concrete question and wait for an answer. Be sure that you checked http://wiki.znc.in/FAQ before. You may want to read http://catb.org/~esr/faqs/smart-questions.html Sorry if this is false alarm.");
	}
	if (my ($issue) = $what=~/#(\d+)/) {
		$heap->{irc}->yield(privmsg=>$chan=>"https://github.com/znc/znc/issues/$issue //TODO: go to github, get the title and show it here");
	}
}

sub msg {
}



