package Wump::BenchMatrix;
use v5.42;
use strict;
use warnings;
use Exporter 'import';
use JSON::PP ();
our @EXPORT_OK = qw(operations variants primitive expected validate_result validate_metadata validate_capture load_capture median summarize report compare);

sub operations () { return qw(arithmetic calls arrays hashes strings regex utf8 json yield spawn channel) }
sub variants () { return qw(stock wump-unused wump-1 wump-2 wump-4 go-1 go-2 go-4) }
sub primitive ($op) { return $op =~ /\A(?:yield|spawn|channel)\z/ ? 1 : 0 }
sub slots ($variant) { return $variant =~ /-(1|2|4)\z/ ? 0 + $1 : 0 }
sub integer ($v, $min, $max) { return defined($v) && !ref($v) && $v =~ /\A\d+\z/ && $v >= $min && $v <= $max }
sub positive ($v) { return defined($v) && !ref($v) && $v =~ /\A\d+(?:\.\d+)?(?:e[+-]?\d+)?\z/i && $v > 0 && $v < 1e100 }
sub string ($v) { return defined($v) && !ref($v) && length($v) }
sub sha ($v) { return string($v) && $v =~ /\A[0-9a-f]{64}\z/ }
sub median (@values) {
	my @v = sort {$a <=> $b} @values;
	@v or die "no samples\n";
	return @v % 2 ? $v[int(@v / 2)] : ($v[@v / 2 - 1] + $v[@v / 2]) / 2;
}

sub expected ($op, $n, $id) {
	return $n if $op eq 'yield';
	return $n * ($n + 1) / 2 if primitive($op);
	# Evaluate one 97-value period, independently of the timed loops.
	my ($period, $tail) = (0, 0);
	for my $i (0..96) {
		my $x = ($i + $id) % 97;
		my $weight = $op eq 'arithmetic' ? $x
			: $op eq 'calls' ? $x + 1
			: $op eq 'arrays' ? 4 * $x + 6
			: $op eq 'hashes' ? 2 * $x + 1
			: $op eq 'strings' ? 11 + ($x >= 10 ? 1 : 0)
			: $op eq 'regex' ? $x + 4
			: $op eq 'utf8' ? 458 + $x % 26
			: $op eq 'json' ? 18 + ($x >= 10 ? 1 : 0)
			: die "unknown operation $op\n";
		$period += $weight;
		$tail += $weight if $i < $n % 97;
	}
	return int($n / 97) * $period + $tail;
}

