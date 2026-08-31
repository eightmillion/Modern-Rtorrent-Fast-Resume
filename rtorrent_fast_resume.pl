#!/usr/bin/env perl

use strict;
use warnings;

BEGIN {
    if (eval { require Convert::Bencode_XS; 1 }) {
        Convert::Bencode_XS->import(qw(bencode bdecode));
    }
    elsif (eval { require Convert::Bencode; 1 }) {
        Convert::Bencode->import(qw(bencode bdecode));
    }
    else {
        die "ERROR: install either Convert::Bencode_XS or Convert::Bencode\n";
    }
}

use File::Basename qw(basename);
use File::Copy qw(copy);
use File::Path qw(make_path);
use File::Spec;
use Getopt::Long qw(GetOptions);
use POSIX qw(strftime);

$| = 1;

my $program = basename($0);

my $mapping;
my $data_dir;
my $session;
my $dry_run       = 0;
my @only_hashes;
my $priority;
my $set_directory = 0;
my $start          = 0;
my $backup         = 1;
my $backup_dir;
my $strict         = 0;
my $quiet          = 0;
my $verbose        = 0;
my $help           = 0;
my $path_mode      = 'auto';
my $progress_opt;              # undef = automatic (TTY only)

my @failure_records;
my $progress_active    = 0;
my $progress_total     = 0;
my $progress_done      = 0;
my $progress_interval  = 1;
my $progress_line_len  = 0;

GetOptions(
    'mapping|m=s'     => \$mapping,
    'data-dir|d=s'    => \$data_dir,
    'session|s=s'     => \$session,
    'dry-run|n'       => \$dry_run,
    'hash=s@'         => \@only_hashes,
    'priority=i'      => \$priority,
    'set-directory'   => \$set_directory,
    'start'           => \$start,
    'backup!'         => \$backup,
    'backup-dir=s'    => \$backup_dir,
    'path-mode=s'     => \$path_mode,
    'strict'          => \$strict,
    'quiet|q'         => \$quiet,
    'verbose|v+'      => \$verbose,
    'progress!'       => \$progress_opt,
    'help|h'          => \$help,
) or usage(2);

usage(0) if $help;

die "ERROR: --session is required\n\n" . usage_text()
    unless defined $session && length $session;

if (@ARGV > 1) {
    die "ERROR: expected at most one mapping file argument\n\n" . usage_text();
}

if (@ARGV == 1) {
    die "ERROR: mapping file was specified both positionally and with --mapping\n"
        if defined $mapping;
    $mapping = $ARGV[0];
}

my $have_mapping  = defined($mapping)  && length($mapping);
my $have_data_dir = defined($data_dir) && length($data_dir);

# If neither a mapping file nor --data-dir is supplied, paths are read
# from each HASH.torrent.rtorrent sidecar. This is the default mode.
die "ERROR: mapping-file mode and --data-dir are mutually exclusive\n"
    if $have_mapping && $have_data_dir;

$path_mode = normalize_mode($path_mode);
die "ERROR: --path-mode must be auto, directory, or directory-base\n"
    unless defined $path_mode;

die "ERROR: --session '$session' is not a directory\n"
    unless -d $session;

if ($have_mapping) {
    die "ERROR: mapping file '$mapping' does not exist\n"
        unless -f $mapping;
}

if ($have_data_dir) {
    die "ERROR: data directory '$data_dir' is not a directory\n"
        unless -d $data_dir;
}

if (defined $priority && ($priority < 0 || $priority > 2)) {
    die "ERROR: --priority must be 0, 1, or 2\n";
}

$session  = File::Spec->rel2abs($session);
$mapping  = File::Spec->rel2abs($mapping)  if $have_mapping;
$data_dir = File::Spec->rel2abs($data_dir) if $have_data_dir;

if ($backup) {
    $backup_dir = defined($backup_dir) && length($backup_dir)
        ? File::Spec->rel2abs($backup_dir)
        : $session . '.fastresume-backups';
}

my $backup_run_dir;
my $backup_stamp = strftime('%Y%m%d-%H%M%S', localtime) . "-$$";

