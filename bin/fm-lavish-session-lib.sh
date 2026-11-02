# shellcheck shell=bash
# Shared Lavish artifact identity for bin/fm-procevent-lavish.sh and
# bin/fm-bearings-board.sh.
# Usage: . bin/fm-lavish-session-lib.sh
#
# Lavish keys a session on its artifact's path as the lavish-axi process spells
# it. Firstmate's Perl realpath answers in the POSIX spelling of the running
# shell, which is the same string on macOS and Linux but not under Git Bash,
# where lavish-axi (a native Node program) records and lists
# C:\Users\...\Temp\claude\...\board.html while realpath answers
# /tmp/claude/.../board.html for the same file. A string comparison of the
# two never matches, so every Lavish source on Windows failed to find its
# session and no listener could start.
#
# Identity here is therefore physical, not a spelling.
# The Perl sub fm_lavish_keys folds any spelling of one file to one comparison
# key.
# On a host with cygpath (Git Bash, MSYS2, Cygwin) every path goes through
# `cygpath -lm`, which answers C:/Users/... for a POSIX, drive-POSIX, or
# Windows spelling alike and expands an 8.3 short name such as LONGUS~1 to
# the long name lavish-axi records.
# Each key is then lowercased, because Windows compares every path component
# case-insensitively while lavish-axi records the on-disk case and Perl
# realpath keeps whatever case the caller typed.
# Elsewhere the key is the spelling itself, so POSIX hosts keep the exact
# comparison they always had.
# Every read of a Lavish-written path - the `file` field of each session in
# state.json and the first column of lavish-axi's session listing - compares
# keys through this one helper, never spellings.
# Each reader folds the artifact and every row it read in one Perl process
# and one cygpath call, so a lookup costs the same few processes however many
# sessions Lavish has saved.

# Physical path of <path>, or exit 1 when it cannot be resolved. The same
# realpath Lavish itself uses to key a session.
fm_lavish_realpath() {  # <path>
  perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$1" 2>/dev/null
}

# Perl source defining fm_lavish_keys(@paths), the comparison key of each path
# in order; see the header for the rule. A host where cygpath cannot be started
# keeps the spellings; one whose cygpath answers short keeps them lowercased.
# shellcheck disable=SC2016
FM_LAVISH_KEYS_PL='
sub fm_lavish_keys {
  my @paths = @_;
  my ($cygpath, $started);
  local $/ = "\n";
  open my $stderr, ">&", \*STDERR or return @paths;
  open STDERR, ">", "/dev/null";
  {
    no warnings "exec";
    $started = open $cygpath, "-|", "cygpath", "-lm", "--", @paths;
  }
  open STDERR, ">&", $stderr;
  return @paths unless $started;
  my @keys = <$cygpath>;
  close $cygpath;
  chomp @keys;
  @keys = @paths unless @keys == @paths;
  return map { lc } @keys;
}
'

# Prints "<host>\n<port>" of one saved Lavish session URL, or a one-line reason
# on stderr with exit 1. The shape is the one lavish-axi writes when it opens a
# board; unroutable addresses are refused rather than guessed around.
fm_lavish_session_url_endpoint() {  # <url>
  perl -e '
    use strict;
    use warnings;
    my ($url) = @ARGV;
    $url =~ m{\Ahttp://(\[[0-9a-fA-F:]+\]|[A-Za-z0-9._-]+):([0-9]+)/session/[0-9a-f]{16}(?:\?[^\s#]*)?\z}
      or die "invalid saved Lavish session URL\n";
    my ($host, $port) = ($1, $2);
    $host =~ s/^\[|\]$//g;
    $host ne "0.0.0.0" && $host ne "::" && $port >= 1 && $port <= 65535
      or die "invalid saved Lavish server address\n";
    print "$host\n$port\n";
  ' "$1"
}

# Prints "<host>\n<port>" for the one saved Lavish session of <artifact> in the
# session store <state.json>, or a one-line reason on stderr with exit 1. The
# store is Lavish's own record of the boards it opened; nothing here writes it.
# Session content never reaches stdout or stderr, only the fixed reasons.
fm_lavish_session_endpoint() {  # <state.json> <artifact>
  local store=$1 artifact=$2 real url
  real=$(fm_lavish_realpath "$artifact") || { printf 'cannot resolve board artifact\n' >&2; return 1; }
  url=$(perl -MJSON::PP -MEncode=encode_utf8 -e "$FM_LAVISH_KEYS_PL"'
    use strict;
    use warnings;
    my ($path, $real) = @ARGV;
    open my $file, "<", $path or die "cannot read Lavish session store\n";
    -f $file or die "Lavish session store is not a regular file\n";
    local $/;
    my $state = eval { decode_json(<$file>) };
    !$@ or die "invalid Lavish session store\n";
    ref($state) eq "HASH" && ref($state->{sessions}) eq "HASH"
      or die "invalid Lavish session store\n";
    my (@files, @urls);
    for my $session (values %{$state->{sessions}}) {
      next unless ref($session) eq "HASH" && defined($session->{file}) && !ref($session->{file});
      next unless length $session->{file};
      push @files, encode_utf8($session->{file});
      push @urls, defined($session->{url}) && !ref($session->{url}) ? $session->{url} : "";
    }
    my ($key, @keys) = fm_lavish_keys($real, @files);
    my @found = map { $urls[$_] } grep { $keys[$_] eq $key } 0 .. $#keys;
    @found == 1 or die "board must have one saved Lavish session\n";
    print $found[0], "\n";
  ' "$store" "$real") || return 1
  fm_lavish_session_url_endpoint "$url"
}

# Exit 0 when lavish-axi's own session listing shows the artifact at the
# physical path <real> open; exit 1 otherwise. Rows are
# `<file>,<status>,"<url>",<pending>[,<listener>]`. lavish-axi prints the file
# bare on POSIX and TOON-quoted on Windows (0.1.92: "C:\\Users\\..."), so a
# quoted first field is unquoted before its key is compared.
fm_lavish_listing_open() {  # <listing> <real>
  printf '%s\n' "$1" | perl -e "$FM_LAVISH_KEYS_PL"'
    my (@files, @statuses);
    while (<STDIN>) {
      chomp;
      s/^\s+//;
      my $file;
      if (s/^"((?:[^"\\]|\\.)*)"//) {
        $file = $1;
        $file =~ s/\\(.)/$1/g;
      } elsif (s/^([^,]*)//) {
        $file = $1;
      } else {
        next;
      }
      s/^,// or next;
      next unless length $file;
      my ($status) = /^([^,]*)/;
      push @files, $file;
      push @statuses, $status;
    }
    my ($key, @keys) = fm_lavish_keys($ARGV[0], @files);
    exit((grep { $keys[$_] eq $key && $statuses[$_] eq "open" } 0 .. $#keys) ? 0 : 1);
  ' "$2"
}
