#!/bin/bash
# rg-fzf-kiro: search Kiro CLI conversations by content; print the picks as JSON to resume them.

show_help() {
    cat << 'EOF'
Usage: rg-fzf-kiro [options]

Search your saved Kiro CLI conversations by what was said. Alt-Enter prints the
selected sessions as JSON, with the command to resume each one.

Options:
  --reindex     Rebuild the search index from scratch
  --index-only  Update the search index and exit
  -h, --help    Show help

Keybindings:
  Ctrl-E      Open the readable copy of the conversation in $EDITOR at the line
  Ctrl-F      Toggle chat search / session filter
  Alt-L       Only show running (live) sessions
  Alt-T       Also search tool calls and tool output
  Alt-S       Also include subagent sessions
  Alt-P       Toggle PCRE2 (lookarounds, backreferences)
  Tab         Toggle selection and move to the next line
  Shift-Tab   Toggle selection and move to the previous line
  Ctrl-A      Select all
  Ctrl-Z      Deselect all
  Enter       Print selected lines (or the current line) and exit
  Alt-Enter   Same, as JSON: session id, title, directory, a resume
              command, live status and the matched line (needs jq)
  Ctrl-P      Toggle preview
  Ctrl-D      Scroll preview down
  Ctrl-U      Scroll preview up
  Alt-W       Toggle line wrapping in the preview
  Alt-N       Toggle line numbers in the preview
  Alt-/  F1   Open these keybindings (read-only) in $EDITOR
  Esc         Exit

Rows show the session's directory (~ is your home folder), the date it started
and its short id, then who wrote the line: you, kiro, summary, agent (a subagent
session's instructions from the main Kiro), call and output (tool activity). In
the copy and the preview each message starts with a comment like
"<!-- kiro · 12 -->": who wrote it and its line (record) in Kiro's session file.

Prompt: "Chat (regex)" searches conversations; "Sessions (fuzzy)" filters by
directory, date or id. Flags: [L] live only, [T] tool output, [S] subagent
sessions, [P] PCRE2 (shown in the session filter).

Environment:
  KIRO_SESSIONS_DIR   Where Kiro saves sessions (default ~/.kiro/sessions/cli)
  RG_FZF_KIRO_CACHE   Where the search index is kept (default ~/.cache/rg-fzf-kiro)
EOF
}

die() {
    echo "rg-fzf-kiro: $*" >&2
    exit 1
}

for cmd in rg fzf jq perl; do
    command -v "$cmd" > /dev/null || die "$cmd is not installed"
done

REINDEX=0
INDEX_ONLY=0
while [[ $# -gt 0 ]]; do
    case $1 in
        --reindex) REINDEX=1; shift ;;
        --index-only) INDEX_ONLY=1; shift ;;
        -h|--help) show_help; exit 0 ;;
        *) die "unknown option '$1' (see --help)" ;;
    esac
done

SESSIONS=${KIRO_SESSIONS_DIR:-$HOME/.kiro/sessions/cli}
CACHE=${RG_FZF_KIRO_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/rg-fzf-kiro}
TEXT="$CACHE/text"
INDEX="$CACHE/sessions.tsv"
[[ -d $SESSIONS ]] || die "no Kiro sessions found in $SESSIONS"
mkdir -p "$CACHE" || die "cannot create $CACHE"