my %wanted_hash;
for my $arg (@only_hashes) {
    for my $hash (split /,/, $arg) {
        $hash =~ s/^\s+|\s+$//g;
        $hash = uc $hash;

        die "ERROR: invalid --hash '$hash'\n"
            unless $hash =~ /^[0-9A-F]{40}$/;

        $wanted_hash{$hash} = 1;
    }
}

print "Session: $session\n" unless $quiet;
if (!$quiet) {
    if ($have_mapping) {
        print "Mapping: $mapping\n";
    }
    elsif ($have_data_dir) {
        print "Data:    $data_dir\n";
    }
    else {
        print "Data:    session sidecars\n";
    }
}
print "Paths:   $path_mode\n" unless $quiet;
print "Backup:  " . ($backup ? "$backup_dir/$backup_stamp" : 'disabled') . "\n"
    unless $quiet || $dry_run;
print "Mode:    DRY RUN\n" if $dry_run && !$quiet;
print "\n" unless $quiet;

my %seen;
my $mapping_lines = 0;
my $updated       = 0;
my $failed        = 0;
my $skipped       = 0;

if ($have_mapping) {
    progress_init(count_mapping_items($mapping));

    open my $mapfh, '<', $mapping
        or die "ERROR: cannot read '$mapping': $!\n";

    while (my $line = <$mapfh>) {
        $mapping_lines++;

        chomp $line;
        $line =~ s/\r$//;

        next if $line =~ /^\s*$/;
        next if $line =~ /^\s*#/;

        my @parts = split /\|/, $line, 3;
        my ($hash, $line_mode, $path);

        if (@parts == 2) {
            ($hash, $path) = @parts;
            $line_mode = $path_mode;
        }
        elsif (@parts == 3) {
            ($hash, $line_mode, $path) = @parts;
            $line_mode = normalize_mode($line_mode);

            unless (defined $line_mode && $line_mode ne 'auto') {
                handle_failure(
                    "line $mapping_lines",
                    "explicit mapping mode must be directory or directory_base"
                );
                progress_step();
                next;
            }
        }
        else {
            handle_failure(
                "line $mapping_lines",
                "invalid mapping line (expected HASH|PATH or HASH|MODE|PATH)"
            );
            progress_step();
            next;
        }

        $hash =~ s/^\s+|\s+$//g;
        $path =~ s/^\s+|\s+$//g;
        $hash = uc $hash;

        unless ($hash =~ /^[0-9A-F]{40}$/) {
            handle_failure("line $mapping_lines", "invalid hash '$hash'");
            progress_step();
            next;
        }

        unless (length $path) {
            handle_failure($hash, "empty path");
            progress_step();
            next;
        }

        if (%wanted_hash && !$wanted_hash{$hash}) {
            $skipped++;
            progress_step();
            next;
        }

        my $identity = "$line_mode\0$path";
        if (exists $seen{$hash}) {
            if ($seen{$hash} eq $identity) {
                print "$hash SKIPPED - duplicate mapping\n" if $verbose && !$quiet;
                $skipped++;
                progress_step();
                next;
            }

            handle_failure($hash, "duplicate hash has conflicting mappings");
            progress_step();
            next;
        }

        $seen{$hash} = $identity;
        run_one($hash, $line_mode, $path);
    }

    close $mapfh;
}
else {
    opendir my $dh, $session
        or die "ERROR: cannot open session directory '$session': $!\n";

    my @hashes;

    while (defined(my $entry = readdir $dh)) {
        next unless $entry =~ /^([0-9A-Fa-f]{40})\.torrent$/;

        my $hash = uc($1);
        my $torrent_file = File::Spec->catfile($session, $entry);

        next unless -f $torrent_file;
        push @hashes, $hash;
    }

    @hashes = sort @hashes;

    closedir $dh;

    die "ERROR: no HASH.torrent files found in '$session'\n"
        unless @hashes;

    my @selected_hashes = %wanted_hash
        ? grep { $wanted_hash{$_} } @hashes
        : @hashes;

    progress_init(scalar @selected_hashes);

    for my $hash (@selected_hashes) {

        if ($have_data_dir) {
            $seen{$hash} = "$path_mode\0$data_dir";
            run_one($hash, $path_mode, $data_dir);
            next;
        }

        my $rt_file = File::Spec->catfile($session, "$hash.torrent.rtorrent");

        my $ok = eval {
            die "rtorrent sidecar missing: $rt_file"
                unless -f $rt_file;

            my $rt = read_bencode($rt_file);

            die "rtorrent sidecar is not a dictionary: $rt_file"
                unless ref($rt) eq 'HASH';

            my ($saved_path, $saved_mode);

            # Prefer an explicitly stored directory_base if this rTorrent
            # build/session format provides one. Otherwise use directory.
            if (defined($rt->{directory_base}) && length($rt->{directory_base})) {
                $saved_path = $rt->{directory_base};
                $saved_mode = 'directory-base';
            }
            elsif (defined($rt->{directory}) && length($rt->{directory})) {
                $saved_path = $rt->{directory};

                # Different rTorrent/session generations have used directory
                # with slightly different practical semantics. Auto mode
                # safely tests both layouts unless the user forced a mode.
                $saved_mode = $path_mode eq 'auto' ? 'auto' : $path_mode;
            }
            else {
                die "no usable directory or directory_base in session sidecar; use --data-dir or a mapping file";
            }

            $saved_path = File::Spec->rel2abs($saved_path);
            $seen{$hash} = "$saved_mode\0$saved_path";

            print "$hash session-path=$saved_path\n"
                if $verbose && !$quiet;

            run_one($hash, $saved_mode, $saved_path);
            1;
        };

        if (!$ok) {
            my $error = $@ || 'unknown error';
            $error =~ s/\s+$//;
            handle_failure($hash, $error);
            progress_step();
        }
    }
}

