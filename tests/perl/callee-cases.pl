use v5.42;
use strict;
use warnings;
BEGIN {
	if (($ENV{WUMP_CALLEE_MODE} // 'plain') ne 'plain') {
		require Wump;
		Wump->import;
	}
}
use JSON::PP ();
my $active = ($ENV{WUMP_CALLEE_MODE} // 'plain') ne 'plain';
sub pause_here { Wump::yield() if $active }
sub named { $_[0] + 3 }
sub forwarded { &named }
sub tail { goto &named }
sub recursive {
	my ($depth, $value) = @_;
	pause_here();
	return $depth ? recursive($depth - 1, $value) : named($value);
}
sub context {
	my ($value, $log) = @_;
	my $kind = !defined(wantarray) ? 'void' : wantarray ? 'list' : 'scalar';
	pause_here();
	push @$log, $kind;
	return $kind eq 'list' ? ($value, $value + 1) : $value;
}
sub cell :lvalue { $_[0]->[0] }
{
	package CalleeBase;
	sub method { $_[1] * 2 }
	package CalleeChild;
	our @ISA = ('CalleeBase');
	sub method { $_[0]->SUPER::method($_[1]) + 1 }
	package CalleeCallable;
	use overload '&{}' => sub {
		my ($self) = @_;
		main::pause_here();
		die "overload failed\n" if $self->[1];
		return $self->[0];
	}, fallback => 1;
	package CalleeTie;
	sub TIESCALAR { bless [$_[1], 0, 0], $_[0] }
	sub FETCH {
		my ($self) = @_;
		$self->[1]++;
		my @grow = (1..8192);
		main::pause_here();
		die "fetch failed\n" if $self->[2];
		return $self->[0];
	}
	package CalleeAutoload;
	our $AUTOLOAD;
	sub deferred;
	sub AUTOLOAD { return $AUTOLOAD =~ /::deferred\z/ ? $_[0] + 11 : die 'unexpected autoload' }
}
sub exercise {
	my ($id) = @_;
	my %seen;
	$seen{named} = named($id);
	my $ref = \&named;
	$seen{reference} = $ref->($id);
	$seen{glob} = &{*named}($id);
	$seen{forwarded} = forwarded($id);
	$seen{tail} = tail($id);
	$seen{recursive} = recursive(3, $id);
	{
		no strict 'refs';
		my $symbol = 'main::named';
		$seen{symbolic} = $symbol->($id);
	}
	$seen{method} = (bless [], 'CalleeBase')->method($id);
	$seen{super} = (bless [], 'CalleeChild')->method($id);
	my $blessed = bless sub { $_[0] + 5 }, 'CalleeCode';
	$seen{blessed} = $blessed->($id);
	my $callable = bless [sub { $_[0] + 7 }, 0], 'CalleeCallable';
	$seen{overloaded} = $callable->($id);
	$callable->[1] = 1;
	eval { $callable->($id) };
	$seen{overload_error} = $@ eq "overload failed\n" ? 1 : 0;
	$callable->[1] = 0;
	$seen{overload_recovered} = $callable->($id);
	tie my $magic, 'CalleeTie', $ref;
	my $tie = tied $magic;
	$seen{magic} = $magic->($id);
	$tie->[0] = sub { $_[0] + 9 };
	$seen{magic_changed} = $magic->($id);
	$tie->[2] = 1;
	eval { $magic->($id) };
	$seen{magic_error} = $@ eq "fetch failed\n" ? 1 : 0;
	$tie->[2] = 0;
	$seen{magic_recovered} = $magic->($id);
	$seen{fetches} = $tie->[1];
	my @log;
	$seen{scalar} = scalar context($id, \@log);
	$seen{list} = [19, context($id, \@log), 23];
	(context($id, \@log), push @log, 'after');
	$seen{contexts} = \@log;
	my $box = [0];
	cell($box) = $id + 13;
	$seen{lvalue} = $box->[0];
	for my $bad (undef, [], {}, 17) {
		eval { $bad->() };
		push @{$seen{bad}}, $@ =~ /(?:undefined value|Not a CODE reference|as a subroutine ref)/ ? 1 : 0;
	}
	return [$id, \%seen];
}

# Autoload mutates interpreter caches; check it in the main act, before
# concurrent work. The common shared CVs below are first entered by workers.
die 'autoload result' unless CalleeAutoload::deferred(4) == 15;
my @results;
if (($ENV{WUMP_CALLEE_MODE} // 'plain') eq 'many') {
	my $out = Wump::chan(8);
	for my $id (1..8) {
		Wump::act(sub {
			my $result;
			$result = exercise($id) for 1..8;
			$out->send($result);
		});
	}
	push @results, scalar $out->recv for 1..8;
} else {
	push @results, exercise($_) for 1..8;
}
print JSON::PP->new->ascii->canonical->encode([sort {$a->[0] <=> $b->[0]} @results]), "\n";