# Home folder as shown with "~" (no trailing slash; "/" or unset means none)
HOME_DIR=${HOME%/}
[[ $HOME_DIR == /* ]] || HOME_DIR=""

# Bump when the index layout or extracted text changes: the whole index is rebuilt
FORMAT=6

# Private directory for the generated helper scripts and picker state, removed on exit
STATE=$(mktemp -d) || die "cannot create a temporary directory"
trap 'rm -rf "$STATE"' EXIT

# ===========================================================================
# Index
#
# Every session becomes two plain-text files that ripgrep searches, stored in
# folders that mirror the session's directory:
#   text/<dir>/<started> #<id8>.chat    your prompts, Kiro's replies, compaction summaries
#   text/<dir>/<started> #<id8>.tools   tool calls and their output
# <dir> is the session's directory, with "~" for your home folder. Each message starts
# with a marker comment, "<!-- kiro · 12 -->": who wrote it, and its record (line) in
# the session's .jsonl.
#
# Kiro only ever appends to a session's .jsonl, so the index remembers how many
# bytes of each one it has read and later reads only what was added. Per session:
#   meta/<id>   one tab-separated row: id kind rel cwd updated_utc updated started title
#   seen/<id>   the .json's modification time when meta/<id> was made
#   state/<id>  format, bytes read, checksums of the start and of the last 64 bytes
#               read, sizes of the two text files, their location (rel), kind, and
#               how many records (lines) of the .jsonl were read
# If a .jsonl shrank, its start or read end changed, or the text files are not the
# sizes recorded (e.g. after an interrupted run), that session is rebuilt from scratch.
# ===========================================================================

# Session metadata -> index row. Every column is non-empty, because bash's read
# merges empty tab-separated columns. kind is "sub" for subagent sessions: ones
# another session started (parent_session_id) for a subagent. /rewind also creates
# child sessions, which are the user's own ("main"). rel is the index file path
# without extension; "." and ".." in a directory can't escape the index folder.
cat > "$STATE/meta.jq" << 'JQ'
def nocontrol: tostring | explode | map(if . < 32 or . == 127 then 32 else . end) | implode;
def nonempty($d): if . == "" then $d else . end;
def localtime($fmt): tostring | sub("\\.[0-9]+Z$"; "Z") | try (fromdate | strflocaltime($fmt)) catch null;
def part: if . == "." then "_." elif . == ".." then "_.." else . end;
def row($id):
    select(type == "object") |
    (.cwd // "" | nocontrol) as $cwd |
    (.created_at // .updated_at // "" | tostring) as $c |
    (.updated_at // .created_at // "" | tostring) as $u |
    (if $cwd == "" then ["(no directory)"]
     elif $home != "" and ($cwd == $home or ($cwd | startswith($home + "/"))) then
         ["~"] + ($cwd[($home | length):] | split("/") | map(select(. != "") | part))
     else
         $cwd | split("/") | map(select(. != "") | part)
         | if length == 0 then ["(root)"] elif .[0] == "~" then ["_~"] + .[1:] else . end
     end) as $dir |
    ($c | localtime("%Y-%m-%d") // ($c | nocontrol | .[0:10]) | nonempty("0000-00-00")) as $day |
    [ $id,
      (if .parent_session_id and .session_created_reason == "subagent" then "sub" else "main" end),
      ($dir + ["\($day) #\($id[0:8])"] | join("/")),
      ($cwd | nonempty(".")),
      ($u | nocontrol | nonempty("0")),
      ($u | localtime("%Y-%m-%d %H:%M") // ($u | nocontrol) | nonempty("unknown")),
      ($c | localtime("%Y-%m-%d %H:%M") // ($c | nocontrol) | nonempty("unknown")),
      (.title // "" | nocontrol | gsub("^ +| +$"; "") | nonempty("untitled"))
    ] | join("\t");
# Input: one line per session, "<id>\t<its .json on one line>". Output: its row,
# or "<id>\tBAD" if the .json is not a session (then the old row is kept).
inputs | index("\t") as $i | .[:$i] as $id
| (.[$i + 1:] | try fromjson catch null) as $j
| [$j | row($id)] | first // "\($id)\tBAD"
JQ

# Session .jsonl (raw lines) -> the readable copy, as Markdown. Each message starts
# with a comment line saying who wrote it and which line of the .jsonl (the record)
# it came from: "<!-- kiro · 12 -->". Then its text, then a blank line. Output lines
# are prefixed "C" for the chat copy or "T" for the tool-activity copy.
# $base is how many records came before this input (when reading only what was added).
# $asker labels the prompts: "you", or "agent" in a subagent session, whose prompts
# come from the main Kiro rather than from you. A record that is not valid JSON is
# skipped. Control characters are removed: a NUL would make ripgrep treat the file as
# binary, and escape codes would garble the list. A text line that looks exactly like
# a marker gets a leading space, so it can't be mistaken for one. Kiro's hidden
# reasoning is never included.
cat > "$STATE/extract.jq" << 'JQ'
def clean: gsub("[\u0000-\u0008\u000b-\u001f\u007f]"; "");
def message($role; $rec):
    "<!-- \($role) · \($rec) -->",
    (split("\n")[] | clean | if test("^<!-- [a-z]+ · [0-9]+ -->$") then " " + . else . end),
    "";
def chat($rec):
    if .kind == "Prompt" then
        .data.content[]? | select(.kind == "text") | .data | strings | message($asker; $rec)
    elif .kind == "AssistantMessage" then
        .data.content[]? | select(.kind == "text") | .data | strings | select(length > 0) | message("kiro"; $rec)
    elif .kind == "Compaction" then
        .data.summary | strings | message("summary"; $rec)
    else empty end;
def tools($rec):
    if .kind == "AssistantMessage" then
        .data.content[]? | select(.kind == "toolUse") | .data | objects
        | "\(.name) \(.input | tojson)" | message("call"; $rec)
    elif .kind == "ToolResults" then
        .data.content[]? | .data | objects | .content[]? | objects
        | if .kind == "text" then .data | strings
          elif .kind == "json" then .data | tojson
          else empty end
        | message("output"; $rec)
    else empty end;
inputs | ($base + input_line_number) as $rec
| try (fromjson | (chat($rec) | "C" + .), (tools($rec) | "T" + .)) catch empty
JQ


# Indexer, in Perl so that each session costs one jq run rather than dozens of small
# programs. It holds an exclusive lock on $CACHE/lock, so two copies of rg-fzf-kiro
# never update the index at the same time; the lock is released however it ends.
cat > "$STATE/indexer.pl" << 'PERL'
use strict;
use warnings;
use Fcntl qw(:flock);
use File::Find ();
use File::Path qw(make_path remove_tree);
use POSIX ();
use Time::HiRes ();

my ($CACHE, $SESSIONS, $FORMAT, $HOME, $REINDEX, $JQ_META, $JQ_EXTRACT, $JOBS) = @ARGV;
my $TEXT = "$CACHE/text";
my $INDEX = "$CACHE/sessions.tsv";
my $TMP = "$CACHE/tmp";
$JOBS = 4 unless defined $JOBS && $JOBS =~ /^[1-9][0-9]*\z/;

# Checksum of the bytes at the start of a file and before the read position. Uses MD5
# when available, else keeps the bytes themselves (as hex), which compares just as well.
my $digest = eval { require Digest::MD5; \&Digest::MD5::md5_hex } || sub { unpack('H*', $_[0]) };

sub fail { print STDERR "rg-fzf-kiro: @_\n"; exit 1 }

open(my $lock, '>>', "$CACHE/lock") or fail("cannot open the index lock: $!");
unless (flock($lock, LOCK_EX | LOCK_NB)) {
    print STDERR "rg-fzf-kiro: waiting for another rg-fzf-kiro to finish indexing...\n";
    flock($lock, LOCK_EX) or fail("cannot lock the index: $!");
}

sub slurp {
    my ($path) = @_;
    open(my $f, '<:raw', $path) or return undef;
    local $/;
    my $c = <$f>;
    close $f;
    return defined $c ? $c : '';
}
sub first_line {
    my $c = slurp($_[0]);
    return undef unless defined $c;
    $c =~ s/\n.*\z//s;
    return $c;
}
my $seq = 0;
sub put {    # write a file atomically: other readers see the old or the new content
    my ($path, $content) = @_;
    my $t = "$TMP/put.$$." . ++$seq;
    open(my $f, '>:raw', $t) or return 0;
    unless ((print $f $content) && close($f) && rename($t, $path)) {
        unlink $t;
        return 0;
    }
    return 1;
}
sub fsize { my @s = stat($_[0]); return @s ? $s[7] : undef }
sub dir_of { my ($p) = @_; $p =~ s{/[^/]*\z}{}; return $p }
sub ensure_dir { my $d = dir_of($_[0]); make_path($d) unless -d $d; return -d $d }
sub same_file {
    my @a = stat($_[0]) or return 0;
    my @b = stat($_[1]) or return 0;
    return $a[0] == $b[0] && $a[1] == $b[1];
}
sub read_at {
    my ($fh, $pos, $len) = @_;
    seek($fh, $pos, 0) or return undef;
    my ($buf, $got) = ('', 0);
    while ($got < $len) {
        my $n = read($fh, $buf, $len - $got, $got);
        return undef unless defined $n;
        last unless $n;
        $got += $n;
    }
    return $got == $len ? $buf : undef;
}
sub sum_head {
    my ($fh, $off) = @_;
    my $b = read_at($fh, 0, $off < 4096 ? $off : 4096);
    return defined $b ? $digest->($b) : undef;
}
sub sum_tail {
    my ($fh, $off) = @_;
    my $n = $off < 64 ? $off : 64;
    my $b = read_at($fh, $off - $n, $n);
    return defined $b ? $digest->($b) : undef;
}
sub append_file {
    my ($from, $to) = @_;
    open(my $in, '<:raw', $from) or return 0;
    open(my $out, '>>:raw', $to) or return 0;
    my $buf;
    while (1) {
        my $n = read($in, $buf, 1 << 20);
        return 0 unless defined $n;
        last unless $n;
        print $out $buf or return 0;
    }
    return close($out);
}
sub state_of { return split /\t/, (first_line("$CACHE/state/$_[0]") // ''), -1 }
sub num { return defined $_[0] && $_[0] =~ /^[0-9]+\z/ }

# --- start: version check, fresh scratch folder ------------------------------------
remove_tree($TMP);
make_path($TMP);
-d $TMP or fail("cannot create the index in $CACHE");
my $version = first_line("$CACHE/version");
if ($REINDEX eq '1' || !defined $version || $version ne $FORMAT) {
    remove_tree($TEXT, "$CACHE/meta", "$CACHE/seen", "$CACHE/state");
    unlink $INDEX;
    put("$CACHE/version", "$FORMAT\n") or fail("cannot write to $CACHE");
}
make_path($TEXT, "$CACHE/meta", "$CACHE/seen", "$CACHE/state");
-d "$CACHE/$_" or fail("cannot create the index in $CACHE") for qw(text meta seen state);

# --- scan the sessions folder --------------------------------------------------------
opendir(my $dh, $SESSIONS) or fail("cannot read $SESSIONS");
my (@ids, %size, %mtime);
for my $f (sort readdir $dh) {
    next unless $f =~ /^([A-Za-z0-9][A-Za-z0-9._-]*)\.json\z/;
    my $id = $1;
    my @j = Time::HiRes::stat("$SESSIONS/$f") or next;
    next unless -f "$SESSIONS/$f";
    push @ids, $id;
    $mtime{$id} = sprintf('%.9f', $j[9]);
    my @l = stat("$SESSIONS/$id.jsonl");
    $size{$id} = (@l && -f "$SESSIONS/$id.jsonl") ? $l[7] : undef;
}
closedir $dh;

# --- metadata: one jq run for every session whose .json changed ----------------------
# A .json that can't be read or parsed keeps its previous row, and is tried again
# next run. Newlines are only whitespace in valid JSON, so joining lines is safe.
my @changed = grep {
    my $seen = first_line("$CACHE/seen/$_");
    !(defined $seen && $seen eq $mtime{$_} && fsize("$CACHE/meta/$_"));
} @ids;
if (@changed) {
    my $in = "$TMP/meta.in";
    open(my $f, '>:raw', $in) or fail("cannot write to $CACHE");
    for my $id (@changed) {
        my $c = slurp("$SESSIONS/$id.json");
        next unless defined $c;
        $c =~ tr/\r\n/  /;
        print $f "$id\t$c\n" or fail("cannot write to $CACHE");
    }
    close $f or fail("cannot write to $CACHE");
    my $pid = open(my $jq, '-|');
    defined $pid or fail("cannot run jq: $!");
    if (!$pid) {
        open(STDIN, '<', $in) or POSIX::_exit(1);
        open(STDERR, '>', '/dev/null');
        exec('jq', '-Rnr', '--arg', 'home', $HOME, '-f', $JQ_META) or POSIX::_exit(127);
    }
    while (my $line = <$jq>) {
        chomp $line;
        my @c = split /\t/, $line, -1;
        next unless @c == 8 && exists $mtime{$c[0]};
        put("$CACHE/meta/$c[0]", "$line\n") && put("$CACHE/seen/$c[0]", "$mtime{$c[0]}\n");
    }
    close $jq;
}

# --- text: sessions with new data, largest amount of reading first -------------------
my (@work, $bytes);
$bytes = 0;
for my $id (@ids) {
    next unless defined $size{$id};
    my $row = first_line("$CACHE/meta/$id");
    next unless defined $row && length $row;
    my ($kind, $rel) = (split /\t/, $row, -1)[1, 2];
    my ($fmt, $off, undef, undef, undef, undef, $oldrel, $oldkind) = state_of($id);
    my $current = defined $fmt && $fmt eq $FORMAT && num($off) && defined $oldkind && $oldkind eq $kind;
    next if $current && $off == $size{$id} && defined $oldrel && $oldrel eq $rel;
    my $left = ($current && $off <= $size{$id}) ? $size{$id} - $off : $size{$id};
    push @work, [$left, $id, $rel, $kind];
    $bytes += $left;
}
if ($bytes >= 1 << 20) {
    printf STDERR "rg-fzf-kiro: indexing %d session(s), %d MB...\n", scalar @work, $bytes >> 20;
}

# Brings one session's two text files up to date. Returns 1 on success. On failure
# nothing is recorded, so the next run tries again (and rebuilds if needed).
sub index_one {
    my ($id, $rel, $kind) = @_;
    my $src = "$SESSIONS/$id.jsonl";
    my ($chat, $tools) = ("$TEXT/$rel.chat", "$TEXT/$rel.tools");
    my ($fmt, $off, $head, $tail, $csz, $tsz, $oldrel, $oldkind, $recs) = state_of($id);
    open(my $in, '<:raw', $src) or return 0;
    my $size = (stat $in)[7];

    # Continue from where the last run stopped, if the file still starts and reads
    # the same up to there, and the text files are exactly as that run left them.
    my $append = defined $fmt && $fmt eq $FORMAT && num($off) && $off > 0 && $size >= $off
        && defined $oldkind && $oldkind eq $kind
        && defined $oldrel && length $oldrel
        && (sum_head($in, $off) // '-') eq ($head // '') && (sum_tail($in, $off) // '-') eq ($tail // '')
        && num($csz) && (fsize("$TEXT/$oldrel.chat") // -1) == $csz
        && num($tsz) && (fsize("$TEXT/$oldrel.tools") // -1) == $tsz
        && num($recs);
    if ($append && $oldrel ne $rel && !same_file("$TEXT/$oldrel.chat", $chat)) {
        $append = ensure_dir($chat) && rename("$TEXT/$oldrel.chat", $chat) && rename("$TEXT/$oldrel.tools", $tools);
    }
    ($off, $recs) = (0, 0) unless $append;

    # Read what was added, up to the last complete line only: the end of the file may
    # be a record Kiro is still writing. The rest is read next time.
    my $chunk = '';
    if ($size > $off) {
        $chunk = read_at($in, $off, $size - $off);
        return 0 unless defined $chunk;
        my $nl = rindex($chunk, "\n");
        substr($chunk, $nl + 1) = '';
    }
    my $keep = length $chunk;
    my $added = ($chunk =~ tr/\n//);

    my ($tc, $tt) = ("$TMP/$id.c", "$TMP/$id.t");
    open(my $oc, '>:raw', $tc) or return 0;
    open(my $ot, '>:raw', $tt) or return 0;
    if ($keep > 0) {
        my $cf = "$TMP/$id.chunk";
        open(my $f, '>:raw', $cf) or return 0;
        (print $f $chunk) && close($f) or return 0;
        undef $chunk;
        my $pid = open(my $jq, '-|');
        return 0 unless defined $pid;
        if (!$pid) {
            open(STDIN, '<', $cf) or POSIX::_exit(1);
            open(STDERR, '>', '/dev/null');
            exec('jq', '-Rnr', '--arg', 'asker', $kind eq 'sub' ? 'agent' : 'you', '--argjson', 'base', $recs,
                 '-f', $JQ_EXTRACT)
                or POSIX::_exit(127);
        }
        while (my $l = <$jq>) {
            if ($l =~ s/^C//) { print $oc $l or return 0 }
            elsif ($l =~ s/^T//) { print $ot $l or return 0 }
        }
        close($jq) or return 0;
        unlink $cf;
    }
    close($oc) && close($ot) or return 0;

    # Commit: text first, then the state, so an interrupted run is caught by the size check
    if ($append) {
        append_file($tc, $chat) && append_file($tt, $tools) or return 0;
        unlink $tc, $tt;
    } else {
        ensure_dir($chat) && rename($tc, $chat) && rename($tt, $tools) or return 0;
    }
    my $newoff = $off + $keep;
    my ($h, $t) = ('none', 'none');
    if ($newoff > 0) {
        ($h, $t) = (sum_head($in, $newoff), sum_tail($in, $newoff));
        return 0 unless defined $h && defined $t;
    }
    return put("$CACHE/state/$id",
        join("\t", $FORMAT, $newoff, $h, $t, fsize($chat) // 0, fsize($tools) // 0, $rel, $kind, $recs + $added) . "\n");
}

my $running = 0;
for my $w (sort { $b->[0] <=> $a->[0] || $a->[1] cmp $b->[1] } @work) {
    if ($running >= $JOBS) {
        $running-- if waitpid(-1, 0) > 0;
    }
    my $pid = fork;
    if (!defined $pid) {
        index_one(@$w[1 .. 3]);
    } elsif ($pid == 0) {
        POSIX::_exit(index_one(@$w[1 .. 3]) ? 0 : 1);
    } else {
        $running++;
    }
}
1 while waitpid(-1, 0) > 0;

# --- forget deleted sessions -----------------------------------------------------------
for my $sub (qw(meta seen state)) {
    opendir(my $d, "$CACHE/$sub") or next;
    for my $id (readdir $d) {
        next if $id eq '.' || $id eq '..';
        my $ok = -f "$SESSIONS/$id.json" && ($sub ne 'state' || -f "$SESSIONS/$id.jsonl");
        unlink "$CACHE/$sub/$id" unless $ok;
    }
    closedir $d;
}

# --- session list, most recently updated first ------------------------------------------
my @rows;
for my $id (@ids) {
    my $r = first_line("$CACHE/meta/$id");
    next unless defined $r && length $r;
    my @c = split /\t/, $r, -1;
    push @rows, [$r, \@c] if @c == 8;
}
@rows = sort { $b->[1][4] cmp $a->[1][4] || $a->[1][0] cmp $b->[1][0] } @rows;
put($INDEX, join('', map { "$_->[0]\n" } @rows)) or fail("cannot write $INDEX");

# --- remove text files that belong to no current session ---------------------------------
# A file is kept if it is a current session's file by name, or the same file by
# identity: on a case-insensitive disk two sessions' directories can differ only
# in case and share one folder.
my (%keep, %keep_id);
for my $r (@rows) {
    my ($id, $rel) = @{ $r->[1] }[0, 2];
    next unless -f "$SESSIONS/$id.jsonl";
    for my $p ("$TEXT/$rel.chat", "$TEXT/$rel.tools") {
        $keep{$p} = 1;
        my @s = stat $p;
        $keep_id{"$s[0]:$s[1]"} = 1 if @s;
    }
}
my @files;
File::Find::find({ no_chdir => 1, wanted => sub { push @files, $File::Find::name if -f $File::Find::name } }, $TEXT);
for my $p (@files) {
    next if $keep{$p};
    my @s = stat $p;
    next if @s && $keep_id{"$s[0]:$s[1]"};
    unlink $p;
}
File::Find::finddepth({ no_chdir => 1, wanted => sub {
    rmdir $File::Find::name if $File::Find::name ne $TEXT && -d $File::Find::name;
} }, $TEXT);
remove_tree($TMP);
exit 0;
PERL

JOBS=$(getconf _NPROCESSORS_ONLN 2> /dev/null)
perl "$STATE/indexer.pl" "$CACHE" "$SESSIONS" "$FORMAT" "$HOME_DIR" "$REINDEX" \
    "$STATE/meta.jq" "$STATE/extract.jq" "$JOBS" || exit 1

[[ $INDEX_ONLY == 1 ]] && exit 0

# ===========================================================================
# Interactive picker. Same design as rg-fzf: result lines are FILE, LINE,
# COLUMN and TEXT joined by NUL + ':', so the fields split exactly.
# ===========================================================================

HEADER_CHAT='C-e:edit | M-enter:json | C-f:sessions | M-l:live | M-t:tools | M-s:subagents | M-p:pcre2 | M-/:keys'
HEADER_SESSIONS='C-e:edit | M-enter:json | C-f:chat | M-l:live | M-t:tools | M-s:subagents | M-p:pcre2 | M-/:keys'

# Picker state in $STATE: content-q and file-q hold the saved query of each mode;
# live, tools, sub and pcre2 exist while that toggle is on; listing exists while the
# list shows sessions (empty query) rather than matching lines; in-sessions exists
# while the session filter is active; nonum exists while preview line numbers are off.
# rg-fzf-kiro-keybindings.txt is the read-only keybinding list that Alt-/ opens.
SEARCH="$STATE/search.sh"
ACTIONS="$STATE/actions.sh"
KEYS_FILE="$STATE/rg-fzf-kiro-keybindings.txt"
show_help | sed -n '/^Keybindings:/,/^Environment:/p' | sed '$d' > "$KEYS_FILE"
chmod 444 "$KEYS_FILE"

# Colors for who wrote each message, and reading the marker comments that start each
# message in a copy ("<!-- kiro · 12 -->"). Shared by the list, preview and JSON.
cat > "$STATE/roles.pl" << 'PERL'
our %ROLE = (
    you     => "\e[1;36m",    # bold cyan
    agent   => "\e[1;34m",    # bold blue: prompts in a subagent session, from the main Kiro
    kiro    => "\e[1;32m",    # bold green
    summary => "\e[1;35m",    # bold magenta
    call    => "\e[33m",      # yellow
    output  => "\e[2m",       # dim
);
our $MARKER = qr/^<!-- (you|agent|kiro|summary|call|output) \x{c2}\x{b7} ([0-9]+) -->$/;
my %marks;
# Markers of a copy, as [line, role, record] sorted by line (read once per file)
sub marks_of {
    my ($path) = @_;
    return $marks{$path} //= do {
        my @m;
        if (open(my $f, '<:raw', $path)) {
            my $n = 0;
            while (my $l = <$f>) {
                $n++;
                chomp $l;
                push @m, [$n, $1, $2] if $l =~ $MARKER;
            }
        }
        \@m;
    };
}
# The marker of the message that line $n belongs to (undef before the first one)
sub mark_at {
    my ($m, $n) = @_;
    my ($lo, $hi, $hit) = (0, $#$m, undef);
    while ($lo <= $hi) {
        my $mid = int(($lo + $hi) / 2);
        if ($m->[$mid][0] <= $n) { $hit = $m->[$mid]; $lo = $mid + 1 } else { $hi = $mid - 1 }
    }
    return $hit;
}
1;
PERL

# List rows: adds who wrote each matched line, colored, and drops matches on the marker
# comments themselves. Only the displayed text changes; the copy is untouched.
cat > "$STATE/color-rows.pl" << 'PERL'
require shift @ARGV;
our (%ROLE);
$| = 1;
while (my $l = <STDIN>) {
    my @f = split /\0:/, $l, 4;
    next unless @f == 4;
    my ($path, $n) = @f[0, 1];
    s/\e\[[0-9;]*m//g for $path, $n;
    my $m = mark_at(marks_of($path), $n);
    next if $m && $m->[0] == $n;
    $f[3] = "$ROLE{$m->[1]}$m->[1]\x{e2}\x{94}\x{82}\e[0m " . $f[3] if $m;
    print join("\0:", @f);
}
PERL

# Preview body: line numbers, and the text around the selected line highlighted as
# Markdown by bat (Kiro writes Markdown), with each message's marker comment colored
# by who wrote it. bat only gets a window around the line, so even huge sessions
# preview quickly; lines outside it are shown plain.
cat > "$STATE/preview.pl" << 'PERL'
use strict;
use warnings;
my ($roles, $file, $line, $state) = @ARGV;
my $numbers = !-e "$state/nonum";    # Alt-N turns line numbers off
require $roles;
our (%ROLE, $MARKER);
$line = 1 unless defined $line && $line =~ /^[0-9]+\z/ && $line > 0;
open(my $f, '<:raw', $file) or do { print "(no text)\n"; exit 0 };
my @text = map { chomp; $_ } <$f>;
close $f;
my $n = @text;
exit 0 unless $n;
$line = $n if $line > $n;
my ($from, $to) = ($line - 300 < 1 ? 1 : $line - 300, $line + 700 > $n ? $n : $line + 700);
my @shown;
if (system('sh', '-c', 'command -v bat > /dev/null 2>&1') == 0) {
    my $win = "$state/preview.$$";
    if (open(my $w, '>:raw', $win)) {
        print $w map { "$_\n" } @text[$from - 1 .. $to - 1];
        close $w;
        my $cols = ($ENV{FZF_PREVIEW_COLUMNS} // 80) - ($numbers ? length($n) + 2 : 2);
        $cols = 20 if $cols < 20;
        if (open(my $b, '-|', 'bat', '--color=always', '--style=plain', '--paging=never', '--wrap=never',
                '--language=markdown', "--terminal-width=$cols", '--highlight-line', $line - $from + 1, '--', $win)) {
            binmode $b;
            @shown = map { chomp; $_ } <$b>;
            close $b;
        }
        unlink $win;
        @shown = () unless @shown == $to - $from + 1;
    }
}
my $width = length $n;
for my $i (1 .. $n) {
    my $t = $text[$i - 1];
    if ($t =~ $MARKER) {
        $t = "$ROLE{$1}<!-- $1 \x{c2}\x{b7} $2 -->\e[0m";
    } elsif ($i >= $from && $i <= $to && @shown) {
        $t = $shown[$i - $from];
    }
    my $mark = $i == $line ? "\e[1;33m>\e[0m" : ' ';
    if ($numbers) {
        printf "%s\e[90m%*d\e[0m %s\n", $mark, $width, $i, $t;
    } else {
        print "$mark $t\n";
    }
}
PERL

# Builds the Alt-Enter JSON. json.pl turns the selected lines into records (fields
# separated by \x01, which can't appear in the copies): copy path, line, column,
# role, original record, full text. json.jq joins them with the session list and
# the live sessions. Each result gets its session's details and a resume command.
cat > "$STATE/json.pl" << 'PERL'
require shift @ARGV;
my $text_dir = shift @ARGV;
my %lines;
while (my $l = <STDIN>) {
    chomp $l;
    my @f = split /\0:/, $l, 4;
    next unless @f >= 3 && $f[1] =~ /^[0-9]+\z/;
    my ($rel, $n, $col) = @f;
    my $path = "$text_dir/$rel";
    my $all = $lines{$path} //= do {
        my @a;
        if (open(my $f, '<:raw', $path)) { @a = map { chomp; $_ } <$f> }
        \@a;
    };
    my $m = mark_at(marks_of($path), $n);
    my $full = $n <= @$all ? $all->[$n - 1] : '';
    print join("\x01", $rel, $n, $col, $m ? $m->[1] : '', $m ? $m->[2] : '', $full), "\n";
}
PERL
cat > "$STATE/json.jq" << 'JQ'
($index | split("\n") | map(select(length > 0) | split("\t")
    | {key: .[2], value: {session_id: .[0], subagent: (.[1] == "sub"), directory: .[3],
                          updated_at: .[4], updated: .[5], started: .[6], title: .[7]}}) | from_entries) as $sessions
| ($live | split(" ") | map(select(length > 0) | split(":") | {key: .[0], value: (.[1] | tonumber)}) | from_entries) as $pids
| {query: $query}
+ (if $filter != "" then {session_filter: $filter} else {} end)
+ {results: [inputs | split("\u0001") as $f
    | ($f[0] | sub("\\.(chat|tools)$"; "")) as $rel
    | $sessions[$rel] as $s | select($s != null)
    | {session_id: $s.session_id, title: $s.title, directory: $s.directory,
       resume: "cd \($s.directory | @sh) && kiro-cli chat --resume-id \($s.session_id | @sh)",
       live: ($pids[$s.session_id] != null), pid: $pids[$s.session_id],
       subagent: $s.subagent, started: $s.started, updated: $s.updated, updated_at: $s.updated_at,
       session_file: "\($sessions_dir)/\($s.session_id).jsonl"}
      + (if $listing == "1" then {} else
          {copy: "\($text_dir)/\($f[0])", line: ($f[1] | tonumber), column: ($f[2] | tonumber),
           record: (if $f[4] == "" then null else $f[4] | tonumber end),
           role: (if $f[3] == "" then null else $f[3] end), text: ($f[5:] | join("\u0001"))}
         end)]}
JQ

# Both helpers start with the paths they need and how to read Kiro's lock files
helper_header() {
    echo '#!/bin/bash'
    printf 'S=%q\nSESSIONS=%q\nTEXT=%q\nINDEX=%q\n' "$STATE" "$SESSIONS" "$TEXT" "$INDEX"
    cat << 'SCRIPT'
# Classifies running pids by their command: "kiro", "other", or "unknown" when the
# command can't be read (some sandboxes block ps). Prints "pid status" lines.
classify() {
    local list out
    list=$(IFS=,; echo "$*")
    out=$(ps -p "$list" -o pid= -o command= 2> /dev/null)
    [[ -n $out ]] || out=$(pgrep -lf . 2> /dev/null)
    printf '%s\n' "$out" | awk -v want="$*" '
        BEGIN { n = split(want, w, " "); for (i = 1; i <= n; i++) st[w[i]] = "unknown" }
        ($1 in st) { p = $1; $1 = ""; st[p] = ($0 ~ /kiro-cli/) ? "kiro" : "other" }
        END { for (p in st) print p, st[p] }'
}

# Kiro writes {"pid": N, ...} to <id>.lock while a kiro-cli has the session open.
# Sets LOCK_PID; fails if there is no readable pid.
read_lock_pid() {
    local content=""
    LOCK_PID=""
    IFS= read -r -d '' content < "$1" 2> /dev/null
    [[ $content =~ \"pid\"[[:space:]]*:[[:space:]]*([0-9]+) ]] || return 1
    LOCK_PID=${BASH_REMATCH[1]}
}

# Sets LIVE to " id:pid id:pid ... " for every session open in a running kiro-cli.
# A lock left behind by a crash can point at a pid now used by another program, so
# the process must be kiro-cli. If its command can't be read it still counts as live.
live_scan() {
    local lock id ids=() pids=() i statuses
    LIVE=" "
    for lock in "$SESSIONS"/*.lock; do
        [[ -f $lock ]] || continue
        read_lock_pid "$lock" || continue
        kill -0 "$LOCK_PID" 2> /dev/null || continue
        id=${lock##*/}
        ids+=("${id%.lock}")
        pids+=("$LOCK_PID")
    done
    (( ${#pids[@]} )) || return 0
    statuses=$'\n'$(classify "${pids[@]}")$'\n'
    for i in "${!pids[@]}"; do
        [[ $statuses == *$'\n'"${pids[$i]} other"$'\n'* ]] || LIVE+="${ids[$i]}:${pids[$i]} "
    done
}
SCRIPT
}

# Search helper, used for every reload:
#   search.sh QUERY                   search for QUERY within the saved session filter
#   search.sh --saved                 same, using the saved chat query
#   search.sh --all-files --saved     saved chat query without the session filter
#                                     (session mode, where fzf does that filtering live)
# An empty query lists the sessions instead. Both are ordered by the session list:
# most recently updated first.
{
    helper_header
    printf 'COLOR_ROWS=%q\nROLES=%q\n' "$STATE/color-rows.pl" "$STATE/roles.pl"
    cat << 'SCRIPT'
FILE_Q=$(cat "$S/file-q" 2>/dev/null)
[[ $1 == --all-files ]] && { FILE_Q=""; shift; }
if [[ $1 == --saved ]]; then
    Q=$(cat "$S/content-q" 2>/dev/null)
else
    Q=$1
fi
LIVE_ONLY=0
[[ -f $S/live ]] && LIVE_ONLY=1
LIVE=" "
[[ -z $Q || $LIVE_ONLY == 1 ]] && live_scan
cd "$TEXT" || exit 0

if [[ -z $Q ]]; then
    touch "$S/listing"
    while IFS=$'\t' read -r id kind rel _ _ updated _; do
        [[ $kind == sub && ! -f $S/sub ]] && continue
        tag=""
        [[ $LIVE == *" $id:"* ]] && tag=$'  \033[33m● live\033[0m'
        [[ $LIVE_ONLY == 1 && -z $tag ]] && continue
        [[ -s $rel.chat ]] || continue    # nothing said yet
        printf '%s\0:1\0:1\0:updated %s%s\n' "$rel.chat" "$updated" "$tag"
    done < "$INDEX" | if [[ -n $FILE_Q ]]; then
        fzf --filter "$FILE_Q" --ansi --delimiter '\x00:' --nth 1 --no-sort
    else
        cat
    fi
    exit 0
fi
rm -f "$S/listing"

ENGINE=default
[[ -f $S/pcre2 ]] && ENGINE=pcre2

# Index files to search, in session-list order. rg -j1 searches them in that order;
# --max-columns shortens huge lines in the list (they are still searched in full).
# xargs -r runs nothing if no file is left.
while IFS=$'\t' read -r id kind rel _; do
    [[ $kind == sub && ! -f $S/sub ]] && continue
    [[ $LIVE_ONLY == 1 && $LIVE != *" $id:"* ]] && continue
    [[ -s $rel.chat ]] && printf '%s\0' "$rel.chat"
    [[ -f $S/tools && -s $rel.tools ]] && printf '%s\0' "$rel.tools"
done < "$INDEX" | if [[ -n $FILE_Q ]]; then
    fzf --filter "$FILE_Q" --read0 --print0 --no-sort
else
    cat
fi | xargs -0 -r rg -j1 --engine "$ENGINE" --ignore-case --column --line-number --no-heading \
    --color=always --with-filename --field-match-separator '\x00:' --max-columns 500 \
    --max-columns-preview -e "$Q" -- 2> /dev/null | perl "$COLOR_ROWS" "$ROLES"
exit 0
SCRIPT
} > "$SEARCH"

# Keybinding helper: prints fzf actions for a key, based on the mode ($FZF_PROMPT).
# Also draws the preview and builds the JSON output.
{
    helper_header
    printf 'SEARCH=%q\nROLES=%q\nPREVIEW=%q\nJSON_PL=%q\nJSON_JQ=%q\n' \
        "$SEARCH" "$STATE/roles.pl" "$STATE/preview.pl" "$STATE/json.pl" "$STATE/json.jq"
    printf 'HEADER_CHAT=%q\nHEADER_SESSIONS=%q\n' "$HEADER_CHAT" "$HEADER_SESSIONS"
    cat << 'SCRIPT'
# Result file name ("<rel>.chat" or "<rel>.tools") -> session row.
# Sets id kind cwd updated started title.
row_of_file() {
    local line
    line=$(B="${1%.*}" awk -F '\t' '$3 == ENVIRON["B"] { print; exit }' "$INDEX")
    [[ -n $line ]] || return 1
    IFS=$'\t' read -r id kind _ cwd _ updated started title <<< "$line"
}

# Prompt: mode, how the typed text is matched, then active toggles.
# The session filter is always fuzzy, so PCRE2 being on shows as a [P] flag there.
prompt() {
    local how=regex flags=""
    [[ -f $S/pcre2 ]] && how=pcre2
    [[ -f $S/live ]] && flags+="L"
    [[ -f $S/tools ]] && flags+="T"
    [[ -f $S/sub ]] && flags+="S"
    if [[ $1 == Sessions ]]; then
        [[ $how == pcre2 ]] && flags+="P"
        how=fuzzy
    fi
    [[ -n $flags ]] && flags=" [$flags]"
    echo "$1 ($how)$flags> "
}

if [[ $FZF_PROMPT == Sessions* ]]; then
    MODE=Sessions RELOAD="reload('$SEARCH' --all-files --saved)"
else
    MODE=Chat RELOAD="reload('$SEARCH' {q})"
fi

case $1 in
    query-changed)
        # Session filter: fzf filters live. Chat: re-run the search.
        # {q} is left for fzf to fill in (it quotes it), never expanded here.
        if [[ $MODE == Sessions ]]; then
            echo "first"
        else
            echo "reload(sleep 0.1; '$SEARCH' {q})"
        fi
        ;;
    toggle-live|toggle-tools|toggle-sub|toggle-pcre2)
        f="$S/${1#toggle-}"
        if [[ -f $f ]]; then rm -f "$f"; else touch "$f"; fi
        echo "change-prompt($(prompt $MODE))+$RELOAD"
        ;;
    switch-mode)
        if [[ $MODE == Chat ]]; then
            touch "$S/in-sessions"
            echo "execute-silent(printf '%s' {q} > '$S/content-q')+change-prompt($(prompt Sessions))+change-header($HEADER_SESSIONS)+enable-search+reload('$SEARCH' --all-files --saved)+transform-query(cat '$S/file-q' 2>/dev/null)"
        else
            rm -f "$S/in-sessions"
            echo "execute-silent(printf '%s' {q} > '$S/file-q')+change-prompt($(prompt Chat))+change-header($HEADER_CHAT)+disable-search+reload('$SEARCH' --saved)+transform-query(cat '$S/content-q' 2>/dev/null)"
        fi
        ;;
    toggle-numbers)
        if [[ -f $S/nonum ]]; then rm -f "$S/nonum"; else touch "$S/nonum"; fi
        echo "refresh-preview"
        ;;
    preview)
        # $2 = result file name, $3 = line. Six header lines, then the conversation.
        row_of_file "$2" || { echo "Session not found"; exit 0; }
        kindnote=""
        [[ $kind == sub ]] && kindnote="  (subagent)"
        live_scan
        printf '\033[1mtitle\033[0m    %s\n' "$title"
        printf '\033[1msession\033[0m  %s%s\n' "$id" "$kindnote"
        printf '\033[1mdir\033[0m      %s\n' "$cwd"
        printf '\033[1mstarted\033[0m  %s    \033[1mupdated\033[0m  %s\n' "$started" "$updated"
        if [[ $LIVE =~ \ $id:([0-9]+)\  ]]; then
            printf '\033[1mstatus\033[0m   \033[33m● live in a running kiro-cli (pid %s)\033[0m\n' "${BASH_REMATCH[1]}"
        else
            printf '\033[1mstatus\033[0m   saved\n'
        fi
        echo "──────────────────────────────────────────────"
        perl "$PREVIEW" "$ROLES" "$TEXT/$2" "$3" "$S"
        ;;
    json)
        # $2 = query, $3 = session filter; the selected lines arrive on stdin
        live_scan
        listing=0
        [[ -f $S/listing ]] && listing=1
        perl "$JSON_PL" "$ROLES" "$TEXT" |
            jq -Rn --arg query "$2" --arg filter "$3" --arg live "$LIVE" --arg listing "$listing" \
                --arg text_dir "$TEXT" --arg sessions_dir "$SESSIONS" --rawfile index "$INDEX" -f "$JSON_JQ"
        ;;