progress_finish();

if (%wanted_hash) {
    for my $hash (sort keys %wanted_hash) {
        next if exists $seen{$hash};
        handle_failure(
            $hash,
            $have_mapping
                ? "requested hash was not found in the mapping file"
                : "requested hash was not found in the session directory"
        );
    }
}

print "\n" unless $quiet;
print "Finished: $updated " . ($dry_run ? "validated" : "updated") .
      ", $failed failed, $skipped skipped\n";
print "Backups: $backup_run_dir\n"
    if !$quiet && !$dry_run && defined $backup_run_dir;

if (@failure_records) {
    print STDERR "\nFailures:\n";
    for my $failure (@failure_records) {
        my ($label, $message) = @$failure;
        print STDERR "  $label - $message\n";
    }
}

exit($failed ? 1 : 0);


sub run_one {
    my ($hash, $mode, $path) = @_;

    my $ok = eval {
        process_torrent($hash, $mode, $path);
        1;
    };

    if (!$ok) {
        my $error = $@ || 'unknown error';
        $error =~ s/\s+$//;
        handle_failure($hash, $error);
        progress_step();
        return;
    }

    $updated++;
    progress_step();
}


sub process_torrent {
    my ($hash, $requested_mode, $mapped_path) = @_;

    my $torrent_file = File::Spec->catfile($session, "$hash.torrent");
    my $resume_file  = "$torrent_file.libtorrent_resume";
    my $rt_file      = "$torrent_file.rtorrent";

    die "torrent file missing: $torrent_file"
        unless -f $torrent_file;

    my $torrent = read_bencode($torrent_file);

    die "torrent has no info dictionary"
        unless ref($torrent) eq 'HASH' && ref($torrent->{info}) eq 'HASH';

    my $info = $torrent->{info};

    my $name = $info->{name};
    die "torrent has no name"
        unless defined $name && length $name;

    my $piece_size = $info->{'piece length'};
    die "torrent has no valid piece length"
        unless defined $piece_size && $piece_size > 0;

    my @entries;
    my $total_size = 0;
    my $multi = exists $info->{files};

    if ($multi) {
        die "torrent files key is not a list"
            unless ref($info->{files}) eq 'ARRAY';

        for my $file (@{$info->{files}}) {
            die "torrent contains an invalid file entry"
                unless ref($file) eq 'HASH'
                    && exists $file->{length}
                    && ref($file->{path}) eq 'ARRAY';

            die "torrent contains a negative file length"
                if $file->{length} < 0;

            my @path = @{$file->{path}};
            die "torrent contains an empty file path"
                unless @path;

            push @entries, {
                length => $file->{length},
                rel    => File::Spec->catfile(@path),
            };

            $total_size += $file->{length};
        }
    }
    else {
        die "single-file torrent has no length"
            unless exists $info->{length};

        die "torrent contains a negative file length"
            if $info->{length} < 0;

        push @entries, {
            length => $info->{length},
            rel    => $name,
        };

        $total_size = $info->{length};
    }

    my $chunks = $total_size
        ? int(($total_size + $piece_size - 1) / $piece_size)
        : 0;

    die "torrent has no pieces string"
        unless exists $info->{pieces};

    my $piece_bytes = length($info->{pieces});
    die "inconsistent piece information: expected " . ($chunks * 20) .
        " bytes, found $piece_bytes"
        if $piece_bytes != $chunks * 20;

    my ($resolved_mode, @disk_paths) = resolve_torrent_layout(
        mode    => $requested_mode,
        mapped  => $mapped_path,
        name    => $name,
        multi   => $multi,
        entries => \@entries,
    );

    print "$hash $name [$resolved_mode]\n" if $verbose && !$quiet;
    print "  mapped=$mapped_path\n" if $verbose && !$quiet;
    print "  size=$total_size piece_length=$piece_size pieces=$chunks files=" .
          scalar(@entries) . "\n"
        if $verbose && !$quiet;

    my @disk_files;
    my $offset = 0;

    for my $index (0 .. $#entries) {
        my $disk_path = $disk_paths[$index];
        my @stat = stat($disk_path);

        die "cannot stat '$disk_path': $!"
            unless @stat;

        my $actual_size   = $stat[7];
        my $expected_size = $entries[$index]{length};

        die "wrong size: $disk_path (disk=$actual_size torrent=$expected_size)"
            if $actual_size != $expected_size;

        my $file_chunks = pieces_touching_file($offset, $expected_size, $piece_size);

        push @disk_files, {
            path      => $disk_path,
            mtime     => $stat[9],
            completed => $file_chunks,
        };

        print "  [$index] completed=$file_chunks mtime=$stat[9] $disk_path\n"
            if $verbose && !$quiet;

        $offset += $expected_size;
    }

    die "internal size accounting error ($offset != $total_size)"
        if $offset != $total_size;

    my $resume = -f $resume_file ? read_bencode($resume_file) : {};
    my $rt     = -f $rt_file     ? read_bencode($rt_file)     : {};

    die "resume sidecar is not a dictionary: $resume_file"
        unless ref($resume) eq 'HASH';

    die "rtorrent sidecar is not a dictionary: $rt_file"
        unless ref($rt) eq 'HASH';

    $resume->{bitfield} = $chunks;

    my @resume_files;
    my $existing_files = ref($resume->{files}) eq 'ARRAY'
        ? $resume->{files}
        : [];

    for my $index (0 .. $#entries) {
        my $file_resume = ref($existing_files->[$index]) eq 'HASH'
            ? { %{$existing_files->[$index]} }
            : {};

        my $file_priority;

        if (defined $priority) {
            $file_priority = $priority;
        }
        elsif (exists $file_resume->{priority}) {
            $file_priority = $file_resume->{priority};
        }
        else {
            $file_priority = 1;
        }

        $file_resume->{priority}  = $file_priority;
        $file_resume->{mtime}     = $disk_files[$index]{mtime};
        $file_resume->{completed} = $disk_files[$index]{completed};

        push @resume_files, $file_resume;
    }

    $resume->{files} = \@resume_files;
    $resume->{'uncertain_pieces.timestamp'} = time;

    $rt->{chunks_wanted} = 0;
    $rt->{chunks_done}   = $chunks;
    $rt->{complete}      = 1;
    $rt->{hashing}       = 0;

    if ($set_directory) {
        $rt->{directory} = resolved_rtorrent_directory(
            mode   => $resolved_mode,
            mapped => $mapped_path,
            name   => $name,
            multi  => $multi,
        );
    }

    if ($start) {
        my $now = time;

        $rt->{state}         = 1;
        $rt->{state_changed} = $now;

        my $counter = defined($rt->{state_counter})
                   && $rt->{state_counter} =~ /^\d+$/
            ? $rt->{state_counter}
            : 0;

        $rt->{state_counter} = $counter + 1;
        $rt->{'timestamp.started'} = $now;
        $rt->{'timestamp.finished'} = 0
            unless exists $rt->{'timestamp.finished'};
    }

    if ($dry_run) {
        print "$hash OK - $chunks pieces (dry-run)\n"
            unless $quiet || $progress_active;
        return;
    }

    if ($backup) {
        # Keep a self-contained backup set for each torrent, even though the
        # .torrent metainfo itself is not modified by this script.
        backup_file($torrent_file) if -e $torrent_file;
        backup_file($resume_file)  if -e $resume_file;
        backup_file($rt_file)      if -e $rt_file;
    }

    atomic_write($resume_file, bencode($resume));
    atomic_write($rt_file,     bencode($rt));

    print "$hash OK - $chunks pieces\n"
        unless $quiet || $progress_active;
}


