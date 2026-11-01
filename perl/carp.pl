sub apply_carp {
	my ($source) = @_;
	edit('dist/Carp/lib/Carp.pm', "sub caller_info {\n", <<'CODE');
sub caller_info {
    # Wump: each diagnostic owns its debugger scratch array, including nested
    # formatting callbacks. The interpreter cache resolves this current binding.
    local @DB::args;
CODE
}
1;