esac
SCRIPT
} > "$ACTIONS"

chmod +x "$SEARCH" "$ACTIONS"
cd "$TEXT" || die "cannot open $TEXT"

# fzf prints the query, the key that closed it (empty for Enter, "alt-enter" for
# Alt-Enter), then the selected lines. Enter: plain file:line:column:text, with the
# NUL separators removed (LC_ALL=C keeps any byte intact). Alt-Enter: JSON.
print_selection() {
    local query key filter=""
    IFS= read -r query || return 0
    IFS= read -r key || return 0
    if [[ $key != alt-enter ]]; then
        LC_ALL=C tr -d '\0'
        return
    fi
    # In the session filter the query box holds the filter text; use the saved search
    if [[ -f $STATE/in-sessions ]]; then
        filter=$query
        query=$(cat "$STATE/content-q" 2> /dev/null)
    else
        filter=$(cat "$STATE/file-q" 2> /dev/null)
    fi
    "$ACTIONS" json "$query" "$filter"
}

# Ctrl-E opens the readable copy in $EDITOR at the line. Editing it does not change
# the session; the index notices and rebuilds the copy on the next start.
EDIT_CMD="${EDITOR:-vim} $(printf '%q' "$TEXT")/{1} +{2}"
KEYS_CMD="${EDITOR:-vim} $(printf '%q' "$KEYS_FILE")"