sub resolve_torrent_layout {
    my %arg = @_;

    my @modes = $arg{mode} eq 'auto'
        ? ('directory-base', 'directory')
        : ($arg{mode});

    my @valid;
    my @errors;

    for my $mode (@modes) {
        my @paths = build_payload_paths(
            mode    => $mode,
            mapped  => $arg{mapped},
            name    => $arg{name},
            multi   => $arg{multi},
            entries => $arg{entries},
        );

        my @missing = grep { !-f $_ } @paths;

        if (!@missing) {
            push @valid, [$mode, \@paths];
        }
        else {
            push @errors, "$mode: missing $missing[0]";
        }
    }

    if (@valid == 1) {
        return ($valid[0][0], @{$valid[0][1]});
    }

    if (@valid > 1) {
        # Auto mode deliberately tests directory-base first. If both layouts
        # happen to exist, prefer directory-base rather than refusing to
        # continue. This treats the supplied/session path itself as the
        # torrent root and avoids unnecessarily appending the torrent name.
        return ($valid[0][0], @{$valid[0][1]});
    }

    die "cannot resolve payload path (" . join('; ', @errors) . ")";
}


sub build_payload_paths {
    my %arg = @_;

    my @paths;

    for my $entry (@{$arg{entries}}) {
        if ($arg{multi}) {
            if ($arg{mode} eq 'directory-base') {
                push @paths, File::Spec->catfile($arg{mapped}, $entry->{rel});
            }
            else {
                push @paths, File::Spec->catfile($arg{mapped}, $arg{name}, $entry->{rel});
            }
        }
        else {
            if ($arg{mode} eq 'directory-base') {
                # Accept either the payload file itself or its containing dir.
                if (-f $arg{mapped}) {
                    push @paths, $arg{mapped};
                }
                else {
                    push @paths, File::Spec->catfile($arg{mapped}, $arg{name});
                }
            }
            else {
                push @paths, File::Spec->catfile($arg{mapped}, $arg{name});
            }
        }
    }

    return @paths;
}


