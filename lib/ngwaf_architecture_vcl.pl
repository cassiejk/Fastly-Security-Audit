#!/usr/bin/env perl
use strict;
use warnings;
use JSON::PP;

my ($path, $window) = @ARGV;
die "usage: ngwaf_architecture_vcl.pl <content-file> <context-lines>\n"
  unless defined($path) && defined($window) && $window =~ /\A\d+\z/;
open my $fh, '<:raw', $path or die "cannot read generated VCL\n";
local $/;
my $source = <$fh> // '';
close $fh;

# Preserve byte positions and newlines while masking strings and comments.
my $clean = $source;
my $state = 'code';
my $long_delim = '';
for (my $i = 0; $i < length($source); $i++) {
  my $c = substr($source, $i, 1);
  my $next = substr($source, $i + 1, 1);
  if ($state eq 'line') {
    if ($c eq "\n") { $state = 'code'; next; }
  } elsif ($state eq 'block') {
    if ($c eq '*' && $next eq '/') {
      substr($clean, $i, 2) = '  '; $i++; $state = 'code'; next;
    }
  } elsif ($state eq 'string') {
    if ($c eq '\\') {
      substr($clean, $i, 2) = '  '; $i++; next;
    }
    $state = 'code' if $c eq '"';
  } elsif ($state eq 'long') {
    my $close = '"' . $long_delim . '}';
    if (substr($source, $i, length($close)) eq $close) {
      substr($clean, $i, length($close)) = ' ' x length($close);
      $i += length($close) - 1;
      $state = 'code';
      next;
    }
  } elsif ($c eq '{' && substr($source, $i) =~ /\A\{([A-Za-z0-9_]*)"/) {
    $long_delim = $1;
    my $open_length = length($long_delim) + 2;
    substr($clean, $i, $open_length) = ' ' x $open_length;
    $i += $open_length - 1;
    $state = 'long';
    next;
  } elsif ($c eq '"') {
    $state = 'string';
  } elsif ($c eq '#' || ($c eq '/' && $next eq '/')) {
    $state = 'line';
  } elsif ($c eq '/' && $next eq '*') {
    substr($clean, $i, 2) = '  '; $i++; $state = 'block'; next;
  } else {
    next;
  }
  substr($clean, $i, 1) = ' ' unless $c eq "\n";
}

my @lines = split /\n/, $source, -1;
pop @lines if @lines && $lines[-1] eq '';
my @matches;
while ($clean =~ /(?<![A-Za-z0-9_])pragma[ \t\r\n]+optional_param[ \t\r\n]+ngwaf_oob_enabled\b/g) {
  my $start = $-[0];
  my $prefix_end = $+[0];
  my $tail = substr($clean, $prefix_end);
  my ($value, $finish);
  if ($tail =~ /\A[ \t\r\n]*=[ \t\r\n]*(true|false)[ \t\r\n]*;/) {
    $value = $1 eq 'true' ? JSON::PP::true : JSON::PP::false;
    $finish = $prefix_end + length($&);
  } elsif ($tail =~ /\A[^;]*;/) {
    $value = undef;
    $finish = $prefix_end + length($&);
  } else {
    $value = undef;
    $finish = $prefix_end;
  }
  my $first = 1 + (() = substr($source, 0, $start) =~ /\n/g);
  my $last = 1 + (() = substr($source, 0, $finish) =~ /\n/g);
  my $raw = substr($source, $start, $finish - $start);
  my @context;
  for (my $line = ($first - $window > 1 ? $first - $window : 1);
       $line <= @lines && $line <= $last + $window; $line++) {
    my $text = $lines[$line - 1];
    if ($line < $first || $line > $last) {
      # Only structural lines are safe to reproduce without inspecting
      # arbitrary neighboring configuration values.
      $text = '[omitted unrelated VCL]'
        unless $text =~ /\A\s*(?:\{|\}|sub\s+[A-Za-z0-9_]+\s*\{|return\([A-Za-z_]+\);)?\s*\z/;
    }
    push @context, {line_number => $line, text => $text};
  }
  push @matches, {
    name => 'ngwaf_oob_enabled', value => $value,
    line_start => $first, line_end => $last,
    raw_text => $raw, context => \@context,
  };
  pos($clean) = $finish if $finish > pos($clean);
}
print JSON::PP->new->utf8->canonical->encode({
  line_count => scalar(@lines), matches => \@matches,
  status => ($state eq 'code' || $state eq 'line')
    ? (@matches == 0 ? 'ABSENT' : @matches == 1 && defined($matches[0]{value}) ? 'PRESENT' : 'AMBIGUOUS')
    : 'UNKNOWN',
});
