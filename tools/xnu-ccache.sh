#!/bin/bash
# ccache for the kernel compiles of .github/workflows/xnu.yml (CCACHE there; xnu's KCC/KC++ = $(CCACHE) $(CC)).
# xnu-12377 (26.x) passes `-MJ x.o.json` (one compile_commands.json fragment per object) on every compile, and ccache
# counts any compile with -MJ as uncacheable: 1180 of 1181 calls in run 40828962696, so every 26.x build was cold.
# ccache's ignore_options gets past that, but then a hit never runs clang and leaves no fragment, which MakeInc.kernel
# needs (it concatenates them into compile_commands.json). So: drop -MJ, compile through ccache, write the fragment
# here, hit or miss. The fragment is the command as run (minus -MJ) instead of clang's normalised one.
args=() mj=
while [ $# -gt 0 ]; do
	if [ "$1" = -MJ ]; then mj=$2; shift 2; continue; fi
	args+=("$1"); shift
done
ccache "${args[@]}" || exit
[ -n "$mj" ] || exit 0
exec perl -e '
	sub js { my $s = shift; $s =~ s/(["\\])/\\$1/g; $s =~ s/\n/\\n/g; $s =~ s/\t/\\t/g; "\"$s\"" }
	my $dir = shift; my ($file, $out);
	for (my $i = 1; $i < @ARGV; $i++) {
		if ($ARGV[$i] eq "-o") { $out = $ARGV[++$i]; next }
		$file = $ARGV[$i] if $ARGV[$i] !~ /^-/ && $ARGV[$i] =~ /\.(c|cc|cp|cpp|cxx|m|mm|s|S)$/;
	}
	if (!defined $out) { ($out = $file) =~ s{.*/}{}; $out =~ s/\.[^.]+$/.o/ }
	print "{ \"directory\": ", js($dir), ", \"file\": ", js($file), ", \"output\": ", js($out),
	      ", \"arguments\": [", join(", ", map { js($_) } @ARGV), "]},\n";
' "$(pwd)" "${args[@]}" > "$mj"