sub resolved_rtorrent_directory {
    my %arg = @_;

    # Keep the user's selected mapping semantics. For multi-file torrents,
    # directory-base already points at the torrent's payload root; directory
    # points at its parent. For single-file torrents both normally resolve to
    # the containing directory.
    if ($arg{multi} && $arg{mode} eq 'directory') {
        return File::Spec->rel2abs(File::Spec->catdir($arg{mapped}, $arg{name}));
    }

    if (!$arg{multi} && -f $arg{mapped}) {
        my ($vol, $dirs, undef) = File::Spec->splitpath(File::Spec->rel2abs($arg{mapped}));
        return File::Spec->catpath($vol, $dirs, '');
    }

    return File::Spec->rel2abs($arg{mapped});
}


sub pieces_touching_file {
    my ($offset, $length, $piece_size) = @_;

    return 0 if $length == 0;

    my $first_piece = int($offset / $piece_size);
    my $last_piece  = int(($offset + $length - 1) / $piece_size);

    return $last_piece - $first_piece + 1;
}


sub normalize_mode {
    my ($mode) = @_;
    return unless defined $mode;

    $mode =~ s/^\s+|\s+$//g;
    $mode = lc $mode;
    $mode =~ tr/_/-/;

    return 'auto'           if $mode eq 'auto';
    return 'directory'      if $mode eq 'directory';
    return 'directory-base' if $mode eq 'directory-base';
    return;
}


sub read_bencode {
    my ($file) = @_;

    open my $fh, '<', $file
        or die "cannot read '$file': $!";

    binmode $fh;
    local $/;
    my $data = <$fh>;

    close $fh
        or die "cannot close '$file' after reading: $!";

    my $decoded = eval { bdecode($data) };
    if ($@) {
        my $error = $@;
        $error =~ s/\s+$//;
        die "cannot decode '$file': $error";
    }

    return $decoded;
}