fzf \
  --ansi \
  --disabled \
  --multi \
  --delimiter '\x00:' \
  --nth 1 \
  --expect alt-enter \
  --print-query \
  --prompt 'Chat (regex)> ' \
  --header "$HEADER_CHAT" \
  --bind "start:reload:'$SEARCH' ''" \
  --bind "change:transform:'$ACTIONS' query-changed" \
  --bind "ctrl-f:transform:'$ACTIONS' switch-mode" \
  --bind "alt-l:transform:'$ACTIONS' toggle-live" \
  --bind "alt-t:transform:'$ACTIONS' toggle-tools" \
  --bind "alt-s:transform:'$ACTIONS' toggle-sub" \
  --bind "alt-p:transform:'$ACTIONS' toggle-pcre2" \
  --bind "ctrl-e:execute:$EDIT_CMD" \
  --bind "tab:toggle+up" \
  --bind "shift-tab:toggle+down" \
  --bind "ctrl-a:select-all" \
  --bind "ctrl-z:deselect-all" \
  --bind "ctrl-p:toggle-preview" \
  --bind "ctrl-d:preview-half-page-down" \
  --bind "ctrl-u:preview-half-page-up" \
  --bind "alt-w:toggle-preview-wrap" \
  --bind "alt-n:transform:'$ACTIONS' toggle-numbers" \
  --bind "alt-/:execute:$KEYS_CMD" \
  --bind "f1:execute:$KEYS_CMD" \
  --preview "'$ACTIONS' preview {1} {2}" \
  --preview-window 'up,60%,border-bottom,+{2}+6/3,~6' | print_selection
