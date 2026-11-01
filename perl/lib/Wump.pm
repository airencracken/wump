package Wump;
use v5.42;
use strict;
use warnings;
no feature 'signatures';
use Exporter ();
our @ISA = qw(Exporter);
our @EXPORT = qw(act chan yield sleep sel waitgroup add done await);
our $VERSION = '0.001';
die "Wump requires the private task-aware Perl build\n" unless defined &_enable;

sub import {
	my $class = shift;
	_enable();
	$^H{'Wump/pocket'} = 1;
	$^H{'Wump/keywords'} = 1;
	$class->export_to_level(1, $class, @_);
}

sub unimport { delete @^H{'Wump/pocket', 'Wump/keywords'} }

sub act (&) { _act($_[0]); return }
sub waitgroup () { _waitgroup('Wump::WaitGroup') }
sub add ($;$) { _wg_add(@_ == 1 ? ($_[0], 1) : @_); return }
sub done ($) { _wg_done(@_); return }
sub await ($) { _wg_wait(@_); return }
sub chan (;$) { _chan(@_ ? $_[0] : 0) }
sub yield () { _yield(); return }
sub sleep ($) { _sleep($_[0]); return }
sub sel ($;$) { _sel(@_ == 1 ? ($_[0], -1) : @_) }

# Registration is setup only. Older private controls retain their supported
# call paths; the native timing probe verifies the compiled operation itself.
if (defined &_intrinsic) {
	_intrinsic(\&act, 'act');
	_intrinsic(\&chan, 'chan');
	_intrinsic(\&sleep, 'sleep');
	_intrinsic(\&sel, 'sel') if defined &_sel;
} elsif (defined &_act_intrinsic) {
	_act_intrinsic(\&act);
}

package Wump::WaitGroup;
sub new { Wump::_waitgroup(@_) }
sub add { &Wump::add(@_); return }
sub done { &Wump::done(@_); return }
sub wait { &Wump::await(@_); return }
sub DESTROY { Wump::_wg_destroy(@_); return }

package Wump::Channel;
sub send { Wump::_send(@_); return }
sub recv { Wump::_recv(@_) }
sub close { Wump::_close(@_); return }
# Keep the original named wrappers byte-for-byte for older matched controls.
if (defined &Wump::_channel_send) {
	no warnings 'redefine';
	*send = \&Wump::_channel_send;
	*recv = \&Wump::_channel_recv;
	*close = \&Wump::_channel_close;
}

1;
