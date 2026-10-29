use v5.42;
use strict;
use warnings;
use Test::More;
use lib 'tests/perl/lib';
use WumpTest ();

for my $slots (1, 2, 4) {
	local $ENV{WUMPPROCS} = $slots;
	WumpTest::check_program(q{
		use Wump;
		use RootFixture;
		our $capture_alias;
		BEGIN { no strict 'refs'; *capture_alias = *{'main::1'} }
		'main-tail' =~ /(main)-(tail)/;
		my $out = chan(4);
		my $group = waitgroup;
		for my $id (1..8) {
			add $group;
			act {
				RootFixture::executor_rendezvous();
				my $word = "w$id";
				my $text = "pre[$word-$id]post";
				for (1..64) {
					$text =~ /\[(w\d+)-(\d+)\]/p or die "match failed\n";
					my $alias = \$1;
					yield;
					die "capture changed\n" unless $1 eq $word && $2 eq "$id"
						&& $$alias eq $word && $capture_alias eq $word
						&& $+ eq "$id" && $^N eq "$id";
					die "match text changed\n" unless $& eq "[$word-$id]"
						&& ${^MATCH} eq "[$word-$id]" && ${^PREMATCH} eq 'pre'
						&& ${^POSTMATCH} eq 'post';
					{
						local $1;
						'local' =~ /(local)/;
						yield;
						die "localized capture changed\n" unless $1 eq 'local';
					}
					die "capture scope was not restored\n" unless $1 eq $word;
					eval { $1 = 'changed' };
					die "capture became writable\n" unless index($@, 'read-only') >= 0 && $1 eq $word;
					{
						my $unicode = "\x{100}-$id-tail";
						$unicode =~ /\A\x{100}-(\d+)-tail\z/ or die "UTF-8 anchored match failed\n";
						die "UTF-8 anchored capture changed\n" unless $1 eq "$id";
						my $ascii = "$id-tail";
						$ascii =~ /(\d+)-tail$/ or die "tail match failed\n";
						die "tail capture changed\n" unless $1 eq "$id";
						my $letters = "A\x{100}\x{4e00}9";
						my @matches = $letters =~ /(\p{L})/g;
						die "Unicode class search changed\n" unless @matches == 3
							&& join('', @matches) eq "A\x{100}\x{4e00}";
						die "Unicode case fold changed\n" unless fc("Stra\x{df}e\x{100}\x{3a3}")
							eq "strasse\x{101}\x{3c3}";
					}
				}
				$out->send(1);
				done $group;
			};
		}
		for (1..8) { die "missing capture worker\n" unless $out->recv == 1 }
		await $group;
		die "main capture changed\n" unless $1 eq 'main' && $2 eq 'tail';
		print "private capture cells retained matches, aliases and local scopes\n";
	}, 0, qr/\Aprivate capture cells retained matches, aliases and local scopes\n\z/,
		"capture cache cells stay private with $slots execution slots");
}

for my $slots (2, 4) {
	local $ENV{WUMPPROCS} = $slots;
	WumpTest::check_program(q{
		use Wump; use RootFixture;
		package CleanupFrames {
			sub new ($class, $id) { bless {id => $id}, $class }
			sub verify ($got, $expected) { die "cleanup capture changed\n" unless $got eq "$expected" }
			sub DESTROY ($self) {
				my $text = "$self->{id}-tail";
				$text =~ /\A(\d+)-tail\z/ or die "cleanup match failed\n";
				verify($1, $self->{id});
			}
		}
		sub spawn_cleanup ($out, $id) {
			my $group = waitgroup;
			my $object = CleanupFrames->new($id);
			act {
				RootFixture::executor_rendezvous();
				die "captured cleanup roots lost\n" unless $group && $object->{id} == $id;
				$out->send(1);
			};
		}
		my $out = chan(8);
		spawn_cleanup($out, $_) for 1..64;
		die "missing cleanup acts\n" if grep { $out->recv != 1 } 1..64;
		print "completed acts retained private destructor frames and match state\n";
	}, 0, qr/\Acompleted acts retained private destructor frames and match state\n\z/,
		"concurrent act teardown drains destructor-created caches with $slots slots");
}

done_testing;
