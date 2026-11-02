package WumpTest::MojoGate;
use v5.42;
use strict;
use warnings;
use WumpDemo::Jobs ();
use WumpDemo::Analysis ();

# Loaded only by the external live-test launcher, before INIT. Use the job
# service's analyzer injection point without adding a test mode to the demo.
sub analyze ($lines, $passes, $cancelled, $max_unique) {
	if (@$lines && $lines->[0] eq 'WUMP_LIVE_CANCEL_GATE') {
		# Keep doing real analysis until cancellation, so scheduling delays
		# cannot let the finite workload finish before the client signals.
		until ($cancelled->()) {
			WumpDemo::Analysis::analyze_chunk($lines, $passes, $cancelled, $max_unique);
			Wump::yield();
		}
		return {cancelled => 1};
	}
	return WumpDemo::Analysis::analyze_chunk($lines, $passes, $cancelled, $max_unique);
}

my $original = \&WumpDemo::Jobs::new;
{
	no warnings 'redefine';
	*WumpDemo::Jobs::new = sub ($class, %options) {
		$options{analyzer} //= \&analyze;
		return $original->($class, %options);
	};
}
1;
