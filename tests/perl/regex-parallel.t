use v5.42;
use strict;
use warnings;
use Test::More;
use lib 'tests/perl/lib';
use WumpTest ();

for my $slots (1, 2, 4) {
	local $ENV{WUMPPROCS} = $slots;
	WumpTest::check_program(q{
		use Wump; use RootFixture;
		my $ascii = qr/\A(?<word>w\d+)-(\d+)\z/;
		my $unicode = qr/\A\x{100}-(\d+)-tail\z/;
		my $once = qr/\A(w\d+)-\d+\z/;
		sub keep_match ($pattern, $text) { return $text =~ /$pattern/o ? $1 : undef }
		sub variable_match ($text, $pattern) { return $text =~ $pattern ? $1 : undef }
		my $out = chan(4);
		for my $id (1..8) {
			act {
				RootFixture::executor_rendezvous();
				for (1..32) {
					my $text = "w$id-$id";
					die "precompiled /o lost its first pattern\n" unless keep_match($once, $text) eq "w$id";
					die "precompiled /o compiled a replacement\n" unless keep_match('not a compiled pattern', $text) eq "w$id";
					$text =~ $ascii or die "precompiled match failed\n";
					my $saved = $1;
					Wump::yield();
					die "precompiled captures crossed acts\n" unless $1 eq $saved && $+{word} eq "w$id";
					die "named capture existence changed\n" unless exists $+{word} && !exists $+{missing};
					die "named capture count changed\n" unless scalar(%+) == 1;
					my $wide = "\x{100}-$id-tail";
					$wide =~ /$unicode/ or die "precompiled Unicode match failed\n";
					die "precompiled Unicode capture changed\n" unless $1 eq "$id";
				}
				$out->send(1);
			};
		}
		die "missing precompiled workers\n" if grep { $out->recv != 1 } 1..8;
		if (Wump::execution_slots() > 1) {
			'w1-1' =~ $ascii or die "named capture setup failed\n";
			eval { $+{word} = 'changed' };
			die "named capture became writable: $@" unless index($@, 'read-only') >= 0;
			eval { delete $+{word} };
			die "named capture deletion succeeded: $@" unless index($@, 'read-only') >= 0;
			eval { %+ = () };
			die "named capture clear succeeded: $@" unless index($@, 'read-only') >= 0;
			my $dynamic = 'w';
			eval { 'w1' =~ /$dynamic/ };
			die "precompiled admission enabled compilation: $@" unless $@ =~ /runtime compilation is not supported/;
			my $with_code = qr/w(?{ 1 })/;
			eval { 'w' =~ $with_code };
			die "precompiled code blocks admitted: $@" unless $@ =~ /runtime compilation is not supported/;
			{ package RegexOverload;
				use overload 'qr' => sub { die "regex overload was called\n" }, fallback => 1;
			}
			my $object = bless {}, 'RegexOverload';
			eval { 'w' =~ $object };
			die "regex overload admitted: $@" unless $@ =~ /runtime compilation is not supported/;
		}
		{ package RegexSubject;
			sub TIESCALAR { bless {}, shift }
			sub FETCH { Wump::yield(); die "subject fetch failed\n" }
		}
		{ package RegexStackSubject;
			sub TIESCALAR { bless {}, shift }
			sub FETCH { my @padding = (1) x 20000; Wump::yield(); return 'w4-4' }
		}
		{ package RegexRecursiveSubject;
			sub TIESCALAR ($class, $pattern) { bless {pattern => $pattern}, $class }
			sub FETCH ($self) {
				die "nested subject match failed\n" unless main::variable_match('w3-3', $self->{pattern}) eq 'w3';
				return 'w4-4';
			}
		}
		tie my $recursive_subject, 'RegexRecursiveSubject', $ascii;
		for (1..16) {
			die "precompiled cache setup failed\n" unless variable_match('w2-2', $ascii) eq 'w2';
			die "precompiled match lost reentrant subject\n" unless variable_match($recursive_subject, $ascii) eq 'w4';
		}
		tie my $grown_subject, 'RegexStackSubject';
		die "precompiled match lost a grown subject stack\n" unless $grown_subject =~ $ascii && $1 eq 'w4';
		tie my $subject, 'RegexSubject';
		for (1..16) {
			eval { $subject =~ $ascii };
			die "precompiled match lost FETCH failure: $@" unless $@ =~ /subject fetch failed/;
		}
		die "precompiled match failed after exception\n" unless 'w9-9' =~ $ascii && $1 eq 'w9';
		print "precompiled regexes preserve private matches and the compiler gate\n";
	}, 0, qr/\Aprecompiled regexes preserve private matches and the compiler gate\n\z/,
		"precompiled patterns run on $slots slots with isolated captures and exception recovery");
}

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
