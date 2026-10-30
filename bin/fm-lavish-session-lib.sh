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
# Identity here is therefore physical, not a spelling. fm_lavish_path_key
# folds any spelling of one file to one comparison key: on a host with cygpath
# (Git Bash, MSYS2, Cygwin) both sides go through `cygpath -m`, which answers
# C:/Users/... for a POSIX, drive-POSIX, or Windows spelling alike, and the
# drive letter is lowercased because Windows compares it case-insensitively.
# Elsewhere the key is the spelling itself, so POSIX hosts keep the exact
# comparison they always had. Every read of a Lavish-written path - the `file`
# field of each session in state.json and the first column of lavish-axi's
# session listing - compares keys through this one helper, never spellings.
#
# File names cross from Perl to bash hex-encoded so a tab, a quote, or an odd
# byte in a path cannot split or truncate a row. Only the row format is
# shared; the two readers below parse Lavish's two different surfaces.

# Physical path of <path>, or exit 1 when it cannot be resolved. The same
# realpath Lavish itself uses to key a session.
fm_lavish_realpath() {  # <path>
  perl -MCwd=realpath -e '$p = realpath($ARGV[0]); defined($p) or exit 1; print "$p\n"' "$1" 2>/dev/null
}

# Comparison key for one spelling of a path; see the header for the rule.
fm_lavish_path_key() {  # <path>
  local key=$1 drive
  if command -v cygpath >/dev/null 2>&1; then
    key=$(cygpath -m -- "$1" 2>/dev/null) || key=$1
    case "$key" in
      [A-Za-z]:*)
        drive=$(printf '%s' "${key:0:1}" | tr '[:upper:]' '[:lower:]')
        key=$drive${key:1}
        ;;
    esac
  fi
  printf '%s\n' "$key"
}

# Decodes the lowercase hex byte string the readers below emit for a file name.
fm_lavish_hex_decode() {  # <hex>
  printf '%b' "$(printf '%s' "$1" | sed 's/../\\x&/g')"
}

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
  local store=$1 artifact=$2 real key rows hex url file matches=0 found=''
  real=$(fm_lavish_realpath "$artifact") || { printf 'cannot resolve board artifact\n' >&2; return 1; }
  key=$(fm_lavish_path_key "$real")
  rows=$(perl -MJSON::PP -MEncode=encode_utf8 -e '
    use strict;
    use warnings;
    my ($path) = @ARGV;
    open my $file, "<", $path or die "cannot read Lavish session store\n";
    -f $file or die "Lavish session store is not a regular file\n";
    local $/;
    my $state = eval { decode_json(<$file>) };
    !$@ or die "invalid Lavish session store\n";
    ref($state) eq "HASH" && ref($state->{sessions}) eq "HASH"
      or die "invalid Lavish session store\n";
    for my $session (values %{$state->{sessions}}) {
      next unless ref($session) eq "HASH" && defined($session->{file}) && !ref($session->{file});
      next unless length $session->{file};
      my $url = defined($session->{url}) && !ref($session->{url}) ? $session->{url} : "";
      $url = "" if $url =~ /\s/;
      print unpack("H*", encode_utf8($session->{file})), "\t", $url, "\n";
    }
  ' "$store") || return 1
  while IFS=$'\t' read -r hex url; do
    [ -n "$hex" ] || continue
    file=$(fm_lavish_hex_decode "$hex")
    [ "$(fm_lavish_path_key "$file")" = "$key" ] || continue
    matches=$((matches + 1))
    found=$url
  done <<< "$rows"
  [ "$matches" -eq 1 ] || { printf 'board must have one saved Lavish session\n' >&2; return 1; }
  fm_lavish_session_url_endpoint "$found"
}

# Exit 0 when lavish-axi's own session listing shows the artifact at the
# physical path <real> open; exit 1 otherwise. Rows are
# `<file>,<status>,"<url>",<pending>[,<listener>]`. lavish-axi prints the file
# bare on POSIX and TOON-quoted on Windows (0.1.92: "C:\\Users\\..."), so a
# quoted first field is unquoted before its key is compared.
fm_lavish_listing_open() {  # <listing> <real>
  local key rows hex status file
  key=$(fm_lavish_path_key "$2")
  rows=$(printf '%s\n' "$1" | perl -e '
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
      print unpack("H*", $file), "\t", $status, "\n";
    }
  ') || return 1
  while IFS=$'\t' read -r hex status; do
    [ -n "$hex" ] || continue
    file=$(fm_lavish_hex_decode "$hex")
    [ "$(fm_lavish_path_key "$file")" = "$key" ] || continue
    [ "$status" = open ] && return 0
  done <<< "$rows"
  return 1
}
