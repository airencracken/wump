# Keep upstream integrity checks useful for the intentionally patched fork.
sub apply_porting {
	my ($source) = @_;
	require Digest::SHA;
	my @customized = (
		['Digest::MD5', 'cpan/Digest-MD5', 'MD5.xs', '7c552068afce187cadd0ed42a9277169d5d8b271'],
		['Digest::SHA', 'cpan/Digest-SHA', 'SHA.xs', '7e92d6904020634076eb940ac5c8b849414d6685'],
		['Encode', 'cpan/Encode', 'Encode.xs', 'd590ca69605b1ecc16bf1692113735130f5d7a41'],
		['IO', 'dist/IO', 'IO.xs', '80235249d34a3fd205c4214568d3d58117394017'],
		['MIME::Base64', 'cpan/MIME-Base64', 'Base64.xs', '0aac9224a7175ac874d6f1ded9d9e8bba64d9ded'],
		['PathTools', 'dist/PathTools', 'Cwd.xs', '4881a8deeb56c7e030b1162c5389be800b4e8a34'],
		['Scalar::Util', 'cpan/Scalar-List-Utils', 'ListUtil.xs', '9a162277acd73951f4fbe9973b25a5d212388c7e'],
		['Socket', 'cpan/Socket', 'Socket.xs', '6018f3e52ecf2b49ca15e5d060d8a63dce60f925'],
		['Time::HiRes', 'dist/Time-HiRes', 'HiRes.xs', '438cba196e9bc38bee914aff2ede5913bfb02809'],
		['Unicode::Normalize', 'dist/Unicode-Normalize', 'Normalize.xs', 'ee16845f81414c0ea847651c7db60c797def6aea'],
	);
	my $maintainers = read_file("$source/Porting/Maintainers.pl");
	my $checksums = read_file("$source/t/porting/customized.dat");
	for my $spec (@customized) {
		my ($module, $directory, $file, $expected) = @$spec;
		my $path = "$directory/$file";
		my $digest = Digest::SHA::sha1_hex(read_file("$source/$path"));
		# Refuse to bless arbitrary cached-source changes when reapplying.
		# Native patch changes must update this audited fingerprint explicitly.
		$digest eq $expected or die "unexpected customized source for $module: $path\n";
		my $start = index($maintainers, "    '$module' => {\n");
		my $end = index($maintainers, "\n    },\n", $start);
		$start >= 0 && $end >= 0 or die "missing maintainer block for $module\n";
		my $entry = substr($maintainers, $start, $end - $start);
		unless ($entry =~ /'\Q$file\E'/) {
			if ($entry =~ /'CUSTOMIZED'\s*=>\s*\[/) {
				$entry =~ s/('CUSTOMIZED'\s*=>\s*\[)/$1\n            '$file',/;
			} else {
				$entry .= "\n        'CUSTOMIZED' => ['$file'],";
			}
		}
		substr($maintainers, $start, $end - $start, $entry);
		my $line = "$module $path $digest\n";
		$checksums .= $line unless $checksums =~ s/^\Q$module $path\E [0-9a-f]+\n/$line/m;
	}
	write_file("$source/Porting/Maintainers.pl", $maintainers);
	write_file("$source/t/porting/customized.dat", $checksums);
	my $diagnostics = read_file("$FindBin::Bin/diagnostics.pod");
	my $anchor = "=item 'X' outside of string\n";
	edit('pod/perldiag.pod', $anchor, $diagnostics . $anchor);
	# This test digests MD5.xs as input data using every native digest API.
	# Its known fixture changed intentionally; retain a fixed expected digest
	# independently verified with host md5sum and the host Digest::MD5.
	edit('cpan/Digest-MD5/t/files.t', 'f4b5da4e0f19b4c0ab374b7085ed8955  MD5.xs',
		'bfc831ff3a9d1b2967a1e126926b1fe4  MD5.xs');
}
1;