sub atomic_write {
    my ($file, $data) = @_;

    my $tmp = "$file.tmp.$$";

    my ($mode, $uid, $gid);
    if (-e $file) {
        my @stat = stat($file);
        if (@stat) {
            $mode = $stat[2] & 07777;
            $uid  = $stat[4];
            $gid  = $stat[5];
        }
    }

    open my $fh, '>', $tmp
        or die "cannot write temporary file '$tmp': $!";

    binmode $fh;

    print {$fh} $data
        or die "cannot write temporary file '$tmp': $!";

    close $fh
        or die "cannot close temporary file '$tmp': $!";

    chmod $mode, $tmp if defined $mode;
    chown $uid, $gid, $tmp if $> == 0 && defined $uid && defined $gid;

    rename $tmp, $file
        or die "cannot replace '$file' with '$tmp': $!";
}


sub backup_file {
    my ($file) = @_;

    unless (defined $backup_run_dir) {
        $backup_run_dir = File::Spec->catdir($backup_dir, $backup_stamp);
        make_path($backup_run_dir)
            or die "cannot create backup directory '$backup_run_dir': $!";
    }

    my $dest = File::Spec->catfile($backup_run_dir, basename($file));

    die "backup destination already exists: $dest"
        if -e $dest;

    copy($file, $dest)
        or die "cannot back up '$file' to '$dest': $!";

    my @stat = stat($file);
    if (@stat) {
        chmod($stat[2] & 07777, $dest);
        chown($stat[4], $stat[5], $dest) if $> == 0;
        utime($stat[8], $stat[9], $dest);
    }

    print "  backup: $dest\n" if $verbose && !$quiet;
}


sub count_mapping_items {
    my ($file) = @_;

    open my $fh, '<', $file
        or die "ERROR: cannot read '$file': $!\n";

    my $count = 0;

    while (my $line = <$fh>) {
        $line =~ s/\r?\n$//;
        next if $line =~ /^\s*$/;
        next if $line =~ /^\s*#/;
        $count++;
    }

    close $fh
        or die "ERROR: cannot close '$file' after counting: $!\n";

    return $count;
}


sub progress_init {
    my ($total) = @_;

    $progress_total    = $total || 0;
    $progress_done     = 0;
    $progress_line_len = 0;

    my $want_progress = defined($progress_opt)
        ? $progress_opt
        : (-t STDOUT ? 1 : 0);

    $progress_active = $want_progress && !$quiet && !$verbose && $progress_total > 0;

    # Cap redraws at roughly 500 per run. A 16,000-torrent session therefore
    # redraws about every 32 torrents instead of writing 16,000 terminal lines.
    $progress_interval = int($progress_total / 500);
    $progress_interval = 1 if $progress_interval < 1;

    progress_draw() if $progress_active;
}


sub progress_step {
    return unless $progress_active;

    $progress_done++;
    $progress_done = $progress_total if $progress_done > $progress_total;

    if (
        $progress_done == $progress_total
        || ($progress_done % $progress_interval) == 0
    ) {
        progress_draw();
    }
}


sub progress_draw {
    return unless $progress_active;

    my $width = 36;
    my $ratio = $progress_total ? ($progress_done / $progress_total) : 1;
    $ratio = 0 if $ratio < 0;
    $ratio = 1 if $ratio > 1;

    my $filled = int($ratio * $width);
    $filled = $width if $progress_done >= $progress_total;

    my $bar = ('#' x $filled) . ('-' x ($width - $filled));
    my $pct = $ratio * 100;

    my $line = sprintf(
        "[%s] %6.2f%%  %d/%d  ok:%d  failed:%d  skipped:%d",
        $bar,
        $pct,
        $progress_done,
        $progress_total,
        $updated,
        $failed,
        $skipped,
    );

    my $padding = $progress_line_len > length($line)
        ? ' ' x ($progress_line_len - length($line))
        : '';

    print STDOUT "\r$line$padding";
    $progress_line_len = length($line);
}


sub progress_clear {
    return unless $progress_active && $progress_line_len;

    print STDOUT "\r", (' ' x $progress_line_len), "\r";
}


