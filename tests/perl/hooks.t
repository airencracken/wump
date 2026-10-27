use v5.42;
use strict;
use warnings;
use Test::More;
use Scalar::Util 'refaddr';
use English '-no_match_vars';
use Wump;
use lib 'tests/perl/lib';
use WumpTest;
use XS::APItest ();

my @seen;
my $root = sub { push @seen, "root:$_[0]" };
local $SIG{__WARN__} = $root;
with_tasks {
	my $out = chan;
	for my $name ('one', 'two') {
		act {
			local $SIG{__WARN__} = sub { yield; push @seen, "$name:$_[0]" };
			yield;
			warn "$name\n";
			$out->send(1);
		};
	}
	$out->recv for 1..2;
};
is_deeply([sort @seen], ["one:one\n", "two:two\n"], 'warning callbacks and recursion guards are act-local across yields');
is(refaddr($SIG{__WARN__}), refaddr($root), 'task hooks leave the root hook intact');

@seen = ();
my @errors;
with_tasks {
	my $out = chan;
	for my $name ('one', 'two') {
		act {
			local $SIG{__DIE__} = sub { yield; push @seen, "$name:$_[0]" };
			eval { die "$name\n" };
			$out->send($@);
		};
	}
	push @errors, scalar $out->recv for 1..2;
};
is_deeply([sort @seen], ["one:one\n", "two:two\n"], 'die callbacks remain isolated while suspended');
is_deeply([sort @errors], ["one\n", "two\n"], 'die hooks preserve caught exceptions');

@seen = ();
with_tasks {
	my $go = chan;
	my $out = chan;
	{
		local $SIG{__WARN__} = sub { push @seen, "ordinary:$_[0]" };
		pocket $SIG{__WARN__} = sub { push @seen, "pocket:$_[0]" };
		act { $go->recv; warn "child\n"; $out->send(1) };
		warn "parent\n";
	}
	$go->send(1);
	$out->recv;
};
is_deeply(\@seen, ["pocket:parent\n", "ordinary:child\n"], 'spawn inherits ordinary hooks through pocket after parent scope exit');

@seen = ();
with_tasks {
	local $SIG{__WARN__} = sub { push @seen, "outer:$_[0]" };
	eval {
		local $SIG{__WARN__} = sub { push @seen, "inner:$_[0]" };
		yield;
		warn "nested\n";
		die "unwind\n";
	};
	warn "restored\n";
};
is_deeply(\@seen, ["inner:nested\n", "outer:restored\n"], 'exception unwinding restores the enclosing hook cache');

my ($escaped, $base);
$base = \$SIG{__WARN__};
@seen = ();
with_tasks {
	local $SIG{__WARN__} = sub { push @seen, "local:$_[0]" };
	$escaped = \$SIG{__WARN__};
	$$base = sub { push @seen, "newroot:$_[0]" };
	warn "active\n";
};
$$escaped = sub { push @seen, "escaped:$_[0]" };
warn "outside\n";
is_deeply(\@seen, ["local:active\n", "newroot:outside\n"], 'base and escaped hook references preserve independent cache identities');
$SIG{__WARN__} = $root;

@seen = ();
with_tasks {
	local $SIG{__WARN__};
	$SIG{__WARN__} = sub {
		$SIG{__WARN__} = sub { push @seen, "replacement:$_[0]" };
		yield;
		push @seen, "selected:$_[0]";
	};
	warn "first\n";
	warn "second\n";
};
is_deeply(\@seen, ["selected:first\n", "replacement:second\n"], 'a selected hook survives self replacement and suspension');

my @warnings;
local $^W = 0;
with_tasks {
	my $out = chan;
	for my $flag (0, 1) {
		act {
			local $^W = $flag;
			yield;
			$out->send([$flag, $^W]);
		};
	}
	push @warnings, scalar $out->recv for 1..2;
};
is_deeply([sort {$a->[0] <=> $b->[0]} @warnings], [[0, 0], [1, 1]], '$^W remains isolated across yields');
is($^W, 0, 'localized warning flags leave root warning state intact');

my ($parent, $child, $saved_flags);
with_tasks {
	my $go = chan;
	my $out = chan;
	{
		local $WARNING = 1;
		pocket $^W = 0;
		$saved_flags = \$^W;
		act { $go->recv; $out->send($^W) };
		$parent = $^W;
	}
	$go->send(1);
	$child = $out->recv;
};
is_deeply([$parent, $child], [0, 1], 'English warning aliases and spawn snapshots respect pocket');
$$saved_flags = 1;
is_deeply([$$saved_flags, $^W], [1, 0], 'escaped warning flags keep private storage');

my @emitted;
with_tasks {
	local $SIG{__WARN__} = sub { push @emitted, $_[0] };
	no warnings;
	{
		local $^W = 1;
		yield;
		my $text = 'oops';
		my $number = $text + 0;
	}
};
is(scalar @emitted, 0, 'explicit lexical no warnings still overrides $^W');

my $unsupported;
with_tasks { eval { local $SIG{INT} = sub {} }; $unsupported = $@ };
like($unsupported, qr/magic variable localization/, 'process signal handlers remain outside act-local hooks');

