use v5.42;
use strict;
use warnings;
use Test::More;
use File::Temp 'tempdir';
use Cwd 'abs_path';

my $dependencies=abs_path('perl/deps.mk');
my $dir=tempdir('wump-build-deps-XXXXXX',TMPDIR=>1,CLEANUP=>1);
chdir $dir or die $!;
sub write_file ($name,$value) {
	open my $out,'>',$name or die "$name: $!";
	print {$out} $value or die $!;
	close $out or die $!;
}
write_file('Makefile',<<"MAKE");
all: miniperl libperl.a
MINIPERL_EXE = miniperl
LIBPERL = libperl.a
ARCHOBJS = runtime.o
OBJ_EXT = .o
include $dependencies
miniperl libperl.a:
\tcp runtime.o \$\@
MAKE
my @inputs=qw(runtime.o wump_runtime.mk wump_plain_ops.o wump_active_ops.o
	wump_task_types.h wump_task_embed.h wump_plain_ops.h);
write_file($_,'initial runtime') for @inputs,qw(miniperl libperl.a);
utime(100,100,@inputs)==@inputs or die $!;
utime(200,200,qw(miniperl libperl.a))==2 or die $!;
system 'make','--no-print-directory','-q','all';
is($?,0,'unchanged runtime requires no relink');
write_file('runtime.o','new runtime instrumentation');
utime(300,300,'runtime.o')==1 or die $!;
system 'make','--no-print-directory','-q','all';
is($?,1<<8,'changed runtime object invalidates both Perl link targets');
system 'make','--no-print-directory','all';
is($?,0,'incremental relink succeeds');
for my $target (qw(miniperl libperl.a)) {
	open my $in,'<',$target or die $!;
	local $/;
	is(<$in>,'new runtime instrumentation',"$target contains the updated runtime");
}
system 'make','--no-print-directory','-q','all';
is($?,0,'relinked targets are stable on the next build');
done_testing;
