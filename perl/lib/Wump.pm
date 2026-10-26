package Wump;
use v5.42;
use strict;
use warnings;
no feature 'signatures';
use Exporter ();
our @ISA = qw(Exporter);
our @EXPORT = qw(run act chan yield sleep);
our $VERSION = '0.001';
die "Wump requires the private task-aware Perl build\n" unless defined &_run;

sub import {
	my $class = shift;
	$^H{'Wump/pocket'} = 1;
	$class->export_to_level(1, $class, @_);
}

sub unimport { delete $^H{'Wump/pocket'} }

sub run (&) { _run($_[0]); return }
sub act (&) { _act($_[0]); return }
sub chan (;$) { _chan(@_ ? $_[0] : 0) }
sub yield () { _yield(); return }
sub sleep ($) { _sleep($_[0]); return }

package Wump::Channel;
sub send { Wump::_send(@_); return }
sub recv { Wump::_recv(@_) }
sub close { Wump::_close(@_); return }

1;