@seen = ();
my @captures;
with_tasks {
	local $SIG{__WARN__} = sub {
		push @captures, $1;
		'handler' =~ /(handler)/;
		yield;
		push @captures, $1;
	};
	'caller' =~ /(caller)/;
	warn "match\n";
	push @captures, $1;
};
is_deeply(\@captures, [qw(caller handler caller)], 'warning callbacks preserve caller captures while using their own matches');

my @deletion;
with_tasks {
	local $SIG{__WARN__} = sub { push @seen, "local:$_[0]" };
	my $old = delete $SIG{__WARN__};
	push @deletion, exists $SIG{__WARN__};
	$SIG{__WARN__} = $old;
	push @deletion, exists $SIG{__WARN__};
	warn "resurrected\n";
};
is_deeply(\@deletion, ['', 1], 'deleting and restoring a private hook keeps exists state coherent');
is_deeply(\@seen, ["local:resurrected\n"], 'resurrected hook cell updates its native callback cache');
is(refaddr($SIG{__WARN__}), refaddr($root), 'hook deletion leaves the root handler intact');

my @numeric;
{
	BEGIN { ${^WARNING_BITS} = undef }
	sub legacy_numeric ($text) { return $text + 0 }
}
with_tasks {
	my $out = chan;
	for my $flag (0, 1) {
		act {
			local $^W = $flag;
			local $SIG{__WARN__} = sub { push @numeric, [$flag, $_[0]] };
			yield;
			legacy_numeric('invalid');
			$out->send(1);
		};
	}
	$out->recv for 1..2;
};
is(scalar @numeric, 1, 'runtime warning generation consults the act-local $^W cache');
is($numeric[0][0], 1, 'only the act with warnings enabled emits the warning');
like($numeric[0][1], qr/isn't numeric/, 'native numeric warning text is preserved');

my ($encoded, $load_error, $during_load);
my @load_seen;
with_tasks {
	eval {
		my $out = chan;
		local $SIG{__WARN__} = sub { push @load_seen, $_[0] };
		local @INC = (sub {
			my ($self, $file) = @_;
			if ($file eq 'PerlIO/encoding.pm') {
				$during_load++;
				warn "temporary loader hook\n";
				act { warn "child during loading\n"; $out->send(1) };
				yield;
				$out->recv;
			}
			return;
		}, @INC);
		my $text = 'hello';
		open my $fh, '<:encoding(UTF-8)', \$text or die "encoding input: $!";
		yield;
		$encoded = <$fh>;
		close $fh;
		warn "after loading\n";
	};
	$load_error = $@;
};
is($load_error, '', 'encoding layers can be loaded inside an act with private hooks');
is($encoded, 'hello', 'act-local loading leaves the encoding usable');
is($during_load, 1, 'encoding initialization exercises a yielding module-search hook');
is_deeply(\@load_seen, ["child during loading\n", "after loading\n"],
	'PerlIO temporary hooks suppress loader warnings while children inherit the ordinary hook');

@seen = ();
with_tasks {
	local $SIG{__WARN__} = sub { push @seen, "old:$_[0]" };
	XS::APItest::Hash::store(\%SIG, '__WARN__', sub { push @seen, "native:$_[0]" });
	yield;
	warn "stored\n";
	XS::APItest::Hash::store_ent(\%SIG, '__WARN__', sub { push @seen, "entry:$_[0]" });
	warn "stored again\n";
};
is_deeply(\@seen, ["native:stored\n", "entry:stored again\n"], 'native hash stores keep private hook magic on the replacement SV');
is(refaddr($SIG{__WARN__}), refaddr($root), 'native hash stores cannot replace the global hook cache');

for my $case (['-W', '1,1,1'], ['-X', '0,0,0'], ['-w', '1,0,0']) {
	my $script = q{
		use Wump;
		my @flags = ($^W);
		{
			local $^W = 0;
			push @flags, $^W;
			my $out = chan;
			act { $out->send($^W) };
			push @flags, scalar $out->recv;
		};
		print join(',', @flags);
	};
	open my $child, '-|', $^X, (map { "-I$_" } grep { !ref } @INC), $case->[0], '-e', $script
		or die "warning-mode child: $!";
	local $/;
	my $text = <$child>;
	my $closed = close $child;
	is_deeply([$closed, $text], [1, $case->[1]], "$case->[0] command-line warning mode survives local and spawn");
}

check_program(q{
	use Wump;
	our $signal_fetches = 0;
	{
	package TiedSignalHooks;
	sub TIEHASH { bless {}, $_[0] }
	sub FETCH { $signal_fetches++; return }
	sub STORE { return }
	sub FIRSTKEY { return }
	sub NEXTKEY { return }
	sub CLEAR { return }
	}
	BEGIN { tie %SIG, 'TiedSignalHooks' }
	eval { local $SIG{__WARN__} = sub {} };
	print $@;
	print "fetches:$signal_fetches\n";
	untie %SIG;
}, 0, qr/magic variable localization[^\n]*\nfetches:0\n\z/,
	'a tied SIG hash cannot bypass validation or invoke FETCH');

done_testing;
