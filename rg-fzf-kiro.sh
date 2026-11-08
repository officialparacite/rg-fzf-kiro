#!/bin/bash
# rg-fzf-kiro: search Kiro CLI conversations by content; print the picks as JSON to resume them.

show_help() {
    cat << 'EOF'
Usage: rg-fzf-kiro [options]
       command | rg-fzf-kiro [options]

Search your saved Kiro CLI conversations by what was said. Enter prints the paths of
the selected sessions' readable copies (plain Markdown files), so rg-fzf or another
rg-fzf-kiro can search them further: rg-fzf-kiro | rg-fzf. Alt-Enter prints them as
JSON, with the command to resume each. Piped in, a list of copies, session ids or
Kiro session files limits the search to those sessions.

Shows Kiro CLI V3 sessions. --v2 adds the ones in the older V2 store; a V2 session
you resumed under V3 shows once, as its V3 copy.

Options:
  --v2          Also show V2 sessions
  -0, --null    Enter separates the paths with NUL instead of newlines
  --reindex     Rebuild the search index from scratch
  --index-only  Update the search index and exit
  -h, --help    Show help

Keybindings:
  Ctrl-E      Open the readable copy of the conversation in $EDITOR at the line
  Ctrl-F      Toggle chat search / session filter
  Alt-G       Only show running (live) sessions
  Alt-S       Also include subagent sessions
  Alt-P       Toggle PCRE2 (lookarounds, backreferences)
  Alt-U       Toggle one result per session (its first match)
  Alt-R       Show messages by: everyone, only you, only Kiro (cycles)
  Tab         Toggle selection and move to the next line
  Shift-Tab   Toggle selection and move to the previous line
  Ctrl-A      Select all
  Ctrl-Z      Deselect all
  Enter       Print the readable copies of the selected lines' sessions and exit
  Ctrl-O      Print the selected lines as shown, and exit
  Alt-Enter   Print the selected lines as JSON: session id, title, directory, a
              resume command, live status and the matched line
  Ctrl-P      Toggle preview
  Ctrl-D      Scroll preview down
  Ctrl-U      Scroll preview up
  Alt-W       Toggle line wrapping in the preview
  Alt-N       Toggle line numbers in the preview
  Alt-/  F1   Open these keybindings (read-only) in $EDITOR
  Esc         Exit

Rows show the session's directory (~ is your home folder), the date it started
and its short id, then who wrote the line: you, kiro, summary (Kiro's summary when
a conversation was compacted) or agent (a subagent session's instructions from the
main Kiro). In the copy and the preview each message starts with a comment like
"<!-- kiro · 12 -->": who wrote it and its line (record) in Kiro's session file.
Tool calls and their output are not searched.

Prompt: "Chat (regex)" searches conversations; "Sessions (fuzzy)" filters by
directory, date or id. Flags: [L] live only, [S] subagent sessions, [U] one result
per session, [P] PCRE2 (shown in the session filter), [R:you] or [R:kiro] whose
messages are shown (Kiro's include its summaries).

Environment:
  KIRO_HOME           Kiro's folder (default ~/.kiro)
  KIRO_SESSIONS_DIR   Where Kiro saves sessions (default $KIRO_HOME/sessions)
  RG_FZF_KIRO_CACHE   Where the search index is kept (default ~/.cache/rg-fzf-kiro)
EOF
}

die() {
    echo "rg-fzf-kiro: $*" >&2
    exit 1
}

for cmd in rg fzf jq perl bat; do
    command -v "$cmd" > /dev/null || die "$cmd is not installed"
done

REINDEX=0
INDEX_ONLY=0
SHOW_V2=0
NUL_OUT=0
while [[ $# -gt 0 ]]; do
    case $1 in
        --v2) SHOW_V2=1; shift ;;
        -0|--null) NUL_OUT=1; shift ;;
        --reindex) REINDEX=1; shift ;;
        --index-only) INDEX_ONLY=1; shift ;;
        -h|--help) show_help; exit 0 ;;
        *) die "unknown option '$1' (see --help)" ;;
    esac
done

