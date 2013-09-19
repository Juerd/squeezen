#!/usr/bin/perl
use strict;
no warnings;
use Curses;
use Curses::UI;
use URI::Escape qw(uri_escape uri_unescape);
use IO::Socket::INET;
use Socket qw(SOCK_STREAM);

{
    my $socket; 
    sub squeeze {
        my @args = @_;
        $_ = uri_escape($_) for @args;

        $socket && $socket->connected or $socket = IO::Socket::INET->new(
            PeerHost => "jukebox:9090",
            Type => SOCK_STREAM,
        ) or return;

        $socket->print("@args\n");
        my @reply = split " ", readline $socket;
        $_ = uri_unescape($_) for @reply;
        return @reply;
    }
}

sub ftime {
    my ($s) = @_;
    $s //= 0;
    my $m = int($s / 60);
    $s %= 60;
    return sprintf "%d:%02d", $m, $s;
}

my $player = "be:e0:e6:04:46:38";

if (@ARGV) {
    $ARGV[0] = $player if $ARGV[0] eq 'P';
    print "$_\n" for squeeze @ARGV;
    exit;
}

my $ui = Curses::UI->new(-compat => 0, -color_support => 1);
my $window = $ui->add(undef,  'Window');
my $in_modal = 0;

sub prev      { squeeze $player, qw'playlist index -1' }
sub next      { squeeze $player, qw'playlist index +1' }
sub playpause { squeeze $player, qw'pause' }
sub jump      { squeeze $player, qw'playlist index', (split /~/, shift->get)[0] }
sub volup     { squeeze $player, qw'mixer volume +2.5'; update_status(); }
sub voldown   { squeeze $player, qw'mixer volume -2.5'; update_status(); }
sub vol       { squeeze $player, qw'mixer volume', shift; update_status(); }
sub mute      { squeeze $player, qw'mixer muting'; update_status(); }

sub delete    {
    my ($nextlist) = @_;
    squeeze $player,qw'playlist delete', $nextlist->get_active_value;
    update_status();
}