sub validate_result ($r, $op, $variant, $n, $jobs) {
	ref($r) eq 'HASH' or die "invalid worker result\n";
	for my $pair ([operation => $op], [iterations => $n], [jobs => $jobs], [slots => slots($variant)]) {
		my ($key, $value) = @$pair;
		defined($r->{$key}) && !ref($r->{$key}) && $r->{$key} eq "$value" or die "worker identity mismatch: $key\n";
	}
	if (($r->{status} // '') eq 'unsupported') {
		my $plain = primitive($op) && ($variant eq 'stock' || $variant eq 'wump-unused')
			&& ($r->{reason} // '') eq 'no coroutine runtime in this mode';
		my $json = $op eq 'json' && $variant =~ /\Awump-[24]\z/
			&& ($r->{reason} // '') eq 'parallel XS admission: utf8::encode'
			&& string($r->{detail}) && $r->{detail} =~ /XS function has not declared parallel safety: utf8::encode\b/;
		$plain || $json or die "unexpected unsupported result\n";
		!exists($r->{wall_seconds}) && !exists($r->{results}) && !exists($r->{units}) or die "unsupported result contains measurements\n";
		return;
	}
	($r->{status} // '') eq 'ok' && positive($r->{wall_seconds}) or die "invalid worker timing or status\n";
	!(primitive($op) && slots($variant) == 0) or die "plain mode claims coroutine execution\n";
	integer($r->{units}, 1, 128000000) && $r->{units} == $n * (primitive($op) ? 1 : $jobs) or die "invalid operation count\n";
	my $count = primitive($op) ? 1 : $jobs;
	ref($r->{results}) eq 'ARRAY' && @{$r->{results}} == $count or die "incomplete job results\n";
	my %seen;
	for my $result (@{$r->{results}}) {
		ref($result) eq 'ARRAY' && @$result == ($op eq 'json' ? 3 : 2) or die "invalid job result\n";
		my ($id, $checksum) = @$result;
		integer($id, 1, $count) && !$seen{$id}++ or die "duplicate or invalid job identity\n";
		integer($checksum, 0, 1e15) && $checksum == expected($op, $n, $id) or die "incorrect job checksum\n";
		if ($op eq 'json') {
			my $last = eval { JSON::PP::decode_json($result->[2]) };
			ref($last) eq 'HASH' && keys(%$last) == 2 && ($last->{s} // '') eq 'word'
				&& integer($last->{n}, 0, 96) && $last->{n} == ($n - 1 + $id) % 97 or die "incorrect JSON payload\n";
		}
	}
}

sub validate_metadata ($capture) {
	ref($capture) eq 'HASH' && ($capture->{schema} // '') eq 'wump-operation-matrix-v1'
		&& JSON::PP::is_bool($capture->{complete}) && $capture->{complete} or die "incomplete or unknown matrix schema\n";
	my $params = $capture->{parameters};
	ref($params) eq 'HASH' && integer($params->{iterations}, 1, 2000000)
		&& integer($params->{jobs}, 1, 64) && integer($params->{runs}, 1, 20) or die "invalid matrix parameters\n";
	my $source = $capture->{source};
	ref($source) eq 'HASH' && string($source->{revision}) && $source->{revision} =~ /\A[0-9a-f]{40,64}\z/
		&& JSON::PP::is_bool($source->{dirty}) && sha($source->{fixture_sha256}) or die "invalid source identity\n";
	ref($capture->{machine}) eq 'HASH' && ref($capture->{binaries}) eq 'HASH' or die "invalid machine or binary metadata\n";
	for my $key (qw(cpu_model affinity kernel)) { string($capture->{machine}{$key}) or die "missing machine identity: $key\n" }
	$capture->{machine}{affinity} =~ /\A\d+(?:-\d+)?(?:,\d+(?:-\d+)?)*\z/ or die "invalid CPU affinity\n";
	for my $role (qw(wump stock go)) {
		my $binary = $capture->{binaries}{$role};
		ref($binary) eq 'HASH' && string($binary->{path}) && sha($binary->{sha256})
			&& ref($binary->{config}) eq 'HASH' or die "missing binary identity: $role\n";
	}
	for my $role (qw(wump stock)) {
		my $config = $capture->{binaries}{$role}{config};
		for my $key (qw(version wump archname cc gccversion ccflags ldflags lddlflags optimize usemultiplicity useithreads use64bitall)) {
			defined($config->{$key}) && !ref($config->{$key}) or die "invalid Perl build configuration: $key\n";
		}
		$config->{version} eq 'v5.42.2' && $config->{wump} eq ($role eq 'wump' ? '1' : '0') or die "wrong Perl interpreter role/version\n";
		join(' ', @{$config}{qw(ccflags ldflags lddlflags)}) !~ /-fsanitize|--coverage|-fprofile/ or die "instrumented Perl build\n";
	}
	for my $key (qw(version archname cc gccversion ccflags ldflags lddlflags optimize usemultiplicity useithreads use64bitall)) {
		$capture->{binaries}{wump}{config}{$key} eq $capture->{binaries}{stock}{config}{$key} or die "stock/Wump build mismatch: $key\n";
	}
	my $go = $capture->{binaries}{go}{config};
	for my $key (qw(version os arch compiler)) { string($go->{$key}) or die "invalid Go build identity\n" }
	ref($go->{settings}) eq 'ARRAY' or die "missing Go build settings\n";
	for my $setting (@{$go->{settings}}) {
		ref($setting) eq 'HASH' && defined($setting->{Key}) && !ref($setting->{Key})
			&& defined($setting->{Value}) && !ref($setting->{Value}) or die "invalid Go build setting\n";
		!($setting->{Key} =~ /\A-(?:race|msan|asan|cover)\z/ && $setting->{Value} eq 'true')
			&& !($setting->{Key} eq '-gcflags' && length($setting->{Value})) or die "instrumented or custom-optimized Go build\n";
	}
	return $capture;
}
sub validate_capture ($capture) {
	validate_metadata($capture);
	my $params = $capture->{parameters};
	my @operations = operations();
	my @variants = variants();
	ref($capture->{cells}) eq 'ARRAY' && @{$capture->{cells}} == @operations * @variants or die "incomplete matrix cells\n";
	my (%seen, %sequence);
	my %ops = map {$_ => 1} operations();
	my %variants = map {$_ => 1} variants();
	for my $cell (@{$capture->{cells}}) {
		ref($cell) eq 'HASH' && $ops{$cell->{operation} // ''} && $variants{$cell->{variant} // ''} or die "unknown matrix cell\n";
		!$seen{"$cell->{operation}:$cell->{variant}"}++ or die "duplicate matrix cell\n";
		ref($cell->{samples}) eq 'ARRAY' && @{$cell->{samples}} == $params->{runs} or die "incomplete matrix samples\n";
		my (%runs, $status, $reason);
		for my $sample (@{$cell->{samples}}) {
			ref($sample) eq 'HASH' && integer($sample->{run}, 1, $params->{runs}) && !$runs{$sample->{run}}++ or die "duplicate or invalid sample\n";
			integer($sample->{sequence}, 1, @operations * @variants * $params->{runs})
				&& !$sequence{$sample->{sequence}}++ or die "duplicate or invalid execution sequence\n";
			validate_result($sample, $cell->{operation}, $cell->{variant}, $params->{iterations}, $params->{jobs});
			$status //= $sample->{status};
			$status eq $sample->{status} or die "inconsistent support across samples\n";
			if ($status eq 'ok') {
				positive($sample->{process_seconds}) && $sample->{process_seconds} >= $sample->{wall_seconds} or die "invalid process timing\n";
			} else {
				!exists($sample->{process_seconds}) || positive($sample->{process_seconds}) or die "invalid unsupported process timing\n";
				$reason //= $sample->{reason};
				$reason eq $sample->{reason} or die "inconsistent unsupported reason\n";
			}
		}
	}
	return $capture;
}

sub load_capture ($path) {
	open my $in, '<', $path or die "$path: $!\n";
	my $capture = eval { local $/; JSON::PP::decode_json(<$in>) };
	close $in or die $!;
	ref($capture) eq 'HASH' or die "$path: invalid JSON capture\n";
	return validate_capture($capture);
}
sub summarize ($capture) {
	my %rows;
	for my $cell (@{$capture->{cells}}) {
		my $samples = $cell->{samples};
		my $summary = {status => $samples->[0]{status}};
		if ($summary->{status} eq 'ok') {
			$summary->{work} = median(map {$_->{wall_seconds} / $_->{units} * 1e9} @$samples);
			$summary->{process} = median(map {$_->{process_seconds} * 1000} @$samples);
		} else { $summary->{reason} = $samples->[0]{reason} }
		$rows{$cell->{operation}}{$cell->{variant}} = $summary;
	}
	return \%rows;
}
sub report ($capture, $metric = 'work') {
	$metric eq 'work' || $metric eq 'process' or die "invalid report metric\n";
	my $summary = summarize($capture);
	my $text = '# Common operation matrix' . "\n\n";
	$text .= $metric eq 'work' ? "Median ns per operation; lower is better.\n\n" : "Median whole-process milliseconds; lower is better.\n\n";
	$text .= "| Operation | Stock Perl | Wump unused | Wump 1 | Wump 2 | Wump 4 | Go 1 | Go 2 | Go 4 |\n";
	$text .= "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |\n";
	for my $op (operations()) {
		$text .= "| $op | " . join(' | ', map {
			$summary->{$op}{$_}{status} eq 'ok' ? sprintf('%.1f', $summary->{$op}{$_}{$metric}) : 'N/A'
		} variants()) . " |\n";
	}
	if ($metric eq 'work') {
		$text .= "\nTime ratios; below 1.0 means Wump takes less time than that control.\n\n";
		$text .= "| Operation | Unused / stock | Wump 1 / stock | Wump 4 / stock | Wump 1 / Go 1 | Wump 4 / Go 4 |\n";
		$text .= "| --- | ---: | ---: | ---: | ---: | ---: |\n";
		for my $op (operations()) {
			my @ratios;
			for my $pair (['wump-unused', 'stock'], ['wump-1', 'stock'], ['wump-4', 'stock'], ['wump-1', 'go-1'], ['wump-4', 'go-4']) {
				my ($a, $b) = map {$summary->{$op}{$_}} @$pair;
				push @ratios, $a->{status} eq 'ok' && $b->{status} eq 'ok' ? sprintf('%.2fx', $a->{work} / $b->{work}) : 'N/A';
			}
			$text .= "| $op | " . join(' | ', @ratios) . " |\n";
		}
	}
	$text .= "\nN/A means unavailable, never a zero-cost operation:\n\n";
	for my $op (operations()) {
		for my $variant (variants()) {
			my $entry = $summary->{$op}{$variant};
			$text .= "- $op / $variant: $entry->{reason}\n" if $entry->{status} ne 'ok';
		}
	}
	$text .= "\n$capture->{parameters}{runs} rotated runs; $capture->{parameters}{iterations} iterations; $capture->{parameters}{jobs} independent jobs for common operations.\n";
	$text .= "CPU affinity: $capture->{machine}{affinity}. Source: $capture->{source}{revision}" . ($capture->{source}{dirty} ? ' (dirty; diagnostic only).' : ' (clean).') . "\n";
	return $text;
}

sub compare ($before, $after, $limit) {
	defined($limit) && !ref($limit) && $limit =~ /\A\d+(?:\.\d+)?\z/ && $limit <= 100 or die "invalid regression budget\n";
	my $json = JSON::PP->new->canonical;
	for my $c ($before, $after) {
		!$c->{source}{dirty} && $c->{parameters}{runs} >= 3 or die "comparison requires clean source and at least three runs\n";
	}
	for my $key (qw(parameters machine)) {
		$json->encode($before->{$key}) eq $json->encode($after->{$key}) or die "incompatible comparison: $key\n";
	}
	$before->{source}{fixture_sha256} eq $after->{source}{fixture_sha256} or die "different benchmark fixtures\n";
	for my $role (qw(stock go)) {
		$before->{binaries}{$role}{sha256} eq $after->{binaries}{$role}{sha256}
			&& $json->encode($before->{binaries}{$role}{config}) eq $json->encode($after->{binaries}{$role}{config}) or die "changed $role control build\n";
	}
	$json->encode($before->{binaries}{wump}{config}) eq $json->encode($after->{binaries}{wump}{config}) or die "changed Wump build configuration\n";
	my ($a, $b) = map {summarize($_)} ($before, $after);
	my ($failed, $text) = (0, '');
	for my $op (operations()) {
		for my $variant (grep {/\Awump/} variants()) {
			my ($old, $new) = ($a->{$op}{$variant}, $b->{$op}{$variant});
			if ($new->{status} ne 'ok') {
				if ($old->{status} eq 'ok') { $failed = 1; $text .= "FAIL $op $variant: support lost\n" }
				else { $text .= "N/A $op $variant: $new->{reason}\n" }
				next;
			}
			if ($old->{status} ne 'ok') { $text .= "NEW $op $variant: now supported; needs a timing baseline\n"; next }
			for my $metric (qw(work process)) {
				my $change = 100 * ($new->{$metric} / $old->{$metric} - 1);
				my $bad = $change > $limit + 1e-9;
				$failed ||= $bad;
				$text .= sprintf("%s %s %s %s: %+.2f%% (budget +%.2f%%)\n", $bad ? 'FAIL' : 'PASS', $op, $variant, $metric, $change, $limit);
			}
		}
	}
	return ($failed ? 1 : 0, $text);
}
1;