# Kiro keeps V3 sessions in $SESSIONS/<workspace>/<id>/ and V2 sessions in $SESSIONS/cli/
KIRO_DIR=${KIRO_HOME:-$HOME/.kiro}
SESSIONS=${KIRO_SESSIONS_DIR:-$KIRO_DIR/sessions}
V2DIR="$SESSIONS/cli"
CACHE=${RG_FZF_KIRO_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/rg-fzf-kiro}
TEXT="$CACHE/text"
INDEX="$CACHE/sessions.tsv"
[[ -d $SESSIONS ]] || die "no Kiro sessions found in $SESSIONS"
mkdir -p "$CACHE" || die "cannot create $CACHE"

# Home folder as shown with "~" (no trailing slash; "/" or unset means none)
HOME_DIR=${HOME%/}
[[ $HOME_DIR == /* ]] || HOME_DIR=""

# Bump when the index layout or extracted text changes: the whole index is rebuilt
FORMAT=7

# Private directory for the generated helper scripts and picker state, removed on exit
STATE=$(mktemp -d) || die "cannot create a temporary directory"
trap 'rm -rf "$STATE"' EXIT

# A pipe or a file on stdin lists the sessions to search. (/dev/null, as in cron,
# counts as nothing given.) It is read now and checked once the index is up to date.
PIPED=0
if [[ $INDEX_ONLY == 0 ]] && [[ -p /dev/stdin || -f /dev/stdin ]]; then
    PIPED=1
    cat > "$STATE/raw"
fi

# ===========================================================================
# Index
#
# Every session becomes a plain-text copy that ripgrep searches, stored in folders
# that mirror the session's directory:
#   text/<dir>/<started> #<id8>.chat    your prompts, Kiro's replies, compaction summaries
# <dir> is the session's directory, with "~" for your home folder. Each message starts
# with a marker comment, "<!-- kiro · 12 -->": who wrote it, and its record (line) in
# the session's file. Tool calls and output, and Kiro's hidden reasoning, are left out.
#
# Sessions come from two stores. V3: <sessions>/<workspace>/<id>/session.json (title,
# directory, dates) and messages.jsonl (the conversation). V2: <sessions>/cli/<id>.json
# and <id>.jsonl. A V2 session resumed under V3 is copied by Kiro to the V3 store as
# cli_<V2 id>_<suffix>, with all of its history; the V2 original is then left out.
#
# Kiro only ever appends to a session's conversation file, so the index remembers how
# many bytes of each one it has read and later reads only what was added. Per session:
#   meta/<id>   one tab-separated row: id kind rel cwd updated_utc updated started
#               title store src (store is v2 or v3; src is Kiro's conversation file)
#   seen/<id>   the metadata file's modification time when meta/<id> was made
#   state/<id>  format, bytes read, checksums of the start and of the last 64 bytes
#               read, size of the copy, its location (rel), kind, and how many
#               records (lines) were read
# If a conversation file shrank, its start or read end changed, or the copy is not the
# size recorded (e.g. after an interrupted run), that session is rebuilt from scratch.
# ===========================================================================

# Session metadata -> index row. Every column is non-empty, because bash's read
# merges empty tab-separated columns. kind is "sub" for subagent sessions: ones
# another session started for a subagent. (V2's /rewind also creates child sessions,
# which are the user's own: "main".) rel is the copy's path without extension; "."
# and ".." in a directory can't escape the index folder. The short id in the name is
# the id's first 8 characters after V3's "sess_" or "cli_" prefix; a V2 session's V3
# copy (cli_<id>_<suffix>) keeps its suffix, so two copies never share a name.
cat > "$STATE/meta.jq" << 'JQ'
def nocontrol: tostring | explode | map(if . < 32 or . == 127 then 32 else . end) | implode;
def nonempty($d): if . == "" then $d else . end;
# Seconds since 1970 from an ISO 8601 time, with or without fractional seconds, and
# "Z", "+05:30", "-0800" or no zone (taken as UTC)
def epoch:
    tostring
    | capture("^(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})?$")
    | (.d + "Z" | fromdate)
      - (if .z == null or .z == "Z" then 0
         else (if .z[0:1] == "-" then -1 else 1 end) * ((.z[1:3] | tonumber) * 3600 + (.z[-2:] | tonumber) * 60) end);
def localtime($fmt): try (epoch | strflocaltime($fmt)) catch null;
def utc: (try (epoch | todate) catch null) // nocontrol;
def part: if . == "." then "_." elif . == ".." then "_.." else . end;
def short($id):
    ($id | capture("^cli_(?<u>[A-Za-z0-9.-]+)_(?<s>[A-Za-z0-9]+)$") | "\(.u[0:8])_\(.s)")
    // ($id | sub("^sess_"; "") | .[0:8]);
# V3 and V2 metadata, in the same terms
def fields($store):
    if $store == "v3" then
        {cwd: (.workspacePaths[0]? // .rootPaths[0]? // ""), created: (.createdAt // .lastModifiedAt // ""),
         updated: (.lastModifiedAt // .createdAt // ""), title: .title, sub: (.createdReason == "subagent")}
    else
        {cwd: (.cwd // ""), created: (.created_at // .updated_at // ""), updated: (.updated_at // .created_at // ""),
         title: .title, sub: ((.parent_session_id and .session_created_reason == "subagent") // false)}
    end;
def row($id; $store; $src):
    select(type == "object") | fields($store) as $m |
    ($m.cwd | nocontrol) as $cwd |
    ($m.created | tostring) as $c |
    ($m.updated | tostring) as $u |
    (if $cwd == "" then ["(no directory)"]
     elif $home != "" and ($cwd == $home or ($cwd | startswith($home + "/"))) then
         ["~"] + ($cwd[($home | length):] | split("/") | map(select(. != "") | part))
     else
         $cwd | split("/") | map(select(. != "") | part)
         | if length == 0 then ["(root)"] elif .[0] == "~" then ["_~"] + .[1:] else . end
     end) as $dir |
    ($c | localtime("%Y-%m-%d") // ($c | nocontrol | .[0:10]) | nonempty("0000-00-00")) as $day |
    [ $id,
      (if $m.sub then "sub" else "main" end),
      ($dir + ["\($day) #\(short($id))"] | join("/")),
      ($cwd | nonempty(".")),
      ($u | utc | nonempty("0")),
      ($u | localtime("%Y-%m-%d %H:%M") // ($u | nocontrol) | nonempty("unknown")),
      ($c | localtime("%Y-%m-%d %H:%M") // ($c | nocontrol) | nonempty("unknown")),
      ($m.title // "" | nocontrol | gsub("^ +| +$"; "") | nonempty("untitled")),
      $store,
      ($src | nocontrol)
    ] | join("\t");
# Input: one line per session, "<id>\t<store>\t<conversation file>\t<metadata on one
# line>". Output: its row, or "<id>\tBAD" if that is not a session (the old row is kept).
inputs | split("\t") as $f
| ($f[3:] | join("\t") | try fromjson catch null) as $j
| [$j | row($f[0]; $f[1]; $f[2])] | first // "\($f[0])\tBAD"
JQ

# Conversation file (raw lines, V2 or V3) -> the readable copy, as Markdown. Each
# message starts with a comment line saying who wrote it and which line of the file
# (the record) it came from: "<!-- kiro · 12 -->". Then its text, then a blank line.
# $base is how many records came before this input (when reading only what was added).
# $asker labels the prompts: "you", or "agent" in a subagent session, whose prompts
# come from the main Kiro rather than from you. A record that is not valid JSON is
# skipped. Control characters are removed: a NUL would make ripgrep treat the file as
# binary, and escape codes would garble the list. A text line that looks exactly like
# a marker gets a leading space, so it can't be mistaken for one. Left out: Kiro's
# hidden reasoning, tool calls and output, and in V3, Kiro's own bookkeeping, the
# copies of earlier messages it re-adds after a compaction (ids "compact_..."), and
# the "[LIVE STEERING" notes that repeat a message you sent while Kiro was working.
cat > "$STATE/extract.jq" << 'JQ'
def clean: gsub("[\u0000-\u0008\u000b-\u001f\u007f]"; "");
def message($role; $rec):
    "<!-- \($role) · \($rec) -->",
    (split("\n")[] | clean | if test("^<!-- [a-z]+ · [0-9]+ -->$") then " " + . else . end),
    "";
def v2($rec):
    if .kind == "Prompt" then
        .data.content[]? | select(.kind == "text") | .data | strings | message($asker; $rec)
    elif .kind == "AssistantMessage" then
        .data.content[]? | select(.kind == "text") | .data | strings | select(length > 0) | message("kiro"; $rec)
    elif .kind == "Compaction" then
        .data.summary | strings | message("summary"; $rec)
    else empty end;
def v3($rec):
    if (.id | tostring | startswith("compact_")) then empty
    else .payload | objects |
        if .type == "user" then
            .content | strings | select(length > 0 and (startswith("[LIVE STEERING") | not)) | message($asker; $rec)
        elif .type == "assistant" and (.operationType == "Say" or .operationType == null) then
            .content | strings | select(length > 0) | message("kiro"; $rec)
        elif .type == "assistant" and .operationType == "Summary" then
            .content | strings | message("summary"; $rec)
        else empty end
    end;
inputs | ($base + input_line_number) as $rec
| try (fromjson | objects | if has("payload") then v3($rec) else v2($rec) end) catch empty
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

my ($CACHE, $V2, $V3, $FORMAT, $HOME, $REINDEX, $JQ_META, $JQ_EXTRACT, $JOBS) = @ARGV;
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

# --- scan both stores -------------------------------------------------------------------
my (@ids, %size, %mtime, %metaf, %src, %store);
sub add_session {
    my ($id, $store, $meta, $data) = @_;
    return if exists $store{$id};
    my @j = Time::HiRes::stat($meta) or return;
    return unless -f $meta;
    push @ids, $id;
    ($store{$id}, $metaf{$id}, $src{$id}) = ($store, $meta, $data);
    $mtime{$id} = sprintf('%.9f', $j[9]);
    my @l = stat($data);
    $size{$id} = (@l && -f $data) ? $l[7] : undef;
}
my $ID = qr/^[A-Za-z0-9][A-Za-z0-9._-]*\z/;
# V3: <sessions>/<workspace>/<id>/. A cli_<V2 id>_<suffix> session is a V2 session
# Kiro copied over when it was resumed under V3; the V2 original is then skipped.
my %migrated;
if (opendir(my $top, $V3)) {
    for my $w (sort readdir $top) {
        next if $w =~ /^\./ || $w eq 'cli' || !-d "$V3/$w";
        opendir(my $wd, "$V3/$w") or next;
        for my $id (sort readdir $wd) {
            next unless $id =~ $ID && -f "$V3/$w/$id/session.json";
            add_session($id, 'v3', "$V3/$w/$id/session.json", "$V3/$w/$id/messages.jsonl");
            $migrated{$1} = 1 if $id =~ /^cli_([A-Za-z0-9.-]+)_[A-Za-z0-9]+\z/;
        }
        closedir $wd;
    }
    closedir $top;
}
# V2: <sessions>/cli/<id>.json and <id>.jsonl
if (opendir(my $dh, $V2)) {
    for my $f (sort readdir $dh) {
        next unless $f =~ /^([A-Za-z0-9][A-Za-z0-9._-]*)\.json\z/;
        next if $migrated{$1};
        add_session($1, 'v2', "$V2/$f", "$V2/$1.jsonl");
    }
    closedir $dh;
}

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
        my $c = slurp($metaf{$id});
        next unless defined $c;
        $c =~ tr/\r\n/  /;
        print $f "$id\t$store{$id}\t$src{$id}\t$c\n" or fail("cannot write to $CACHE");
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
        next unless @c == 10 && exists $mtime{$c[0]};
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
    my ($fmt, $off, undef, undef, undef, $oldrel, $oldkind) = state_of($id);
    my $current = defined $fmt && $fmt eq $FORMAT && num($off) && defined $oldkind && $oldkind eq $kind;
    next if $current && $off == $size{$id} && defined $oldrel && $oldrel eq $rel;
    my $left = ($current && $off <= $size{$id}) ? $size{$id} - $off : $size{$id};
    push @work, [$left, $id, $rel, $kind];
    $bytes += $left;
}
if ($bytes >= 1 << 20) {
    printf STDERR "rg-fzf-kiro: indexing %d session(s), %d MB...\n", scalar @work, $bytes >> 20;
}

# Brings one session's copy up to date. Returns 1 on success. On failure nothing is
# recorded, so the next run tries again (and rebuilds if needed).
sub index_one {
    my ($id, $rel, $kind) = @_;
    my $src = $src{$id};
    my $chat = "$TEXT/$rel.chat";
    my ($fmt, $off, $head, $tail, $csz, $oldrel, $oldkind, $recs) = state_of($id);
    open(my $in, '<:raw', $src) or return 0;
    my $size = (stat $in)[7];

    # Continue from where the last run stopped, if the file still starts and reads
    # the same up to there, and the copy is exactly as that run left it.
    my $append = defined $fmt && $fmt eq $FORMAT && num($off) && $off > 0 && $size >= $off
        && defined $oldkind && $oldkind eq $kind
        && defined $oldrel && length $oldrel
        && (sum_head($in, $off) // '-') eq ($head // '') && (sum_tail($in, $off) // '-') eq ($tail // '')
        && num($csz) && (fsize("$TEXT/$oldrel.chat") // -1) == $csz
        && num($recs);
    if ($append && $oldrel ne $rel && !same_file("$TEXT/$oldrel.chat", $chat)) {
        $append = ensure_dir($chat) && rename("$TEXT/$oldrel.chat", $chat);
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

    my $tc = "$TMP/$id.c";
    open(my $oc, '>:raw', $tc) or return 0;
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
        while (my $l = <$jq>) { print $oc $l or return 0 }
        close($jq) or return 0;
        unlink $cf;
    }
    close($oc) or return 0;

    # Commit: text first, then the state, so an interrupted run is caught by the size check
    if ($append) {
        append_file($tc, $chat) or return 0;
        unlink $tc;
    } else {
        ensure_dir($chat) && rename($tc, $chat) or return 0;
    }
    my $newoff = $off + $keep;
    my ($h, $t) = ('none', 'none');
    if ($newoff > 0) {
        ($h, $t) = (sum_head($in, $newoff), sum_tail($in, $newoff));
        return 0 unless defined $h && defined $t;
    }
    return put("$CACHE/state/$id",
        join("\t", $FORMAT, $newoff, $h, $t, fsize($chat) // 0, $rel, $kind, $recs + $added) . "\n");
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

# --- forget deleted sessions (and V2 originals that now have a V3 copy) ---------------
for my $sub (qw(meta seen state)) {
    opendir(my $d, "$CACHE/$sub") or next;
    for my $id (readdir $d) {
        next if $id eq '.' || $id eq '..';
        my $ok = exists $metaf{$id} && ($sub ne 'state' || defined $size{$id});
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
    push @rows, [$r, \@c] if @c == 10;
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
    next unless defined $size{$id};
    my $p = "$TEXT/$rel.chat";
    $keep{$p} = 1;
    my @s = stat $p;
    $keep_id{"$s[0]:$s[1]"} = 1 if @s;
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
perl "$STATE/indexer.pl" "$CACHE" "$V2DIR" "$SESSIONS" "$FORMAT" "$HOME_DIR" "$REINDEX" \
    "$STATE/meta.jq" "$STATE/extract.jq" "$JOBS" || exit 1

[[ $INDEX_ONLY == 1 ]] && exit 0

# Piped sessions: one per line, or NUL-separated if the list contains a NUL. Each can
# be a readable copy (what Enter prints), a session id, or one of Kiro's files or
# folders for the session (V2: cli/<id>.jsonl, .json...; V3: <id>/ and the files in
# it). A V2 session that now has a V3 copy is found by its V2 id too. Each must be in
# the index. Saved as " id id ... " in $STATE/only.
if [[ $PIPED == 1 ]]; then
    read -r ok bad < <(perl -e '
        my ($raw, $index, $text, $out) = @ARGV;
        my %known;    # every name of a session -> its id
        open(my $i, "<", $index) or exit 1;
        while (<$i>) {
            chomp;
            my @c = split /\t/;
            my ($id, $rel, $src) = @c[0, 2, 9];
            $known{$_} = $id for $id, "$rel.chat", "$text/$rel.chat", $src;
            $known{$1} = $id if $id =~ /^cli_([A-Za-z0-9.-]+)_[A-Za-z0-9]+\z/;
        }
        open(my $r, "<:raw", $raw) or exit 1;
        my $d = do { local $/; <$r> } // "";
        my ($bad, %ok, @order) = (0);
        for (split($d =~ /\0/ ? qr/\0/ : qr/\n/, $d)) {
            s/^\s+|\s+\z//g;
            next if $_ eq "";
            (my $e = $_) =~ s{/+\z}{};
            my $id = $known{$e};
            unless (defined $id) {
                my @p = split m{/}, $e;
                (my $base = $p[-1] // "") =~ s/\.[^.]*\z//;
                $id = $known{$base} // $known{$p[-1] // ""} // (@p > 1 ? $known{$p[-2]} : undef);
            }
            if (defined $id) { push @order, $id unless $ok{$id}++ } else { $bad++ }
        }
        open(my $o, ">", $out) or exit 1;
        print $o " ", join(" ", @order), " ";
        print scalar(@order), " $bad\n";
    ' "$STATE/raw" "$INDEX" "$TEXT" "$STATE/only")
    rm -f "$STATE/raw"
    [[ ${ok:-0} == 0 && ${bad:-0} == 0 ]] && die "no sessions given on stdin"
    [[ ${ok:-0} == 0 ]] && die "none of the sessions given on stdin are known"
    [[ $bad -gt 0 ]] && echo "rg-fzf-kiro: skipped $bad unknown session(s) from stdin" >&2
fi

[[ $SHOW_V2 == 1 ]] && touch "$STATE/v2"
if [[ $SHOW_V2 == 0 && $PIPED == 0 ]] &&
    ! awk -F '\t' '$9 == "v3" { found = 1; exit } END { exit !found }' "$INDEX"; then
    echo "rg-fzf-kiro: no V3 sessions yet; --v2 shows your V2 sessions" >&2
fi

# ===========================================================================
# Interactive picker. Same design as rg-fzf: result lines are FILE, LINE,
# COLUMN and TEXT joined by NUL + ':', so the fields split exactly.
# ===========================================================================

HEADER_CHAT='C-e:edit | C-o:lines | M-enter:json | C-f:sessions | M-g:live | M-s:subagents | M-u:unique | M-r:role | M-p:pcre2 | M-/:keys'
HEADER_SESSIONS='C-e:edit | C-o:lines | M-enter:json | C-f:chat | M-g:live | M-s:subagents | M-u:unique | M-r:role | M-p:pcre2 | M-/:keys'

# Picker state in $STATE: content-q and file-q hold the saved query of each mode;
# live, sub, pcre2 and unique exist while that toggle is on; role holds "you" or
# "kiro" while Alt-R limits whose messages show; v2 exists with --v2; only holds the
# piped session ids; listing exists while the list shows sessions (empty query)
# rather than matching lines; in-sessions exists while the session filter is active;
# nonum exists while preview line numbers are off. rg-fzf-kiro-keybindings.txt is
# the read-only keybinding list that Alt-/ opens.
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
);
our $MARKER = qr/^<!-- (you|agent|kiro|summary) \x{c2}\x{b7} ([0-9]+) -->$/;
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
# comments themselves. Then, while Alt-R is on, drops rows not written by that role,
# and while Alt-U is on, rows of a session already shown. Only the displayed text
# changes; the copy is untouched.
cat > "$STATE/color-rows.pl" << 'PERL'
my ($roles, $state) = @ARGV;
require $roles;
our (%ROLE);
my $unique = -e "$state/unique";
my $want = "";
if (open(my $r, '<', "$state/role")) { $want = <$r> // ""; chomp $want }
my $allowed = { you => { you => 1 }, kiro => { kiro => 1, summary => 1 } }->{$want};
my %seen;
$| = 1;
while (my $l = <STDIN>) {
    my @f = split /\0:/, $l, 4;
    next unless @f == 4;
    my ($path, $n) = @f[0, 1];
    s/\e\[[0-9;]*m//g for $path, $n;
    my $m = mark_at(marks_of($path), $n);
    next if $m && $m->[0] == $n;
    next if $allowed && !($m && $allowed->{$m->[1]});
    if ($unique) {
        next if $seen{$path}++;
    }
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
my @shown;    # stays empty (lines shown plain) if bat fails on this text
{
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
                          updated_at: .[4], updated: .[5], started: .[6], title: .[7],
                          store: .[8], session_file: .[9]}}) | from_entries) as $sessions
| ($live | split(" ") | map(select(length > 0) | split(":") | {key: .[0], value: (.[1] | tonumber)}) | from_entries) as $pids
| {query: $query}
+ (if $filter != "" then {session_filter: $filter} else {} end)
+ {results: [inputs | split("\u0001") as $f
    | ($f[0] | sub("\\.chat$"; "")) as $rel
    | $sessions[$rel] as $s | select($s != null)
    | {session_id: $s.session_id, title: $s.title, directory: $s.directory, store: $s.store,
       resume: "cd \($s.directory | @sh) && kiro-cli chat --\($s.store) --resume-id \($s.session_id | @sh)",
       live: ($pids[$s.session_id] != null), pid: $pids[$s.session_id],
       subagent: $s.subagent, started: $s.started, updated: $s.updated, updated_at: $s.updated_at,
       session_file: $s.session_file}
      + (if $listing == "1" then {} else
          {copy: "\($text_dir)/\($f[0])", line: ($f[1] | tonumber), column: ($f[2] | tonumber),
           record: (if $f[4] == "" then null else $f[4] | tonumber end),
           role: (if $f[3] == "" then null else $f[3] end), text: ($f[5:] | join("\u0001"))}
         end)]}
JQ

# Both helpers start with the paths they need and how to read Kiro's lock files
helper_header() {
    echo '#!/bin/bash'
    printf 'S=%q\nV2DIR=%q\nV3DIR=%q\nTEXT=%q\nINDEX=%q\n' "$STATE" "$V2DIR" "$SESSIONS" "$TEXT" "$INDEX"
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

# While a kiro-cli has a session open, Kiro writes {"pid": N, ...} to a lock file:
# cli/<id>.lock for V2, <workspace>/<id>/.lock for V3.
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
    for lock in "$V2DIR"/*.lock "$V3DIR"/*/*/.lock; do
        [[ -f $lock ]] || continue
        read_lock_pid "$lock" || continue
        kill -0 "$LOCK_PID" 2> /dev/null || continue
        if [[ $lock == */.lock ]]; then
            id=${lock%/.lock}
            id=${id##*/}
        else
            id=${lock##*/}
            id=${id%.lock}
        fi
        ids+=("$id")
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
# Piped sessions, " id id ... ": only these are searched, whatever their store or kind
ONLY=$(cat "$S/only" 2>/dev/null)
SHOW_V2=0
[[ -f $S/v2 ]] && SHOW_V2=1
# Whether a session (id, kind, store) is listed: piped sessions are exactly the ones
# named; otherwise subagent sessions need Alt-S, and V2 sessions need --v2
keep() {
    if [[ -n $ONLY ]]; then
        [[ $ONLY == *" $1 "* ]]
        return
    fi
    [[ $2 == sub && ! -f $S/sub ]] && return 1
    [[ $3 == v2 && $SHOW_V2 == 0 ]] && return 1
    return 0
}
LIVE=" "
[[ -z $Q || $LIVE_ONLY == 1 ]] && live_scan
cd "$TEXT" || exit 0

if [[ -z $Q ]]; then
    touch "$S/listing"
    while IFS=$'\t' read -r id kind rel _ _ updated _ _ store _; do
        keep "$id" "$kind" "$store" || continue
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
while IFS=$'\t' read -r id kind rel _ _ _ _ _ store _; do
    keep "$id" "$kind" "$store" || continue
    [[ $LIVE_ONLY == 1 && $LIVE != *" $id:"* ]] && continue
    [[ -s $rel.chat ]] && printf '%s\0' "$rel.chat"
done < "$INDEX" | if [[ -n $FILE_Q ]]; then
    fzf --filter "$FILE_Q" --read0 --print0 --no-sort
else
    cat
fi | xargs -0 -r rg -j1 --engine "$ENGINE" --ignore-case --column --line-number --no-heading \
    --color=always --with-filename --field-match-separator '\x00:' --max-columns 500 \
    --max-columns-preview -e "$Q" -- 2> /dev/null | perl "$COLOR_ROWS" "$ROLES" "$S"
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
# Result file name ("<rel>.chat") -> session row.
# Sets id kind cwd updated started title store.
row_of_file() {
    local line
    line=$(B="${1%.*}" awk -F '\t' '$3 == ENVIRON["B"] { print; exit }' "$INDEX")
    [[ -n $line ]] || return 1
    IFS=$'\t' read -r id kind _ cwd _ updated started title store _ <<< "$line"
}

# Prompt: mode, how the typed text is matched, then active toggles.
# The session filter is always fuzzy, so PCRE2 being on shows as a [P] flag there.
prompt() {
    local how=regex flags=""
    [[ -f $S/pcre2 ]] && how=pcre2
    [[ -f $S/live ]] && flags+="L"
    [[ -f $S/sub ]] && flags+="S"
    [[ -f $S/unique ]] && flags+="U"
    if [[ $1 == Sessions ]]; then
        [[ $how == pcre2 ]] && flags+="P"
        how=fuzzy
    fi
    [[ -n $flags ]] && flags=" [$flags]"
    [[ -s $S/role ]] && flags+=" [R:$(cat "$S/role")]"
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
    toggle-live|toggle-sub|toggle-pcre2|toggle-unique)
        f="$S/${1#toggle-}"
        if [[ -f $f ]]; then rm -f "$f"; else touch "$f"; fi
        echo "change-prompt($(prompt $MODE))+$RELOAD"
        ;;
    cycle-role)
        # everyone -> you -> kiro -> everyone
        case $(cat "$S/role" 2>/dev/null) in
            "") echo you > "$S/role" ;;
            you) echo kiro > "$S/role" ;;
            *) rm -f "$S/role" ;;
        esac
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
        [[ $store == v2 ]] && kindnote+="  (v2)"
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
                --arg text_dir "$TEXT" --rawfile index "$INDEX" -f "$JSON_JQ"
        ;;