my $current_folder;
my $bdialog;
sub browser_go {
    my ($browser, $action) = @_;
    my $pick = $browser->get || "";
    if ($action and $action eq "GO_BACK") {
        $pick = $browser->{__back} or return;
    }
    my $ypos;
    if ($pick =~ s/!(\d+)$//) {
        $ypos = $1;
    }
    if ($pick eq 'MIX') {
        squeeze $player, qw'randomplay tracks';
        update_status();
        $browser->clear_selection();
    } elsif ($pick eq 'CLEAR') {
        squeeze $player, qw'playlist clear';
        update_status();
        $browser->clear_selection();
    } elsif ($pick =~ /^folder~(.*)/) {
        my @path = split /\D/, $1;
        my @up = @path > 1 ? @path[0 .. ($#path - 1)] : ();

        my $fid = $path[-1];

        my %finfo = map { split /:/, $_, 2 } grep /:/,
            squeeze qw'musicfolder 0 1 return_top:1', "folder_id:$fid";

        my %parent = @up
            ? (
                map { split /:/, $_, 2 } grep /:/,
                squeeze qw'musicfolder 0 1 return_top:1', "folder_id:$up[-1]"
            )
            : ();

        my @folder = squeeze qw'musicfolder 0 2000 tags:at', "folder_id:$fid";
        my @items;
        while (defined (my $item = shift @folder)) {
            my ($key, $value) = split /:/, $item, 2;
            if ($key eq 'id') {
                push @items, { id => $value };
            } elsif (@items) {
                $items[-1]{$key} = $value;
            }
        }
        my $y = $browser->{-ypos};
        my $values = [ "HOME", (@up ? "folder~@up!$y" : ()), map {
            "$_->{type}~@path~$_->{id}"
        } @items ];
        my $labels = { "HOME" => "== Home ==", (@up ? ("folder~@up!$y" => "<- $parent{filename}") : ()),
        map { ("$_->{type}~@path~$_->{id}" => $_->{filename}) } @items };
        $browser->{__back} = @up ? "folder~@up!$y" : "HOME";
        $browser->title($finfo{filename});
        $browser->values($values);
        $browser->labels($labels);
        $browser->{-ypos} = $ypos // 1;
        $browser->draw();

        $current_folder = $fid;
    } elsif ($pick =~ /^(PLAY|ADD|INSERT)(?:~(\d))?~(\d+)/) {
        my $command = lc $1;
        my $skip = $2;
        my $id = $3;
        my $url = (grep /^url:/,
            squeeze qw'songinfo 0 100 tags:u', "track_id:$id")[0];
        $url =~ s/^url://;

        squeeze $player, qw'playlist', $command, $url;
        squeeze $player, qw'playlist index +1' if $skip;
        browser_go($browser, 'GO_BACK');
    } elsif ($pick =~ /~(\d+)$/) {
        my $id = $1;

        # Oh, this is so ugly.
        $pick =~ s///;
        $pick =~ s/^\w+/folder/;
        my $y = $browser->{-ypos};
        $browser->{__back} = "$pick!$y";

        $browser->title("What do you want me to do?");
        $browser->values([ "INSERT~1~$id", "INSERT~0~$id", "ADD~$id", "PLAY~$id", "$pick!$y" ]);
        $browser->labels({
            "INSERT~1~$id" => "Add to TOP of playlist and SKIP right to it",
            "INSERT~0~$id" => "Add to TOP of playlist",
            "ADD~$id" => "Add to BOTTOM of playlist",
            "PLAY~$id" => "Start new playlist with this song",
            "$pick!$y" => "<- Never mind",
        });
        $browser->draw();
    } else {
        $browser->title("Browser");
        $browser->values([ qw/MIX folder~0 CLEAR/ ]);
        $browser->labels({
            CLEAR => "Clear playlist",
            MIX => "Party mix",
            'folder~0' => "Browse music folder",
        });
        $browser->draw();
    }
}


sub help {
    $in_modal = 1;
    $ui->dialog(-title => "Help", -message => q{
    ? h             Help
    q               Quit

    Tab Enter ...   The usual GUI stuff

    + =             Volume louder
    -               Volume softer
    1 2 3 ... 0     Volume
    m `             Mute

    < ,             Previous
    p \ |           Play / Pause
    > .             Next
    });
    $in_modal = 0;
}

my %keys = (
    'h' => \&help,
    '?' => \&help,
    'q' => sub { exit },
    '+' => \&volup,
    '=' => \&volup,
    '-' => \&voldown,
    'p' => \&playpause,
    '\\' => \&playpause,
    '|' => \&playpause,
    '<' => \&prev,
    '>' => \&next,
    ',' => \&prev,
    '.' => \&next,
    '`' => \&mute,
    'm' => \&mute,
    '1' => sub { vol  10 },
    '2' => sub { vol  20 },
    '3' => sub { vol  30 },
    '4' => sub { vol  40 },
    '5' => sub { vol  50 },
    '6' => sub { vol  60 },
    '7' => sub { vol  70 },
    '8' => sub { vol  80 },
    '9' => sub { vol  90 },
    '0' => sub { vol 100 },
);
$ui->set_binding($keys{$_}, $_) for keys %keys;


my $title = $window->add(undef, 'Container',
    -releasefocus => 1,
    -border => 1,
    -height => 4,
    -titlereverse => 0,
);
my $time = $title->add(undef, 'Label' );
my $buttons = [
    { -label => '  <<  ', -onpress => \&prev },
    { -label => '  PP  ', -onpress => \&playpause },
    { -label => '  >>  ', -onpress => \&next },
];

$title->add(undef, 'Buttonbox',
    -y => 1,
    -buttons => $buttons
);

my $nextlist = $window->add(undef, 'Listbox',
    -border => 1,
    -height => 8,
    -y => 4,
    -title => "Playlist",
    -titlereverse => 0,
    -onchange => \&jump,
    -vscrollbar => 'right',
);
$nextlist->set_binding(\&delete, KEY_DC());

my $browser = $window->add(undef, 'Listbox',
    -y => 12,
    -border => 1,
    -height => 10,
    -titlereverse => 0,
    -onchange => \&browser_go,
    -vscrollbar => 'right',
);
$browser->set_binding(sub {
    browser_go($browser, "GO_BACK");
}, KEY_LEFT());


$title->set_binding(sub { $browser->focus }, KEY_BTAB);
$title->set_binding(sub { $nextlist->focus }, "\t");

browser_go($browser);
update_status();

$ui->set_timer(1, sub {
    update_status()
});

$ui->mainloop;

#  meh, globals :)

sub update_status {
    my @status = squeeze $player, qw'status - 20';
    my @playlist;
    my %status;
    while (defined ($_ = shift @status)) {
        my ($key, $value) = split ':', $_, 2;
        if ($key eq 'playlist index') {
            push @playlist, { index => $value };
        } elsif (@playlist) {
            $playlist[-1]{ $key } = $value;
        } else {
            $status{$key} = $value;
        }
    }

    my $t = ftime($status{time}) . ' / ' . ftime($status{duration});
    $status{'mixer volume'} //= 0;
    my $v = $status{'mixer volume'} > 0
        ? sprintf "[-%-40s+]", '#' x ($status{'mixer volume'} / 2.5)
        : sprintf "* MUTE *";
    my $i = 0;
    # $v =~ s[#]{ my $n = int((++$i + 3) / 4); $n < 10 ? $n : 0 }ge;
    my $pos = $time->width() - length($v);
    $time->text(sprintf "%-${pos}s%s", $t, $v);

    $status{mode} //= 'pause';
    $buttons->[1]{-label} = $status{mode} eq 'pause' ? '  >   ' : '  ||  ';

    my $np = (grep { $_->{index} == $status{playlist_cur_index} } @playlist)[0];
    $title->title($np ? "$np->{artist} - $np->{title}" : "Silence");

    my $ypos = $nextlist->{-ypos};
    (undef, my $song_id) = split /~/, $nextlist->get_active_value // "~-1";
    unless ($in_modal) {
        for (0..$#playlist) {
            $ypos = $_ if $playlist[$_]->{id} == $song_id;
        }
        $nextlist->values(
            [ map "$_->{index}~$_->{id}", @playlist ]
        );
        $nextlist->labels( { map {
            ("$_->{index}~$_->{id}" => "$_->{artist} - $_->{title}")
        } @playlist });
        $nextlist->{-ypos} = $ypos;
        $nextlist->draw();
    }
}