sub progress_finish {
    return unless $progress_active;

    $progress_done = $progress_total;
    progress_draw();
    print STDOUT "\n";

    $progress_active   = 0;
    $progress_line_len = 0;
}


sub handle_failure {
    my ($label, $message) = @_;

    $message =~ s/\s+$//;
    $message =~ s/\s+at\s+\Q$0\E\s+line\s+\d+\.?\s*$//;

    progress_clear();

    push @failure_records, [$label, $message];

    print STDERR "$label FAILED: $message\n";
    $failed++;

    if ($strict) {
        print STDERR "\nStopped because --strict was specified.\n";
        exit 1;
    }
}


sub usage {
    my ($exit_code) = @_;
    print usage_text();
    exit $exit_code;
}


sub usage_text {
    my $text = <<'USAGE';
Usage:
  __PROGRAM__ --session DIR [options]
  __PROGRAM__ --session DIR --data-dir DIR [options]
  __PROGRAM__ --session DIR [options] MAPPING_FILE

Required:
  -s, --session DIR        rTorrent split-session directory.

Input modes:
  Default                  Read each torrent's saved directory information
                           from HASH.torrent.rtorrent. The script scans all
                           HASH.torrent files in SESSION automatically.

  -d, --data-dir DIR       Override session paths with one common parent
                           directory containing the payload data for every
                           torrent in the session.

  MAPPING_FILE             Override session paths with per-torrent mappings
                           for mixed or moved storage.
  -m, --mapping FILE       Alternate way to specify MAPPING_FILE.

  --hash HASH              Process only HASH. May be repeated.
                           Comma-separated hashes are also accepted.
  --path-mode MODE         How payload paths are interpreted:
                             auto            detect per torrent (default)
                             directory       PATH/name/files for multi-file
                             directory-base  PATH/files for multi-file
                           Session mode uses a stored directory_base directly
                           when available; a stored directory is auto-detected
                           unless you force a mode.

Common data-directory examples:
  DATA/Movie.mkv                         single-file torrent
  DATA/Torrent.Name/file1                multi-file torrent
  DATA/Torrent.Name/subdir/file2

Mapping formats:
  HASH|PATH
  HASH|directory|PATH
  HASH|directory_base|PATH

Behavior:
  -n, --dry-run            Validate and calculate without writing.
      --priority N         Force file priority to N (0, 1, or 2).
                           Default: preserve existing priority; use 1 if absent.
      --set-directory      Update the .rtorrent directory field from the
                           resolved payload path. Otherwise preserve it.
      --start              Mark torrents started (state=1). Otherwise preserve
                           existing started/stopped state.
      --[no-]backup        Enable or disable per-torrent backups.
                           Backs up HASH.torrent plus both split sidecars.
                           Backups are enabled by default.
      --backup-dir DIR     Backup root directory. Default:
                           SESSION.fastresume-backups
                           Each run gets a timestamped subdirectory.
      --strict             Stop immediately on the first failure.

Output:
  -q, --quiet              Print only failures and final totals.
  -v, --verbose            Show torrent and per-file calculations.
      --[no-]progress      Enable or disable the in-place progress bar.
                           Default: enabled automatically on a terminal,
                           disabled when output is redirected or verbose.
                           Failures are always listed again at the end.
  -h, --help               Show this help.

Session files:
  HASH.torrent
  HASH.torrent.libtorrent_resume
  HASH.torrent.rtorrent

Examples:
  # Normal case: use the paths already saved in the session.
  __PROGRAM__ \
      --session /home/user/.session

  # Validate session-derived paths without changing anything.
  __PROGRAM__ \
      --session /home/user/.session \
      --dry-run

  # All torrents have been moved beneath one common directory.
  __PROGRAM__ \
      --session /home/user/.session \
      --data-dir /srv/torrents

  # Mixed or moved storage: use HASH|PATH mappings.
  __PROGRAM__ \
      --session /home/user/.session \
      mappings.txt

IMPORTANT:
  Stop rTorrent before writing session files. This script verifies file
  existence and exact sizes, but it does NOT hash payload data. Use it only
  when you already trust the data and need to reconstruct lost resume state.
USAGE

    $text =~ s/__PROGRAM__/$program/g;
    return $text;
}