esac
SCRIPT
} > "$ACTIONS"

chmod +x "$SEARCH" "$ACTIONS"
cd "$TEXT" || die "cannot open $TEXT"

# fzf prints the query, the key that closed it (empty for Enter), then the selected
# lines. Enter: the full paths of those lines' readable copies, each once, in
# session-list order (most recently updated first), one per line or NUL-separated
# with -0; only copies in the index are printed. Ctrl-O:
# the lines as file:line:column:text, with the NUL separators removed (LC_ALL=C keeps
# any byte intact). Alt-Enter: JSON.
print_selection() {
    local query key filter=""
    IFS= read -r query || return 0
    IFS= read -r key || return 0
    if [[ -z $key ]]; then
        LC_ALL=C perl -e '
            my ($index, $text, $nul) = @ARGV;
            my $sep = $nul ? "\0" : "\n";
            my %want;
            while (my $l = <STDIN>) {
                my ($f) = split /\0:/, $l, 2;
                $f =~ s/\e\[[0-9;]*m//g;
                $f =~ s/\.chat\z//;
                $want{$f} = 1;
            }
            open(my $i, "<", $index) or exit 1;
            while (<$i>) {
                my (undef, undef, $rel) = split /\t/;
                print "$text/$rel.chat$sep" if delete $want{$rel};
            }' "$INDEX" "$TEXT" "$NUL_OUT"
        return
    fi
    if [[ $key == ctrl-o ]]; then
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
  --expect alt-enter,ctrl-o \
  --print-query \
  --prompt 'Chat (regex)> ' \
  --header "$HEADER_CHAT" \
  --bind "start:reload:'$SEARCH' ''" \
  --bind "change:transform:'$ACTIONS' query-changed" \
  --bind "ctrl-f:transform:'$ACTIONS' switch-mode" \
  --bind "alt-g:transform:'$ACTIONS' toggle-live" \
  --bind "alt-s:transform:'$ACTIONS' toggle-sub" \
  --bind "alt-p:transform:'$ACTIONS' toggle-pcre2" \
  --bind "alt-u:transform:'$ACTIONS' toggle-unique" \
  --bind "alt-r:transform:'$ACTIONS' cycle-role" \
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
  --preview-window 'up,60%,border-bottom,+{2}+6/3,~6' < /dev/null | print_selection
